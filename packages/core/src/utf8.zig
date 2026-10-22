//! UTF-8 primitives used by every protocol and the editor: strict
//! validation with a SIMD ASCII fast path, lossy decoding, LSP column
//! conversion between UTF-8/UTF-16/UTF-32 units, and WTF-8/WTF-16 helpers
//! for Windows paths.

const std = @import("std");

const V = @Vector(32, u8);

/// True if `bytes` is well-formed UTF-8 per RFC 3629 (no overlongs, no
/// surrogates, nothing above U+10FFFF). Agrees with `std.unicode.utf8ValidateSlice`.
pub fn validate(bytes: []const u8) bool {
    return validatePrefix(bytes) == bytes.len;
}

/// Length of the longest prefix of `bytes` consisting only of complete,
/// well-formed sequences. For streaming input, an incomplete sequence at the
/// end of a chunk is excluded so it can be retried with the next chunk.
pub fn validatePrefix(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        // ASCII fast path: 32 bytes at a time.
        while (i + 32 <= bytes.len) {
            const v: V = bytes[i..][0..32].*;
            if (@reduce(.Or, v) >= 0x80) break;
            i += 32;
        }
        if (i >= bytes.len) break;
        const c = bytes[i];
        if (c < 0x80) {
            i += 1;
            continue;
        }
        const n = seqLen(bytes[i..]);
        if (n == 0) return i;
        i += n;
    }
    return i;
}

/// Length of the complete well-formed sequence at the start of `s`
/// (non-empty, first byte >= 0x80), or 0 if it is ill-formed or truncated.
fn seqLen(s: []const u8) usize {
    const r = maximalSubpart(s);
    return if (r.valid) r.len else 0;
}

const Subpart = struct { len: usize, valid: bool, cp: u21 };

/// Decodes the sequence at the start of `s` (non-empty). For ill-formed
/// input returns the length of the maximal subpart (Unicode 3.9, U+FFFD
/// substitution practice); that length is at least 1.
fn maximalSubpart(s: []const u8) Subpart {
    const c = s[0];
    if (c < 0x80) return .{ .len = 1, .valid = true, .cp = c };
    var need: usize = undefined;
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    var cp: u21 = undefined;
    switch (c) {
        0xC2...0xDF => {
            need = 1;
            cp = c & 0x1F;
        },
        0xE0 => {
            need = 2;
            lo = 0xA0;
            cp = c & 0x0F;
        },
        0xE1...0xEC, 0xEE...0xEF => {
            need = 2;
            cp = c & 0x0F;
        },
        0xED => {
            need = 2;
            hi = 0x9F;
            cp = c & 0x0F;
        },
        0xF0 => {
            need = 3;
            lo = 0x90;
            cp = c & 0x07;
        },
        0xF1...0xF3 => {
            need = 3;
            cp = c & 0x07;
        },
        0xF4 => {
            need = 3;
            hi = 0x8F;
            cp = c & 0x07;
        },
        else => return .{ .len = 1, .valid = false, .cp = 0xFFFD },
    }
    var k: usize = 1;
    while (k <= need) : (k += 1) {
        if (k >= s.len) return .{ .len = k, .valid = false, .cp = 0xFFFD };
        const b = s[k];
        const l: u8 = if (k == 1) lo else 0x80;
        const h: u8 = if (k == 1) hi else 0xBF;
        if (b < l or b > h) return .{ .len = k, .valid = false, .cp = 0xFFFD };
        cp = (cp << 6) | (b & 0x3F);
    }
    return .{ .len = need + 1, .valid = true, .cp = cp };
}

/// Decodes UTF-8, yielding U+FFFD once per maximal ill-formed subsequence
/// (the W3C/WHATWG decoder behaviour). Consumes all input; never fails.
pub const LossyIterator = struct {
    bytes: []const u8,
    i: usize = 0,

    /// The next code point, or null at the end.
    pub fn next(it: *LossyIterator) ?u21 {
        if (it.i >= it.bytes.len) return null;
        const r = maximalSubpart(it.bytes[it.i..]);
        it.i += r.len;
        return r.cp;
    }
};

/// Column units (LSP `PositionEncodingKind`): bytes, UTF-16 code units, or
/// code points.
pub const Encoding = enum { utf8, utf16, utf32 };

fn isAscii(s: []const u8) bool {
    var i: usize = 0;
    while (i + 32 <= s.len) : (i += 32) {
        const v: V = s[i..][0..32].*;
        if (@reduce(.Or, v) >= 0x80) return false;
    }
    for (s[i..]) |c| if (c >= 0x80) return false;
    return true;
}

fn units(r: Subpart, enc: Encoding) u32 {
    return switch (enc) {
        .utf8 => @intCast(r.len),
        .utf16 => if (r.valid and r.cp >= 0x10000) 2 else if (r.valid) 1 else @intCast(r.len),
        .utf32 => if (r.valid) 1 else @intCast(r.len),
    };
}

/// Byte offset of column `col` (in `enc` units) within `line`. A column
/// inside a code point clamps to the start of that code point; a column past
/// the end returns `line.len`. Each byte of an ill-formed subsequence counts
/// as one unit.
pub fn columnToByte(line: []const u8, col: u32, enc: Encoding) usize {
    if (enc == .utf8 or isAscii(line)) {
        if (col >= line.len) return line.len;
        if (enc != .utf8) return col;
        var b: usize = col;
        while (b > 0 and (line[b] & 0xC0) == 0x80 and maximalSubpartStartsBefore(line, b)) b -= 1;
        return b;
    }
    var i: usize = 0;
    var c: u32 = 0;
    while (i < line.len) {
        const r = maximalSubpart(line[i..]);
        const u = units(r, enc);
        if (c + u > col) return i;
        c += u;
        i += r.len;
    }
    return line.len;
}

/// True if byte `b` is a continuation byte inside a valid sequence starting before it.
fn maximalSubpartStartsBefore(line: []const u8, b: usize) bool {
    var start = b;
    var back: usize = 0;
    while (start > 0 and back < 3 and (line[start] & 0xC0) == 0x80) : (back += 1) start -= 1;
    const r = maximalSubpart(line[start..]);
    return r.valid and start + r.len > b;
}

/// Column (in `enc` units) of byte offset `byte` within `line`; an offset
/// inside a code point clamps to that code point's start; past the end
/// counts the whole line.
pub fn byteToColumn(line: []const u8, byte: usize, enc: Encoding) u32 {
    const end = @min(byte, line.len);
    if (enc == .utf8) return @intCast(columnToByte(line, @intCast(end), .utf8));
    if (isAscii(line[0..end])) return @intCast(end);
    var i: usize = 0;
    var c: u32 = 0;
    while (i < end) {
        const r = maximalSubpart(line[i..]);
        if (i + r.len > end) break;
        c += units(r, enc);
        i += r.len;
    }
    return c;
}

/// Converts WTF-8 (Windows paths) to NUL-terminated WTF-16LE. Caller frees.
pub fn toWtf16LeZ(gpa: std.mem.Allocator, wtf8: []const u8) error{ InvalidWtf8, OutOfMemory }![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, wtf8);
}

/// Converts WTF-16LE to WTF-8. Caller frees.
pub fn fromWtf16Le(gpa: std.mem.Allocator, w: []const u16) error{OutOfMemory}![]u8 {
    return std.unicode.wtf16LeToWtf8Alloc(gpa, w);
}

/// ASCII case-insensitive equality (non-ASCII bytes compare exactly).
pub fn eqlAsciiIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "utf8: validation table" {
    const ok = [_][]const u8{ "", "hello", "\xC2\x80", "\xE2\x82\xAC", "\xF0\x9F\x98\x80", "\xF4\x8F\xBF\xBF", "a" ** 70 ++ "\xE2\x82\xAC" };
    const bad = [_][]const u8{ "\xC0\x80", "\xC1\xBF", "\xED\xA0\x80", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\x80", "\xE2\x82", "\xFF", "a" ** 40 ++ "\xC0" };
    for (ok) |s| {
        try std.testing.expect(validate(s));
        try std.testing.expect(std.unicode.utf8ValidateSlice(s));
    }
    for (bad) |s| {
        try std.testing.expect(!validate(s));
        try std.testing.expect(!std.unicode.utf8ValidateSlice(s));
    }
    try std.testing.expectEqual(@as(usize, 3), validatePrefix("abc\xE2\x82"));
}

test "utf8: lossy iterator maximal subparts" {
    // From the Unicode standard's U+FFFD example: 61 F1 80 80 E1 80 C2 62 80 63 80 BF 64
    var it: LossyIterator = .{ .bytes = "\x61\xF1\x80\x80\xE1\x80\xC2\x62\x80\x63\x80\xBF\x64" };
    const want = [_]u21{ 'a', 0xFFFD, 0xFFFD, 0xFFFD, 'b', 0xFFFD, 'c', 0xFFFD, 0xFFFD, 'd' };
    for (want) |w| try std.testing.expectEqual(@as(?u21, w), it.next());
    try std.testing.expectEqual(@as(?u21, null), it.next());
}

test "utf8: column conversion" {
    const line = "a\u{e9}\u{1F600}b"; // bytes: a(1) é(2) 😀(4) b(1)
    try std.testing.expectEqual(@as(usize, 7), columnToByte(line, 4, .utf16));
    try std.testing.expectEqual(@as(usize, 3), columnToByte(line, 3, .utf16)); // inside the surrogate pair
    try std.testing.expectEqual(@as(usize, 3), columnToByte(line, 2, .utf16));
    try std.testing.expectEqual(@as(usize, 7), columnToByte(line, 3, .utf32));
    try std.testing.expectEqual(@as(usize, 8), columnToByte(line, 99, .utf32));
    try std.testing.expectEqual(@as(usize, 1), columnToByte(line, 2, .utf8)); // inside é
    try std.testing.expectEqual(@as(u32, 4), byteToColumn(line, 7, .utf16));
    try std.testing.expectEqual(@as(u32, 3), byteToColumn(line, 7, .utf32));
    try std.testing.expectEqual(@as(u32, 2), byteToColumn(line, 5, .utf16)); // inside 😀
    try std.testing.expectEqual(@as(u32, 5), byteToColumn("hello world", 5, .utf16));
}

test "utf8: wtf16 round trip and ascii case" {
    const gpa = std.testing.allocator;
    const w = try toWtf16LeZ(gpa, "C:\\Users\\\u{e9}");
    defer gpa.free(w);
    const back = try fromWtf16Le(gpa, w);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("C:\\Users\\\u{e9}", back);
    try std.testing.expect(eqlAsciiIgnoreCase("Content-Length", "content-length"));
}

fn genValid(s: *std.testing.Smith, buf: []u8) []u8 {
    var n: usize = 0;
    while (n + 4 <= buf.len and !s.eos()) {
        const cp: u21 = switch (s.valueRangeAtMost(u8, 0, 3)) {
            0 => s.valueRangeAtMost(u21, 0, 0x7F),
            1 => s.valueRangeAtMost(u21, 0x80, 0x7FF),
            2 => s.valueRangeAtMost(u21, 0xE000, 0xFFFF),
            else => s.valueRangeAtMost(u21, 0x10000, 0x10FFFF),
        };
        n += std.unicode.utf8Encode(cp, buf[n..]) catch unreachable;
    }
    return buf[0..n];
}

test "fuzz: utf8 column round trip" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const line = genValid(s, &buf);
            for ([_]Encoding{ .utf8, .utf16, .utf32 }) |enc| {
                var it: LossyIterator = .{ .bytes = line };
                var byte: usize = 0;
                while (it.next()) |_| {
                    const col = byteToColumn(line, byte, enc);
                    try std.testing.expectEqual(byte, columnToByte(line, col, enc));
                    byte = it.i;
                }
                try std.testing.expectEqual(line.len, columnToByte(line, byteToColumn(line, line.len, enc), enc));
            }
        }
    }.one, .{});
}

test "fuzz: utf8 validate matches std" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try std.testing.expectEqual(std.unicode.utf8ValidateSlice(input), validate(input));
            const p = validatePrefix(input);
            try std.testing.expect(std.unicode.utf8ValidateSlice(input[0..p]));
            var it: LossyIterator = .{ .bytes = input };
            var count: usize = 0;
            while (it.next()) |_| count += 1;
            try std.testing.expectEqual(input.len, it.i);
            try std.testing.expect(count <= input.len);
        }
    }.one, .{ .corpus = &.{ "", "abc", "\xF0\x9F\x98", "\xED\xA0\x80", "a\xC3\xA9b" } });
}
