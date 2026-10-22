//! The sfnt table directory and the TTC (font collection) header.

const std = @import("std");
const reader = @import("reader.zig");
const Reader = reader.Reader;
const Tag = reader.Tag;
const tag = reader.tag;

/// Tables that `Face` locates at init time, in a fixed array.
pub const KnownTag = enum {
    cmap,
    head,
    hhea,
    hmtx,
    maxp,
    name,
    os2,
    post,
    glyf,
    loca,
    cff,
    cff2,
    gsub,
    gpos,
    gdef,
    kern,
    fvar,
    avar,
    gvar,
    hvar,
    mvar,
    colr,
    cpal,
    sbix,
    cbdt,
    cblc,
    stat,

    /// Number of known tags.
    pub const count = @typeInfo(KnownTag).@"enum".fields.len;

    /// The four-character code of each known tag.
    pub const tags: [count]Tag = .{
        tag("cmap"), tag("head"), tag("hhea"), tag("hmtx"), tag("maxp"), tag("name"), tag("OS/2"),
        tag("post"), tag("glyf"), tag("loca"), tag("CFF "), tag("CFF2"), tag("GSUB"), tag("GPOS"),
        tag("GDEF"), tag("kern"), tag("fvar"), tag("avar"), tag("gvar"), tag("HVAR"), tag("MVAR"),
        tag("COLR"), tag("CPAL"), tag("sbix"), tag("CBDT"), tag("CBLC"), tag("STAT"),
    };

    /// The known tag for `t`, if any.
    pub fn fromTag(t: Tag) ?KnownTag {
        inline for (tags, 0..) |k, i| if (k == t) return @enumFromInt(i);
        return null;
    }
};

/// Located tables of one face. Ranges are clamped to the file; tables that
/// do not fit are dropped.
pub const TableDir = struct {
    known: [KnownTag.count]?Range = @splat(null),
    /// Offset of the table records (for unknown-tag lookups).
    records_off: u32 = 0,
    num_tables: u16 = 0,
    /// The sfnt version: 0x00010000, 'OTTO' or 'true'.
    version: u32 = 0,

    /// A table's byte range within the file.
    pub const Range = struct { off: u32, len: u32 };

    /// Parses the table directory at `off` of `file`.
    pub fn parse(file: []const u8, off: u32) error{ Malformed, Unsupported }!TableDir {
        var r = try Reader.at(file, off);
        const version = try r.u32_();
        switch (version) {
            0x00010000, tag("OTTO"), tag("true") => {},
            else => return error.Unsupported, // includes 'typ1'
        }
        const num_tables = try r.u16_();
        try r.skip(6); // searchRange etc. are derived, never trusted
        var dir: TableDir = .{ .records_off = r.pos, .num_tables = num_tables, .version = version };
        if (r.remaining() < @as(usize, num_tables) * 16) return error.Malformed;
        for (0..num_tables) |_| {
            const t = try r.u32_();
            _ = try r.u32_(); // checksum
            const t_off = try r.u32_();
            const t_len = try r.u32_();
            const k = KnownTag.fromTag(t) orelse continue;
            if (dir.known[@intFromEnum(k)] != null) continue; // first wins
            if (clamp(file, t_off, t_len)) |range| dir.known[@intFromEnum(k)] = range;
        }
        return dir;
    }

    fn clamp(file: []const u8, off: u32, len: u32) ?Range {
        if (off >= file.len) return null;
        const avail: u32 = @intCast(file.len - off);
        return .{ .off = off, .len = @min(len, avail) };
    }

    /// The bytes of known table `k` within `file`, if present.
    pub fn get(d: *const TableDir, file: []const u8, k: KnownTag) ?[]const u8 {
        const range = d.known[@intFromEnum(k)] orelse return null;
        return file[range.off..][0..range.len];
    }

    /// The bytes of any table by tag (linear scan for unknown tags).
    pub fn find(d: *const TableDir, file: []const u8, t: Tag) ?[]const u8 {
        if (KnownTag.fromTag(t)) |k| return d.get(file, k);
        var r = Reader.at(file, d.records_off) catch return null;
        for (0..d.num_tables) |_| {
            const rt = r.u32_() catch return null;
            r.skip(4) catch return null;
            const off = r.u32_() catch return null;
            const len = r.u32_() catch return null;
            if (rt != t) continue;
            const range = clamp(file, off, len) orelse return null;
            return file[range.off..][0..range.len];
        }
        return null;
    }

    /// Iterates the raw table records `(tag, off, len)`, unclamped.
    pub fn records(d: *const TableDir, file: []const u8) RecordIterator {
        return .{ .r = Reader.at(file, d.records_off) catch .{ .data = &.{} }, .left = d.num_tables };
    }
};

/// One raw table record.
pub const Record = struct { tag: Tag, checksum: u32, off: u32, len: u32 };

/// Iterator over table records; stops early on truncation.
pub const RecordIterator = struct {
    r: Reader,
    left: u16,

    /// The next record, or null at the end.
    pub fn next(it: *RecordIterator) ?Record {
        if (it.left == 0) return null;
        it.left -= 1;
        const t = it.r.u32_() catch return null;
        const c = it.r.u32_() catch return null;
        const o = it.r.u32_() catch return null;
        const l = it.r.u32_() catch return null;
        return .{ .tag = t, .checksum = c, .off = o, .len = l };
    }
};

/// Number of faces in `bytes`: the TTC `numFonts`, or 1 for a plain sfnt.
pub fn faceCount(bytes: []const u8) error{Malformed}!u32 {
    const v = try reader.readAt(u32, bytes, 0);
    if (v != tag("ttcf")) return 1;
    const major = try reader.readAt(u16, bytes, 4);
    if (major != 1 and major != 2) return error.Malformed;
    const n = try reader.readAt(u32, bytes, 8);
    if (bytes.len < 12 or (bytes.len - 12) / 4 < n) return error.Malformed;
    return n;
}

/// Offset of the table directory of face `index`.
pub fn faceOffset(bytes: []const u8, index: u32) error{ Malformed, IndexOutOfRange }!u32 {
    const v = try reader.readAt(u32, bytes, 0);
    if (v != tag("ttcf")) {
        if (index != 0) return error.IndexOutOfRange;
        return 0;
    }
    const n = try faceCount(bytes);
    if (index >= n) return error.IndexOutOfRange;
    return reader.readAt(u32, bytes, 12 + @as(usize, index) * 4);
}

/// The OpenType table checksum: the sum of big-endian u32 words, with the
/// tail zero-padded.
pub fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) sum +%= std.mem.readInt(u32, data[i..][0..4], .big);
    if (i < data.len) {
        var tail: [4]u8 = @splat(0);
        @memcpy(tail[0 .. data.len - i], data[i..]);
        sum +%= std.mem.readInt(u32, &tail, .big);
    }
    return sum;
}

test "checksum pads the tail" {
    try std.testing.expectEqual(@as(u32, 0x01020304 +% 0x05000000), checksum(&.{ 1, 2, 3, 4, 5 }));
}

test "faceCount and faceOffset" {
    var ttc: [20]u8 = undefined;
    @memcpy(ttc[0..4], "ttcf");
    std.mem.writeInt(u16, ttc[4..6], 1, .big);
    std.mem.writeInt(u16, ttc[6..8], 0, .big);
    std.mem.writeInt(u32, ttc[8..12], 2, .big);
    std.mem.writeInt(u32, ttc[12..16], 100, .big);
    std.mem.writeInt(u32, ttc[16..20], 200, .big);
    try std.testing.expectEqual(@as(u32, 2), try faceCount(&ttc));
    try std.testing.expectEqual(@as(u32, 200), try faceOffset(&ttc, 1));
    try std.testing.expectError(error.IndexOutOfRange, faceOffset(&ttc, 2));
    std.mem.writeInt(u32, ttc[8..12], 1000, .big);
    try std.testing.expectError(error.Malformed, faceCount(&ttc));
}
