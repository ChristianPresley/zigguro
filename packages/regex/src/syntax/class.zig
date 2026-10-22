//! Code point and byte sets for character classes.
//!
//! `RangeSet` holds sorted, non-overlapping, non-adjacent `[lo, hi]` ranges
//! over the Unicode scalar values (0..0x10FFFF minus surrogates; surrogates
//! are dropped on construction because they can never appear in UTF-8).
//! Every operation returns a new set in the given allocator, which is the
//! translator's arena, so nothing is freed individually.

const std = @import("std");
const casefold = @import("casefold.zig");

const Allocator = std.mem.Allocator;

/// The largest scalar value.
pub const max_cp: u21 = 0x10FFFF;

/// A set of code points.
pub const RangeSet = struct {
    ranges: []const [2]u21,

    /// The empty set.
    pub const empty: RangeSet = .{ .ranges = &.{} };

    /// The set of every scalar value.
    pub const all: RangeSet = .{ .ranges = &.{ .{ 0, 0xD7FF }, .{ 0xE000, max_cp } } };

    /// Builds a canonical set from arbitrary (unsorted, overlapping) ranges.
    pub fn fromRanges(gpa: Allocator, input: []const [2]u21) Allocator.Error!RangeSet {
        const buf = try gpa.alloc([2]u21, input.len);
        @memcpy(buf[0..input.len], input);
        return canonicalize(gpa, buf[0..input.len]);
    }

    /// A set holding exactly `cp`.
    pub fn single(gpa: Allocator, cp: u21) Allocator.Error!RangeSet {
        return fromRanges(gpa, &.{.{ cp, cp }});
    }

    /// Sorts and merges `buf` in place, then returns a copy without
    /// surrogates.
    fn canonicalize(gpa: Allocator, buf: [][2]u21) Allocator.Error!RangeSet {
        std.mem.sort([2]u21, buf, {}, struct {
            fn lt(_: void, a: [2]u21, b: [2]u21) bool {
                return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
            }
        }.lt);
        var n: usize = 0;
        for (buf) |r| {
            if (r[0] > r[1]) continue;
            if (n > 0 and @as(u32, r[0]) <= @as(u32, buf[n - 1][1]) + 1) {
                buf[n - 1][1] = @max(buf[n - 1][1], r[1]);
            } else {
                buf[n] = r;
                n += 1;
            }
        }
        // Remove the surrogate block, which may split one range in two.
        const out = try gpa.alloc([2]u21, n + 1);
        var k: usize = 0;
        for (buf[0..n]) |r| {
            if (r[1] < 0xD800 or r[0] > 0xDFFF) {
                out[k] = r;
                k += 1;
                continue;
            }
            if (r[0] < 0xD800) {
                out[k] = .{ r[0], 0xD7FF };
                k += 1;
            }
            if (r[1] > 0xDFFF) {
                out[k] = .{ 0xE000, r[1] };
                k += 1;
            }
        }
        return .{ .ranges = out[0..k] };
    }

    /// Whether `cp` is in the set (binary search).
    pub fn contains(s: RangeSet, cp: u21) bool {
        var lo: usize = 0;
        var hi: usize = s.ranges.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = s.ranges[mid];
            if (cp < r[0]) {
                hi = mid;
            } else if (cp > r[1]) {
                lo = mid + 1;
            } else return true;
        }
        return false;
    }

    /// Number of code points in the set.
    pub fn count(s: RangeSet) usize {
        var n: usize = 0;
        for (s.ranges) |r| n += @as(usize, r[1]) - r[0] + 1;
        return n;
    }

    /// Whether the set is empty.
    pub fn isEmpty(s: RangeSet) bool {
        return s.ranges.len == 0;
    }

    /// Set equality.
    pub fn eql(a: RangeSet, b: RangeSet) bool {
        if (a.ranges.len != b.ranges.len) return false;
        for (a.ranges, b.ranges) |x, y| if (x[0] != y[0] or x[1] != y[1]) return false;
        return true;
    }

    /// `a ∪ b`.
    pub fn unionWith(a: RangeSet, b: RangeSet, gpa: Allocator) Allocator.Error!RangeSet {
        const buf = try gpa.alloc([2]u21, a.ranges.len + b.ranges.len);
        @memcpy(buf[0..a.ranges.len], a.ranges);
        @memcpy(buf[a.ranges.len..][0..b.ranges.len], b.ranges);
        return canonicalize(gpa, buf[0 .. a.ranges.len + b.ranges.len]);
    }

    /// `a ∩ b`.
    pub fn intersect(a: RangeSet, b: RangeSet, gpa: Allocator) Allocator.Error!RangeSet {
        var out: std.ArrayList([2]u21) = .empty;
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.ranges.len and j < b.ranges.len) {
            const x = a.ranges[i];
            const y = b.ranges[j];
            const lo = @max(x[0], y[0]);
            const hi = @min(x[1], y[1]);
            if (lo <= hi) try out.append(gpa, .{ lo, hi });
            if (x[1] < y[1]) i += 1 else j += 1;
        }
        return .{ .ranges = out.items };
    }

    /// The complement over the scalar values.
    pub fn negate(a: RangeSet, gpa: Allocator) Allocator.Error!RangeSet {
        var out: std.ArrayList([2]u21) = .empty;
        var next: u32 = 0;
        for (a.ranges) |r| {
            if (r[0] > next) try out.append(gpa, .{ @intCast(next), r[0] - 1 });
            next = @as(u32, r[1]) + 1;
        }
        if (next <= max_cp) try out.append(gpa, .{ @intCast(next), max_cp });
        // The input has no surrogates, so the gap over them must be removed.
        return canonicalize(gpa, out.items);
    }

    /// `a − b`.
    pub fn difference(a: RangeSet, b: RangeSet, gpa: Allocator) Allocator.Error!RangeSet {
        return a.intersect(try b.negate(gpa), gpa);
    }

    /// `(a − b) ∪ (b − a)`.
    pub fn symmetricDifference(a: RangeSet, b: RangeSet, gpa: Allocator) Allocator.Error!RangeSet {
        return (try a.unionWith(b, gpa)).difference(try a.intersect(b, gpa), gpa);
    }

    /// Adds every simple case variant of every member (closes the set under
    /// simple case folding orbits).
    pub fn caseFoldClosure(a: RangeSet, gpa: Allocator) Allocator.Error!RangeSet {
        var extra: std.ArrayList([2]u21) = .empty;
        // Walk the (small, sorted) orbit index rather than every member.
        var ri: usize = 0;
        for (casefold.index()) |e| {
            while (ri < a.ranges.len and a.ranges[ri][1] < e.cp) ri += 1;
            if (ri == a.ranges.len) break;
            if (e.cp < a.ranges[ri][0]) continue;
            for (casefold.orbitOf(e)) |m| try extra.append(gpa, .{ m, m });
        }
        if (extra.items.len == 0) return a;
        return a.unionWith(.{ .ranges = extra.items }, gpa);
    }

    /// Whether every member is ASCII.
    pub fn isAscii(s: RangeSet) bool {
        return s.ranges.len == 0 or s.ranges[s.ranges.len - 1][1] < 0x80;
    }
};

/// A set of bytes, for classes in `(?-u)` mode.
pub const ByteSet = struct {
    bits: std.StaticBitSet(256) = .initEmpty(),

    /// Adds `[lo, hi]`.
    pub fn addRange(s: *ByteSet, lo: u8, hi: u8) void {
        s.bits.setRangeValue(.{ .start = lo, .end = @as(usize, hi) + 1 }, true);
    }

    /// Whether `b` is in the set.
    pub fn contains(s: ByteSet, b: u8) bool {
        return s.bits.isSet(b);
    }

    /// The complement.
    pub fn negate(s: ByteSet) ByteSet {
        return .{ .bits = s.bits.complement() };
    }

    /// `a ∪ b`.
    pub fn unionWith(a: ByteSet, b: ByteSet) ByteSet {
        return .{ .bits = a.bits.unionWith(b.bits) };
    }

    /// `a ∩ b`.
    pub fn intersect(a: ByteSet, b: ByteSet) ByteSet {
        return .{ .bits = a.bits.intersectWith(b.bits) };
    }

    /// `a − b`.
    pub fn difference(a: ByteSet, b: ByteSet) ByteSet {
        return .{ .bits = a.bits.differenceWith(b.bits) };
    }

    /// `(a − b) ∪ (b − a)`.
    pub fn symmetricDifference(a: ByteSet, b: ByteSet) ByteSet {
        return .{ .bits = a.bits.xorWith(b.bits) };
    }

    /// Adds the other ASCII case of every ASCII letter.
    pub fn asciiCaseFold(a: ByteSet) ByteSet {
        var s = a;
        for ('A'..'Z' + 1) |c| {
            if (a.bits.isSet(c) or a.bits.isSet(c + 32)) {
                s.bits.set(c);
                s.bits.set(c + 32);
            }
        }
        return s;
    }

    /// Number of members.
    pub fn count(s: ByteSet) usize {
        return s.bits.count();
    }

    /// Whether the set is empty.
    pub fn isEmpty(s: ByteSet) bool {
        return s.bits.count() == 0;
    }

    /// The members as sorted, merged ranges (at most 128).
    pub fn ranges(s: ByteSet, buf: *[128][2]u8) [][2]u8 {
        var n: usize = 0;
        var b: usize = 0;
        while (b < 256) {
            if (!s.bits.isSet(b)) {
                b += 1;
                continue;
            }
            const lo = b;
            while (b < 256 and s.bits.isSet(b)) b += 1;
            buf[n] = .{ @intCast(lo), @intCast(b - 1) };
            n += 1;
        }
        return buf[0..n];
    }
};

/// Converts an ASCII-only `RangeSet` to a `ByteSet`.
pub fn asciiToBytes(s: RangeSet) ByteSet {
    var out: ByteSet = .{};
    for (s.ranges) |r| {
        if (r[0] > 0xFF) break;
        out.addRange(@intCast(r[0]), @intCast(@min(r[1], 0xFF)));
    }
    return out;
}

test "class: set algebra laws (random sets vs bitset reference)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rnd = prng.random();
    // Sample a window around interesting boundaries so the reference stays small.
    const window_lo: u21 = 0xD700;
    const window_hi: u21 = 0xE100;
    const W = window_hi - window_lo + 1;
    for (0..200) |_| {
        var sets: [2]RangeSet = undefined;
        var refs: [2]std.StaticBitSet(W) = undefined;
        for (&sets, &refs) |*s, *ref| {
            ref.* = .initEmpty();
            var raw: [6][2]u21 = undefined;
            const n = rnd.intRangeAtMost(usize, 0, 6);
            for (raw[0..n]) |*r| {
                const a = rnd.intRangeAtMost(u21, window_lo, window_hi);
                const b = rnd.intRangeAtMost(u21, window_lo, window_hi);
                r.* = .{ @min(a, b), @max(a, b) };
                for (r[0]..@as(usize, r[1]) + 1) |cp| if (cp < 0xD800 or cp > 0xDFFF) ref.set(cp - window_lo);
            }
            s.* = try RangeSet.fromRanges(arena, raw[0..n]);
        }
        const ops = .{ "unionWith", "intersect", "difference", "symmetricDifference" };
        inline for (ops) |op| {
            const got = try @field(RangeSet, op)(sets[0], sets[1], arena);
            for (0..W) |i| {
                const cp: u21 = @intCast(window_lo + i);
                const a = refs[0].isSet(i);
                const b = refs[1].isSet(i);
                const want = if (comptime std.mem.eql(u8, op, "unionWith")) a or b else if (comptime std.mem.eql(u8, op, "intersect")) a and b else if (comptime std.mem.eql(u8, op, "difference")) a and !b else a != b;
                try std.testing.expectEqual(want, got.contains(cp));
            }
            // Canonical: sorted, disjoint, non-adjacent, no surrogates.
            for (got.ranges, 0..) |r, k| {
                try std.testing.expect(r[0] <= r[1]);
                try std.testing.expect(r[1] < 0xD800 or r[0] > 0xDFFF);
                if (k > 0) try std.testing.expect(@as(u32, got.ranges[k - 1][1]) + 1 < r[0] or (got.ranges[k - 1][1] == 0xD7FF and r[0] == 0xE000));
            }
        }
        // Double negation.
        const nn = try (try sets[0].negate(arena)).negate(arena);
        try std.testing.expect(nn.eql(sets[0]));
    }
}

test "class: negate covers the scalar values" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const n = try RangeSet.empty.negate(arena_state.allocator());
    try std.testing.expect(n.eql(RangeSet.all));
    try std.testing.expect((try RangeSet.all.negate(arena_state.allocator())).isEmpty());
}

test "class: byte sets" {
    var s: ByteSet = .{};
    s.addRange('a', 'c');
    const f = s.asciiCaseFold();
    try std.testing.expect(f.contains('B'));
    try std.testing.expectEqual(@as(usize, 256 - 3), s.negate().count());
    var buf: [128][2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), f.ranges(&buf).len);
}
