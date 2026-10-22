//! Pack index v2 (`.idx`): fanout, sorted object names, CRC32s and 31/64-bit
//! offsets. Read over mapped bytes; also written by the indexer.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;

/// Errors for malformed index files.
pub const Error = error{CorruptIndex};

/// idx v2 magic.
pub const magic = "\xfftOc";

/// A parsed view over idx v2 bytes. Lookups do not allocate.
pub const PackIndex = struct {
    bytes: []const u8,
    format: ObjectFormat,
    n: u32,
    names: usize,
    crcs: usize,
    off32: usize,
    off64: usize,
    off64_count: usize,

    /// Validates the header and table sizes of an idx v2 file.
    pub fn parse(bytes: []const u8, fmt: ObjectFormat) Error!PackIndex {
        const hl = fmt.len();
        if (bytes.len < 8 + 1024 + 2 * hl) return error.CorruptIndex;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.CorruptIndex;
        if (readU32(bytes, 4) != 2) return error.CorruptIndex;
        var prev: u32 = 0;
        for (0..256) |i| {
            const f = readU32(bytes, 8 + i * 4);
            if (f < prev) return error.CorruptIndex;
            prev = f;
        }
        const n = prev;
        const names: usize = 8 + 1024;
        const crcs = names + @as(usize, n) * hl;
        const off32 = crcs + @as(usize, n) * 4;
        const off64 = off32 + @as(usize, n) * 4;
        if (off64 + 2 * hl > bytes.len) return error.CorruptIndex;
        const rest = bytes.len - 2 * hl - off64;
        if (rest % 8 != 0) return error.CorruptIndex;
        return .{
            .bytes = bytes,
            .format = fmt,
            .n = n,
            .names = names,
            .crcs = crcs,
            .off32 = off32,
            .off64 = off64,
            .off64_count = rest / 8,
        };
    }

    /// Number of objects.
    pub fn count(ix: *const PackIndex) u32 {
        return ix.n;
    }

    fn name(ix: *const PackIndex, pos: u32) []const u8 {
        const hl = ix.format.len();
        return ix.bytes[ix.names + @as(usize, pos) * hl ..][0..hl];
    }

    /// Object name at sorted position `pos`.
    pub fn oidAt(ix: *const PackIndex, pos: u32) Oid {
        return .fromBytes(ix.format, ix.name(pos));
    }

    /// Sorted position of `id`, or null.
    pub fn find(ix: *const PackIndex, id: Oid) ?u32 {
        const key = id.slice();
        const first = key[0];
        var lo: u32 = if (first == 0) 0 else readU32(ix.bytes, 8 + (@as(usize, first) - 1) * 4);
        var hi: u32 = readU32(ix.bytes, 8 + @as(usize, first) * 4);
        // Lower bound over [lo, hi).
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, ix.name(mid), key)) {
                .lt => lo = mid + 1,
                .eq => return mid,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// Pack offset of the object at `pos`; null when a 64-bit offset points
    /// outside the large-offset table.
    pub fn offsetChecked(ix: *const PackIndex, pos: u32) ?u64 {
        const o = readU32(ix.bytes, ix.off32 + @as(usize, pos) * 4);
        if (o & 0x8000_0000 == 0) return o;
        const i: usize = o & 0x7fff_ffff;
        if (i >= ix.off64_count) return null;
        return std.mem.readInt(u64, ix.bytes[ix.off64 + i * 8 ..][0..8], .big);
    }

    /// Pack offset of the object at `pos` (31-bit or 64-bit table). A broken
    /// large-offset reference returns maxInt, which pack reads reject.
    pub fn offset(ix: *const PackIndex, pos: u32) u64 {
        return ix.offsetChecked(pos) orelse std.math.maxInt(u64);
    }

    /// CRC32 of the packed entry at `pos`.
    pub fn crc32(ix: *const PackIndex, pos: u32) u32 {
        return readU32(ix.bytes, ix.crcs + @as(usize, pos) * 4);
    }

    /// Checksum of the pack this index describes.
    pub fn packChecksum(ix: *const PackIndex) []const u8 {
        const hl = ix.format.len();
        return ix.bytes[ix.bytes.len - 2 * hl ..][0..hl];
    }

    /// Whether the trailing checksum matches the file contents.
    pub fn verifyChecksum(ix: *const PackIndex) bool {
        const hl = ix.format.len();
        const h = oid_mod.hashBytes(ix.format, ix.bytes[0 .. ix.bytes.len - hl]);
        return std.mem.eql(u8, h.slice(), ix.bytes[ix.bytes.len - hl ..]);
    }
};

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}

/// One object for `writeIndex`.
pub const Entry = struct {
    /// Object name.
    oid: Oid,
    /// CRC32 of the raw packed entry.
    crc32: u32,
    /// Offset in the pack.
    offset: u64,

    /// Orders by object name.
    pub fn lessThan(_: void, a: Entry, b: Entry) bool {
        return a.oid.order(b.oid) == .lt;
    }
};

/// Writes an idx v2 file for `entries`, which must be sorted by Oid
/// (`Entry.lessThan`). Returns the idx checksum.
pub fn writeIndex(w: *std.Io.Writer, fmt: ObjectFormat, entries: []const Entry, pack_checksum: []const u8) std.Io.Writer.Error!Oid {
    var hasher = oid_mod.Hasher.init(fmt);
    var hbuf: [256]u8 = undefined;
    var hw = w.hashed(&hasher, &hbuf);
    const o = &hw.writer;
    try o.writeAll(magic);
    try o.writeInt(u32, 2, .big);
    var bucket: usize = 0;
    for (0..256) |i| {
        while (bucket < entries.len and entries[bucket].oid.bytes[0] <= i) bucket += 1;
        try o.writeInt(u32, @intCast(bucket), .big);
    }
    for (entries) |e| try o.writeAll(e.oid.slice());
    for (entries) |e| try o.writeInt(u32, e.crc32, .big);
    var large: u32 = 0;
    for (entries) |e| {
        if (e.offset < 0x8000_0000) {
            try o.writeInt(u32, @intCast(e.offset), .big);
        } else {
            try o.writeInt(u32, 0x8000_0000 | large, .big);
            large += 1;
        }
    }
    for (entries) |e| if (e.offset >= 0x8000_0000) try o.writeInt(u64, e.offset, .big);
    try o.writeAll(pack_checksum);
    try o.flush();
    const sum = hasher.final();
    try w.writeAll(sum.slice());
    return sum;
}

test "idx: fixture lookups incl 64-bit offsets" {
    const t = std.testing;
    const gpa = t.allocator;
    // Synthetic index with one offset past 2 GiB.
    var entries = [_]Entry{
        .{ .oid = oid_mod.hashBytes(.sha1, "a"), .crc32 = 1, .offset = 12 },
        .{ .oid = oid_mod.hashBytes(.sha1, "b"), .crc32 = 2, .offset = 0x1_2345_6789 },
        .{ .oid = oid_mod.hashBytes(.sha1, "c"), .crc32 = 3, .offset = 0x7fff_ffff },
        .{ .oid = oid_mod.hashBytes(.sha1, "d"), .crc32 = 4, .offset = 0x8000_0000 },
    };
    std.mem.sort(Entry, &entries, {}, Entry.lessThan);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = try writeIndex(&aw.writer, .sha1, &entries, &(@as([20]u8, @splat(7))));
    const ix = try PackIndex.parse(aw.written(), .sha1);
    try t.expect(ix.verifyChecksum());
    try t.expectEqual(@as(u32, 4), ix.count());
    try t.expectEqual(@as(usize, 2), ix.off64_count);
    for (entries) |e| {
        const pos = ix.find(e.oid).?;
        try t.expectEqual(e.offset, ix.offset(pos));
        try t.expectEqual(e.crc32, ix.crc32(pos));
        try t.expect(ix.oidAt(pos).eql(e.oid));
    }
    try t.expect(ix.find(oid_mod.hashBytes(.sha1, "zz")) == null);
    try t.expectError(error.CorruptIndex, PackIndex.parse(aw.written()[0 .. aw.written().len - 3], .sha1));
}
