//! Packfiles (`.pack` v2/v3) read through their idx v2: entry headers,
//! zlib-inflated data, and OFS_DELTA/REF_DELTA chains resolved iteratively
//! with a shared delta-base cache.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const object = @import("../object.zig");
const zlib = @import("../zlib.zig");
const delta = @import("delta.zig");
const idx_mod = @import("idx.zig");
const cache_mod = @import("cache.zig");
const MappedFile = @import("../mapped.zig").MappedFile;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const ObjectType = object.ObjectType;
const Object = object.Object;
const PackIndex = idx_mod.PackIndex;
const DeltaBaseCache = cache_mod.DeltaBaseCache;
const Allocator = std.mem.Allocator;

/// Errors from reading pack entries. `CorruptPack` is also reported when an
/// entry's offset lies outside the pack (see `last_error_offset`).
pub const ReadError = error{ CorruptPack, MissingBase } || Allocator.Error;

/// Errors opening a pack.
pub const OpenError = ReadError || idx_mod.Error || @import("../mapped.zig").Error;

/// Pack entry type numbers.
pub const EntryKind = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,

    /// The object type for non-delta kinds.
    pub fn objectType(k: EntryKind) ?ObjectType {
        return switch (k) {
            .ofs_delta, .ref_delta => null,
            else => @enumFromInt(@intFromEnum(k)),
        };
    }
};

/// Delta base reference of an entry.
pub const Base = union(enum) {
    /// Not a delta.
    none,
    /// OFS_DELTA: absolute offset of the base entry.
    offset: u64,
    /// REF_DELTA: object name of the base.
    oid: Oid,
};

/// A decoded entry header.
pub const EntryHeader = struct {
    /// Entry type.
    kind: EntryKind,
    /// Inflated size (object size, or delta size for deltas).
    size: u64,
    /// Delta base, if any.
    base: Base,
    /// Offset of the zlib data.
    data_offset: u64,
};

/// Maximum delta chain length followed before declaring the pack corrupt
/// (REF_DELTA entries could otherwise form cycles).
pub const max_chain = 10_000;

/// Parses the entry header at `off` in pack bytes `data` (excluding the
/// trailer; pass `data[0 .. len - hash_len]`).
pub fn parseEntryHeader(data: []const u8, off: u64, fmt: ObjectFormat) error{CorruptPack}!EntryHeader {
    if (off < 12 or off >= data.len) return error.CorruptPack;
    var p: usize = @intCast(off);
    var b = data[p];
    p += 1;
    const kind_n: u3 = @truncate(b >> 4);
    if (kind_n == 0 or kind_n == 5) return error.CorruptPack;
    const kind: EntryKind = @enumFromInt(kind_n);
    var size: u64 = b & 15;
    var shift: u7 = 4;
    while (b & 0x80 != 0) {
        if (p >= data.len or shift > 60) return error.CorruptPack;
        b = data[p];
        p += 1;
        size |= @as(u64, b & 0x7f) << @intCast(shift);
        shift += 7;
    }
    var base: Base = .none;
    switch (kind) {
        .ofs_delta => {
            if (p >= data.len) return error.CorruptPack;
            b = data[p];
            p += 1;
            var v: u64 = b & 0x7f;
            while (b & 0x80 != 0) {
                if (p >= data.len or v >= (1 << 56)) return error.CorruptPack;
                b = data[p];
                p += 1;
                v = ((v + 1) << 7) | (b & 0x7f);
            }
            if (v == 0 or v >= off) return error.CorruptPack;
            base = .{ .offset = off - v };
        },
        .ref_delta => {
            const hl = fmt.len();
            if (p + hl > data.len) return error.CorruptPack;
            base = .{ .oid = .fromBytes(fmt, data[p..][0..hl]) };
            p += hl;
        },
        else => {},
    }
    return .{ .kind = kind, .size = size, .base = base, .data_offset = p };
}

/// An open pack with its index.
pub const Pack = struct {
    /// Identifier unique within an `Odb` (cache key).
    id: u32,
    /// Hash function of the repository.
    format: ObjectFormat,
    /// Whole pack file.
    bytes: []const u8,
    /// Its idx.
    index: PackIndex,
    /// Number of objects (from the pack header).
    count: u32,
    /// Base name without extension, e.g. "pack-1234…" (owned when opened
    /// from disk).
    name: []const u8 = "",
    pack_file: MappedFile,
    idx_file: MappedFile,
    rev: ?@import("rev.zig").RevIndex = null,

    /// Pack data without the trailer.
    pub fn body(p: *const Pack) []const u8 {
        return p.bytes[0 .. p.bytes.len - p.format.len()];
    }

    /// Opens `<stem>.pack` and `<stem>.idx` in `dir`.
    pub fn open(gpa: Allocator, io: std.Io, dir: std.Io.Dir, stem: []const u8, fmt: ObjectFormat, id: u32) OpenError!*Pack {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const pack_path = std.fmt.bufPrint(&pbuf, "{s}.pack", .{stem}) catch return error.CorruptPack;
        var pf = try MappedFile.open(gpa, io, dir, pack_path);
        errdefer pf.close(gpa, io);
        const idx_path = std.fmt.bufPrint(&pbuf, "{s}.idx", .{stem}) catch return error.CorruptPack;
        var xf = try MappedFile.open(gpa, io, dir, idx_path);
        errdefer xf.close(gpa, io);
        const p = try gpa.create(Pack);
        errdefer gpa.destroy(p);
        p.* = try init(pf, xf, fmt, id);
        p.name = try gpa.dupe(u8, std.fs.path.basename(stem));
        return p;
    }

    /// Builds a pack over already-loaded files and validates that the pack
    /// header, object count and checksum agree with the index.
    pub fn init(pack_file: MappedFile, idx_file: MappedFile, fmt: ObjectFormat, id: u32) (idx_mod.Error || error{CorruptPack})!Pack {
        const data = pack_file.bytes;
        const hl = fmt.len();
        if (data.len < 12 + hl) return error.CorruptPack;
        if (!std.mem.eql(u8, data[0..4], "PACK")) return error.CorruptPack;
        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != 2 and version != 3) return error.CorruptPack;
        const count = std.mem.readInt(u32, data[8..12], .big);
        const index = try PackIndex.parse(idx_file.bytes, fmt);
        if (index.count() != count) return error.CorruptPack;
        if (!std.mem.eql(u8, index.packChecksum(), data[data.len - hl ..])) return error.CorruptPack;
        return .{
            .id = id,
            .format = fmt,
            .bytes = data,
            .index = index,
            .count = count,
            .pack_file = pack_file,
            .idx_file = idx_file,
        };
    }

    /// Closes the files (and frees `p` when it came from `open`).
    pub fn close(p: *Pack, gpa: Allocator, io: std.Io) void {
        if (p.rev) |*r| r.deinit(gpa);
        p.pack_file.close(gpa, io);
        p.idx_file.close(gpa, io);
        if (p.name.len > 0) {
            gpa.free(p.name);
            gpa.destroy(p);
        }
    }

    /// The entry header at `off`.
    pub fn entryHeader(p: *const Pack, off: u64) error{CorruptPack}!EntryHeader {
        return parseEntryHeader(p.body(), off, p.format);
    }

    /// Offset of `id` in this pack, or null.
    pub fn find(p: *const Pack, id: Oid) ?u64 {
        const pos = p.index.find(id) orelse return null;
        return p.index.offset(pos);
    }

    /// Inflates the data of an entry into a new buffer of `h.size` bytes.
    pub fn inflate(p: *const Pack, gpa: Allocator, h: EntryHeader) ReadError![]u8 {
        if (h.size > std.math.maxInt(usize) or h.size > p.bytes.len * 1032 + 1024) return error.CorruptPack;
        const out = try gpa.alloc(u8, @intCast(h.size));
        errdefer gpa.free(out);
        var r: std.Io.Reader = .fixed(p.body()[@intCast(h.data_offset)..]);
        zlib.inflateExact(&r, out) catch return error.CorruptPack;
        return out;
    }

    fn baseOffset(p: *const Pack, h: EntryHeader) ReadError!u64 {
        return switch (h.base) {
            .none => unreachable,
            .offset => |o| o,
            .oid => |id| p.find(id) orelse error.MissingBase,
        };
    }

    /// Reads the object at `off`, resolving delta chains. Bases met on the
    /// way are cached in `cache`.
    pub fn readAt(p: *const Pack, gpa: Allocator, cache: ?*DeltaBaseCache, off: u64) ReadError!Object {
        var chain: std.ArrayList(u64) = .empty;
        defer chain.deinit(gpa);
        var cur = off;
        var base: Object = while (true) {
            if (cur != off) if (cache) |c| {
                if (try c.get(gpa, .{ .pack = p.id, .offset = cur })) |hit| break .{ .type = hit.type, .data = hit.data };
            };
            const h = try p.entryHeader(cur);
            if (h.kind.objectType()) |t| break .{ .type = t, .data = try p.inflate(gpa, h) };
            if (chain.items.len >= max_chain) return error.CorruptPack;
            try chain.append(gpa, cur);
            cur = try p.baseOffset(h);
        };
        errdefer gpa.free(base.data);
        var i = chain.items.len;
        while (i > 0) {
            i -= 1;
            if (cache) |c| c.put(.{ .pack = p.id, .offset = cur }, base.type, base.data);
            cur = chain.items[i];
            const h = try p.entryHeader(cur);
            const d = try p.inflate(gpa, h);
            defer gpa.free(d);
            const dh = delta.parseHeader(d) catch return error.CorruptPack;
            if (dh.result_size > std.math.maxInt(usize)) return error.CorruptPack;
            const out = try gpa.alloc(u8, @intCast(dh.result_size));
            delta.applyDelta(base.data, d, out) catch {
                gpa.free(out);
                return error.CorruptPack;
            };
            gpa.free(base.data);
            base.data = out;
        }
        return base;
    }

    /// Type and size of the object at `off` without inflating non-delta
    /// entries; deltas inflate only their first bytes and walk base headers.
    pub fn readHeaderAt(p: *const Pack, off: u64) ReadError!struct { type: ObjectType, size: u64 } {
        const h = try p.entryHeader(off);
        if (h.kind.objectType()) |t| return .{ .type = t, .size = h.size };
        var buf: [512]u8 = undefined;
        var r: std.Io.Reader = .fixed(p.body()[@intCast(h.data_offset)..]);
        const prefix = zlib.inflatePrefix(&r, &buf) catch return error.CorruptPack;
        const dh = delta.parseHeader(prefix) catch return error.CorruptPack;
        var cur = try p.baseOffset(h);
        var steps: usize = 0;
        while (true) : (steps += 1) {
            if (steps >= max_chain) return error.CorruptPack;
            const bh = try p.entryHeader(cur);
            if (bh.kind.objectType()) |t| return .{ .type = t, .size = dh.result_size };
            cur = try p.baseOffset(bh);
        }
    }
};

const testdata = @import("../testdata.zig");

test "pack: read all objects from fixture packs (sha1+sha256) and verify hashes" {
    const t = std.testing;
    const gpa = t.allocator;
    for ([_]ObjectFormat{ .sha1, .sha256 }) |fmt| {
        var fx = try testdata.Fixture.open(gpa, t.io, fmt);
        defer fx.close();
        var cache: DeltaBaseCache = .init(gpa, t.io, 1 << 20);
        defer cache.deinit();
        var total: usize = 0;
        for (fx.packs.items) |p| {
            var pos: u32 = 0;
            while (pos < p.index.count()) : (pos += 1) {
                const id = p.index.oidAt(pos);
                var o = try p.readAt(gpa, &cache, p.index.offset(pos));
                defer o.deinit(gpa);
                try t.expect(object.hashObject(fmt, o.type, o.data).eql(id));
                const hh = try p.readHeaderAt(p.index.offset(pos));
                try t.expectEqual(o.type, hh.type);
                try t.expectEqual(@as(u64, o.data.len), hh.size);
                const want = fx.expected.get(id).?;
                try t.expectEqual(want.type, o.type);
                try t.expectEqual(want.size, o.data.len);
                total += 1;
            }
        }
        try t.expect(total > 100);
    }
}
