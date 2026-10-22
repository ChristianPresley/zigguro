//! Reverse indexes (`.rev`): idx positions in pack-offset order, so an offset
//! maps to its object and entry sizes come from neighbouring offsets. Read
//! from disk when present, else computed from the idx.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const PackIndex = @import("idx.zig").PackIndex;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;

/// Errors for malformed `.rev` files.
pub const Error = error{CorruptRev};

/// `.rev` magic.
pub const magic = "RIDX";

/// Positions of idx entries sorted by pack offset.
pub const RevIndex = struct {
    /// Big-endian u32 table from a mapped `.rev` file.
    mapped: ?[]const u8 = null,
    /// Computed table.
    owned: ?[]u32 = null,
    n: u32,

    /// Validates a `.rev` file for an index with `count` objects.
    pub fn parse(bytes: []const u8, fmt: ObjectFormat, count: u32) Error!RevIndex {
        const hl = fmt.len();
        const need = 12 + @as(usize, count) * 4 + 2 * hl;
        if (bytes.len != need) return error.CorruptRev;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.CorruptRev;
        if (std.mem.readInt(u32, bytes[4..8], .big) != 1) return error.CorruptRev;
        if (std.mem.readInt(u32, bytes[8..12], .big) != fmt.hashVersion()) return error.CorruptRev;
        return .{ .mapped = bytes[12..][0 .. @as(usize, count) * 4], .n = count };
    }

    /// Computes the table by sorting idx positions by offset.
    pub fn compute(gpa: Allocator, ix: *const PackIndex) Allocator.Error!RevIndex {
        const n = ix.count();
        const pos = try gpa.alloc(u32, n);
        for (pos, 0..) |*p, i| p.* = @intCast(i);
        std.mem.sort(u32, pos, ix, struct {
            fn lt(x: *const PackIndex, a: u32, b: u32) bool {
                return x.offset(a) < x.offset(b);
            }
        }.lt);
        return .{ .owned = pos, .n = n };
    }

    /// Frees a computed table.
    pub fn deinit(r: *RevIndex, gpa: Allocator) void {
        if (r.owned) |o| gpa.free(o);
        r.* = undefined;
    }

    /// idx position of the `i`-th entry in pack order.
    pub fn position(r: *const RevIndex, i: u32) u32 {
        if (r.owned) |o| return o[i];
        return std.mem.readInt(u32, r.mapped.?[@as(usize, i) * 4 ..][0..4], .big);
    }

    /// Pack-order index of the entry at `off`, or null.
    pub fn findOffset(r: *const RevIndex, ix: *const PackIndex, off: u64) ?u32 {
        var lo: u32 = 0;
        var hi: u32 = r.n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const o = ix.offset(r.position(mid));
            if (o < off) lo = mid + 1 else if (o > off) hi = mid else return mid;
        }
        return null;
    }

    /// Offset where the entry following `off` begins (the trailer start for
    /// the last entry): `end - off` is the raw entry size.
    pub fn entryEnd(r: *const RevIndex, ix: *const PackIndex, off: u64, pack_len: u64) ?u64 {
        const i = r.findOffset(ix, off) orelse return null;
        if (i + 1 < r.n) return ix.offset(r.position(i + 1));
        return pack_len - ix.format.len();
    }
};

/// Writes a `.rev` file for positions in pack order.
pub fn writeRev(w: *std.Io.Writer, fmt: ObjectFormat, positions: []const u32, pack_checksum: []const u8) std.Io.Writer.Error!void {
    var hasher = oid_mod.Hasher.init(fmt);
    var hbuf: [256]u8 = undefined;
    var hw = w.hashed(&hasher, &hbuf);
    const o = &hw.writer;
    try o.writeAll(magic);
    try o.writeInt(u32, 1, .big);
    try o.writeInt(u32, fmt.hashVersion(), .big);
    for (positions) |p| try o.writeInt(u32, p, .big);
    try o.writeAll(pack_checksum);
    try o.flush();
    try w.writeAll(hasher.final().slice());
}

test "rev: matches computed" {
    const t = std.testing;
    const gpa = t.allocator;
    const testdata = @import("../testdata.zig");
    for ([_]ObjectFormat{ .sha1, .sha256 }) |fmt| {
        var fx = try testdata.Fixture.open(gpa, t.io, fmt);
        defer fx.close();
        var pd = try fx.packDir();
        defer pd.close(t.io);
        for (fx.packs.items) |p| {
            var buf: [256]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "{s}.rev", .{p.name});
            const bytes = try pd.readFileAlloc(t.io, name, gpa, .limited(1 << 20));
            defer gpa.free(bytes);
            const disk = try RevIndex.parse(bytes, fmt, p.index.count());
            var calc = try RevIndex.compute(gpa, &p.index);
            defer calc.deinit(gpa);
            var i: u32 = 0;
            while (i < calc.n) : (i += 1) try t.expectEqual(calc.position(i), disk.position(i));
            // Our writer reproduces git's file byte for byte.
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try writeRev(&aw.writer, fmt, calc.owned.?, p.index.packChecksum());
            try t.expectEqualSlices(u8, bytes, aw.written());
            const first = p.index.offset(calc.position(0));
            try t.expectEqual(@as(u64, 12), first);
            try t.expectEqual(@as(?u32, 0), calc.findOffset(&p.index, 12));
            try t.expect(calc.findOffset(&p.index, 13) == null);
        }
    }
}
