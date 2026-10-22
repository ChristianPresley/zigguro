//! The single process-wide owner of the allocator and the `std.Io`
//! implementation, plus the UI mailbox and UI-thread assertions.
//!
//! Threading rules:
//! (a) The UI thread owns all GUI state and never performs blocking `Io`
//!     operations. Every blocking helper in zg_core, zg_jsonrpc and zg_net
//!     calls `assertNotUi()`, which panics in builds with
//!     `-Dassert_ui_thread` (default: Debug).
//! (b) Short CPU work runs through `io.async` / `Subsystem.spawn`, which may
//!     execute inline; long-lived loops (protocol readers, streams) use
//!     `io.concurrent` / `Subsystem.spawnLoop` and never run inline.
//! (c) Each subsystem owns a `std.Io.Group` (`Subsystem`), so shutdown and
//!     cancellation are structured: `Subsystem.shutdown` cancels and joins.
//! (d) Results return to the UI thread only through `post` (bounded mailbox,
//!     no allocation) plus the platform `Waker`; the UI thread `drain`s on
//!     wake and redraws only damaged regions.
//! (e) Cancellation surfaces as `error.Canceled` from any `Io` call:
//!     propagate it, or use `io.recancel()` / `io.swapCancelProtection()`.
//!
//! A Runtime is initialised in place (`io` points into `threaded`) and must
//! never be copied afterwards; Debug builds check this.

const Runtime = @This();
const std = @import("std");
const options = @import("zg_options");
const alloc = @import("../alloc.zig");
const mailbox_mod = @import("mailbox.zig");
const Waker = @import("waker.zig").Waker;

/// Message type of the UI mailbox.
pub const UiMsg = mailbox_mod.UiMsg;
/// Errors from `post`.
pub const PostError = mailbox_mod.PostError;

gpa_state: alloc.Gpa,
threaded: std.Io.Threaded,
/// The process allocator (thread-safe).
gpa: std.mem.Allocator,
/// The process `Io`.
io: std.Io,
ui_thread: ?std.Thread.Id = null,
mailbox: mailbox_mod.Mailbox,
owns_io: bool,
self_check: *const Runtime,

/// Tuning for `init`.
pub const Options = struct {
    /// Max threads for `io.async` (null: CPU count - 1).
    async_limit: ?std.Io.Limit = null,
    /// Max units of concurrency for `io.concurrent` (long-lived loops).
    concurrent_limit: std.Io.Limit = .limited(64),
    /// Worker stack size.
    stack_size: usize = 1 << 20,
    /// Mailbox capacity (power of two).
    mailbox_capacity: u32 = 4096,
    /// Override the `-Dgpa` choice.
    gpa_kind: ?alloc.GpaKind = null,
};

/// Initialises `rt` in place: GPA, `std.Io.Threaded` with explicit limits,
/// and the mailbox. Budget: < 2 ms (no file or network I/O here).
pub fn init(rt: *Runtime, min: std.process.Init.Minimal, opts: Options) !void {
    rt.gpa_state = .{ .kind = opts.gpa_kind orelse alloc.defaultGpaKind() };
    rt.gpa = rt.gpa_state.allocator();
    rt.threaded = std.Io.Threaded.init(rt.gpa, .{
        .async_limit = opts.async_limit,
        .concurrent_limit = opts.concurrent_limit,
        .stack_size = opts.stack_size,
        .argv0 = .init(min.args),
        .environ = min.environ,
    });
    rt.io = rt.threaded.io();
    rt.owns_io = true;
    rt.ui_thread = null;
    rt.self_check = rt;
    rt.mailbox = mailbox_mod.Mailbox.init(rt.gpa, opts.mailbox_capacity) catch |err| {
        rt.threaded.deinit();
        _ = rt.gpa_state.deinit();
        return err;
    };
}

/// Initialises `rt` for tests with `std.testing.allocator` and `std.testing.io`.
pub fn initTesting(rt: *Runtime) void {
    rt.initBorrowed(std.testing.allocator, std.testing.io, 4096) catch @panic("OOM");
}

/// Initialises `rt` on an allocator and `Io` owned by the caller (tests,
/// benchmarks, embedding); `deinit` then frees only the mailbox.
pub fn initBorrowed(rt: *Runtime, gpa: std.mem.Allocator, io: std.Io, mailbox_capacity: u32) !void {
    rt.gpa_state = .{ .kind = .page };
    rt.threaded = undefined;
    rt.gpa = gpa;
    rt.io = io;
    rt.owns_io = false;
    rt.ui_thread = null;
    rt.self_check = rt;
    rt.mailbox = try mailbox_mod.Mailbox.init(gpa, mailbox_capacity);
}

/// Tears down the mailbox, the `Io` and the GPA; returns the leak check.
pub fn deinit(rt: *Runtime) std.heap.Check {
    rt.checkNotMoved();
    rt.mailbox.deinit(rt.gpa);
    if (!rt.owns_io) return .ok;
    rt.threaded.deinit();
    return rt.gpa_state.deinit();
}

fn checkNotMoved(rt: *const Runtime) void {
    if (std.debug.runtime_safety and rt.self_check != rt) @panic("zg_core.Runtime was copied after init");
}

/// Records the calling thread as the UI thread and installs its waker.
pub fn bindUiThread(rt: *Runtime, waker: Waker) void {
    rt.checkNotMoved();
    rt.ui_thread = std.Thread.getCurrentId();
    rt.mailbox.waker = waker;
}

/// True when called on the bound UI thread.
pub fn isUiThread(rt: *const Runtime) bool {
    const ui = rt.ui_thread orelse return false;
    return ui == std.Thread.getCurrentId();
}

/// Panics if called on the UI thread (only with `-Dassert_ui_thread`).
/// Every blocking helper calls this first.
pub inline fn assertNotUi(rt: *const Runtime) void {
    if (!options.assert_ui_thread) return;
    if (rt.isUiThread()) @panic("blocking I/O on the UI thread");
}

/// Posts `msg` to the UI thread from any thread; never blocks or allocates.
/// Wakes the UI thread only on the first post after a drain.
pub fn post(rt: *Runtime, msg: UiMsg) PostError!void {
    return rt.mailbox.post(rt.io, msg, rt.isUiThread());
}

/// UI thread only: drains up to `out.len` messages without blocking.
pub fn drain(rt: *Runtime, out: []UiMsg) usize {
    if (std.debug.runtime_safety and rt.ui_thread != null and !rt.isUiThread()) @panic("Runtime.drain off the UI thread");
    return rt.mailbox.drain(rt.io, out);
}

test "runtime: init/deinit no leak" {
    var rt: Runtime = undefined;
    try rt.init(.{ .environ = .empty, .args = .{ .vector = &.{} } }, .{ .gpa_kind = .debug, .mailbox_capacity = 64 });
    try std.testing.expectEqual(std.heap.Check.ok, rt.deinit());
}

test "runtime: post/drain FIFO across 4 producer threads" {
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    rt.bindUiThread(.noop);
    const per = 10_000;
    const Producer = struct {
        fn run(r: *Runtime, id: u32) void {
            var i: u64 = 0;
            while (i < per) {
                // Yield rather than spin: on runners with fewer cores than
                // threads (or under x86 emulation) spinning starves the
                // consumer.
                r.post(.{ .kind = 7, .source = id, .a = i }) catch {
                    std.Thread.yield() catch {};
                    continue;
                };
                i += 1;
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Producer.run, .{ &rt, @as(u32, @intCast(id)) });
    var next = [_]u64{0} ** 4;
    var received: usize = 0;
    var buf: [256]UiMsg = undefined;
    while (received < 4 * per) {
        const n = rt.drain(&buf);
        for (buf[0..n]) |m| {
            try std.testing.expectEqual(next[m.source], m.a);
            next[m.source] += 1;
        }
        received += n;
        if (n == 0) std.Thread.yield() catch {};
    }
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 0), rt.drain(&buf));
}

test "runtime: wake coalescing" {
    const TestWaker = @import("waker.zig").TestWaker;
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var tw: TestWaker = .{};
    rt.mailbox.waker = tw.waker(); // UI thread unbound: posts take the queue path
    for (0..1000) |i| {
        rt.post(.{ .kind = 1, .a = i }) catch |e| switch (e) {
            error.Full => break,
            error.Closed => return e,
        };
    }
    try std.testing.expectEqual(@as(u64, 1), tw.count.load(.monotonic));
    var buf: [4096]UiMsg = undefined;
    _ = rt.drain(&buf);
    try rt.post(.{ .kind = 1 });
    try std.testing.expectEqual(@as(u64, 2), tw.count.load(.monotonic));
}

test "runtime: isUiThread and self-post path" {
    var rt: Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try std.testing.expect(!rt.isUiThread());
    rt.assertNotUi(); // unbound: must not panic
    rt.bindUiThread(.noop);
    try std.testing.expect(rt.isUiThread());
    try rt.post(.{ .kind = 3 });
    const Other = struct {
        fn run(r: *Runtime, out: *bool) void {
            out.* = r.isUiThread();
            r.assertNotUi();
        }
    };
    var other_is_ui = true;
    const t = try std.Thread.spawn(.{}, Other.run, .{ &rt, &other_is_ui });
    t.join();
    try std.testing.expect(!other_is_ui);
    var buf: [4]UiMsg = undefined;
    try std.testing.expectEqual(@as(usize, 1), rt.drain(&buf));
}

test "runtime: post and drain do not allocate" {
    var counting = alloc.CountingAllocator.init(std.testing.allocator);
    var rt: Runtime = undefined;
    rt.initTesting();
    rt.mailbox.deinit(rt.gpa);
    rt.gpa = counting.allocator();
    rt.mailbox = try mailbox_mod.Mailbox.init(rt.gpa, 64);
    defer _ = rt.deinit();
    const before = counting.allocs.load(.monotonic);
    var buf: [64]UiMsg = undefined;
    for (0..1000) |_| {
        try rt.post(.{ .kind = 1 });
        _ = rt.drain(&buf);
    }
    try std.testing.expectEqual(before, counting.allocs.load(.monotonic));
}
