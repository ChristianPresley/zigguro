//! `RetryPolicy`: which failures are retried and how long to wait.
//! Full-jitter exponential backoff; a server `Retry-After` (seconds or
//! HTTP-date, RFC 9110) sets the wait instead.

const std = @import("std");
const Provider = @import("Provider.zig");
const timefmt = @import("timefmt.zig");

const StreamError = Provider.StreamError;

pub const Decision = enum {
    retry,
    no_retry,
    /// Retry only after the server-specified wait (429 with `retry-after`).
    retry_after_only,
};

pub const RetryPolicy = struct {
    max_attempts: u8 = 4,
    base_ms: u32 = 500,
    cap_ms: u32 = 30_000,
    retry_stream_stall: bool = true,
    /// A `retry-after` longer than this is not waited out.
    max_retry_after_ms: u64 = 10 * 60_000,

    /// Classifies one failure. `StreamTruncated` must only reach here when
    /// no content was received; otherwise recovery decides.
    pub fn classify(p: RetryPolicy, err: StreamError, status: ?u16, has_retry_after: bool) Decision {
        if (status) |s| switch (s) {
            408, 409, 500, 502, 503, 504, 529 => return .retry,
            429 => return if (has_retry_after) .retry_after_only else .no_retry,
            400, 401, 402, 403, 404, 413, 422 => return .no_retry,
            else => {},
        };
        return switch (err) {
            error.Network, error.Timeout, error.Overloaded, error.ServerError, error.StreamTruncated => .retry,
            error.StreamStalled => if (p.retry_stream_stall) .retry else .no_retry,
            // A spend-cap 429 carries no retry-after.
            error.RateLimited => if (has_retry_after) .retry_after_only else .no_retry,
            else => .no_retry,
        };
    }

    /// Full jitter: uniform in [0, min(cap, base × 2^attempt)].
    pub fn backoffMs(p: RetryPolicy, attempt: u8, random: std.Random) u64 {
        const shift: u6 = @intCast(@min(attempt, 30));
        const ceiling = @min(@as(u64, p.cap_ms), @as(u64, p.base_ms) << shift);
        return random.uintAtMost(u64, ceiling);
    }

    /// The wait before retry number `attempt + 1`, or null to give up.
    pub fn delayMs(p: RetryPolicy, d: Decision, attempt: u8, retry_after_ms: ?u64, random: std.Random) ?u64 {
        if (d == .no_retry or attempt + 1 >= p.max_attempts) return null;
        if (retry_after_ms) |ra| return if (ra > p.max_retry_after_ms) null else ra;
        if (d == .retry_after_only) return null;
        return p.backoffMs(attempt, random);
    }
};

/// Parses a `Retry-After` value (delta seconds or IMF-fixdate) into a wait
/// in milliseconds relative to `now_ms` (Unix ms). Past dates give 0.
pub fn parseRetryAfter(value: []const u8, now_ms: i64) ?u64 {
    const v = std.mem.trim(u8, value, " \t");
    if (std.fmt.parseInt(u64, v, 10)) |secs| return secs *| 1000 else |_| {}
    const at = timefmt.parseHttpDate(v) orelse return null;
    return if (at > now_ms) @intCast(at - now_ms) else 0;
}

const testing = std.testing;

test "classify_table" {
    const p: RetryPolicy = .{};
    const Case = struct { err: StreamError, status: ?u16, ra: bool, want: Decision };
    const cases = [_]Case{
        .{ .err = error.Timeout, .status = 408, .ra = false, .want = .retry },
        .{ .err = error.InvalidRequest, .status = 409, .ra = false, .want = .retry },
        .{ .err = error.RateLimited, .status = 429, .ra = true, .want = .retry_after_only },
        .{ .err = error.RateLimited, .status = 429, .ra = false, .want = .no_retry },
        .{ .err = error.ServerError, .status = 500, .ra = false, .want = .retry },
        .{ .err = error.ServerError, .status = 502, .ra = false, .want = .retry },
        .{ .err = error.ServerError, .status = 503, .ra = false, .want = .retry },
        .{ .err = error.ServerError, .status = 504, .ra = false, .want = .retry },
        .{ .err = error.Overloaded, .status = 529, .ra = false, .want = .retry },
        .{ .err = error.InvalidRequest, .status = 400, .ra = false, .want = .no_retry },
        .{ .err = error.Auth, .status = 401, .ra = false, .want = .no_retry },
        .{ .err = error.InvalidRequest, .status = 402, .ra = false, .want = .no_retry },
        .{ .err = error.Auth, .status = 403, .ra = false, .want = .no_retry },
        .{ .err = error.InvalidRequest, .status = 404, .ra = false, .want = .no_retry },
        .{ .err = error.ContextOverflow, .status = 413, .ra = false, .want = .no_retry },
        .{ .err = error.Network, .status = null, .ra = false, .want = .retry },
        .{ .err = error.StreamStalled, .status = null, .ra = false, .want = .retry },
        .{ .err = error.StreamTruncated, .status = null, .ra = false, .want = .retry },
        .{ .err = error.Canceled, .status = null, .ra = false, .want = .no_retry },
        .{ .err = error.Protocol, .status = null, .ra = false, .want = .no_retry },
    };
    for (cases) |c| {
        errdefer std.debug.print("{t} {?d}\n", .{ c.err, c.status });
        try testing.expectEqual(c.want, p.classify(c.err, c.status, c.ra));
    }
    const no_stall: RetryPolicy = .{ .retry_stream_stall = false };
    try testing.expectEqual(Decision.no_retry, no_stall.classify(error.StreamStalled, null, false));
}

test "retry_after_seconds_and_date" {
    const now: i64 = 784_111_777_000; // Sun, 06 Nov 1994 08:49:37 GMT
    try testing.expectEqual(@as(?u64, 3000), parseRetryAfter("3", now));
    try testing.expectEqual(@as(?u64, 0), parseRetryAfter(" 0 ", now));
    try testing.expectEqual(@as(?u64, 23_000), parseRetryAfter("Sun, 06 Nov 1994 08:50:00 GMT", now));
    try testing.expectEqual(@as(?u64, 0), parseRetryAfter("Sun, 06 Nov 1994 08:00:00 GMT", now));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("soon", now));
    const p: RetryPolicy = .{};
    var rng = std.Random.DefaultPrng.init(1);
    try testing.expectEqual(@as(?u64, 3000), p.delayMs(.retry_after_only, 0, 3000, rng.random()));
    try testing.expectEqual(@as(?u64, null), p.delayMs(.retry_after_only, 0, null, rng.random()));
    try testing.expectEqual(@as(?u64, null), p.delayMs(.retry, 0, 60 * 60_000, rng.random()));
    try testing.expectEqual(@as(?u64, null), p.delayMs(.retry, 3, null, rng.random()));
    try testing.expectEqual(@as(?u64, null), p.delayMs(.no_retry, 0, null, rng.random()));
}

test "jitter_bounds" {
    const p: RetryPolicy = .{ .base_ms = 500, .cap_ms = 30_000 };
    var rng = std.Random.DefaultPrng.init(7);
    var max_seen = [_]u64{0} ** 8;
    for (0..10_000) |i| {
        const attempt: u8 = @intCast(i % 8);
        const d = p.backoffMs(attempt, rng.random());
        const ceiling = @min(@as(u64, 30_000), @as(u64, 500) << @intCast(attempt));
        try testing.expect(d <= ceiling);
        max_seen[attempt] = @max(max_seen[attempt], d);
    }
    // Spread: each attempt's samples reach the top half of their range.
    for (max_seen, 0..) |m, a| try testing.expect(m * 2 >= @min(@as(u64, 30_000), @as(u64, 500) << @intCast(a)));
}
