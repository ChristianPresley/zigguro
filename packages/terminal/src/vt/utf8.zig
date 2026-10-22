//! Streaming UTF-8 decoder for the ground state.
//!
//! Ill-formed input is replaced with U+FFFD per maximal subpart (Unicode
//! §3.9, "U+FFFD Substitution of Maximal Subparts", as in the WHATWG
//! decoder). An incomplete sequence at the end of a buffer is carried into
//! the next call. Decoding stops before C0 controls, DEL and ESC so the state
//! table handles them. C1 code points (U+0080-U+009F) are decoded and dropped.

const std = @import("std");
const fast_path = @import("fast_path.zig");

/// The replacement character.
pub const replacement: u21 = 0xFFFD;

/// Decoder state carried across `decode` calls.
pub const Decoder = struct {
    /// Code point bits accumulated from the bytes of the pending sequence.
    cp: u21 = 0,
    /// Continuation bytes still needed; 0 when no sequence is pending.
    need: u2 = 0,
    /// Inclusive bounds for the next continuation byte (Unicode Table 3-7).
    lo: u8 = 0x80,
    hi: u8 = 0xBF,
    /// With 8-bit C1 controls enabled, a lead byte 0x80-0x9F stops decoding
    /// so the state table executes it.
    c1_8bit: bool = false,

    /// Result of one `decode` call.
    pub const Result = struct { consumed: usize, written: usize };

    /// Whether a multi-byte sequence is pending.
    pub fn pending(d: *const Decoder) bool {
        return d.need != 0;
    }

    /// Decodes as much of `bytes` as fits into `out`. Stops before a byte
    /// < 0x20, 0x7F (and a C1 lead byte when `c1_8bit`); a pending sequence
    /// interrupted by such a byte is flushed as one U+FFFD first.
    pub fn decode(d: *Decoder, bytes: []const u8, out: []u21) Result {
        var i: usize = 0;
        var w: usize = 0;
        while (i < bytes.len and w < out.len) {
            const b = bytes[i];
            if (d.need == 0) {
                if (b < 0x80) {
                    if (b < 0x20 or b == 0x7F) break;
                    // ASCII run inside mixed text.
                    const n = @min(fast_path.scanPrintable(bytes[i..]), out.len - w);
                    for (bytes[i..][0..n], out[w..][0..n]) |c, *o| o.* = c;
                    i += n;
                    w += n;
                    continue;
                }
                i += 1;
                switch (b) {
                    0xC2...0xDF => {
                        d.need = 1;
                        d.cp = b & 0x1F;
                    },
                    0xE0...0xEF => {
                        if (b == 0xE0) d.lo = 0xA0;
                        if (b == 0xED) d.hi = 0x9F;
                        d.need = 2;
                        d.cp = b & 0x0F;
                    },
                    0xF0...0xF4 => {
                        if (b == 0xF0) d.lo = 0x90;
                        if (b == 0xF4) d.hi = 0x8F;
                        d.need = 3;
                        d.cp = b & 0x07;
                    },
                    else => {
                        if (d.c1_8bit and b <= 0x9F) {
                            i -= 1;
                            break;
                        }
                        out[w] = replacement;
                        w += 1;
                    },
                }
                continue;
            }
            if (b < d.lo or b > d.hi) {
                // Maximal subpart ends here; reprocess `b` as a new lead byte.
                d.reset();
                out[w] = replacement;
                w += 1;
                continue;
            }
            i += 1;
            d.lo = 0x80;
            d.hi = 0xBF;
            d.cp = (d.cp << 6) | (b & 0x3F);
            d.need -= 1;
            if (d.need == 0) {
                const cp = d.cp;
                d.cp = 0;
                if (cp < 0x80 or cp > 0x9F) {
                    out[w] = cp;
                    w += 1;
                }
            }
        }
        return .{ .consumed = i, .written = w };
    }

    /// Flushes a pending sequence: returns true (one U+FFFD is owed) if one
    /// was pending, and resets.
    pub fn flush(d: *Decoder) bool {
        const p = d.need != 0;
        d.reset();
        return p;
    }

    /// Drops any pending sequence.
    pub fn reset(d: *Decoder) void {
        d.cp = 0;
        d.need = 0;
        d.lo = 0x80;
        d.hi = 0xBF;
    }
};

const testing = std.testing;

fn decodeAll(d: *Decoder, bytes: []const u8, out: []u21) []u21 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const r = d.decode(bytes[i..], out[w..]);
        i += r.consumed;
        w += r.written;
        if (r.consumed == 0 and r.written == 0) {
            // A control byte: flush any pending sequence, then emit the byte.
            if (d.flush()) {
                out[w] = replacement;
                w += 1;
            }
            out[w] = bytes[i];
            w += 1;
            i += 1;
        }
    }
    return out[0..w];
}

test "decoder equals std.unicode reference on valid input" {
    const s = "héllo wörld — 日本語 🧑‍🌾 \u{10FFFF}";
    var out: [64]u21 = undefined;
    var d: Decoder = .{};
    const got = decodeAll(&d, s, &out);
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    var k: usize = 0;
    while (it.nextCodepoint()) |cp| : (k += 1) try testing.expectEqual(cp, got[k]);
    try testing.expectEqual(k, got.len);
}

test "maximal subpart replacement" {
    const F = replacement;
    const cases = [_]struct { in: []const u8, want: []const u21 }{
        .{ .in = "\xC0\x80", .want = &.{ F, F } },
        .{ .in = "\xE0\x80\x80", .want = &.{ F, F, F } },
        .{ .in = "\xED\xA0\x80", .want = &.{ F, F, F } }, // surrogate
        .{ .in = "\xF4\x90\x80\x80", .want = &.{ F, F, F, F } },
        .{ .in = "\xE2\x82", .want = &.{} }, // still pending at end
        .{ .in = "\xE2\x82A", .want = &.{ F, 'A' } },
        .{ .in = "\x80\xBFa", .want = &.{ F, F, 'a' } }, // lone continuations
        .{ .in = "\xF0\x9F\x98\x80", .want = &.{0x1F600} },
        .{ .in = "\xF0\x9F\x98\n", .want = &.{ F, '\n' } },
        .{ .in = "\xFF\xFE", .want = &.{ F, F } },
    };
    for (cases) |c| {
        var d: Decoder = .{};
        var out: [16]u21 = undefined;
        try testing.expectEqualSlices(u21, c.want, decodeAll(&d, c.in, &out));
    }
}

test "truncated sequence completed in the next call" {
    var d: Decoder = .{};
    var out: [4]u21 = undefined;
    const a = d.decode("\xF0\x9F\x98", &out);
    try testing.expectEqual(@as(usize, 3), a.consumed);
    try testing.expectEqual(@as(usize, 0), a.written);
    const b = d.decode("\x80", &out);
    try testing.expectEqual(@as(usize, 1), b.written);
    try testing.expectEqual(@as(u21, 0x1F600), out[0]);
}

test "split feed at every byte offset of a 4-byte emoji yields one cp" {
    const s = "\xF0\x9F\xA7\x91";
    for (0..s.len + 1) |cut| {
        var d: Decoder = .{};
        var out: [4]u21 = undefined;
        const a = d.decode(s[0..cut], &out);
        const b = d.decode(s[cut..], out[a.written..]);
        try testing.expectEqual(@as(usize, 1), a.written + b.written);
        try testing.expectEqual(@as(u21, 0x1F9D1), out[0]);
    }
}

test "C1 code points not printed in UTF-8 mode" {
    var d: Decoder = .{};
    var out: [4]u21 = undefined;
    const r = d.decode("a\xC2\x9Bb", &out);
    try testing.expectEqualSlices(u21, &.{ 'a', 'b' }, out[0..r.written]);
}

test "decoding stops before controls and with full output" {
    var d: Decoder = .{};
    var out: [2]u21 = undefined;
    const r = d.decode("ab\x1b[", &out);
    try testing.expectEqual(@as(usize, 2), r.consumed);
    const r2 = d.decode("\x1b", &out);
    try testing.expectEqual(@as(usize, 0), r2.consumed);
    const r3 = d.decode("éééé", &out);
    try testing.expectEqual(@as(usize, 2), r3.written);
    try testing.expectEqual(@as(usize, 4), r3.consumed);
}
