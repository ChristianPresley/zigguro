//! `Subsystem`: structured lifetime for a package's background work, on a
//! `std.Io.Group`.
//!
//! - Short CPU work uses `spawn` (`Group.async`; may run inline).
//! - Long-lived loops (an LSP stdout reader, an SSE stream) use `spawnLoop`
//!   (`Group.concurrent`), which fails with `error.ConcurrencyUnavailable`
//!   when the runtime's concurrency limit is reached. Never run such a loop
//!   through `spawn`: inline execution would deadlock it.
//!
//! Cancellation: `shutdown` cancels the group; tasks then see
//! `error.Canceled` from any `Io` call. Handle it by (1) propagating it,
//! (2) `io.recancel()` after cleanup that must not be interrupted, or
//! (3) `io.swapCancelProtection()` around a critical section.

const std = @import("std");

/// A group of background tasks owned by one subsystem.
pub const Subsystem = struct {
    group: std.Io.Group = .init,
    io: std.Io,

    /// A subsystem running tasks on `io`.
    pub fn init(io: std.Io) Subsystem {
        return .{ .io = io };
    }

    /// Runs short work asynchronously (possibly inline). `func` must return
    /// something coercible to `std.Io.Cancelable!void`.
    pub fn spawn(self: *Subsystem, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) void {
        self.group.async(self.io, func, args);
    }

    /// Starts a long-lived loop on its own unit of concurrency.
    pub fn spawnLoop(self: *Subsystem, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) std.Io.ConcurrentError!void {
        return self.group.concurrent(self.io, func, args);
    }

    /// Waits for every task to finish without canceling them.
    pub fn join(self: *Subsystem) std.Io.Cancelable!void {
        return self.group.await(self.io);
    }

    /// Cancels every task and waits for them to finish. Idempotent.
    pub fn shutdown(self: *Subsystem) void {
        self.group.cancel(self.io);
    }
};

test "runtime: Subsystem.shutdown cancels loops within 50 ms" {
    const io = std.testing.io;
    var sub = Subsystem.init(io);
    const Loop = struct {
        fn run(i: std.Io, ticks: *std.atomic.Value(u32)) std.Io.Cancelable!void {
            while (true) {
                try i.sleep(.fromMilliseconds(1), .awake);
                _ = ticks.fetchAdd(1, .monotonic);
            }
        }
    };
    var ticks: std.atomic.Value(u32) = .init(0);
    try sub.spawnLoop(Loop.run, .{ io, &ticks });
    try io.sleep(.fromMilliseconds(5), .awake);
    const t0 = std.Io.Timestamp.now(io, .awake);
    sub.shutdown();
    const elapsed = t0.durationTo(std.Io.Timestamp.now(io, .awake));
    try std.testing.expect(elapsed.toMilliseconds() < 50);
}

test "runtime: Subsystem.spawn runs short work" {
    const io = std.testing.io;
    var sub = Subsystem.init(io);
    var counter: std.atomic.Value(u32) = .init(0);
    const Work = struct {
        fn run(c: *std.atomic.Value(u32)) void {
            _ = c.fetchAdd(1, .monotonic);
        }
    };
    for (0..8) |_| sub.spawn(Work.run, .{&counter});
    try sub.join();
    try std.testing.expectEqual(@as(u32, 8), counter.load(.monotonic));
}
