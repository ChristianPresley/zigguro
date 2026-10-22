//! When to check for updates (E17.F04.S01.T02): 20 s after the first
//! frame, then every 6 h with ±30 min of uniform jitter; network failures
//! back off 1 min, 5 min, 30 min, then rejoin the normal schedule. Pure:
//! callers pass the clock and the random bits, and keep one deadline.

const std = @import("std");

/// Delay of the first automatic check after the first frame.
pub const first_delay_ms: i64 = 20 * std.time.ms_per_s;
/// Interval between checks.
pub const interval_ms: i64 = 6 * std.time.ms_per_hour;
/// Half-width of the uniform jitter around `interval_ms`.
pub const jitter_ms: i64 = 30 * std.time.ms_per_min;
/// Retry delays after consecutive network failures.
pub const backoff_ms = [_]i64{ 1 * std.time.ms_per_min, 5 * std.time.ms_per_min, 30 * std.time.ms_per_min };

/// The first deadline, `first_delay_ms` after the first frame.
pub fn first(first_frame_ms: i64) i64 {
    return first_frame_ms + first_delay_ms;
}

/// The deadline after a completed check at `now_ms`.
pub fn next(now_ms: i64, random: u64) i64 {
    const span: u64 = @intCast(2 * jitter_ms + 1);
    const offset: i64 = @as(i64, @intCast(random % span)) - jitter_ms;
    return now_ms + interval_ms + offset;
}

/// The deadline after the `failures`-th consecutive network failure
/// (1-based); past the backoff table, the normal schedule.
pub fn retry(now_ms: i64, failures: u32, random: u64) i64 {
    if (failures == 0) return next(now_ms, random);
    if (failures <= backoff_ms.len) return now_ms + backoff_ms[failures - 1];
    return next(now_ms, random);
}

/// True when `deadline_ms` has passed, e.g. on waking from sleep: check
/// once, then schedule from now.
pub fn due(deadline_ms: i64, now_ms: i64) bool {
    return now_ms >= deadline_ms;
}

const testing = std.testing;

test "schedule: jitter stays within ±30 min" {
    var prng: std.Random.DefaultPrng = .init(42);
    var lo: i64 = std.math.maxInt(i64);
    var hi: i64 = std.math.minInt(i64);
    for (0..10_000) |_| {
        const d = next(0, prng.random().int(u64));
        lo = @min(lo, d);
        hi = @max(hi, d);
        try testing.expect(d >= interval_ms - jitter_ms and d <= interval_ms + jitter_ms);
    }
    // Uniform: both ends are approached.
    try testing.expect(lo < interval_ms - jitter_ms + std.time.ms_per_min);
    try testing.expect(hi > interval_ms + jitter_ms - std.time.ms_per_min);
    try testing.expectEqual(interval_ms - jitter_ms, next(0, 0));
    try testing.expectEqual(interval_ms + jitter_ms, next(0, @intCast(2 * jitter_ms)));
}

test "schedule: first check, backoff, overdue" {
    try testing.expectEqual(@as(i64, 1_000 + 20_000), first(1_000));
    try testing.expectEqual(@as(i64, 60_000), retry(0, 1, 0));
    try testing.expectEqual(@as(i64, 300_000), retry(0, 2, 0));
    try testing.expectEqual(@as(i64, 1_800_000), retry(0, 3, 0));
    try testing.expectEqual(next(0, 7), retry(0, 4, 7));
    try testing.expect(due(100, 100));
    try testing.expect(!due(101, 100));
}
