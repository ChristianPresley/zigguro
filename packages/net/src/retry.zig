//! Retry policy: which failures retry, exponential backoff with full jitter
//! and `Retry-After` (RFC 9110 section 10.2.3).

const std = @import("std");

pub const RetryPolicy = enum {
    /// Retry only idempotent methods (GET, HEAD, PUT, DELETE, OPTIONS, TRACE).
    idempotent_only,
    always,
    never,
};

/// Backoff parameters.
pub const Backoff = struct {
    base_ms: u64 = 500,
    cap_ms: u64 = 30_000,

    /// Full jitter: a uniform delay in `[0, min(cap, base * 2^attempt)]`.
    pub fn delayMs(b: Backoff, attempt: u32, random: u64) u64 {
        const shift: u6 = @intCast(@min(attempt, 40));
        const ceiling = @min(b.cap_ms, b.base_ms *| (@as(u64, 1) << shift));
        return random % (ceiling + 1);
    }
};

/// True for statuses worth retrying: 408, 429, 500, 502, 503, 504 and 529
/// (Anthropic "overloaded").
pub fn retryableStatus(status: std.http.Status) bool {
    return switch (@intFromEnum(status)) {
        408, 429, 500, 502, 503, 504, 529 => true,
        else => false,
    };
}

pub fn methodAllowed(policy: RetryPolicy, method: std.http.Method) bool {
    return switch (policy) {
        .never => false,
        .always => true,
        .idempotent_only => switch (method) {
            .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE => true,
            else => false,
        },
    };
}

/// Parses `Retry-After` (delta-seconds or IMF-fixdate) into milliseconds
/// from `now_unix_s`; null when malformed.
pub fn parseRetryAfter(value_in: []const u8, now_unix_s: i64) ?u64 {
    const value = std.mem.trim(u8, value_in, " \t");
    if (value.len == 0) return null;
    if (std.fmt.parseInt(u64, value, 10)) |s| return s *| 1000 else |_| {}
    const t = parseImfFixdate(value) orelse return null;
    return if (t <= now_unix_s) 0 else @as(u64, @intCast(t - now_unix_s)) * 1000;
}

/// `Sun, 06 Nov 1994 08:49:37 GMT` to Unix seconds.
pub fn parseImfFixdate(s: []const u8) ?i64 {
    if (s.len != 29 or s[3] != ',' or s[4] != ' ' or s[7] != ' ' or s[11] != ' ' or s[16] != ' ' or
        s[19] != ':' or s[22] != ':' or s[25] != ' ' or !std.mem.eql(u8, s[26..], "GMT")) return null;
    const day = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var month: u8 = 0;
    for (months, 1..) |m, i| {
        if (std.mem.eql(u8, s[8..11], m)) month = @intCast(i);
    }
    if (month == 0) return null;
    const year = std.fmt.parseInt(i64, s[12..16], 10) catch return null;
    const hh = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    const mm = std.fmt.parseInt(i64, s[20..22], 10) catch return null;
    const ss = std.fmt.parseInt(i64, s[23..25], 10) catch return null;
    if (day < 1 or day > 31 or hh > 23 or mm > 59 or ss > 60) return null;
    return daysFromCivil(year, month, day) * 86400 + hh * 3600 + mm * 60 + ss;
}

/// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant).
fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "retry: Retry-After seconds and HTTP-date" {
    try std.testing.expectEqual(@as(?u64, 120_000), parseRetryAfter("120", 0));
    try std.testing.expectEqual(@as(?i64, 784111777), parseImfFixdate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try std.testing.expectEqual(@as(?u64, 7000), parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", 784111770));
    try std.testing.expectEqual(@as(?u64, 0), parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", 784111800));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfter("soon", 0));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfter("Sun, 06 Foo 1994 08:49:37 GMT", 0));
    try std.testing.expectEqual(@as(?i64, 951782400), parseImfFixdate("Tue, 29 Feb 2000 00:00:00 GMT"));
}

test "retry: backoff jitter bounds" {
    const b: Backoff = .{};
    var prng: std.Random.DefaultPrng = .init(42);
    for (0..10) |attempt| {
        const ceiling = @min(b.cap_ms, b.base_ms << @intCast(attempt));
        for (0..200) |_| try std.testing.expect(b.delayMs(@intCast(attempt), prng.random().int(u64)) <= ceiling);
    }
    try std.testing.expectEqual(@as(u64, 500), b.delayMs(0, 500));
    try std.testing.expectEqual(@as(u64, 0), b.delayMs(0, 501));
    try std.testing.expect(b.delayMs(100, std.math.maxInt(u64)) <= b.cap_ms);
}

test "retry: statuses and methods" {
    try std.testing.expect(retryableStatus(.too_many_requests));
    try std.testing.expect(retryableStatus(@enumFromInt(529)));
    try std.testing.expect(!retryableStatus(.bad_request));
    try std.testing.expect(methodAllowed(.idempotent_only, .GET));
    try std.testing.expect(!methodAllowed(.idempotent_only, .POST));
    try std.testing.expect(methodAllowed(.always, .POST));
    try std.testing.expect(!methodAllowed(.never, .GET));
}
