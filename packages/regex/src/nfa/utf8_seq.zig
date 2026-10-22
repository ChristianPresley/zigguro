//! Splits code point ranges into UTF-8 byte-range sequences, so a Unicode
//! class becomes a small automaton over bytes. For example U+0000..U+FFFF is
//!
//!     [00-7F]
//!     [C2-DF][80-BF]
//!     [E0][A0-BF][80-BF]
//!     [E1-EC][80-BF][80-BF]
//!     [ED][80-9F][80-BF]
//!     [EE-EF][80-BF][80-BF]
//!
//! The algorithm is the one from Russ Cox's RE2 and Rust's `regex-syntax`
//! (`utf8.rs`): split at encoded-length boundaries, then at continuation-byte
//! boundaries, until every range encodes to a rectangle of byte ranges.
//! Sequences come out in lexicographic byte order.

const std = @import("std");

/// One byte range `[lo, hi]`.
pub const ByteRange = struct {
    lo: u8,
    hi: u8,

    /// Whether `b` is in the range.
    pub fn contains(r: ByteRange, b: u8) bool {
        return b >= r.lo and b <= r.hi;
    }
};

/// A sequence of 1-4 byte ranges matching one encoded code point.
pub const Sequence = struct {
    ranges: [4]ByteRange = undefined,
    len: u8 = 0,

    /// The used ranges.
    pub fn slice(s: *const Sequence) []const ByteRange {
        return s.ranges[0..s.len];
    }

    /// Whether `bytes` (exactly `len` bytes) matches the sequence.
    pub fn matches(s: *const Sequence, bytes: []const u8) bool {
        if (bytes.len != s.len) return false;
        for (s.slice(), bytes) |r, b| if (!r.contains(b)) return false;
        return true;
    }
};

const max_scalar = [_]u32{ 0x7F, 0x7FF, 0xFFFF, 0x10FFFF };

/// Iterates the UTF-8 sequences of a list of scalar ranges. The iterator
/// keeps a small fixed stack; ranges are given in ascending order.
pub const Sequences = struct {
    input: []const [2]u21,
    next_input: usize = 0,
    stack: [16][2]u32 = undefined,
    sp: usize = 0,

    /// Iterates the sequences of `ranges` (sorted, non-overlapping).
    pub fn init(ranges: []const [2]u21) Sequences {
        return .{ .input = ranges };
    }

    fn push(it: *Sequences, lo: u32, hi: u32) void {
        it.stack[it.sp] = .{ lo, hi };
        it.sp += 1;
    }

    /// The next sequence, or null when done.
    pub fn next(it: *Sequences) ?Sequence {
        while (true) {
            if (it.sp == 0) {
                if (it.next_input == it.input.len) return null;
                const r = it.input[it.next_input];
                it.next_input += 1;
                it.push(r[0], r[1]);
            }
            it.sp -= 1;
            var r = it.stack[it.sp];
            inner: while (true) {
                // Split around the surrogates.
                if (r[0] < 0xE000 and r[1] > 0xD7FF) {
                    if (r[0] <= 0xD7FF and r[1] >= 0xE000) {
                        it.push(0xE000, r[1]);
                        r[1] = 0xD7FF;
                    } else if (r[0] >= 0xD800 and r[1] <= 0xDFFF) {
                        break :inner; // entirely surrogates
                    } else if (r[0] >= 0xD800) {
                        r[0] = 0xE000;
                    } else {
                        r[1] = 0xD7FF;
                    }
                }
                if (r[0] > r[1]) break :inner;
                // Split at encoded-length boundaries.
                for (max_scalar[0..3]) |m| {
                    if (r[0] <= m and m < r[1]) {
                        it.push(m + 1, r[1]);
                        r[1] = m;
                        continue :inner;
                    }
                }
                if (r[1] <= 0x7F) {
                    var s: Sequence = .{ .len = 1 };
                    s.ranges[0] = .{ .lo = @intCast(r[0]), .hi = @intCast(r[1]) };
                    return s;
                }
                // Split at continuation-byte boundaries.
                var i: u5 = 1;
                while (i < 4) : (i += 1) {
                    const m: u32 = (@as(u32, 1) << (6 * @as(u5, i))) - 1;
                    if ((r[0] & ~m) != (r[1] & ~m)) {
                        if ((r[0] & m) != 0) {
                            it.push((r[0] | m) + 1, r[1]);
                            r[1] = r[0] | m;
                            continue :inner;
                        }
                        if ((r[1] & m) != m) {
                            it.push(r[1] & ~m, r[1]);
                            r[1] = (r[1] & ~m) - 1;
                            continue :inner;
                        }
                    }
                }
                var lo_buf: [4]u8 = undefined;
                var hi_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(r[0]), &lo_buf) catch unreachable;
                const n2 = std.unicode.utf8Encode(@intCast(r[1]), &hi_buf) catch unreachable;
                std.debug.assert(n == n2);
                var s: Sequence = .{ .len = @intCast(n) };
                for (0..n) |k| s.ranges[k] = .{ .lo = lo_buf[k], .hi = hi_buf[k] };
                return s;
            }
        }
    }
};

test "utf8_seq: the BMP example" {
    var it = Sequences.init(&.{.{ 0, 0xFFFF }});
    const want = [_][]const [2]u8{
        &.{.{ 0x00, 0x7F }},
        &.{ .{ 0xC2, 0xDF }, .{ 0x80, 0xBF } },
        &.{ .{ 0xE0, 0xE0 }, .{ 0xA0, 0xBF }, .{ 0x80, 0xBF } },
        &.{ .{ 0xE1, 0xEC }, .{ 0x80, 0xBF }, .{ 0x80, 0xBF } },
        &.{ .{ 0xED, 0xED }, .{ 0x80, 0x9F }, .{ 0x80, 0xBF } },
        &.{ .{ 0xEE, 0xEF }, .{ 0x80, 0xBF }, .{ 0x80, 0xBF } },
    };
    for (want) |w| {
        const s = it.next().?;
        try std.testing.expectEqual(w.len, s.len);
        for (w, s.slice()) |a, b| {
            try std.testing.expectEqual(a[0], b.lo);
            try std.testing.expectEqual(a[1], b.hi);
        }
    }
    try std.testing.expect(it.next() == null);
}

test "utf8_seq: sequences match exactly the encoded members (sampled)" {
    var prng: std.Random.DefaultPrng = .init(42);
    const rnd = prng.random();
    for (0..200) |_| {
        const a = rnd.intRangeAtMost(u21, 0, 0x10FFFF);
        const b = rnd.intRangeAtMost(u21, 0, 0x10FFFF);
        const lo = @min(a, b);
        const hi = @max(a, b);
        var seqs: std.ArrayList(Sequence) = .empty;
        defer seqs.deinit(std.testing.allocator);
        var it = Sequences.init(&.{.{ lo, hi }});
        var prev: ?Sequence = null;
        while (it.next()) |s| {
            // Lexicographic order.
            if (prev) |p| try std.testing.expect(p.ranges[0].lo <= s.ranges[0].lo);
            prev = s;
            try seqs.append(std.testing.allocator, s);
        }
        for (0..300) |_| {
            const cp = rnd.intRangeAtMost(u21, 0, 0x10FFFF);
            if (cp >= 0xD800 and cp <= 0xDFFF) continue;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            var hits: usize = 0;
            for (seqs.items) |s| {
                if (s.matches(buf[0..n])) hits += 1;
            }
            try std.testing.expectEqual(@as(usize, @intFromBool(cp >= lo and cp <= hi)), hits);
        }
    }
}
