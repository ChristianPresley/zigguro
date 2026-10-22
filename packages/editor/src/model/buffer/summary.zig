//! The piece tree's monoid summary: byte, line-break and UTF-16 counts plus
//! the edge information that makes `combine` exact when a CRLF pair or a
//! UTF-8 sequence straddles two pieces.
//!
//! Line terminators are `\n`, `\r\n` (counted once) and a lone `\r`, as in
//! LSP 3.17 and `zg_core.LineIndex`. UTF-16 units follow
//! `zg_core.utf8.byteToColumn`: 1 per code point below U+10000, 2 above,
//! and 1 per byte of an ill-formed subsequence (maximal subparts, W3C
//! decoder rules).
//!
//! UTF-16 counting is a small transducer. `utf16` holds the units emitted by
//! decoding the bytes from the ground state; a sequence still incomplete at
//! the end is kept as `tail_lead` / `tail_n` and not counted yet. `combine`
//! resumes that partial sequence over the first bytes of the right-hand side
//! (`head`). Bytes a ground decode consumes as part of the resumed sequence
//! are always continuation bytes, which a ground decode counts as one unit
//! each, so the right side's count is corrected by subtracting them.

const std = @import("std");

const V = @Vector(32, u8);

/// Summary of a byte string. `combine` is associative; `empty` is its
/// identity.
pub const Summary = struct {
    bytes: u64 = 0,
    /// Line terminators.
    newlines: u64 = 0,
    /// UTF-16 units emitted, excluding a pending partial sequence at the end.
    utf16: u64 = 0,
    /// Bytes before the first terminator (all bytes when there is none).
    first_line_bytes: u32 = 0,
    /// Bytes after the last terminator (all bytes when there is none).
    last_line_bytes: u32 = 0,
    /// Longest line segment, terminators excluded.
    max_line_bytes: u32 = 0,
    /// The first `min(3, bytes)` bytes.
    head: [3]u8 = .{ 0, 0, 0 },
    /// Lead byte of a UTF-8 sequence left incomplete at the end.
    tail_lead: u8 = 0,
    /// Bytes of that incomplete sequence (0 = none).
    tail_n: u8 = 0,
    starts_with_lf: bool = false,
    ends_with_cr: bool = false,
    /// False while a large original is still being indexed (estimated
    /// newline counts).
    lines_exact: bool = true,

    pub const empty: Summary = .{};

    /// Total UTF-16 units, counting a pending partial sequence at the end
    /// as one unit per byte.
    pub fn utf16Total(s: Summary) u64 {
        return s.utf16 + s.tail_n;
    }

    /// The summary of `a ++ b`.
    pub fn combine(a: Summary, b: Summary) Summary {
        if (b.bytes == 0) return a;
        if (a.bytes == 0) return b;
        var r: Summary = .{
            .bytes = a.bytes + b.bytes,
            .newlines = a.newlines + b.newlines,
            .starts_with_lf = a.starts_with_lf,
            .ends_with_cr = b.ends_with_cr,
            .lines_exact = a.lines_exact and b.lines_exact,
            .tail_lead = b.tail_lead,
            .tail_n = b.tail_n,
        };
        if (a.ends_with_cr and b.starts_with_lf) r.newlines -= 1;
        r.first_line_bytes = if (a.newlines == 0) a.first_line_bytes +| b.first_line_bytes else a.first_line_bytes;
        r.last_line_bytes = if (b.newlines == 0) a.last_line_bytes +| b.last_line_bytes else b.last_line_bytes;
        r.max_line_bytes = @max(@max(a.max_line_bytes, b.max_line_bytes), a.last_line_bytes +| b.first_line_bytes);
        if (a.bytes >= 3) {
            r.head = a.head;
        } else {
            const an: usize = @intCast(a.bytes);
            r.head = a.head;
            var i: usize = an;
            var j: usize = 0;
            while (i < 3 and j < b.bytes) : ({
                i += 1;
                j += 1;
            }) r.head[i] = b.head[j];
        }
        const u = Utf16State.of(a).then(b);
        r.utf16 = u.units;
        r.tail_lead = u.lead;
        r.tail_n = u.n;
        return r;
    }

    /// The summary of `bytes` (SIMD for line breaks and ASCII runs).
    pub fn of(bytes: []const u8) Summary {
        var s: Summary = .{ .bytes = bytes.len };
        if (bytes.len == 0) return s;
        for (bytes[0..@min(bytes.len, 3)], 0..) |c, i| s.head[i] = c;
        s.starts_with_lf = bytes[0] == '\n';
        s.ends_with_cr = bytes[bytes.len - 1] == '\r';
        scanLines(bytes, &s);
        scanUtf16(bytes, &s);
        return s;
    }
};

/// The UTF-16 part of a summary: units emitted plus a pending partial
/// sequence. A cheaper accumulator than a full `Summary` for seeks.
pub const Utf16State = struct {
    units: u64 = 0,
    lead: u8 = 0,
    n: u8 = 0,

    /// The UTF-16 state of `s`.
    pub fn of(s: Summary) Utf16State {
        return .{ .units = s.utf16, .lead = s.tail_lead, .n = s.tail_n };
    }

    /// Total units with the pending sequence flushed.
    pub fn total(u: Utf16State) u64 {
        return u.units + u.n;
    }

    /// The state after appending text summarized by `b`.
    pub fn then(a: Utf16State, b: Summary) Utf16State {
        if (b.bytes == 0) return a;
        if (a.n == 0) return .{ .units = a.units + b.utf16, .lead = b.tail_lead, .n = b.tail_n };
        // Resume a's partial sequence over b's head.
        const info = leadInfo(a.lead).?;
        var n: u8 = a.n;
        const blen: usize = @intCast(@min(b.bytes, 3));
        var k: usize = 0;
        while (true) {
            if (k == blen) {
                // b is consumed and the sequence is still incomplete (b is
                // at most 2 continuation bytes, counted b.bytes units).
                std.debug.assert(blen == b.bytes);
                return .{ .units = a.units, .lead = a.lead, .n = n };
            }
            const byte = b.head[k];
            const lo: u8 = if (n == 1) info.lo else 0x80;
            const hi: u8 = if (n == 1) info.hi else 0xBF;
            if (byte < lo or byte > hi) {
                return .{ .units = a.units + n + (b.utf16 - k), .lead = b.tail_lead, .n = b.tail_n };
            }
            n += 1;
            k += 1;
            if (n == info.len) {
                return .{ .units = a.units + @as(u64, if (info.len == 4) 2 else 1) + (b.utf16 - k), .lead = b.tail_lead, .n = b.tail_n };
            }
        }
    }
};

/// Line-break count and trailing-CR state; a cheaper accumulator than a
/// full `Summary` for seeks.
pub const LineState = struct {
    newlines: u64 = 0,
    ends_with_cr: bool = false,

    /// The state after appending text summarized by `b`.
    pub fn then(a: LineState, b: Summary) LineState {
        if (b.bytes == 0) return a;
        return .{
            .newlines = a.newlines + b.newlines - @intFromBool(a.ends_with_cr and b.starts_with_lf),
            .ends_with_cr = b.ends_with_cr,
        };
    }

    /// The state after appending `bytes`.
    pub fn thenBytes(a: LineState, bytes: []const u8) LineState {
        if (bytes.len == 0) return a;
        return .{
            .newlines = a.newlines + countNewlines(bytes) - @intFromBool(a.ends_with_cr and bytes[0] == '\n'),
            .ends_with_cr = bytes[bytes.len - 1] == '\r',
        };
    }
};

/// Line terminators in `bytes` (CRLF counted once), SIMD.
pub fn countNewlines(bytes: []const u8) u64 {
    var n: u64 = 0;
    var i: usize = 0;
    var prev_cr = false;
    while (i + 32 <= bytes.len) : (i += 32) {
        const v: V = bytes[i..][0..32].*;
        const lf: u32 = @bitCast(v == @as(V, @splat('\n')));
        const cr: u32 = @bitCast(v == @as(V, @splat('\r')));
        // A CR followed by LF (also across the block edge) counts once.
        const crlf = cr & (lf >> 1);
        n += @popCount(lf) + @popCount(cr) - @popCount(crlf);
        if (prev_cr and (lf & 1) != 0) n -= 1;
        prev_cr = (cr >> 31) != 0;
    }
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == '\n') {
            if (!prev_cr) n += 1;
        } else if (c == '\r') n += 1;
        prev_cr = c == '\r';
    }
    return n;
}

/// UTF-16 state of `bytes` decoded from the ground state.
pub fn utf16Of(bytes: []const u8) Utf16State {
    var s: Summary = .{ .bytes = bytes.len };
    scanUtf16(bytes, &s);
    return .of(s);
}

/// UTF-8 sequence shape for a lead byte: total length and the allowed range
/// of the second byte.
pub const LeadInfo = struct { len: u8, lo: u8, hi: u8 };

/// Sequence info for `lead`, or null when it cannot start a sequence.
pub fn leadInfo(lead: u8) ?LeadInfo {
    return switch (lead) {
        0xC2...0xDF => .{ .len = 2, .lo = 0x80, .hi = 0xBF },
        0xE0 => .{ .len = 3, .lo = 0xA0, .hi = 0xBF },
        0xE1...0xEC, 0xEE...0xEF => .{ .len = 3, .lo = 0x80, .hi = 0xBF },
        0xED => .{ .len = 3, .lo = 0x80, .hi = 0x9F },
        0xF0 => .{ .len = 4, .lo = 0x90, .hi = 0xBF },
        0xF1...0xF3 => .{ .len = 4, .lo = 0x80, .hi = 0xBF },
        0xF4 => .{ .len = 4, .lo = 0x80, .hi = 0x8F },
        else => null,
    };
}

fn scanLines(bytes: []const u8, s: *Summary) void {
    // Positions of terminator ends drive the line lengths.
    var line_start: usize = 0;
    var first: ?usize = null;
    var max_len: usize = 0;
    var count: u64 = 0;
    const nl: V = @splat('\n');
    const cr: V = @splat('\r');
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 32 <= bytes.len) {
            const v: V = bytes[i..][0..32].*;
            const m: u32 = @as(u32, @bitCast(v == nl)) | @as(u32, @bitCast(v == cr));
            if (m == 0) {
                i += 32;
                continue;
            }
            i += @ctz(m);
        }
        const c = bytes[i];
        if (c == '\n' or c == '\r') {
            const len = i - line_start;
            if (first == null) first = len;
            max_len = @max(max_len, len);
            count += 1;
            if (c == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
            line_start = i + 1;
        }
        i += 1;
    }
    const last = bytes.len - line_start;
    max_len = @max(max_len, last);
    s.newlines = count;
    s.first_line_bytes = sat32(first orelse bytes.len);
    s.last_line_bytes = sat32(last);
    s.max_line_bytes = sat32(max_len);
}

fn sat32(x: usize) u32 {
    return @intCast(@min(x, std.math.maxInt(u32)));
}

fn scanUtf16(bytes: []const u8, s: *Summary) void {
    var units: u64 = 0;
    var lead: u8 = 0;
    var n: u8 = 0;
    var info: LeadInfo = undefined;
    var i: usize = 0;
    while (i < bytes.len) {
        if (n == 0) {
            // ASCII fast path, 32 bytes at a time.
            if (i + 32 <= bytes.len) {
                const v: V = bytes[i..][0..32].*;
                const hi_mask: u32 = @bitCast(v >= @as(V, @splat(0x80)));
                if (hi_mask == 0) {
                    units += 32;
                    i += 32;
                    continue;
                }
                const skip = @ctz(hi_mask);
                units += skip;
                i += skip;
            }
            const c = bytes[i];
            i += 1;
            if (c < 0x80) {
                units += 1;
            } else if (leadInfo(c)) |li| {
                lead = c;
                info = li;
                n = 1;
            } else {
                units += 1;
            }
            continue;
        }
        const c = bytes[i];
        const lo: u8 = if (n == 1) info.lo else 0x80;
        const hi: u8 = if (n == 1) info.hi else 0xBF;
        if (c < lo or c > hi) {
            // Ill-formed: one unit per consumed byte; reprocess `c`.
            units += n;
            n = 0;
            continue;
        }
        n += 1;
        i += 1;
        if (n == info.len) {
            units += if (info.len == 4) 2 else 1;
            n = 0;
        }
    }
    s.utf16 = units;
    s.tail_lead = if (n == 0) 0 else lead;
    s.tail_n = n;
}

fn refUtf16(bytes: []const u8) u64 {
    const utf8 = @import("zg_core").utf8;
    return utf8.byteToColumn(bytes, bytes.len, .utf16);
}

fn refNewlines(bytes: []const u8) u64 {
    var n: u64 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') n += 1 else if (bytes[i] == '\r') {
            n += 1;
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
        }
    }
    return n;
}

fn expectSame(a: Summary, b: Summary) !void {
    try std.testing.expectEqual(a.bytes, b.bytes);
    try std.testing.expectEqual(a.newlines, b.newlines);
    try std.testing.expectEqual(a.utf16Total(), b.utf16Total());
    try std.testing.expectEqual(a.utf16, b.utf16);
    try std.testing.expectEqual(a.tail_n, b.tail_n);
    try std.testing.expectEqual(a.first_line_bytes, b.first_line_bytes);
    try std.testing.expectEqual(a.last_line_bytes, b.last_line_bytes);
    try std.testing.expectEqual(a.max_line_bytes, b.max_line_bytes);
    try std.testing.expectEqual(a.starts_with_lf, b.starts_with_lf);
    try std.testing.expectEqual(a.ends_with_cr, b.ends_with_cr);
    try std.testing.expectEqualSlices(u8, a.head[0..@min(a.bytes, 3)], b.head[0..@min(b.bytes, 3)]);
}

const alphabet = [_]u8{ 'a', '\n', '\r', 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80, 0xED, 0xA0, 0xFF, 0xF4, 0x90, 0x80 };

fn randomBytes(r: std.Random, buf: []u8) []u8 {
    const n = r.uintLessThan(usize, buf.len + 1);
    for (buf[0..n]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
    return buf[0..n];
}

test "summary: of matches references" {
    var prng: std.Random.DefaultPrng = .init(11);
    const r = prng.random();
    var buf: [200]u8 = undefined;
    for (0..3000) |_| {
        const b = randomBytes(r, &buf);
        const s = Summary.of(b);
        try std.testing.expectEqual(refUtf16(b), s.utf16Total());
        try std.testing.expectEqual(refNewlines(b), s.newlines);
    }
    const long = "abc\r\n" ** 20 ++ "é€😀" ++ "x" ** 40 ++ "\n";
    const s = Summary.of(long);
    try std.testing.expectEqual(refUtf16(long), s.utf16Total());
    try std.testing.expectEqual(@as(u64, 21), s.newlines);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_bytes);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_bytes);
    try std.testing.expectEqual(@as(u32, 49), s.max_line_bytes);
}

test "summary: combine of a split equals of the whole" {
    var prng: std.Random.DefaultPrng = .init(12);
    const r = prng.random();
    var buf: [64]u8 = undefined;
    for (0..5000) |_| {
        const b = randomBytes(r, &buf);
        const cut = r.uintLessThan(usize, b.len + 1);
        try expectSame(Summary.of(b), Summary.of(b[0..cut]).combine(Summary.of(b[cut..])));
    }
}

test "summary: combine is associative" {
    var prng: std.Random.DefaultPrng = .init(13);
    const r = prng.random();
    var buf: [48]u8 = undefined;
    for (0..5000) |_| {
        const b = randomBytes(r, &buf);
        const c1 = r.uintLessThan(usize, b.len + 1);
        const c2 = c1 + r.uintLessThan(usize, b.len - c1 + 1);
        const x = Summary.of(b[0..c1]);
        const y = Summary.of(b[c1..c2]);
        const z = Summary.of(b[c2..]);
        try expectSame(x.combine(y).combine(z), x.combine(y.combine(z)));
        try expectSame(Summary.of(b), x.combine(y).combine(z));
    }
}

test "summary: crlf straddling counts one line" {
    const a = Summary.of("ab\r");
    const b = Summary.of("\ncd");
    const c = a.combine(b);
    try std.testing.expectEqual(@as(u64, 1), c.newlines);
    try std.testing.expectEqual(@as(u32, 2), c.last_line_bytes);
    try std.testing.expectEqual(@as(u32, 2), c.first_line_bytes);
}

test "summary: countNewlines matches the scalar count" {
    var prng: std.Random.DefaultPrng = .init(14);
    const r = prng.random();
    var buf: [300]u8 = undefined;
    for (0..2000) |_| {
        const b = randomBytes(r, &buf);
        try std.testing.expectEqual(refNewlines(b), countNewlines(b));
    }
}

test "summary: 4-byte sequence split across three pieces counts two units" {
    const e = "😀";
    const s = Summary.of(e[0..1]).combine(Summary.of(e[1..3])).combine(Summary.of(e[3..]));
    try std.testing.expectEqual(@as(u64, 2), s.utf16Total());
    try std.testing.expectEqual(@as(u8, 0), s.tail_n);
}
