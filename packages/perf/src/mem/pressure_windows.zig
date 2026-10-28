//! Windows pressure source (E14.F04.S02.T01): the low and high memory
//! resource notifications, on one task.
//!
//! - `normal`: wait on `low` (and the stop event) with no timeout. When it
//!   signals: `critical`, reclaim.
//! - `critical`: `low` stays signalled while memory is low, so wait on
//!   `high` with a 5 s timeout instead. On a timeout, if `low` no longer
//!   holds, back to `normal` (memory is between the thresholds); if it
//!   still holds and the last reclaim is 30 s old, reclaim again. When
//!   `high` signals: `normal`.
//!
//! The 5 s wake exists only while memory is low.

const std = @import("std");
const pressure = @import("pressure.zig");

/// How a wait ended.
pub const Wait = enum { signaled, timeout, stop };

/// The handle layer (real kernel32 calls, or a fake in tests).
pub const Ops = struct {
    ctx: ?*anyopaque = null,
    wait_low: *const fn (ctx: ?*anyopaque) Wait,
    wait_high: *const fn (ctx: ?*anyopaque, timeout_ms: u32) Wait,
    query_low: *const fn (ctx: ?*anyopaque) bool,
    now_ms: *const fn (ctx: ?*anyopaque) u64,
};

pub const critical_poll_ms = 5_000;
pub const repeat_reclaim_ms = 30_000;

/// What a step asks the monitor to do.
pub const Action = enum { none, reclaim, normal };

/// The state machine; `step` blocks in one wait.
pub const Machine = struct {
    state: enum { normal, critical } = .normal,
    last_reclaim_ms: u64 = 0,

    /// One wait and its transition; null when stopped.
    pub fn step(m: *Machine, ops: Ops) ?Action {
        switch (m.state) {
            .normal => switch (ops.wait_low(ops.ctx)) {
                .stop => return null,
                .timeout => return .none,
                .signaled => {
                    m.state = .critical;
                    m.last_reclaim_ms = ops.now_ms(ops.ctx);
                    return .reclaim;
                },
            },
            .critical => switch (ops.wait_high(ops.ctx, critical_poll_ms)) {
                .stop => return null,
                .signaled => {
                    m.state = .normal;
                    return .normal;
                },
                .timeout => {
                    if (!ops.query_low(ops.ctx)) {
                        m.state = .normal;
                        return .normal;
                    }
                    const now = ops.now_ms(ops.ctx);
                    if (now -| m.last_reclaim_ms < repeat_reclaim_ms) return .none;
                    m.last_reclaim_ms = now;
                    return .reclaim;
                },
            },
        }
    }
};

const win = struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;
    const WAIT_TIMEOUT: u32 = 0x102;
    const INFINITE: u32 = 0xffff_ffff;
    extern "kernel32" fn CreateMemoryResourceNotification(kind: c_int) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn QueryMemoryResourceNotification(h: HANDLE, state: *BOOL) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForMultipleObjects(n: u32, handles: [*]const HANDLE, wait_all: BOOL, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
};

/// The real source: the two notification handles and a stop event.
pub const Notifications = struct {
    gpa: std.mem.Allocator,
    sink: pressure.OsSink,
    low: win.HANDLE,
    high: win.HANDLE,
    stop_event: win.HANDLE,
    machine: Machine = .{},

    /// Creates the handles; null when they are unavailable.
    pub fn open(gpa: std.mem.Allocator, sink: pressure.OsSink) !?*Notifications {
        const low = win.CreateMemoryResourceNotification(0) orelse return null;
        const high = win.CreateMemoryResourceNotification(1) orelse {
            win.windows.CloseHandle(low);
            return null;
        };
        const stop_event = win.CreateEventW(null, .TRUE, .FALSE, null) orelse {
            win.windows.CloseHandle(low);
            win.windows.CloseHandle(high);
            return null;
        };
        const n = try gpa.create(Notifications);
        n.* = .{ .gpa = gpa, .sink = sink, .low = low, .high = high, .stop_event = stop_event };
        return n;
    }

    fn ops(n: *Notifications) Ops {
        return .{ .ctx = n, .wait_low = waitLow, .wait_high = waitHigh, .query_low = queryLow, .now_ms = nowMs };
    }

    fn waitPair(n: *Notifications, h: win.HANDLE, ms: u32) Wait {
        const hs = [_]win.HANDLE{ n.stop_event, h };
        const r = win.WaitForMultipleObjects(2, &hs, .FALSE, ms);
        return switch (r) {
            1 => .signaled,
            win.WAIT_TIMEOUT => .timeout,
            else => .stop,
        };
    }

    fn waitLow(ctx: ?*anyopaque) Wait {
        const n: *Notifications = @ptrCast(@alignCast(ctx.?));
        return n.waitPair(n.low, win.INFINITE);
    }

    fn waitHigh(ctx: ?*anyopaque, ms: u32) Wait {
        const n: *Notifications = @ptrCast(@alignCast(ctx.?));
        return n.waitPair(n.high, ms);
    }

    fn queryLow(ctx: ?*anyopaque) bool {
        const n: *Notifications = @ptrCast(@alignCast(ctx.?));
        var state: win.BOOL = .FALSE;
        if (win.QueryMemoryResourceNotification(n.low, &state) == .FALSE) return false;
        return state != .FALSE;
    }

    fn nowMs(_: ?*anyopaque) u64 {
        return win.GetTickCount64();
    }

    /// The waiting task.
    pub fn run(n: *Notifications) std.Io.Cancelable!void {
        while (n.machine.step(n.ops())) |a| switch (a) {
            .none => {},
            .reclaim => n.sink.report(n.sink.ctx, .critical),
            .normal => n.sink.report(n.sink.ctx, .none),
        };
    }

    /// Wakes `run` so it returns.
    pub fn requestStop(n: *Notifications) void {
        _ = win.SetEvent(n.stop_event);
    }

    /// Closes the handles and frees the source (after `run` returned).
    pub fn close(n: *Notifications) void {
        for ([_]win.HANDLE{ n.low, n.high, n.stop_event }) |h| win.windows.CloseHandle(h);
        n.gpa.destroy(n);
    }
};

const Fake = struct {
    /// Scripted results, consumed in order.
    waits: []const Wait,
    lows: []const bool = &.{},
    now: u64 = 0,
    wi: usize = 0,
    li: usize = 0,
    high_timeouts: [8]u32 = @splat(0),
    hi: usize = 0,

    fn ops(f: *Fake) Ops {
        return .{ .ctx = f, .wait_low = waitLow, .wait_high = waitHigh, .query_low = queryLow, .now_ms = nowMs };
    }
    fn next(f: *Fake) Wait {
        defer f.wi += 1;
        return if (f.wi < f.waits.len) f.waits[f.wi] else .stop;
    }
    fn waitLow(ctx: ?*anyopaque) Wait {
        return next(@ptrCast(@alignCast(ctx.?)));
    }
    fn waitHigh(ctx: ?*anyopaque, ms: u32) Wait {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.high_timeouts[f.hi] = ms;
        f.hi += 1;
        f.now += if (f.wi < f.waits.len and f.waits[f.wi] == .timeout) ms else 0;
        return f.next();
    }
    fn queryLow(ctx: ?*anyopaque) bool {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        defer f.li += 1;
        return f.lows[f.li];
    }
    fn nowMs(ctx: ?*anyopaque) u64 {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        return f.now;
    }
};

test "pressure_windows: state machine low to high" {
    // low signals -> critical + reclaim; high times out 6 times with low
    // still set (30 s later: reclaim again); then high signals -> normal.
    var f: Fake = .{
        .waits = &.{ .signaled, .timeout, .timeout, .timeout, .timeout, .timeout, .timeout, .signaled },
        .lows = &.{ true, true, true, true, true, true },
    };
    var m: Machine = .{};
    var got: [16]Action = undefined;
    var n: usize = 0;
    while (m.step(f.ops())) |a| : (n += 1) got[n] = a;
    try std.testing.expectEqualSlices(Action, &.{ .reclaim, .none, .none, .none, .none, .none, .reclaim, .normal }, got[0..n]);
    try std.testing.expectEqual(@as(u32, critical_poll_ms), f.high_timeouts[0]);
    try std.testing.expect(m.state == .normal);
}

test "pressure_windows: leaves critical when low clears" {
    var f: Fake = .{ .waits = &.{ .signaled, .timeout, .stop }, .lows = &.{false} };
    var m: Machine = .{};
    try std.testing.expectEqual(Action.reclaim, m.step(f.ops()).?);
    try std.testing.expectEqual(Action.normal, m.step(f.ops()).?);
    // Back in normal it waits on low again, with no timeout.
    try std.testing.expect(m.step(f.ops()) == null);
    try std.testing.expectEqual(@as(usize, 1), f.hi);
}
