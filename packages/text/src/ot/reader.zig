//! Bounds-checked big-endian reader over font bytes. Every multi-byte read
//! does one bounds check and then `std.mem.readInt(.big)`; nothing ever
//! casts pointers into unaligned font data.

const std = @import("std");

/// A glyph index within one face; 0 is `.notdef`.
pub const GlyphId = u16;

/// A big-endian four-character code, e.g. `tag("GSUB")`.
pub const Tag = u32;

/// Every parser in `ot` reports hostile or truncated input as this error.
pub const Error = error{Malformed};

/// The `Tag` for a four-character string.
pub fn tag(comptime s: *const [4]u8) Tag {
    return std.mem.readInt(u32, s, .big);
}

/// The four characters of `t` (for diagnostics and dumps).
pub fn tagName(t: Tag) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, t, .big);
    return out;
}

/// A cursor over `data`. `pos` is the offset of the next read.
pub const Reader = struct {
    data: []const u8,
    pos: u32 = 0,

    /// A reader positioned at `off`; `off == data.len` is allowed (empty).
    pub fn at(data: []const u8, off: usize) Error!Reader {
        if (off > data.len or data.len > std.math.maxInt(u32)) return error.Malformed;
        return .{ .data = data, .pos = @intCast(off) };
    }

    /// Bytes left after `pos`.
    pub fn remaining(r: Reader) usize {
        return r.data.len - r.pos;
    }

    fn take(r: *Reader, comptime n: usize) Error!*const [n]u8 {
        if (r.data.len - r.pos < n) return error.Malformed;
        const p = r.data[r.pos..][0..n];
        r.pos += n;
        return p;
    }

    /// Reads one byte.
    pub fn u8_(r: *Reader) Error!u8 {
        return (try r.take(1))[0];
    }

    /// Reads one signed byte.
    pub fn i8_(r: *Reader) Error!i8 {
        return @bitCast((try r.take(1))[0]);
    }

    /// Reads a big-endian `uint16`.
    pub fn u16_(r: *Reader) Error!u16 {
        return std.mem.readInt(u16, try r.take(2), .big);
    }

    /// Reads a big-endian `int16` (also FWORD).
    pub fn i16_(r: *Reader) Error!i16 {
        return std.mem.readInt(i16, try r.take(2), .big);
    }

    /// Reads a big-endian `uint24` (named `u24_`: `u24` would shadow the primitive).
    pub fn u24_(r: *Reader) Error!u24 {
        return std.mem.readInt(u24, try r.take(3), .big);
    }

    /// Reads a big-endian `uint32` (also Offset32 and Tag).
    pub fn u32_(r: *Reader) Error!u32 {
        return std.mem.readInt(u32, try r.take(4), .big);
    }

    /// Reads a big-endian `int32` (also Fixed 16.16).
    pub fn i32_(r: *Reader) Error!i32 {
        return std.mem.readInt(i32, try r.take(4), .big);
    }

    /// Advances by `n` bytes.
    pub fn skip(r: *Reader, n: usize) Error!void {
        if (r.data.len - r.pos < n) return error.Malformed;
        r.pos += @intCast(n);
    }

    /// The next `n` bytes, advancing past them.
    pub fn slice(r: *Reader, n: usize) Error![]const u8 {
        if (r.data.len - r.pos < n) return error.Malformed;
        const s = r.data[r.pos..][0..n];
        r.pos += @intCast(n);
        return s;
    }
};

/// Reads a `T` (u8..u32, i8..i32) at absolute offset `off` of `data`.
pub fn readAt(comptime T: type, data: []const u8, off: usize) Error!T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    if (off > data.len or data.len - off < n) return error.Malformed;
    return std.mem.readInt(T, data[off..][0..n], .big);
}

/// `data[off..]`, or `error.Malformed` when `off` is past the end.
pub fn sub(data: []const u8, off: usize) Error![]const u8 {
    if (off > data.len) return error.Malformed;
    return data[off..];
}

/// `data[off..][0..len]`, or `error.Malformed` when it does not fit.
pub fn subLen(data: []const u8, off: usize, len: usize) Error![]const u8 {
    if (off > data.len or data.len - off < len) return error.Malformed;
    return data[off..][0..len];
}

test "reader bounds" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0xff };
    var r = try Reader.at(&bytes, 0);
    try std.testing.expectEqual(@as(u16, 0x0102), try r.u16_());
    try std.testing.expectEqual(@as(u24, 0x0304ff), try r.u24_());
    try std.testing.expectError(error.Malformed, r.u8_());
    try std.testing.expectError(error.Malformed, Reader.at(&bytes, 6));
    var e = try Reader.at(&bytes, 5);
    try std.testing.expectEqual(@as(usize, 0), e.remaining());
    try std.testing.expectError(error.Malformed, e.skip(1));
    var s = try Reader.at(&bytes, 3);
    try std.testing.expectEqual(@as(i16, 0x04ff), try s.i16_());
    try std.testing.expectError(error.Malformed, readAt(u32, &bytes, 2));
    try std.testing.expectEqual(@as(u32, 0x020304ff), try readAt(u32, &bytes, 1));
    try std.testing.expectError(error.Malformed, subLen(&bytes, 4, 2));
    try std.testing.expectEqual(tag("GSUB"), 0x47535542);
    try std.testing.expectEqualStrings("GSUB", &tagName(tag("GSUB")));
}
