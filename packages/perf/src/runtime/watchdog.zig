//! The UI stall watchdog (E14.F01.S02.T01): a concurrent task that notices
//! when the UI thread has not come back to its event wait for `warn_ns`
//! and reports the stall with the UI thread's open trace zones. While the
//! UI waits for events the watchdog sleeps on a futex with no timeout, so
//! an idle app costs 0 wakeups.

const std = @import("std");
const wake_count = @import("../idle/wake_count.zig");
const zg_core = @import("zg_core");
const shadow_stack = @import("shadow_stack.zig");
const Site = zg_core.trace.Site;

const log = std.log.scoped(.perf);

/// One stall report.
pub const StallReport = struct {
    /// How long the UI thread has been busy so far.
    duration_ns: u64,
    /// The UI thread's open zones, outermost first (`depth` entries).
    zone_stack: [16]?*const Site,
    /// Valid entries in `zone_stack`.
    depth: u8,
    /// When the busy interval started (`.awake` ns).
    started_ns: u64,
    /// 0 for the first report of a stall, then 1, 2, ... for follow-ups.
    sequence: u32,

    /// The open zones.
    pub fn zones(r: *const StallReport) []const ?*const Site {
        return r.zone_stack[0..r.depth];
    }
};

const UiState = enum(u32) { waiting, running };

/// Watches one UI thread. Create with `start`, feed with `heartbeat` and
/// `enterWait` from the UI thread, end with `stop`.
pub const StallWatchdog = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    group: std.Io.Group = .init,
    /// Raw `fastTicks` of the last heartbeat.
    last_beat: std.atomic.Value(u64) = .init(0),
    ui_state: std.atomic.Value(UiState) = .init(.waiting),
    /// Futex word: bumped when the UI leaves its wait, and on stop.
    gen: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    /// Times the watchdog task returned from a wait (tests).
    wakeups: std.atomic.Value(u64) = .init(0),
    /// Reports delivered (tests).
    reports: std.atomic.Value(u64) = .init(0),
    cal: zg_core.time.TickCalibration,

    /// Watchdog options.
    pub const Options = struct {
        /// Busy time before the first report.
        warn_ns: u64 = 50 * std.time.ns_per_ms,
        /// Follow-up reports come at 2x and 4x `warn_ns`, then every this.
        repeat_ns: u64 = std.time.ns_per_s,
        /// Called on the watchdog task for every report.
        on_stall: ?*const fn (ctx: ?*anyopaque, report: StallReport) void = null,
        /// Passed to `on_stall`.
        context: ?*anyopaque = null,
        /// The UI thread's shadow stack (from
        /// `shadow_stack.enableForCurrentThread` on that thread).
        stack: ?*const shadow_stack.ShadowStack = null,
        /// Log each report at warn level.
        log: bool = true,
    };

    /// Allocates the watchdog and spawns its task with `io.concurrent`.
    /// Returns null (and logs once) when the `Io` cannot run concurrent
    /// tasks; callers then simply run without a watchdog.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, opts: Options) error{OutOfMemory}!?*StallWatchdog {
        zg_core.time.setFallbackIo(io);
        const w = try gpa.create(StallWatchdog);
        w.* = .{ .gpa = gpa, .io = io, .opts = opts, .cal = .begin(io) };
        w.group.concurrent(io, loop, .{w}) catch {
            log.info("stall watchdog disabled: no concurrency in this Io", .{});
            gpa.destroy(w);
            return null;
        };
        return w;
    }

    /// UI thread, at the top of every loop iteration: one relaxed store,
    /// plus a futex wake when the UI was waiting.
    pub fn heartbeat(w: *StallWatchdog) void {
        w.last_beat.store(zg_core.time.fastTicks(), .monotonic);
        if (w.ui_state.load(.monotonic) == .waiting) {
            w.ui_state.store(.running, .release);
            _ = w.gen.fetchAdd(1, .release);
            w.io.futexWake(u32, &w.gen.raw, 1);
        }
    }

    /// UI thread, right before blocking for events (not a stall).
    pub fn enterWait(w: *StallWatchdog) void {
        w.ui_state.store(.waiting, .release);
    }

    /// Stops the task and frees the watchdog.
    pub fn stop(w: *StallWatchdog) void {
        w.stopping.store(true, .release);
        _ = w.gen.fetchAdd(1, .release);
        w.io.futexWake(u32, &w.gen.raw, 1);
        w.group.cancel(w.io);
        w.gpa.destroy(w);
    }

    fn beatNs(w: *StallWatchdog, ticks: u64) u64 {
        return w.cal.toNs(ticks);
    }

    fn loop(w: *StallWatchdog) std.Io.Cancelable!void {
        const io = w.io;
        var seen_beat: u64 = 0;
        var report_seq: u32 = 0;
        var next_report_ns: u64 = 0;
        while (!w.stopping.load(.acquire)) {
            const g = w.gen.load(.acquire);
            if (w.ui_state.load(.acquire) == .waiting) {
                report_seq = 0;
                try io.futexWait(u32, &w.gen.raw, g);
                wake_count.noteWake("perf.watchdog", .signal);
                _ = w.wakeups.fetchAdd(1, .monotonic);
                continue;
            }
            w.cal.finish(io);
            const beat = w.last_beat.load(.monotonic);
            const beat_ns = w.beatNs(beat);
            if (beat != seen_beat) {
                seen_beat = beat;
                report_seq = 0;
                next_report_ns = beat_ns + w.opts.warn_ns;
            }
            const now = zg_core.time.nowNs(io);
            if (now >= next_report_ns) {
                // The UI may have reached its wait since the check above.
                if (w.ui_state.load(.acquire) == .waiting or w.last_beat.load(.monotonic) != beat) continue;
                w.report(beat_ns, now, report_seq);
                report_seq += 1;
                next_report_ns = beat_ns + switch (report_seq) {
                    1 => 2 * w.opts.warn_ns,
                    2 => 4 * w.opts.warn_ns,
                    else => (now - beat_ns) + w.opts.repeat_ns,
                };
                continue;
            }
            const deadline: std.Io.Clock.Timestamp = .{ .raw = .fromNanoseconds(@intCast(next_report_ns)), .clock = .awake };
            try io.futexWaitTimeout(u32, &w.gen.raw, g, .{ .deadline = deadline });
            wake_count.noteWake("perf.watchdog", .timer);
            _ = w.wakeups.fetchAdd(1, .monotonic);
        }
    }

    fn report(w: *StallWatchdog, started_ns: u64, now: u64, seq: u32) void {
        var r: StallReport = .{ .duration_ns = now -| started_ns, .zone_stack = @splat(null), .depth = 0, .started_ns = started_ns, .sequence = seq };
        if (w.opts.stack) |s| r.depth = s.snapshot(&r.zone_stack);
        _ = w.reports.fetchAdd(1, .monotonic);
        zg_core.trace.counter("perf.stall_ms", @intCast(r.duration_ns / std.time.ns_per_ms));
        if (w.opts.log) {
            var buf: [512]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&buf);
            shadow_stack.writeStack(&fw, r.zones()) catch {};
            log.warn("ui stall {d} ms in [{s}]", .{ r.duration_ns / std.time.ns_per_ms, fw.buffered() });
        }
        if (w.opts.on_stall) |f| f(w.opts.context, r);
    }
};

const Collect = struct {
    mutex: std.Io.Mutex = .init,
    list: [16]StallReport = undefined,
    n: usize = 0,

    fn on(ctx: ?*anyopaque, r: StallReport) void {
        const c: *Collect = @ptrCast(@alignCast(ctx.?));
        c.mutex.lockUncancelable(std.testing.io);
        defer c.mutex.unlock(std.testing.io);
        if (c.n < c.list.len) c.list[c.n] = r;
        c.n += 1;
    }
};

fn spin(io: std.Io, ns: u64) void {
    const t0 = zg_core.time.nowNs(io);
    while (zg_core.time.nowNs(io) - t0 < ns) std.atomic.spinLoopHint();
}

test "watchdog: reports busy loop" {
    const io = std.testing.io;
    var c: Collect = .{};
    const UiThread = struct {
        fn run(wd: **StallWatchdog, ready: *std.atomic.Value(bool), stack_out: *?*const shadow_stack.ShadowStack, go: *std.atomic.Value(bool)) void {
            if (shadow_stack.enabled) stack_out.* = shadow_stack.enableForCurrentThread();
            ready.store(true, .release);
            while (!go.load(.acquire)) std.atomic.spinLoopHint();
            const w = wd.*;
            w.heartbeat();
            const a = zg_core.trace.zone(@src(), "a");
            const b = zg_core.trace.zone(@src(), "b");
            spin(std.testing.io, 120 * std.time.ns_per_ms);
            b.end();
            a.end();
            w.enterWait();
            zg_core.trace.zone_hook = null;
        }
    };
    var ready: std.atomic.Value(bool) = .init(false);
    var go: std.atomic.Value(bool) = .init(false);
    var stack: ?*const shadow_stack.ShadowStack = null;
    var wd: *StallWatchdog = undefined;
    const t = try std.Thread.spawn(.{}, UiThread.run, .{ &wd, &ready, &stack, &go });
    while (!ready.load(.acquire)) std.atomic.spinLoopHint();
    wd = (try StallWatchdog.start(std.testing.allocator, io, .{ .warn_ns = 50 * std.time.ns_per_ms, .on_stall = Collect.on, .context = &c, .stack = stack, .log = false })) orelse return error.SkipZigTest;
    go.store(true, .release);
    t.join();
    try io.sleep(.fromMilliseconds(20), .awake);
    wd.stop();
    // 50 ms first report and the 2x (100 ms) follow-up; 4x (200 ms) never comes.
    try std.testing.expectEqual(@as(usize, 2), c.n);
    try std.testing.expect(c.list[0].duration_ns >= 50 * std.time.ns_per_ms);
    try std.testing.expect(c.list[1].duration_ns >= 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 1), c.list[1].sequence);
    if (shadow_stack.enabled) {
        try std.testing.expectEqual(@as(u8, 2), c.list[0].depth);
        try std.testing.expectEqualStrings("a", c.list[0].zone_stack[0].?.name);
        try std.testing.expectEqualStrings("b", c.list[0].zone_stack[1].?.name);
    }
    var events: std.ArrayList(zg_core.trace.Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try zg_core.trace.collect(std.testing.allocator, &events);
}

test "watchdog: waiting is not a stall" {
    const io = std.testing.io;
    var c: Collect = .{};
    const wd = (try StallWatchdog.start(std.testing.allocator, io, .{ .warn_ns = 20 * std.time.ns_per_ms, .on_stall = Collect.on, .context = &c, .log = false })) orelse return error.SkipZigTest;
    wd.enterWait();
    try io.sleep(.fromMilliseconds(300), .awake);
    try std.testing.expectEqual(@as(u64, 0), wd.wakeups.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), wd.reports.load(.monotonic));
    // A short busy burst ending in a wait is not reported either.
    wd.heartbeat();
    wd.enterWait();
    try io.sleep(.fromMilliseconds(60), .awake);
    try std.testing.expectEqual(@as(usize, 0), c.n);
    wd.stop();
}
