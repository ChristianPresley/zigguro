//! Assertion evaluation at a haystack position, shared by the engines.
//!
//! Word assertions in Unicode mode decode the code point before and after
//! the position (up to 4 bytes each way, possibly across chunks) and test
//! membership in `\w`; invalid UTF-8 is never a word character.

const std = @import("std");
const Look = @import("../syntax/hir.zig").Look;
const Input = @import("../input.zig").Input;
const unicode = @import("../syntax/unicode.zig");

/// Whether `b` is an ASCII word byte `[0-9A-Za-z_]`.
pub inline fn isWordByte(b: u8) bool {
    return switch (b) {
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

/// Whether `cp` is in Unicode `\w`.
pub fn isWordChar(cp: u21) bool {
    if (cp < 0x80) return isWordByte(@intCast(cp));
    const rs = unicode.perlWord();
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < rs[mid][0]) {
            hi = mid;
        } else if (cp > rs[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// Decodes the code point starting at `at`, or null (end or invalid).
pub fn decodeFwd(in: *const Input, at: u64) ?u21 {
    if (at >= in.total_len) return null;
    var buf: [4]u8 = undefined;
    buf[0] = in.byteAt(at);
    const n = std.unicode.utf8ByteSequenceLength(buf[0]) catch return null;
    if (at + n > in.total_len) return null;
    for (1..n) |i| buf[i] = in.byteAt(at + i);
    return std.unicode.utf8Decode(buf[0..n]) catch null;
}

/// Decodes the code point ending at `at`, or null (start or invalid).
pub fn decodeRev(in: *const Input, at: u64) ?u21 {
    if (at == 0) return null;
    // Find the lead byte within the previous 4 bytes.
    var start = at - 1;
    var k: usize = 0;
    while (k < 3 and start > 0 and (in.byteAt(start) & 0xC0) == 0x80) : (k += 1) start -= 1;
    const cp = decodeFwd(in, start) orelse return null;
    const n = std.unicode.utf8CodepointSequenceLength(cp) catch return null;
    if (start + n != at) return null;
    return cp;
}

fn wordBefore(in: *const Input, at: u64, comptime uni: bool) bool {
    if (at == 0) return false;
    if (!uni) return isWordByte(in.byteAt(at - 1));
    const cp = decodeRev(in, at) orelse return false;
    return isWordChar(cp);
}

fn wordAfter(in: *const Input, at: u64, comptime uni: bool) bool {
    if (at >= in.total_len) return false;
    if (!uni) return isWordByte(in.byteAt(at));
    const cp = decodeFwd(in, at) orelse return false;
    return isWordChar(cp);
}

/// Whether `look` holds at position `at`.
pub fn matches(look: Look, in: *const Input, at: u64) bool {
    const len = in.total_len;
    return switch (look) {
        .start_text => at == 0,
        .end_text => at == len,
        .start_line => at == 0 or in.byteAt(at - 1) == '\n',
        .end_line => at == len or in.byteAt(at) == '\n',
        .start_line_crlf => at == 0 or in.byteAt(at - 1) == '\n' or
            (in.byteAt(at - 1) == '\r' and (at == len or in.byteAt(at) != '\n')),
        .end_line_crlf => at == len or in.byteAt(at) == '\r' or
            (in.byteAt(at) == '\n' and (at == 0 or in.byteAt(at - 1) != '\r')),
        .word_ascii => wordBefore(in, at, false) != wordAfter(in, at, false),
        .word_ascii_negate => wordBefore(in, at, false) == wordAfter(in, at, false),
        .word_unicode => wordBefore(in, at, true) != wordAfter(in, at, true),
        .word_unicode_negate => blk: {
            // Rust: \B never matches inside an invalid or partial UTF-8
            // sequence boundary-wise; we treat positions inside a code point
            // as non-word on both sides, so \B holds there.
            break :blk wordBefore(in, at, true) == wordAfter(in, at, true);
        },
        .word_start_ascii => !wordBefore(in, at, false) and wordAfter(in, at, false),
        .word_end_ascii => wordBefore(in, at, false) and !wordAfter(in, at, false),
        .word_start_half_ascii => !wordBefore(in, at, false),
        .word_end_half_ascii => !wordAfter(in, at, false),
        .word_start_unicode => !wordBefore(in, at, true) and wordAfter(in, at, true),
        .word_end_unicode => wordBefore(in, at, true) and !wordAfter(in, at, true),
        .word_start_half_unicode => !wordBefore(in, at, true),
        .word_end_half_unicode => !wordAfter(in, at, true),
    };
}

test "look: lines, crlf and words" {
    const in = Input.fromSlice("ab\r\ncd é1");
    try std.testing.expect(matches(.start_text, &in, 0));
    try std.testing.expect(!matches(.start_line, &in, 3));
    try std.testing.expect(matches(.start_line, &in, 4));
    try std.testing.expect(matches(.end_line_crlf, &in, 2));
    try std.testing.expect(!matches(.end_line_crlf, &in, 3));
    try std.testing.expect(!matches(.start_line_crlf, &in, 3));
    try std.testing.expect(matches(.start_line_crlf, &in, 4));
    try std.testing.expect(matches(.word_ascii, &in, 0));
    try std.testing.expect(matches(.word_ascii_negate, &in, 1));
    // "é1": é is a Unicode word char but not an ASCII one.
    try std.testing.expect(matches(.word_unicode, &in, 7));
    try std.testing.expect(!matches(.word_unicode, &in, 9));
    try std.testing.expect(matches(.word_ascii, &in, 9));
    try std.testing.expect(matches(.end_text, &in, in.total_len));
}
