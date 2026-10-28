//! `LatencyHistogram`: an HDR-style log-linear histogram with fixed memory
//! and constant-time `record` (E14.F03.S01.T01). Values below 128 ns are
//! exact; above, each power of two has 64 sub-buckets, so a reported
//! percentile is within 1.6 % of the true value. Range 0 .. 2^35 ns
//! (~34 s), clamped at the top.

const std = @import("std");

/// Linear (exact) buckets: 0..127.
const linear = 128;
/// Sub-buckets per power of two above the linear range.
const sub_buckets = 64;
/// Highest bit position kept (values clamp to 2^(max_bit+1) - 1).
const max_bit = 34;

/// Number of buckets.
pub const bucket_count = linear + (max_bit - 6) * sub_buckets;

/// Largest value recorded without clamping.
pub const max_value: u64 = (@as(u64, 1) << (max_bit + 1)) - 1;

/// Bucket index for `ns`.
pub fn bucketOf(ns: u64) usize {
    const v: u64 = @min(ns, max_value);
    if (v < linear) return @intCast(v);
    const b: u6 = @intCast(63 - @clz(v));
    const sub: usize = @intCast((v >> (b - 6)) & (sub_buckets - 1));
    return linear + (@as(usize, b) - 7) * sub_buckets + sub;
}

/// The largest value that falls into bucket `i`.
pub fn upperBound(i: usize) u64 {
    if (i < linear) return i;
    const k = i - linear;
    const b: u6 = @intCast(k / sub_buckets + 7);
    const sub: u64 = k % sub_buckets;
    return ((sub_buckets + sub + 1) << (b - 6)) - 1;
}

/// A fixed-size latency histogram (about 7.5 KiB). Single writer; readers
/// take a copy.
pub const LatencyHistogram = struct {
    counts: [bucket_count]u32 = @splat(0),
    total: u64 = 0,
    sum: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    /// Records one value.
    pub fn record(h: *LatencyHistogram, ns: u64) void {
        const i = bucketOf(ns);
        h.counts[i] +|= 1;
        h.total += 1;
        h.sum +|= ns;
        h.min = @min(h.min, ns);
        h.max = @max(h.max, ns);
    }

    /// The value at percentile `p` (0..100): the upper bound of the bucket
    /// holding the rank-ceil(p/100 * total) sample, capped at `max`. 0 when
    /// empty.
    pub fn percentile(h: *const LatencyHistogram, p: f64) u64 {
        if (h.total == 0) return 0;
        const want_f = @ceil(@min(100.0, @max(0.0, p)) / 100.0 * @as(f64, @floatFromInt(h.total)));
        const want: u64 = @max(1, @as(u64, @intFromFloat(want_f)));
        var seen: u64 = 0;
        for (h.counts, 0..) |c, i| {
            seen += c;
            if (seen >= want) return @min(upperBound(i), h.max);
        }
        return h.max;
    }

    /// Mean of the recorded values (0 when empty).
    pub fn mean(h: *const LatencyHistogram) f64 {
        if (h.total == 0) return 0;
        return @as(f64, @floatFromInt(h.sum)) / @as(f64, @floatFromInt(h.total));
    }

    /// Adds every sample of `o`.
    pub fn merge(h: *LatencyHistogram, o: *const LatencyHistogram) void {
        for (&h.counts, o.counts) |*a, b| a.* +|= b;
        h.total += o.total;
        h.sum +|= o.sum;
        h.min = @min(h.min, o.min);
        h.max = @max(h.max, o.max);
    }

    /// Forgets every sample.
    pub fn reset(h: *LatencyHistogram) void {
        h.* = .{};
    }
};

/// "The last N samples" semantics with two histograms: samples go to
/// `current`; when it holds `window` samples it becomes `previous`.
/// Percentiles cover both, i.e. between N and 2N recent samples.
pub const RollingHistogram = struct {
    current: LatencyHistogram = .{},
    previous: LatencyHistogram = .{},
    window: u32 = 1000,

    /// Records one value.
    pub fn record(r: *RollingHistogram, ns: u64) void {
        if (r.current.total >= r.window) {
            r.previous = r.current;
            r.current.reset();
        }
        r.current.record(ns);
    }

    /// Percentile over the recent samples.
    pub fn percentile(r: *const RollingHistogram, p: f64) u64 {
        var m = r.previous;
        m.merge(&r.current);
        return m.percentile(p);
    }
};

test "histogram: exact below 128" {
    var h: LatencyHistogram = .{};
    for (0..128) |v| h.record(v);
    for (0..128) |v| try std.testing.expectEqual(@as(u64, v), upperBound(bucketOf(v)));
    try std.testing.expectEqual(@as(u64, 63), h.percentile(50));
    try std.testing.expectEqual(@as(u64, 127), h.percentile(100));
}

test "histogram: relative error ≤ 1.6 % over random values" {
    var prng = std.Random.DefaultPrng.init(0x14);
    const r = prng.random();
    for (0..200_000) |_| {
        const v = r.intRangeAtMost(u64, 0, max_value);
        const ub = upperBound(bucketOf(v));
        try std.testing.expect(ub >= v);
        try std.testing.expect(@as(f64, @floatFromInt(ub - v)) <= 0.016 * @as(f64, @floatFromInt(v)) + 0.5);
    }
    // Clamped above the range.
    try std.testing.expectEqual(bucket_count - 1, bucketOf(std.math.maxInt(u64)));
}

test "histogram: percentile monotone" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var h: LatencyHistogram = .{};
    for (0..10_000) |_| h.record(r.intRangeAtMost(u64, 1, 50_000_000));
    var prev: u64 = 0;
    var p: f64 = 0;
    while (p <= 100) : (p += 0.5) {
        const v = h.percentile(p);
        try std.testing.expect(v >= prev);
        prev = v;
    }
    try std.testing.expectEqual(h.max, h.percentile(100));
}

test "histogram: merge equals combined" {
    var prng = std.Random.DefaultPrng.init(9);
    const r = prng.random();
    var a: LatencyHistogram = .{};
    var b: LatencyHistogram = .{};
    var all: LatencyHistogram = .{};
    for (0..5000) |i| {
        const v = r.intRangeAtMost(u64, 0, 1 << 30);
        if (i % 2 == 0) a.record(v) else b.record(v);
        all.record(v);
    }
    a.merge(&b);
    try std.testing.expectEqualSlices(u32, &all.counts, &a.counts);
    try std.testing.expectEqual(all.percentile(99), a.percentile(99));
    try std.testing.expectEqual(all.mean(), a.mean());
}

test "histogram: rolling window" {
    var r: RollingHistogram = .{ .window = 10 };
    for (0..10) |_| r.record(1_000_000);
    for (0..10) |_| r.record(10);
    for (0..10) |_| r.record(10);
    // The 1 ms samples have rolled out.
    try std.testing.expectEqual(@as(u64, 10), r.percentile(100));
}
