//! `StartupTimeline` (E14.F05.S01.T01): phase marks from process creation
//! to the first interactive frame, on the `.awake` clock.
//!
//! `mark` is idempotent (the first call wins) and costs one atomic load
//! once the phase is set, so call sites can sit on hot paths (the Host
//! marks the first frame on every frame). Marks taken before `install`
//! (`main_entered` is the first statement of `main`, before the runtime
//! has an `Io`) store raw `fastTicks` and are converted in `summary`.
//! Each first mark also records the trace instant `startup.<phase>`.

const std = @import("std");
const zg_core = @import("zg_core");
const process_start = @import("process_start.zig");

/// Startup phases, roughly in order. Owners mark their own.
pub const Phase = enum(u8) {
    process_created,
    main_entered,
    runtime_ready,
    config_loaded,
    platform_ready,
    gpu_ready,
    fonts_ready,
    window_created,
    workbench_built,
    session_restored,
    first_frame_submitted,
    first_frame_presented,
    /// Presented and the UI thread waiting for input.
    interactive,
    first_input_handled,

    /// The epic that owns the phase (its `startup.phase.<owner>` budget
    /// covers the time from the previous mark).
    pub fn owner(p: Phase) []const u8 {
        return switch (p) {
            .process_created, .main_entered => "os",
            .runtime_ready => "e00",
            .config_loaded => "e15",
            .platform_ready, .window_created => "e01",
            .gpu_ready => "e02",
            .fonts_ready => "e03",
            .workbench_built, .first_frame_submitted, .first_frame_presented, .interactive, .first_input_handled => "e04",
            .session_restored => "e08",
        };
    }
};

pub const phase_count = @typeInfo(Phase).@"enum".fields.len;

/// A raw-ticks mark (taken before `install`).
const raw_bit: u64 = 1 << 63;

const sites = blk: {
    var s: [phase_count]zg_core.trace.Site = undefined;
    for (@typeInfo(Phase).@"enum".fields, 0..) |f, i| s[i] = .{ .name = "startup." ++ f.name, .file = "", .line = 0 };
    break :blk s;
};

/// Called on the marking thread when a phase is first marked; keep it
/// short (post real work to a worker).
pub const Hook = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, tl: *StartupTimeline) void,
};

fn phaseBit(p: Phase) u32 {
    return @as(u32, 1) << @as(u5, @intCast(@intFromEnum(p)));
}

const HookSlot = struct {
    used: bool = false,
    phase: Phase = .process_created,
    hook: Hook = undefined,
    /// Claimed by whichever of `markAt` and `on` runs the hook first.
    fired: std.atomic.Value(bool) = .init(false),
};

pub const StartupTimeline = struct {
    /// ns on the `.awake` clock, or ticks | `raw_bit`; 0 = unset.
    marks: [phase_count]std.atomic.Value(u64) = @splat(.init(0)),
    io: ?std.Io = null,
    cal: ?zg_core.time.TickCalibration = null,
    resolution_ns: u64 = 0,
    hooks: [8]HookSlot = @splat(.{}),
    hooks_mutex: std.atomic.Mutex = .unlocked,
    /// A bit per phase with hooks, so marks without hooks skip the lock.
    hook_phases: std.atomic.Value(u32) = .init(0),

    var global_timeline: StartupTimeline = .{};

    /// The process's timeline.
    pub fn global() *StartupTimeline {
        return &global_timeline;
    }

    /// Gives the timeline its clock and records `process_created` from
    /// the OS. Call right after the runtime exists.
    pub fn install(t: *StartupTimeline, io: std.Io) void {
        t.io = io;
        t.cal = .begin(io);
        if (process_start.processCreatedNs(io)) |ps| {
            t.resolution_ns = ps.resolution_ns;
            _ = t.marks[@intFromEnum(Phase.process_created)].cmpxchgStrong(0, ps.created_ns, .acq_rel, .monotonic);
        }
    }

    /// Records `p` now, unless it is already set.
    pub fn mark(t: *StartupTimeline, p: Phase) void {
        const slot = &t.marks[@intFromEnum(p)];
        if (slot.load(.monotonic) != 0) return;
        const v: u64 = if (t.io) |io| zg_core.time.nowNs(io) else zg_core.time.fastTicks() | raw_bit;
        t.markAt(p, v);
    }

    /// Records `p` at `ns` (`.awake`), unless it is already set.
    pub fn markAtNs(t: *StartupTimeline, p: Phase, ns: u64) void {
        if (t.marks[@intFromEnum(p)].load(.monotonic) != 0) return;
        t.markAt(p, ns);
    }

    fn markAt(t: *StartupTimeline, p: Phase, v: u64) void {
        // seq_cst pairs with `on`: either it sees the mark or this sees
        // its hook bit (or both; `fired` keeps the hook to one run).
        if (t.marks[@intFromEnum(p)].cmpxchgStrong(0, @max(v, 1), .seq_cst, .monotonic) != null) return;
        zg_core.trace.recordRaw(.instant, &sites[@intFromEnum(p)], 0);
        if (t.hook_phases.load(.seq_cst) & phaseBit(p) == 0) return;
        while (!t.hooks_mutex.tryLock()) std.atomic.spinLoopHint();
        var run: [8]?Hook = @splat(null);
        for (&t.hooks, 0..) |*h, i| if (h.used and h.phase == p and !h.fired.swap(true, .acq_rel)) {
            run[i] = h.hook;
        };
        t.hooks_mutex.unlock();
        for (run) |h| if (h) |hook| hook.f(hook.ctx, t);
    }

    /// Whether `p` was marked.
    pub fn isSet(t: *const StartupTimeline, p: Phase) bool {
        return t.marks[@intFromEnum(p)].load(.monotonic) != 0;
    }

    /// Runs `hook` when `p` is first marked (at once if it already is).
    /// Runs exactly once. Room for eight hooks; false when full.
    pub fn on(t: *StartupTimeline, p: Phase, hook: Hook) bool {
        while (!t.hooks_mutex.tryLock()) std.atomic.spinLoopHint();
        const slot = for (&t.hooks) |*h| {
            if (!h.used) break h;
        } else {
            t.hooks_mutex.unlock();
            return false;
        };
        slot.* = .{ .used = true, .phase = p, .hook = hook };
        _ = t.hook_phases.fetchOr(phaseBit(p), .seq_cst);
        t.hooks_mutex.unlock();
        if (t.marks[@intFromEnum(p)].load(.seq_cst) != 0 and !slot.fired.swap(true, .acq_rel)) hook.f(hook.ctx, t);
        return true;
    }

    /// Runs `hook` when the first frame is presented.
    pub fn onFirstPresented(t: *StartupTimeline, hook: Hook) bool {
        return t.on(.first_frame_presented, hook);
    }

    /// The marks in `.awake` nanoseconds.
    pub fn summary(t: *StartupTimeline) Summary {
        var s: Summary = .{ .process_start_resolution_ns = t.resolution_ns };
        if (t.cal) |*c| if (t.io) |io| c.finish(io);
        for (&s.phases, &t.marks) |*out, *m| {
            const v = m.load(.acquire);
            out.* = if (v == 0) null else if (v & raw_bit != 0) (if (t.cal) |c| c.toNs(v & ~raw_bit) else null) else v;
        }
        return s;
    }

    /// Clears every mark (tests).
    pub fn reset(t: *StartupTimeline) void {
        t.* = .{};
    }
};

/// Startup marks, in `.awake` nanoseconds.
pub const Summary = struct {
    phases: [phase_count]?u64 = @splat(null),
    process_start_resolution_ns: u64 = 0,
    /// `warm` when the previous run was recent (the OS file cache is
    /// probably hot); a guess either way.
    launch_kind: enum { cold_guess, warm } = .cold_guess,

    pub fn at(s: Summary, p: Phase) ?u64 {
        return s.phases[@intFromEnum(p)];
    }

    /// Where the total starts: process creation when its resolution is
    /// 1 ms or better, else `main_entered`.
    pub fn origin(s: Summary) ?u64 {
        if (s.at(.process_created)) |c| if (s.process_start_resolution_ns <= std.time.ns_per_ms) return c;
        return s.at(.main_entered) orelse s.at(.process_created);
    }

    /// The first frame: presented, else submitted.
    pub fn firstFrame(s: Summary) ?u64 {
        return s.at(.first_frame_presented) orelse s.at(.first_frame_submitted);
    }

    /// Whether `firstFrame` is a submit time standing in for presentation.
    pub fn presentEstimated(s: Summary) bool {
        return s.at(.first_frame_presented) == null;
    }

    /// Origin to the first interactive frame (or the first frame).
    pub fn totalNs(s: Summary) ?u64 {
        const o = s.origin() orelse return null;
        const end = s.at(.interactive) orelse s.firstFrame() orelse return null;
        return end -| o;
    }
};

test "startup: marks idempotent and ordered" {
    var t: StartupTimeline = .{};
    // Before install: raw ticks.
    t.mark(.main_entered);
    try std.testing.expect(t.marks[@intFromEnum(Phase.main_entered)].load(.monotonic) & raw_bit != 0 or !zg_core.time.has_fast_ticks);
    t.install(std.testing.io);
    t.mark(.runtime_ready);
    const first = t.marks[@intFromEnum(Phase.runtime_ready)].load(.monotonic);
    try std.testing.io.sleep(.fromMilliseconds(2), .awake);
    t.mark(.runtime_ready);
    try std.testing.expectEqual(first, t.marks[@intFromEnum(Phase.runtime_ready)].load(.monotonic));
    t.mark(.workbench_built);
    t.mark(.first_frame_submitted);
    t.mark(.interactive);
    const s = t.summary();
    try std.testing.expect(s.at(.runtime_ready).? <= s.at(.workbench_built).?);
    try std.testing.expect(s.at(.workbench_built).? <= s.at(.first_frame_submitted).?);
    if (zg_core.time.has_fast_ticks) try std.testing.expect(s.at(.main_entered).? <= s.at(.runtime_ready).? + std.time.ns_per_ms);
    try std.testing.expect(s.presentEstimated());
    try std.testing.expect(s.totalNs() != null);
    if (s.at(.process_created)) |c| try std.testing.expect(c <= s.at(.runtime_ready).?);
}

test "startup: first-presented hooks run once" {
    var t: StartupTimeline = .{};
    t.install(std.testing.io);
    const H = struct {
        var n: u32 = 0;
        fn f(_: ?*anyopaque, _: *StartupTimeline) void {
            n += 1;
        }
    };
    H.n = 0;
    try std.testing.expect(t.onFirstPresented(.{ .ctx = null, .f = H.f }));
    t.mark(.first_frame_presented);
    t.mark(.first_frame_presented);
    try std.testing.expectEqual(@as(u32, 1), H.n);
    // Registered after the fact: runs at once.
    _ = t.onFirstPresented(.{ .ctx = null, .f = H.f });
    // Other phases' hooks wait for their phase.
    _ = t.on(.interactive, .{ .ctx = null, .f = H.f });
    try std.testing.expectEqual(@as(u32, 2), H.n);
    t.mark(.interactive);
    try std.testing.expectEqual(@as(u32, 3), H.n);
}

test "startup: origin prefers precise process start" {
    var s: Summary = .{};
    s.phases[@intFromEnum(Phase.process_created)] = 1_000;
    s.phases[@intFromEnum(Phase.main_entered)] = 9_000;
    s.phases[@intFromEnum(Phase.interactive)] = 50_000;
    s.process_start_resolution_ns = 10 * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(?u64, 41_000), s.totalNs());
    s.process_start_resolution_ns = 100;
    try std.testing.expectEqual(@as(?u64, 49_000), s.totalNs());
}
