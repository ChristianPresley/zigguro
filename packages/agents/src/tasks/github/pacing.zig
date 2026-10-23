//! Request pacing for the GitHub client (E13.F03.S03.T01), following
//! GitHub's REST best practices: one request at a time (the client's
//! queue), at least a second between mutating requests, and waiting out
//! rate limits instead of retrying into them.
//!
//! - `retry-after` (seconds) on a 403 or 429: wait that long.
//! - `x-ratelimit-remaining: 0`: wait until `x-ratelimit-reset` (epoch
//!   seconds), on that response and before the next request.
//! - Any other 429, or a 403 whose message mentions a rate limit (the
//!   secondary limits): wait 60 s, doubling each attempt.
//! - `x-poll-interval` (seconds): the next request waits that long.
//!
//! After `max_attempts` limited responses in a row the request fails.
//! All waits go through the injected clock.

const std = @import("std");
const zg_ai = @import("zg_ai");

const Io = std.Io;
const Header = std.http.Header;

pub const Clock = zg_ai.ratelimit.Clock;

pub const Policy = struct {
    mutation_gap_ms: u64 = 1000,
    /// The first wait for a secondary limit without `retry-after`.
    secondary_min_ms: u64 = 60_000,
    max_attempts: u8 = 5,
    /// The longest single wait (a primary limit resets within an hour).
    max_wait_ms: u64 = 3_600_000 + 60_000,
};

pub const Pacer = struct {
    clock: Clock = .real,
    policy: Policy = .{},
    /// When the last mutating request finished.
    last_mutation_ms: ?i64 = null,
    /// No request before this (rate limits, poll intervals).
    not_before_ms: i64 = 0,

    /// Waits until a request may go out.
    pub fn wait(p: *Pacer, io: Io, mutation: bool) Io.Cancelable!void {
        var t = p.not_before_ms;
        if (mutation) if (p.last_mutation_ms) |l| {
            t = @max(t, l + @as(i64, @intCast(p.policy.mutation_gap_ms)));
        };
        const now = p.clock.now(io);
        if (t > now) try p.clock.sleep(io, @intCast(t - now));
    }

    /// Records a response: when it finished and what its headers say about
    /// the next request.
    pub fn observe(p: *Pacer, io: Io, mutation: bool, headers: []const Header) void {
        const now = p.clock.now(io);
        if (mutation) p.last_mutation_ms = now;
        if (secondsHeader(headers, "x-poll-interval")) |s| p.delay(now, s * 1000);
        if (exhausted(headers)) if (resetWait(headers, now)) |ms| p.delay(now, ms);
    }

    /// Holds every request for `ms` from `now`.
    pub fn delay(p: *Pacer, now: i64, ms: u64) void {
        const capped: i64 = @intCast(@min(ms, p.policy.max_wait_ms));
        p.not_before_ms = @max(p.not_before_ms, now + capped);
    }

    /// How long to wait before retrying a limited response (`attempt` is
    /// 1 for the first try), or null when it is not limited.
    pub fn limitWait(p: *const Pacer, status: u16, headers: []const Header, message: ?[]const u8, now: i64, attempt: u8) ?u64 {
        if (status != 403 and status != 429) return null;
        if (secondsHeader(headers, "retry-after")) |s| return s * 1000;
        if (exhausted(headers)) return resetWait(headers, now) orelse p.policy.secondary_min_ms;
        const secondary = status == 429 or if (message) |m| containsIgnoreCase(m, "rate limit") else false;
        if (!secondary) return null;
        const shift: u6 = @intCast(@min(attempt -| 1, 20));
        return p.policy.secondary_min_ms << shift;
    }
};

fn exhausted(headers: []const Header) bool {
    const v = get(headers, "x-ratelimit-remaining") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, v, " "), "0");
}

/// Milliseconds until `x-ratelimit-reset`, at least a second.
fn resetWait(headers: []const Header, now: i64) ?u64 {
    const reset_s = secondsHeader(headers, "x-ratelimit-reset") orelse return null;
    const reset_ms: i64 = @intCast(@min(reset_s, std.math.maxInt(i64) / 1000) * 1000);
    return @intCast(@max(reset_ms - now, 1000));
}

fn secondsHeader(headers: []const Header, name: []const u8) ?u64 {
    const v = get(headers, name) orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, v, " "), 10) catch null;
}

pub fn get(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    return false;
}

test "limit waits" {
    const p: Pacer = .{};
    const now: i64 = 1_000_000_000_000;
    try std.testing.expectEqual(null, p.limitWait(200, &.{}, null, now, 1));
    try std.testing.expectEqual(null, p.limitWait(403, &.{}, "Resource not accessible by integration", now, 1));
    try std.testing.expectEqual(30_000, p.limitWait(403, &.{.{ .name = "Retry-After", .value = "30" }}, null, now, 1));
    try std.testing.expectEqual(90_000, p.limitWait(403, &.{
        .{ .name = "x-ratelimit-remaining", .value = "0" },
        .{ .name = "x-ratelimit-reset", .value = "1000000090" },
    }, null, now, 1));
    try std.testing.expectEqual(60_000, p.limitWait(429, &.{}, null, now, 1));
    try std.testing.expectEqual(240_000, p.limitWait(403, &.{}, "You have exceeded a secondary Rate Limit.", now, 3));
}
