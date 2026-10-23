//! Deterministic jitter (E13.F02.S01.T02): each automation fires a fixed
//! delay after its nominal time, derived from the workspace and the
//! automation name, so many workspaces' `0 9 * * *` jobs do not all start
//! in the same second, and the delay is the same across restarts.

const std = @import("std");
const cron = @import("cron.zig");
const zone = @import("zone.zig");

/// The delay for `name` in seconds, at most `jitter_s`.
pub fn offsetS(workspace_key: []const u8, name: []const u8, jitter_s: u32) u32 {
    if (jitter_s == 0) return 0;
    var h: std.hash.Wyhash = .init(0);
    h.update(workspace_key);
    h.update("\x00");
    h.update(name);
    return @intCast(h.final() % (@as(u64, jitter_s) + 1));
}

/// The default when an automation sets none: no jitter for schedules
/// that fire more often than every 10 minutes, otherwise a tenth of the
/// interval, at most 5 minutes.
pub fn defaultS(c: *const cron.CronExpr) u32 {
    // Firing at most once a week: a long interval.
    const interval = shortestIntervalS(c) orelse std.math.maxInt(i64);
    if (interval < 10 * 60) return 0;
    return @intCast(@min(@divTrunc(interval, 10), 5 * 60));
}

/// The shortest gap between fires over a sample eight days (UTC), or
/// null when it fires less than twice in them.
fn shortestIntervalS(c: *const cron.CronExpr) ?i64 {
    const utc = zone.utcZone();
    // Monday 2026-01-05 00:00 UTC; eight days so a weekly job shows a gap.
    const start: i64 = 1_767_571_200;
    var prev = c.next(utc, start - 1) orelse return null;
    var best: ?i64 = null;
    var n: u32 = 0;
    while (n < 64) : (n += 1) {
        const t = c.next(utc, prev) orelse break;
        if (t - start > 8 * 86_400) break;
        best = if (best) |b| @min(b, t - prev) else t - prev;
        prev = t;
    }
    return best;
}

const testing = std.testing;

test "jitter_deterministic_and_bounded" {
    try testing.expectEqual(offsetS("ws", "daily", 120), offsetS("ws", "daily", 120));
    var seen_nonzero = false;
    var differs = false;
    const first = offsetS("ws", "a0", 600);
    var buf: [8]u8 = undefined;
    for (0..200) |i| {
        const name = std.fmt.bufPrint(&buf, "a{d}", .{i}) catch unreachable;
        const o = offsetS("ws", name, 600);
        try testing.expect(o <= 600);
        if (o != 0) seen_nonzero = true;
        if (o != first) differs = true;
    }
    try testing.expect(seen_nonzero and differs);
    try testing.expectEqual(@as(u32, 0), offsetS("ws", "x", 0));
    // Another workspace, another delay (for this pair).
    try testing.expect(offsetS("ws-1", "daily", 3600) != offsetS("ws-2", "daily", 3600));
    try testing.expectEqual(@as(u32, 0), defaultS(&(try cron.CronExpr.parse("*/5 * * * *"))));
    try testing.expectEqual(@as(u32, 60), defaultS(&(try cron.CronExpr.parse("*/10 * * * *"))));
    try testing.expectEqual(@as(u32, 300), defaultS(&(try cron.CronExpr.parse("0 9 * * *"))));
    try testing.expectEqual(@as(u32, 300), defaultS(&(try cron.CronExpr.parse("0 9 * * 1"))));
    try testing.expectEqual(@as(u32, 300), defaultS(&(try cron.CronExpr.parse("0 9 1 1 *"))));
}
