//! UTF-8 ⇄ UTF-16LE for Win32 `W` functions, on top of `std.unicode`.

const std = @import("std");
const unicode = std.unicode;

/// A comptime UTF-16 literal: `L("zigguro")`.
pub const L = unicode.utf8ToUtf16LeStringLiteral;

/// Converts `s` into `buf` with a NUL terminator.
pub fn toWide(buf: []u16, s: []const u8) error{ InvalidUtf8, NoSpaceLeft }![:0]u16 {
    const n = unicode.calcUtf16LeLen(s) catch return error.InvalidUtf8;
    if (n + 1 > buf.len) return error.NoSpaceLeft;
    _ = unicode.utf8ToUtf16Le(buf, s) catch return error.InvalidUtf8;
    buf[n] = 0;
    return buf[0..n :0];
}

/// Converts `s` to an allocated NUL-terminated UTF-16 string.
pub fn toWideAlloc(gpa: std.mem.Allocator, s: []const u8) error{ InvalidUtf8, OutOfMemory }![:0]u16 {
    return unicode.utf8ToUtf16LeAllocZ(gpa, s);
}

/// Converts UTF-16 (unpaired surrogates are an error) into `buf`.
/// `buf` needs at most 3 bytes per UTF-16 unit.
pub fn fromWide(buf: []u8, w: []const u16) error{ InvalidUtf16, NoSpaceLeft }![]u8 {
    if (buf.len < w.len * 3) return error.NoSpaceLeft;
    const n = unicode.utf16LeToUtf8(buf, w) catch return error.InvalidUtf16;
    return buf[0..n];
}

/// Converts UTF-16 to allocated UTF-8.
pub fn fromWideAlloc(gpa: std.mem.Allocator, w: []const u16) error{ InvalidUtf16, OutOfMemory }![]u8 {
    return unicode.utf16LeToUtf8Alloc(gpa, w) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf16,
    };
}

/// The length of a NUL-terminated UTF-16 string from the OS.
pub fn len(p: [*:0]const u16) usize {
    return std.mem.len(p);
}

const testing = std.testing;

test "utf16 roundtrip incl. surrogate pairs" {
    const s = "zig 🦎 Grüße 日本";
    var wbuf: [64]u16 = undefined;
    const w = try toWide(&wbuf, s);
    // 🦎 is U+1F98E: a surrogate pair.
    try testing.expectEqual(0xD83E, w[4]);
    try testing.expectEqual(0xDD8E, w[5]);
    try testing.expectEqual(0, wbuf[w.len]);
    var ubuf: [128]u8 = undefined;
    try testing.expectEqualStrings(s, try fromWide(&ubuf, w));

    const wa = try toWideAlloc(testing.allocator, s);
    defer testing.allocator.free(wa);
    try testing.expectEqualSlices(u16, w, wa);
    const ua = try fromWideAlloc(testing.allocator, wa);
    defer testing.allocator.free(ua);
    try testing.expectEqualStrings(s, ua);

    try testing.expectEqualSlices(u16, &.{ 'z', 'g' }, L("zg"));
    try testing.expectError(error.NoSpaceLeft, toWide(wbuf[0..3], "abc"));
    try testing.expectError(error.InvalidUtf8, toWide(&wbuf, "\xff"));
    try testing.expectError(error.InvalidUtf16, fromWide(&ubuf, &.{0xD83E}));
    try testing.expectEqual(2, len(L("zg")));
}
