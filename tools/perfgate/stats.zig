//! Statistics for perfgate (E14.F06.S02.T01): the Mann–Whitney U test
//! (exact for small samples without ties, normal approximation with tie
//! and continuity correction otherwise), medians and the coefficient of
//! variation.

const std = @import("std");

pub const Mwu = struct {
    /// U of the second sample (`b`): pairs (b_i, a_j) with b_i > a_j, ties
    /// counting one half.
    u: f64,
    /// P(U >= u) under the null: small when `b` is larger ("head slower").
    p_one_sided_greater: f64,
    /// P(U <= u) under the null: small when `b` is smaller.
    p_one_sided_less: f64,
    /// Rank-biserial correlation 2U/(n1 n2) - 1, in [-1, 1].
    effect_rb: f64,
    exact: bool,
};

/// Samples per side up to which the exact distribution is used.
pub const exact_max_n = 20;

/// Tests `b` (head) against `a` (base). Needs at least one sample per
/// side.
pub fn mannWhitneyU(gpa: std.mem.Allocator, a: []const f64, b: []const f64) !Mwu {
    std.debug.assert(a.len > 0 and b.len > 0);
    const n1 = a.len;
    const n2 = b.len;
    const n = n1 + n2;
    const Item = struct { v: f64, head: bool };
    const pooled = try gpa.alloc(Item, n);
    defer gpa.free(pooled);
    for (a, 0..) |v, i| pooled[i] = .{ .v = v, .head = false };
    for (b, 0..) |v, i| pooled[n1 + i] = .{ .v = v, .head = true };
    std.mem.sort(Item, pooled, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return x.v < y.v;
        }
    }.lt);
    // Midranks; Σ(t³ - t) for the tie correction.
    var r_head: f64 = 0;
    var tie_sum: f64 = 0;
    var i: usize = 0;
    while (i < n) {
        var j = i + 1;
        while (j < n and pooled[j].v == pooled[i].v) j += 1;
        const t: f64 = @floatFromInt(j - i);
        const mid = (@as(f64, @floatFromInt(i + 1)) + @as(f64, @floatFromInt(j))) / 2;
        for (pooled[i..j]) |it| if (it.head) {
            r_head += mid;
        };
        tie_sum += t * t * t - t;
        i = j;
    }
    const f1: f64 = @floatFromInt(n1);
    const f2: f64 = @floatFromInt(n2);
    const u = r_head - f2 * (f2 + 1) / 2;
    var res: Mwu = .{ .u = u, .p_one_sided_greater = 1, .p_one_sided_less = 1, .effect_rb = 2 * u / (f1 * f2) - 1, .exact = false };
    if (n1 <= exact_max_n and n2 <= exact_max_n and tie_sum == 0) {
        const ui: usize = @intFromFloat(u);
        res.p_one_sided_greater = try exactTail(gpa, n2, n1, ui, .greater);
        res.p_one_sided_less = try exactTail(gpa, n2, n1, ui, .less);
        res.exact = true;
    } else {
        res.p_one_sided_greater = normalTail(n1, n2, u, tie_sum, .greater);
        res.p_one_sided_less = normalTail(n1, n2, u, tie_sum, .less);
    }
    return res;
}

pub const Tail = enum { greater, less };

/// P(U >= u) or P(U <= u) for U of a sample of `h` against `b` others,
/// without ties: counts arrangements by dynamic programming over (h, b,
/// u), f(h, b, u) = f(h-1, b, u-b) + f(h, b-1, u).
pub fn exactTail(gpa: std.mem.Allocator, h: usize, b: usize, u: usize, tail: Tail) !f64 {
    const max_u = h * b;
    const stride = max_u + 1;
    // Layers over h; each holds (b + 1) rows of counts.
    var prev = try gpa.alloc(f64, (b + 1) * stride);
    defer gpa.free(prev);
    var cur = try gpa.alloc(f64, (b + 1) * stride);
    defer gpa.free(cur);
    @memset(prev, 0);
    for (0..b + 1) |bb| prev[bb * stride] = 1; // h = 0: U = 0
    for (1..h + 1) |_| {
        @memset(cur, 0);
        cur[0] = 1; // b = 0: U = 0
        for (1..b + 1) |bb| for (0..stride) |uu| {
            var v = cur[(bb - 1) * stride + uu];
            if (uu >= bb) v += prev[bb * stride + uu - bb];
            cur[bb * stride + uu] = v;
        };
        std.mem.swap([]f64, &prev, &cur);
    }
    const row = prev[b * stride ..][0..stride];
    var total: f64 = 0;
    var tail_sum: f64 = 0;
    for (row, 0..) |c, uu| {
        total += c;
        if ((tail == .greater and uu >= u) or (tail == .less and uu <= u)) tail_sum += c;
    }
    return tail_sum / total;
}

/// The normal approximation with tie correction σ² = n1n2/12 ·
/// ((n+1) − Σ(t³−t)/(n(n−1))) and a continuity correction of 0.5.
pub fn normalTail(n1: usize, n2: usize, u: f64, tie_sum: f64, tail: Tail) f64 {
    const f1: f64 = @floatFromInt(n1);
    const f2: f64 = @floatFromInt(n2);
    const nn = f1 + f2;
    const mu = f1 * f2 / 2;
    const variance = f1 * f2 / 12 * ((nn + 1) - tie_sum / (nn * (nn - 1)));
    if (variance <= 0) return if ((tail == .greater and u >= mu) or (tail == .less and u <= mu)) 1 else 0;
    const sigma = @sqrt(variance);
    const z = switch (tail) {
        .greater => (u - mu - 0.5) / sigma,
        .less => (mu - u - 0.5) / sigma,
    };
    return 0.5 * erfc(z / std.math.sqrt2);
}

/// The complementary error function (Numerical Recipes' Chebyshev fit,
/// relative error below 1.2e-7).
pub fn erfc(x: f64) f64 {
    const z = @abs(x);
    const t = 1 / (1 + 0.5 * z);
    const r = t * @exp(-z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
    return if (x >= 0) r else 2 - r;
}

/// The median of `v` (sorts a copy).
pub fn median(gpa: std.mem.Allocator, v: []const f64) !f64 {
    if (v.len == 0) return 0;
    const s = try gpa.dupe(f64, v);
    defer gpa.free(s);
    std.mem.sort(f64, s, {}, std.sort.asc(f64));
    return if (s.len % 2 == 1) s[s.len / 2] else (s[s.len / 2 - 1] + s[s.len / 2]) / 2;
}

/// Standard deviation over mean (0 for fewer than 2 samples).
pub fn cv(v: []const f64) f64 {
    if (v.len < 2) return 0;
    var sum: f64 = 0;
    for (v) |x| sum += x;
    const mean = sum / @as(f64, @floatFromInt(v.len));
    if (mean == 0) return 0;
    var ss: f64 = 0;
    for (v) |x| ss += (x - mean) * (x - mean);
    return @sqrt(ss / @as(f64, @floatFromInt(v.len - 1))) / mean;
}

const gpa_t = std.testing.allocator;

test "mwu: exact p for 5v5 fully separated = 1/252" {
    const r = try mannWhitneyU(gpa_t, &.{ 1, 2, 3, 4, 5 }, &.{ 6, 7, 8, 9, 10 });
    try std.testing.expect(r.exact);
    try std.testing.expectEqual(@as(f64, 25), r.u);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 252.0), r.p_one_sided_greater, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), r.p_one_sided_less, 1e-12);
}

test "mwu: ties midranks" {
    // Pooled 1 2 2 3: ranks 1, 2.5, 2.5, 4. Head {2, 3}: R = 6.5, U = 3.5.
    const r = try mannWhitneyU(gpa_t, &.{ 1, 2 }, &.{ 2, 3 });
    try std.testing.expectEqual(@as(f64, 3.5), r.u);
    try std.testing.expect(!r.exact);
}

test "mwu: normal approx close to exact at n=20" {
    var worst: f64 = 0;
    var u: usize = 150;
    while (u <= 300) : (u += 10) {
        const e = try exactTail(gpa_t, 20, 20, u, .greater);
        const a = normalTail(20, 20, @floatFromInt(u), 0, .greater);
        worst = @max(worst, @abs(e - a));
    }
    try std.testing.expect(worst < 0.01);
}

test "mwu: effect size" {
    const sep = try mannWhitneyU(gpa_t, &.{ 1, 2, 3 }, &.{ 4, 5, 6 });
    try std.testing.expectEqual(@as(f64, 1), sep.effect_rb);
    const rev = try mannWhitneyU(gpa_t, &.{ 4, 5, 6 }, &.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(f64, -1), rev.effect_rb);
    const same = try mannWhitneyU(gpa_t, &.{ 1, 3, 5, 7 }, &.{ 2, 4, 6, 8 });
    try std.testing.expect(@abs(same.effect_rb) < 0.5);
}

test "stats: median and cv" {
    try std.testing.expectEqual(@as(f64, 2.5), try median(gpa_t, &.{ 4, 1, 3, 2 }));
    try std.testing.expectEqual(@as(f64, 0), cv(&.{ 5, 5, 5 }));
    try std.testing.expectApproxEqAbs(@as(f64, 1), erfc(0), 1e-7);
}
