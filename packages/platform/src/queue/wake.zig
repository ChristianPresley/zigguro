//! Wakes the UI thread from any thread: an eventfd on Linux, an auto-reset
//! event on Windows, and a futex word elsewhere (headless on other OSes).
//! `waker` adapts it to `zg_core.runtime.Waker`, so zg_core mailboxes wake
//! the UI thread too.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");

/// The OS object a backend can poll alongside its own fds or handles.
pub const NativeHandle = union(enum) {
    /// A file descriptor that becomes readable when signalled (Linux).
    fd: i32,
    /// A waitable `HANDLE` (Windows).
    handle: *anyopaque,
    /// No pollable object (futex fallback).
    none,
};

const Impl = switch (builtin.os.tag) {
    .linux => @import("wake_linux.zig").LinuxWake,
    .windows => @import("wake_windows.zig").WindowsWake,
    else => FutexWake,
};

/// A wake object shared between waiters and signallers.
pub const Wake = struct {
    impl: Impl,

    /// Creates the OS object. `io` is used by the futex fallback.
    pub fn init(io: std.Io) error{SystemResources}!Wake {
        return .{ .impl = if (Impl == FutexWake) .{ .io = io } else try Impl.init() };
    }

    /// Releases the OS object.
    pub fn deinit(self: *Wake) void {
        if (Impl != FutexWake) self.impl.deinit();
    }

    /// Wakes a waiter. Any thread; never blocks; signals coalesce.
    pub fn signal(self: *Wake) void {
        self.impl.signal();
    }

    /// The pollable OS object.
    pub fn handle(self: *const Wake) NativeHandle {
        return switch (builtin.os.tag) {
            .linux => .{ .fd = self.impl.fd },
            .windows => .{ .handle = self.impl.event },
            else => .none,
        };
    }

    /// Clears pending signals. Call after the waiter has woken and before
    /// it drains its queues, so a signal during the drain is not lost.
    pub fn consume(self: *Wake) void {
        self.impl.consume();
    }

    /// Blocks until signalled or `timeout_ns` passes (null: no timeout).
    /// Returns whether a signal was seen.
    pub fn wait(self: *Wake, timeout_ns: ?u64) bool {
        return self.impl.wait(timeout_ns);
    }

    /// The zg_core waker for this object; `self` must outlive it.
    pub fn waker(self: *Wake) zg_core.runtime.Waker {
        return .{ .ctx = self, .wakeFn = wakeFn };
    }

    fn wakeFn(ctx: ?*anyopaque) void {
        const self: *Wake = @ptrCast(@alignCast(ctx.?));
        self.signal();
    }
};

const FutexWake = struct {
    io: std.Io,
    word: std.atomic.Value(u32) = .init(0),

    fn signal(self: *FutexWake) void {
        if (self.word.swap(1, .release) == 0) self.io.futexWake(u32, &self.word.raw, 1);
    }

    fn consume(self: *FutexWake) void {
        self.word.store(0, .monotonic);
    }

    fn wait(self: *FutexWake, timeout_ns: ?u64) bool {
        if (self.word.load(.acquire) != 0) return true;
        const timeout: std.Io.Timeout = if (timeout_ns) |ns| .{ .duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake } } else .none;
        self.io.futexWaitTimeout(u32, &self.word.raw, 0, timeout) catch {};
        return self.word.load(.acquire) != 0;
    }
};

const testing = std.testing;

test "wake: signal before wait returns at once; consume clears it" {
    var w = try Wake.init(testing.io);
    defer w.deinit();
    w.signal();
    w.signal();
    try testing.expect(w.wait(0));
    w.consume();
    try testing.expect(!w.wait(std.time.ns_per_ms));
}

test "wake latency smoke" {
    var w = try Wake.init(testing.io);
    defer w.deinit();
    const S = struct {
        fn run(wake: *Wake, sent: *i96) void {
            sent.* = std.Io.Clock.awake.now(testing.io).nanoseconds;
            wake.signal();
        }
    };
    var sent: i96 = 0;
    const t = try std.Thread.spawn(.{}, S.run, .{ &w, &sent });
    try testing.expect(w.wait(5 * std.time.ns_per_s));
    const now = std.Io.Clock.awake.now(testing.io).nanoseconds;
    t.join();
    w.consume();
    // A smoke check, not a benchmark: CI hosts are noisy.
    try testing.expect(now - sent < 5 * std.time.ns_per_ms);
}

test "wake: zg_core mailbox post wakes the waiter" {
    var w = try Wake.init(testing.io);
    defer w.deinit();
    var rt: zg_core.Runtime = undefined;
    try rt.initBorrowed(testing.allocator, testing.io, 16);
    defer _ = rt.deinit();
    rt.bindUiThread(w.waker());
    const P = struct {
        fn run(r: *zg_core.Runtime) void {
            r.post(.{ .kind = 42 }) catch unreachable;
        }
    };
    const t = try std.Thread.spawn(.{}, P.run, .{&rt});
    try testing.expect(w.wait(5 * std.time.ns_per_s));
    t.join();
    w.consume();
    var out: [4]zg_core.Runtime.UiMsg = undefined;
    try testing.expectEqual(1, rt.drain(&out));
    try testing.expectEqual(42, out[0].kind);
}
