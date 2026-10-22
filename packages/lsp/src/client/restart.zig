//! Crash restart policy: exponential backoff (1 s, 2 s, 4 s, ... capped at
//! 60 s) counted over the crashes in a sliding window, and `disable` after
//! `max_crashes` crashes inside `window` (5 in 3 minutes). The clock is
//! passed in, so tests drive it directly.

const std = @import("std");
const Io = std.Io;

pub const Decision = union(enum) {
    /// Restart after this delay.
    restart_after: Io.Duration,
    /// Too many crashes: stay down until the user re-enables the server.
    disable,
};

pub const RestartPolicy = struct {
    max_crashes: u32 = 5,
    window: Io.Duration = .fromSeconds(180),
    base: Io.Duration = .fromSeconds(1),
    cap: Io.Duration = .fromSeconds(60),
    /// Crash times (ns, `.awake` clock), oldest first; at most `max_crashes`.
    times: [16]i96 = undefined,
    n: u32 = 0,

    /// Records a crash at `now_ns` and decides what to do.
    pub fn onCrash(p: *RestartPolicy, now_ns: i96) Decision {
        std.debug.assert(p.max_crashes > 0 and p.max_crashes <= p.times.len);
        // Forget crashes that left the window.
        const horizon = now_ns - p.window.nanoseconds;
        var keep: u32 = 0;
        for (p.times[0..p.n]) |t| if (t > horizon) {
            p.times[keep] = t;
            keep += 1;
        };
        p.n = keep;
        if (p.n == p.max_crashes) {
            std.mem.copyForwards(i96, p.times[0 .. p.n - 1], p.times[1..p.n]);
            p.n -= 1;
        }
        p.times[p.n] = now_ns;
        p.n += 1;
        if (p.n >= p.max_crashes) return .disable;
        const shift: u6 = @intCast(@min(p.n - 1, 30));
        const delay = @min(p.base.nanoseconds << shift, p.cap.nanoseconds);
        return .{ .restart_after = .{ .nanoseconds = delay } };
    }

    /// Forgets all crashes (the user re-enabled the server).
    pub fn reset(p: *RestartPolicy) void {
        p.n = 0;
    }
};

const s: i96 = std.time.ns_per_s;

test "restart: backoff 1/2/4 s" {
    var p: RestartPolicy = .{};
    try std.testing.expectEqual(@as(i96, 1 * s), p.onCrash(0).restart_after.nanoseconds);
    try std.testing.expectEqual(@as(i96, 2 * s), p.onCrash(10 * s).restart_after.nanoseconds);
    try std.testing.expectEqual(@as(i96, 4 * s), p.onCrash(20 * s).restart_after.nanoseconds);
    // Crashes older than the window no longer count.
    var q: RestartPolicy = .{};
    _ = q.onCrash(0);
    _ = q.onCrash(1 * s);
    try std.testing.expectEqual(@as(i96, 1 * s), q.onCrash(400 * s).restart_after.nanoseconds);
}

test "restart: disabled after 5 crashes in 3 min" {
    var p: RestartPolicy = .{};
    for (0..4) |i| try std.testing.expect(p.onCrash(@as(i96, @intCast(i)) * 30 * s) == .restart_after);
    try std.testing.expect(p.onCrash(150 * s) == .disable);
    // Spread over more than 3 minutes: never disabled.
    var q: RestartPolicy = .{};
    for (0..20) |i| try std.testing.expect(q.onCrash(@as(i96, @intCast(i)) * 50 * s) == .restart_after);
    // Backoff caps at 60 s.
    var r: RestartPolicy = .{ .max_crashes = 16, .window = .fromSeconds(100_000) };
    var last: i96 = 0;
    for (0..10) |i| last = r.onCrash(@as(i96, @intCast(i)) * s).restart_after.nanoseconds;
    try std.testing.expectEqual(@as(i96, 60 * s), last);
}
