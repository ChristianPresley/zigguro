//! The platform wake hook used by the UI mailbox. E01 implements real wakers
//! (Win32 `PostMessageW` to the UI window; Wayland/X11 an eventfd or
//! self-pipe polled with the display fd). zg_core ships `Waker.noop`,
//! `EventWaker` (on `std.Io.Event`) and `TestWaker` (counts wakes).

const std = @import("std");

/// A type-erased "wake the UI thread" callback. `wakeFn` must be thread-safe,
/// must not block, and may be called spuriously.
pub const Waker = struct {
    ctx: ?*anyopaque,
    wakeFn: *const fn (?*anyopaque) void,

    /// A waker that does nothing (for headless use before a platform binds).
    pub const noop: Waker = .{ .ctx = null, .wakeFn = noopWake };

    fn noopWake(_: ?*anyopaque) void {}

    /// Wakes the UI thread.
    pub fn wake(w: Waker) void {
        w.wakeFn(w.ctx);
    }
};

/// A waker backed by `std.Io.Event`, for headless loops and tests: the UI
/// loop calls `wait()`, producers wake it.
pub const EventWaker = struct {
    event: std.Io.Event = .unset,
    io: std.Io,
    /// Number of `wake` calls observed.
    wakes: std.atomic.Value(u64) = .init(0),

    /// The type-erased waker; `self` must outlive it.
    pub fn waker(self: *EventWaker) Waker {
        return .{ .ctx = self, .wakeFn = wakeImpl };
    }

    fn wakeImpl(ctx: ?*anyopaque) void {
        const self: *EventWaker = @ptrCast(@alignCast(ctx.?));
        _ = self.wakes.fetchAdd(1, .monotonic);
        self.event.set(self.io);
    }

    /// Blocks until woken, then re-arms. Only for loops that are allowed to
    /// block (headless CLI, tests); never on a real GUI thread.
    pub fn wait(self: *EventWaker) void {
        self.event.waitUncancelable(self.io);
        self.event.reset();
    }

    /// Like `wait` with a timeout; returns false if it expired.
    pub fn waitTimeout(self: *EventWaker, timeout: std.Io.Timeout) bool {
        self.event.waitTimeout(self.io, timeout) catch return false;
        self.event.reset();
        return true;
    }
};

/// A waker that only counts calls.
pub const TestWaker = struct {
    count: std.atomic.Value(u64) = .init(0),

    /// The type-erased waker; `self` must outlive it.
    pub fn waker(self: *TestWaker) Waker {
        return .{ .ctx = self, .wakeFn = wakeImpl };
    }

    fn wakeImpl(ctx: ?*anyopaque) void {
        const self: *TestWaker = @ptrCast(@alignCast(ctx.?));
        _ = self.count.fetchAdd(1, .monotonic);
    }
};

test "waker: noop and test waker" {
    Waker.noop.wake();
    var t: TestWaker = .{};
    t.waker().wake();
    t.waker().wake();
    try std.testing.expectEqual(@as(u64, 2), t.count.load(.monotonic));
}

test "waker: EventWaker wakes a waiting thread" {
    var ew: EventWaker = .{ .io = std.testing.io };
    const t = try std.Thread.spawn(.{}, Waker.wake, .{ew.waker()});
    ew.wait();
    t.join();
    try std.testing.expectEqual(@as(u64, 1), ew.wakes.load(.monotonic));
    try std.testing.expect(!ew.waitTimeout(.{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }));
}
