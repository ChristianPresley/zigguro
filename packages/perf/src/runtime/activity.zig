//! `ActivitySignal` (E14.F01.S02.T02): the UI thread publishes how busy it
//! is and background schedulers (indexer, syntax, SCM, search) read it to
//! yield. Reads are wait-free; publishing is one atomic store, plus a futex
//! wake only when someone waits and the level leaves `frame_busy`.

const std = @import("std");
const wake_count = @import("../idle/wake_count.zig");
const zg_core = @import("zg_core");

/// The UI activity signal.
pub const ActivitySignal = struct {
    /// level (low 8 bits) | last activity ns >> 8 (high 56 bits).
    state: std.atomic.Value(u64) = .init(0),
    /// Futex word bumped on wake-worthy transitions.
    epoch: std.atomic.Value(u32) = .init(0),
    /// Threads inside `waitUntilNot`.
    waiters: std.atomic.Value(u32) = .init(0),
    /// The clock and futex `Io`; set once at startup (`install`).
    io: ?std.Io = null,

    /// UI activity levels.
    pub const Level = enum(u8) {
        /// No input for `idle_after_ns`.
        idle,
        /// Input arrived recently; frames are not being built right now.
        interactive,
        /// The UI thread is building or submitting a frame.
        frame_busy,
    };

    /// No activity for this long reads as `idle`, without any timer.
    pub const idle_after_ns: u64 = 2 * std.time.ns_per_s;

    /// Sets the `Io` used for the clock in `level` and for wakeups.
    pub fn install(s: *ActivitySignal, io: std.Io) void {
        s.io = io;
    }

    fn pack(lvl: Level, now_ns: u64) u64 {
        return (now_ns & ~@as(u64, 0xff)) | @intFromEnum(lvl);
    }

    /// UI thread: publishes `level` observed at `now_ns` (`.awake` ns).
    pub fn publish(s: *ActivitySignal, lvl: Level, now_ns: u64) void {
        const prev = s.state.swap(pack(lvl, now_ns), .release);
        const prev_lvl: Level = @enumFromInt(@as(u8, @truncate(prev)));
        const wake = (prev_lvl == .frame_busy and lvl != .frame_busy) or (lvl == .idle and prev_lvl != .idle);
        if (wake and s.waiters.load(.acquire) != 0) {
            _ = s.epoch.fetchAdd(1, .release);
            if (s.io) |io| io.futexWake(u32, &s.epoch.raw, std.math.maxInt(u32));
        }
    }

    /// The published level, ignoring time (one atomic load).
    pub fn publishedLevel(s: *const ActivitySignal) Level {
        return @enumFromInt(@as(u8, @truncate(s.state.load(.acquire))));
    }

    /// The level at `now_ns`: a published `interactive` older than
    /// `idle_after_ns` reads as `idle`.
    pub fn levelAt(s: *const ActivitySignal, now_ns: u64) Level {
        const v = s.state.load(.acquire);
        const lvl: Level = @enumFromInt(@as(u8, @truncate(v)));
        if (lvl == .interactive and now_ns -| (v & ~@as(u64, 0xff)) >= idle_after_ns) return .idle;
        return lvl;
    }

    /// The current level (one atomic load plus a clock read; wait-free).
    /// Without an installed `Io` the published level is returned.
    pub fn level(s: *const ActivitySignal) Level {
        const io = s.io orelse return s.publishedLevel();
        return s.levelAt(zg_core.time.nowNs(io));
    }

    /// Nanoseconds since the last published activity (0 while busy).
    pub fn idleForNs(s: *const ActivitySignal, now_ns: u64) u64 {
        const v = s.state.load(.acquire);
        if (@as(u8, @truncate(v)) == @intFromEnum(Level.frame_busy)) return 0;
        return now_ns -| (v & ~@as(u64, 0xff));
    }

    /// Worker thread: blocks until the level is not `lvl`, or until
    /// `deadline_ns` (`.awake` ns) with `error.Timeout`.
    pub fn waitUntilNot(s: *ActivitySignal, io: std.Io, lvl: Level, deadline_ns: ?u64) (error{Timeout} || std.Io.Cancelable)!void {
        _ = s.waiters.fetchAdd(1, .acq_rel);
        defer _ = s.waiters.fetchSub(1, .acq_rel);
        while (true) {
            const e = s.epoch.load(.acquire);
            const now = zg_core.time.nowNs(io);
            if (s.levelAt(now) != lvl) return;
            if (deadline_ns) |d| if (now >= d) return error.Timeout;
            // The lazy interactive -> idle transition has no publisher.
            var wake_at: ?u64 = deadline_ns;
            if (lvl == .interactive) {
                const at = (s.state.load(.acquire) & ~@as(u64, 0xff)) + idle_after_ns;
                wake_at = if (wake_at) |d| @min(d, at) else at;
            }
            const timeout: std.Io.Timeout = if (wake_at) |d| .{ .deadline = .{ .raw = .fromNanoseconds(@intCast(d)), .clock = .awake } } else .none;
            try io.futexWaitTimeout(u32, &s.epoch.raw, e, timeout);
            wake_count.noteWake("perf.activity_wait", .signal);
        }
    }

    /// How many background workers to run: all but one core when idle,
    /// half the cores otherwise (E08 indexer policy).
    pub fn recommendedWorkers(s: *const ActivitySignal, cpu_count: usize) usize {
        if (s.level() == .idle) return @max(1, cpu_count -| 1);
        return @max(1, cpu_count / 2);
    }
};

/// The process-wide signal. The runtime calls `global.install(io)` once.
pub var global: ActivitySignal = .{};

/// How long `yieldPoint` waits for a busy frame to finish at most.
pub const yield_budget_ns: u64 = 4 * std.time.ns_per_ms;

/// For chunked background loops (call about every 1 ms of work): returns
/// `error.Canceled` when the task is canceled and waits up to 4 ms while
/// the UI is building a frame.
pub fn yieldPoint(io: std.Io) std.Io.Cancelable!void {
    return yieldPointOn(&global, io);
}

/// `yieldPoint` on an explicit signal.
pub fn yieldPointOn(s: *ActivitySignal, io: std.Io) std.Io.Cancelable!void {
    try io.checkCancel();
    if (s.publishedLevel() != .frame_busy) return;
    s.waitUntilNot(io, .frame_busy, zg_core.time.nowNs(io) + yield_budget_ns) catch |err| switch (err) {
        error.Timeout => {},
        error.Canceled => return error.Canceled,
    };
}

test "activity: publish/level transitions" {
    var s: ActivitySignal = .{};
    try std.testing.expectEqual(ActivitySignal.Level.idle, s.level());
    s.publish(.interactive, 10_000);
    try std.testing.expectEqual(ActivitySignal.Level.interactive, s.levelAt(10_500));
    s.publish(.frame_busy, 11_000);
    try std.testing.expectEqual(ActivitySignal.Level.frame_busy, s.levelAt(99 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), s.idleForNs(20_000));
    s.publish(.interactive, 12_000);
    try std.testing.expectEqual(ActivitySignal.Level.interactive, s.levelAt(12_000));
    try std.testing.expectEqual(@as(usize, 4), s.recommendedWorkers(8));
}

test "activity: idle derived from time without timer" {
    var s: ActivitySignal = .{};
    const t0: u64 = 5 * std.time.ns_per_s;
    s.publish(.interactive, t0);
    try std.testing.expectEqual(ActivitySignal.Level.interactive, s.levelAt(t0 + ActivitySignal.idle_after_ns - 1000));
    try std.testing.expectEqual(ActivitySignal.Level.idle, s.levelAt(t0 + ActivitySignal.idle_after_ns));
    try std.testing.expect(s.idleForNs(t0 + 3 * std.time.ns_per_s) >= 3 * std.time.ns_per_s - 256);
}

test "activity: waitUntilNot wakes on transition" {
    const io = std.testing.io;
    var s: ActivitySignal = .{};
    s.install(io);
    s.publish(.frame_busy, zg_core.time.nowNs(io));
    const Ui = struct {
        fn run(sig: *ActivitySignal) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(30), .awake) catch {};
            sig.publish(.interactive, zg_core.time.nowNs(std.testing.io));
        }
    };
    const t0 = zg_core.time.nowNs(io);
    const t = try std.Thread.spawn(.{}, Ui.run, .{&s});
    try s.waitUntilNot(io, .frame_busy, t0 + 5 * std.time.ns_per_s);
    const waited = zg_core.time.nowNs(io) - t0;
    t.join();
    try std.testing.expect(waited >= 25 * std.time.ns_per_ms);
    try std.testing.expect(waited < 2 * std.time.ns_per_s);
    try std.testing.expectError(error.Timeout, s.waitUntilNot(io, .interactive, zg_core.time.nowNs(io) + std.time.ns_per_ms));
}

test "activity: yieldPoint returns Canceled when group canceled" {
    const io = std.testing.io;
    var s: ActivitySignal = .{};
    s.install(io);
    s.publish(.frame_busy, zg_core.time.nowNs(io));
    const Worker = struct {
        fn run(sig: *ActivitySignal, result: *?anyerror) std.Io.Cancelable!void {
            while (true) {
                yieldPointOn(sig, std.testing.io) catch |err| {
                    result.* = err;
                    return err;
                };
            }
        }
    };
    var result: ?anyerror = null;
    var group: std.Io.Group = .init;
    group.concurrent(io, Worker.run, .{ &s, &result }) catch return error.SkipZigTest;
    try io.sleep(.fromMilliseconds(20), .awake);
    group.cancel(io);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), result);
}
