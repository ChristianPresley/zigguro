//! The font database's binary form, used both in memory and as the
//! persistent cache (`fontdb-v1.bin`): a header, a section table and
//! nine 8-byte-aligned sections of fixed-size records. Loading is one
//! read plus bounds and reference checks; the records are used in place.
//!
//! Header (32 bytes): "ZGFDB\x01\0\0", version u32, endianness marker
//! u32 (0x01020304 as written), section count u32, reserved. Then per
//! section an (offset u64, count u64) pair, counts in records.

const std = @import("std");
const Allocator = std.mem.Allocator;
const db = @import("db.zig");

pub const magic = "ZGFDB\x01\x00\x00";
pub const version: u32 = 1;
const endian_marker: u32 = 0x01020304;

pub const Error = error{ BadMagic, BadVersion, Corrupt };

/// Section record types, in file order.
const kinds = .{
    u8, // strings
    [2]u32, // string offset, length
    db.FileRec,
    db.FaceInfo,
    [2]u32, // coverage ranges (first, last code point)
    [2]u32, // coverage sets (first range, range count)
    u32, // block offsets (block_count + 1)
    u32, // block faces
    db.FamilyEntry,
};
const section_count = kinds.len;
const header_len = 32 + section_count * 16;

/// Views of every section.
pub const Sections = struct {
    strings: []const u8 = &.{},
    str_offs: []const [2]u32 = &.{},
    files: []const db.FileRec = &.{},
    faces: []const db.FaceInfo = &.{},
    ranges: []const [2]u32 = &.{},
    coverages: []const [2]u32 = &.{},
    block_offs: []const u32 = &.{},
    block_faces: []const u32 = &.{},
    families: []const db.FamilyEntry = &.{},

    fn slices(s: *const Sections) [section_count][]const u8 {
        var out: [section_count][]const u8 = undefined;
        inline for (std.meta.fields(Sections), 0..) |f, i| out[i] = std.mem.sliceAsBytes(@field(s, f.name));
        return out;
    }
};

/// `s` as one buffer.
pub fn serialize(gpa: Allocator, s: *const Sections) Allocator.Error![]align(8) u8 {
    const bytes = s.slices();
    var len: usize = header_len;
    for (bytes) |b| len = std.mem.alignForward(usize, len, 8) + b.len;
    len = std.mem.alignForward(usize, len, 8);
    const buf = try gpa.alignedAlloc(u8, .@"8", len);
    @memset(buf, 0);
    @memcpy(buf[0..8], magic);
    std.mem.writeInt(u32, buf[8..12], version, .little);
    std.mem.writeInt(u32, buf[12..16], endian_marker, .native);
    std.mem.writeInt(u32, buf[16..20], section_count, .little);
    var off: usize = header_len;
    inline for (std.meta.fields(Sections), 0..) |f, i| {
        off = std.mem.alignForward(usize, off, 8);
        const b = bytes[i];
        @memcpy(buf[off..][0..b.len], b);
        const count = @field(s, f.name).len;
        std.mem.writeInt(u64, buf[32 + i * 16 ..][0..8], off, .little);
        std.mem.writeInt(u64, buf[32 + i * 16 + 8 ..][0..8], count, .little);
        off += b.len;
    }
    return buf;
}

/// The sections of `buf`, checked: every section in bounds and aligned,
/// and every cross reference (strings, files, coverage, faces, blocks)
/// valid, so readers need no further checks.
pub fn parse(buf: []align(8) const u8) Error!Sections {
    if (buf.len < header_len or !std.mem.eql(u8, buf[0..8], magic)) return error.BadMagic;
    if (std.mem.readInt(u32, buf[8..12], .little) != version) return error.BadVersion;
    // Written on another endianness: not ours to read.
    if (std.mem.readInt(u32, buf[12..16], .native) != endian_marker) return error.BadVersion;
    if (std.mem.readInt(u32, buf[16..20], .little) != section_count) return error.BadVersion;
    var s: Sections = .{};
    inline for (std.meta.fields(Sections), 0..) |f, i| {
        const T = kinds[i];
        const off = std.mem.readInt(u64, buf[32 + i * 16 ..][0..8], .little);
        const count = std.mem.readInt(u64, buf[32 + i * 16 + 8 ..][0..8], .little);
        if (off % 8 != 0 or off > buf.len or count > (buf.len - off) / @sizeOf(T)) return error.Corrupt;
        const start: usize = @intCast(off);
        const n: usize = @intCast(count);
        const p: [*]const T = @ptrCast(@alignCast(buf[start..].ptr));
        @field(s, f.name) = p[0..n];
    }
    try check(&s);
    return s;
}

fn check(s: *const Sections) Error!void {
    const nstr = s.str_offs.len;
    for (s.str_offs) |so| if (@as(u64, so[0]) + so[1] > s.strings.len) return error.Corrupt;
    for (s.files) |f| if (f.path >= nstr) return error.Corrupt;
    for (s.ranges) |r| if (r[0] > r[1] or r[1] > 0x10FFFF) return error.Corrupt;
    for (s.coverages) |c| if (@as(u64, c[0]) + c[1] > s.ranges.len) return error.Corrupt;
    for (s.faces) |f| {
        if (f.file >= s.files.len or f.coverage >= s.coverages.len) return error.Corrupt;
        for ([_]u32{ f.family, f.typographic_family, f.style_name, f.full_name, f.postscript }) |id|
            if (id >= nstr) return error.Corrupt;
        if (f.slant > 2 or f.color > 3) return error.Corrupt;
    }
    if (s.block_offs.len != db.block_count + 1) {
        if (s.block_offs.len != 0 or s.block_faces.len != 0) return error.Corrupt;
    } else {
        var prev: u32 = 0;
        for (s.block_offs) |o| {
            if (o < prev) return error.Corrupt;
            prev = o;
        }
        if (prev != s.block_faces.len) return error.Corrupt;
    }
    for (s.block_faces) |f| if (f >= s.faces.len) return error.Corrupt;
    for (s.families) |e| if (e.key >= nstr or e.name >= nstr or e.face >= s.faces.len) return error.Corrupt;
}
