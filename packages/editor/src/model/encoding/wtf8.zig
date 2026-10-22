//! WTF-8: UTF-8 that also carries unpaired surrogates (U+D800..U+DFFF) as
//! three-byte sequences, so UTF-16 with lone surrogates round-trips.

const std = @import("std");

/// Appends `cp` (any code point up to U+10FFFF, surrogates included).
pub fn append(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    try out.appendSlice(gpa, encode(cp, &buf));
}

/// The WTF-8 bytes of `cp` in `buf`.
pub fn encode(cp: u21, buf: *[4]u8) []const u8 {
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return buf[0..1];
    }
    if (cp < 0x800) {
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return buf[0..2];
    }
    if (cp < 0x10000) {
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return buf[0..3];
    }
    buf[0] = @intCast(0xF0 | (cp >> 18));
    buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (cp & 0x3F));
    return buf[0..4];
}

/// One decoded code point and its length, or null for an invalid sequence
/// at `i` (overlong, out of range or cut short).
pub fn next(bytes: []const u8, i: usize) ?struct { cp: u21, len: u3 } {
    const b0 = bytes[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const n: u3 = if (b0 & 0xE0 == 0xC0) 2 else if (b0 & 0xF0 == 0xE0) 3 else if (b0 & 0xF8 == 0xF0) 4 else return null;
    if (i + n > bytes.len) return null;
    var cp: u21 = b0 & (@as(u8, 0x7F) >> n);
    for (bytes[i + 1 .. i + n]) |b| {
        if (b & 0xC0 != 0x80) return null;
        cp = (cp << 6) | (b & 0x3F);
    }
    const min: u21 = switch (n) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (cp < min or cp > 0x10FFFF) return null;
    return .{ .cp = cp, .len = n };
}

test "wtf8: surrogates round-trip" {
    var buf: [4]u8 = undefined;
    const s = encode(0xD800, &buf);
    try std.testing.expectEqualSlices(u8, "\xED\xA0\x80", s);
    const d = next(s, 0).?;
    try std.testing.expectEqual(@as(u21, 0xD800), d.cp);
    try std.testing.expectEqual(@as(?@TypeOf(d), null), next("\xC0\x80", 0));
    try std.testing.expectEqual(@as(u21, 0x1F600), next(encode(0x1F600, &buf), 0).?.cp);
}
