//! UTF-8 decoding helpers for the segmenters: forward decoding with
//! maximal-subpart error handling (same as `zg_core.utf8.LossyIterator`)
//! and backward stepping that agrees with it.

const std = @import("std");
const zg_core = @import("zg_core");

/// One decoded unit: a code point, or U+FFFD for an ill-formed subsequence.
pub const Unit = struct { cp: u21, len: u8, valid: bool };

/// Decodes the unit starting at `i` (`i < bytes.len`).
pub inline fn at(bytes: []const u8, i: usize) Unit {
    const c = bytes[i];
    if (c < 0x80) return .{ .cp = c, .len = 1, .valid = true };
    // Well-formed fast path (RFC 3629 table); anything else goes through
    // the maximal-subpart decoder.
    const rest = bytes.len - i;
    if (c >= 0xC2 and c <= 0xDF) {
        if (rest >= 2 and bytes[i + 1] & 0xC0 == 0x80)
            return .{ .cp = (@as(u21, c & 0x1F) << 6) | (bytes[i + 1] & 0x3F), .len = 2, .valid = true };
    } else if (c >= 0xE0 and c <= 0xEF) {
        if (rest >= 3) {
            const c1 = bytes[i + 1];
            const c2 = bytes[i + 2];
            const lo: u8 = if (c == 0xE0) 0xA0 else 0x80;
            const hi: u8 = if (c == 0xED) 0x9F else 0xBF;
            if (c1 >= lo and c1 <= hi and c2 & 0xC0 == 0x80)
                return .{ .cp = (@as(u21, c & 0x0F) << 12) | (@as(u21, c1 & 0x3F) << 6) | (c2 & 0x3F), .len = 3, .valid = true };
        }
    } else if (c >= 0xF0 and c <= 0xF4) {
        if (rest >= 4) {
            const c1 = bytes[i + 1];
            const lo: u8 = if (c == 0xF0) 0x90 else 0x80;
            const hi: u8 = if (c == 0xF4) 0x8F else 0xBF;
            if (c1 >= lo and c1 <= hi and bytes[i + 2] & 0xC0 == 0x80 and bytes[i + 3] & 0xC0 == 0x80)
                return .{ .cp = (@as(u21, c & 0x07) << 18) | (@as(u21, c1 & 0x3F) << 12) | (@as(u21, bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F), .len = 4, .valid = true };
        }
    }
    var it: zg_core.utf8.LossyIterator = .{ .bytes = bytes, .i = i };
    const cp = it.next().?;
    const len: u8 = @intCast(it.i - i);
    const valid = cp != 0xFFFD or (len == 3 and bytes[i] == 0xEF and bytes[i + 1] == 0xBF and bytes[i + 2] == 0xBD);
    return .{ .cp = cp, .len = len, .valid = valid };
}

/// Start of the unit that ends at `pos` (`pos` must be a unit boundary
/// greater than 0). Any non-continuation byte is a unit boundary under
/// maximal-subpart decoding, so decoding forward from at most 4 bytes back
/// resynchronises before `pos`.
pub fn prevStart(bytes: []const u8, pos: usize) usize {
    std.debug.assert(pos > 0);
    if (bytes[pos - 1] < 0x80) return pos - 1;
    var i = pos - @min(pos, 4);
    var last = i;
    while (i < pos) {
        last = i;
        i += at(bytes, i).len;
    }
    return last;
}

/// Snaps `offset` back to the start of the unit containing it.
pub fn snap(bytes: []const u8, offset: usize) usize {
    if (offset >= bytes.len) return bytes.len;
    if (bytes[offset] < 0x80 or bytes[offset] >= 0xC0) return offset;
    var i = offset - @min(offset, 3);
    var last = i;
    while (i <= offset) {
        last = i;
        i += at(bytes, i).len;
    }
    return last;
}

test "prevStart agrees with forward decoding" {
    const cases = [_][]const u8{ "a\u{E9}\u{4E00}\u{1F600}b", "\xE0\x80\x80\x80\x80x", "\xF0\x9F\x98", "\xED\xA0\x80", "\xEF\xBF\xBD\xC3" };
    for (cases) |s| {
        var starts: [32]usize = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (n += 1) {
            starts[n] = i;
            i += at(s, i).len;
        }
        var k = n;
        var pos = s.len;
        while (k > 0) {
            k -= 1;
            const p = prevStart(s, pos);
            try std.testing.expectEqual(starts[k], p);
            for (p..pos) |o| try std.testing.expectEqual(p, snap(s, o));
            pos = p;
        }
    }
    try std.testing.expect(at("\xEF\xBF\xBD", 0).valid);
    try std.testing.expect(!at("\xC3", 0).valid);
}
