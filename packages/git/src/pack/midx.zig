//! Multi-pack-index (`objects/pack/multi-pack-index`, v1/v2), read-only:
//! one sorted object table across many packs. PNAM, OIDF, OIDL, OOFF and
//! LOFF are used; RIDX, BTMP and unknown chunks are ignored.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;

/// Errors for malformed midx files.
pub const Error = error{CorruptMidx};

/// A located object.
pub const Location = struct {
    /// Index into `packNames()` order.
    pack: u32,
    /// Offset in that pack.
    offset: u64,
};

/// A parsed view over midx bytes. Lookups do not allocate.
pub const Midx = struct {
    bytes: []const u8,
    format: ObjectFormat,
    pack_count: u32,
    n: u32,
    pnam: []const u8,
    oidf: usize,
    oidl: usize,
    ooff: usize,
    loff: ?[]const u8,

    /// Validates the header and chunk table.
    pub fn parse(bytes: []const u8, fmt: ObjectFormat) Error!Midx {
        const hl = fmt.len();
        if (bytes.len < 12 + hl) return error.CorruptMidx;
        if (!std.mem.eql(u8, bytes[0..4], "MIDX")) return error.CorruptMidx;
        if (bytes[4] != 1 and bytes[4] != 2) return error.CorruptMidx;
        if (bytes[5] != fmt.hashVersion()) return error.CorruptMidx;
        const chunks = bytes[6];
        if (bytes[7] != 0) return error.CorruptMidx; // incremental chains are not supported
        const pack_count = std.mem.readInt(u32, bytes[8..12], .big);
        const table_end = 12 + (@as(usize, chunks) + 1) * 12;
        const data_end = bytes.len - hl;
        if (table_end > data_end) return error.CorruptMidx;

        var pnam: ?[]const u8 = null;
        var oidf: ?[]const u8 = null;
        var oidl: ?[]const u8 = null;
        var ooff: ?[]const u8 = null;
        var loff: ?[]const u8 = null;
        for (0..chunks) |i| {
            const e = bytes[12 + i * 12 ..];
            const next = bytes[12 + (i + 1) * 12 ..];
            const start = std.mem.readInt(u64, e[4..12], .big);
            const end = std.mem.readInt(u64, next[4..12], .big);
            if (start < table_end or end < start or end > data_end) return error.CorruptMidx;
            const chunk = bytes[@intCast(start)..@intCast(end)];
            const id = e[0..4];
            if (std.mem.eql(u8, id, "PNAM")) pnam = chunk else if (std.mem.eql(u8, id, "OIDF")) oidf = chunk else if (std.mem.eql(u8, id, "OIDL")) oidl = chunk else if (std.mem.eql(u8, id, "OOFF")) ooff = chunk else if (std.mem.eql(u8, id, "LOFF")) loff = chunk;
        }
        if (std.mem.readInt(u32, bytes[12 + @as(usize, chunks) * 12 ..][0..4], .big) != 0) return error.CorruptMidx;
        const f = oidf orelse return error.CorruptMidx;
        const l = oidl orelse return error.CorruptMidx;
        const o = ooff orelse return error.CorruptMidx;
        const p = pnam orelse return error.CorruptMidx;
        if (f.len != 1024) return error.CorruptMidx;
        var prev: u32 = 0;
        for (0..256) |i| {
            const v = std.mem.readInt(u32, f[i * 4 ..][0..4], .big);
            if (v < prev) return error.CorruptMidx;
            prev = v;
        }
        const n = prev;
        if (l.len != @as(usize, n) * hl or o.len != @as(usize, n) * 8) return error.CorruptMidx;
        if (loff) |lo| if (lo.len % 8 != 0) return error.CorruptMidx;
        const m: Midx = .{
            .bytes = bytes,
            .format = fmt,
            .pack_count = pack_count,
            .n = n,
            .pnam = p,
            .oidf = f.ptr - bytes.ptr,
            .oidl = l.ptr - bytes.ptr,
            .ooff = o.ptr - bytes.ptr,
            .loff = loff,
        };
        var it = m.packNames();
        var names: u32 = 0;
        while (it.next()) |_| names += 1;
        if (names != pack_count) return error.CorruptMidx;
        return m;
    }

    /// Iterator over pack names ("pack-….idx"), in pack-int-id order.
    pub fn packNames(m: *const Midx) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, m.pnam, 0);
    }

    /// Number of objects.
    pub fn count(m: *const Midx) u32 {
        return m.n;
    }

    fn name(m: *const Midx, pos: u32) []const u8 {
        const hl = m.format.len();
        return m.bytes[m.oidl + @as(usize, pos) * hl ..][0..hl];
    }

    /// Object name at sorted position `pos`.
    pub fn oidAt(m: *const Midx, pos: u32) Oid {
        return .fromBytes(m.format, m.name(pos));
    }

    /// Location of the object at `pos`; null when it references a missing
    /// large offset or pack.
    pub fn locationAt(m: *const Midx, pos: u32) ?Location {
        const e = m.bytes[m.ooff + @as(usize, pos) * 8 ..][0..8];
        const pack = std.mem.readInt(u32, e[0..4], .big);
        if (pack >= m.pack_count) return null;
        const off = std.mem.readInt(u32, e[4..8], .big);
        if (off & 0x8000_0000 == 0) return .{ .pack = pack, .offset = off };
        const lo = m.loff orelse return null;
        const i: usize = off & 0x7fff_ffff;
        if ((i + 1) * 8 > lo.len) return null;
        return .{ .pack = pack, .offset = std.mem.readInt(u64, lo[i * 8 ..][0..8], .big) };
    }

    /// Finds `id`.
    pub fn find(m: *const Midx, id: Oid) ?Location {
        const key = id.slice();
        const first = key[0];
        var lo: u32 = if (first == 0) 0 else std.mem.readInt(u32, m.bytes[m.oidf + (@as(usize, first) - 1) * 4 ..][0..4], .big);
        var hi: u32 = std.mem.readInt(u32, m.bytes[m.oidf + @as(usize, first) * 4 ..][0..4], .big);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, m.name(mid), key)) {
                .lt => lo = mid + 1,
                .eq => return m.locationAt(mid),
                .gt => hi = mid,
            }
        }
        return null;
    }
};

test "midx: lookup equals per-pack" {
    const t = std.testing;
    const gpa = t.allocator;
    const testdata = @import("../testdata.zig");
    for ([_]ObjectFormat{ .sha1, .sha256 }) |fmt| {
        var fx = try testdata.Fixture.open(gpa, t.io, fmt);
        defer fx.close();
        var pd = try fx.packDir();
        defer pd.close(t.io);
        const bytes = try pd.readFileAlloc(t.io, "multi-pack-index", gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        const m = try Midx.parse(bytes, fmt);
        var names: [8][]const u8 = undefined;
        var it = m.packNames();
        var k: usize = 0;
        while (it.next()) |nm| : (k += 1) names[k] = nm;
        try t.expectEqual(fx.packs.items.len, k);
        var total: u32 = 0;
        for (fx.packs.items) |p| {
            const pi = for (names[0..k], 0..) |nm, i| {
                if (std.mem.startsWith(u8, nm, p.name)) break i;
            } else return error.TestUnexpectedResult;
            var pos: u32 = 0;
            while (pos < p.index.count()) : (pos += 1) {
                const id = p.index.oidAt(pos);
                const loc = m.find(id).?;
                // An object in several packs is attributed to one of them.
                if (loc.pack == pi) try t.expectEqual(p.index.offset(pos), loc.offset);
            }
            total += p.index.count();
        }
        try t.expect(m.count() <= total);
        try t.expect(m.find(Oid.zero(fmt)) == null);
        try t.expectError(error.CorruptMidx, Midx.parse(bytes[0 .. bytes.len - 5], fmt));
    }
}
