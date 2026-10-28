//! `FrameTimeline` (E14.F03.S01.T01): joins per-frame CPU stats (E04), GPU
//! times (E02, from the render thread) and presentation feedback (E01/E02)
//! into `FrameRecord`s, keeps latency histograms, publishes trace counters
//! and calls a hook on slow frames (the flight recorder's trigger).
//!
//! Threading: everything runs on the UI thread except `onGpu`, which the
//! render thread calls; GPU samples cross through a lock-free SPSC ring and
//! are folded in at the next `onFrameStats`.

const std = @import("std");
const zg_core = @import("zg_core");
const record_mod = @import("record.zig");
const histogram = @import("histogram.zig");
const registry = @import("../budget/registry.zig");

const FrameRecord = record_mod.FrameRecord;
const InputKind = record_mod.InputKind;
const LatencyHistogram = histogram.LatencyHistogram;
const log = std.log.scoped(.perf);

/// The per-frame data E04 reports after submit (an adapter from its
/// `FrameStats`).
pub const FrameStatsView = struct {
    seq: u64,
    win: u32 = 0,
    /// Oldest unprocessed input's OS time; 0 = no input this frame.
    t_input_ns: u64 = 0,
    input_kind: InputKind = .none,
    t_frame_start_ns: u64,
    dispatch_ns: u32 = 0,
    build_ns: u32 = 0,
    layout_ns: u32 = 0,
    paint_ns: u32 = 0,
    submit_ns: u32 = 0,
    t_submit_ns: u64,
    /// 0 when the frame was not presented.
    present_id: u64 = 0,
    damage_px: u64 = 0,
};

/// Why a frame was slow.
pub const SlowReason = enum { key_to_photon, frame_cpu, gpu };

/// Called once per slow frame.
pub const SlowFrameHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, rec: *const FrameRecord, reason: SlowReason) void,
};

const GpuSample = struct { seq: u64, gpu_ns: u32 };

/// Frames without feedback finalize as estimated after this many newer
/// frames.
pub const feedback_window = 8;

/// The frame timeline.
pub const FrameTimeline = struct {
    gpa: std.mem.Allocator,
    ring: []FrameRecord,
    /// Slots whose record is final (or empty).
    final: []bool,
    /// Highest seq seen.
    newest: u64 = 0,
    gpu_queue: zg_core.containers.SpscRing(GpuSample, 256) = .empty,
    /// Key/text frames: OS input to presentation (real feedback only).
    key_to_photon: LatencyHistogram = .{},
    /// Same, from estimated presentation times.
    key_to_photon_estimated: LatencyHistogram = .{},
    /// UI-thread CPU per frame.
    frame_cpu: LatencyHistogram = .{},
    /// GPU time per frame.
    gpu: LatencyHistogram = .{},
    /// Display refresh interval for estimates (E01 `Event.frame.refresh_ns`).
    refresh_ns: u64 = 8_333_333,
    /// Slow = above this factor times the budget limit.
    slow_factor: f64 = 2.0,
    hook: ?SlowFrameHook = null,
    /// Frames finalized, discarded, estimated (diagnostics).
    finalized: u64 = 0,
    discarded: u64 = 0,
    estimated: u64 = 0,
    clock_warned: bool = false,

    /// A timeline holding the last `capacity` frames (default 1024).
    pub fn init(gpa: std.mem.Allocator, capacity: u32) !FrameTimeline {
        const ring = try gpa.alloc(FrameRecord, capacity);
        errdefer gpa.free(ring);
        const final = try gpa.alloc(bool, capacity);
        @memset(ring, .{});
        @memset(final, true);
        return .{ .gpa = gpa, .ring = ring, .final = final };
    }

    /// Frees the ring.
    pub fn deinit(t: *FrameTimeline) void {
        t.gpa.free(t.ring);
        t.gpa.free(t.final);
        t.* = undefined;
    }

    /// Installs the slow-frame hook.
    pub fn setSlowFrameHook(t: *FrameTimeline, hook: SlowFrameHook) void {
        t.hook = hook;
    }

    fn slot(t: *FrameTimeline, seq: u64) usize {
        return @intCast(seq % t.ring.len);
    }

    /// Render thread: GPU time of frame `seq`. Dropped if the queue is full.
    pub fn onGpu(t: *FrameTimeline, seq: u64, gpu_ns: u32) void {
        _ = t.gpu_queue.push(.{ .seq = seq, .gpu_ns = gpu_ns });
    }

    fn foldGpu(t: *FrameTimeline) void {
        while (t.gpu_queue.pop()) |g| {
            const i = t.slot(g.seq);
            if (t.ring[i].seq != g.seq) continue;
            t.ring[i].gpu_ns = g.gpu_ns;
            if (t.final[i]) t.gpu.record(g.gpu_ns);
        }
    }

    /// UI thread, after submit.
    pub fn onFrameStats(t: *FrameTimeline, s: FrameStatsView) void {
        t.foldGpu();
        const i = t.slot(s.seq);
        // The slot's previous occupant is about to be overwritten.
        if (!t.final[i]) t.finalizeEstimated(i);
        t.ring[i] = .{
            .seq = s.seq,
            .win = s.win,
            .t_input_os_ns = if (s.t_input_ns != 0) s.t_input_ns else null,
            .input_kind = s.input_kind,
            .t_frame_start_ns = s.t_frame_start_ns,
            .dispatch_ns = s.dispatch_ns,
            .build_ns = s.build_ns,
            .layout_ns = s.layout_ns,
            .paint_ns = s.paint_ns,
            .submit_ns = s.submit_ns,
            .t_submit_ns = s.t_submit_ns,
            .present_id = s.present_id,
            .damage_px = s.damage_px,
        };
        t.final[i] = false;
        t.newest = @max(t.newest, s.seq);
        t.frame_cpu.record(t.ring[i].cpuNs());
        if (s.present_id == 0) {
            // Nothing presented: nothing to wait for.
            t.ring[i].discarded = true;
            t.finalize(i);
        }
        // Frames older than the feedback window finalize as estimated.
        var k: usize = 0;
        while (k < t.ring.len) : (k += 1) {
            if (!t.final[k] and t.ring[k].seq + feedback_window <= t.newest) t.finalizeEstimated(k);
        }
    }

    /// UI thread: presentation feedback (`flags` from E01; `discarded`
    /// when the compositor dropped the frame).
    pub fn onPresented(t: *FrameTimeline, present_id: u64, t_presented_ns: u64, flags: u8) void {
        t.onPresentedEx(present_id, t_presented_ns, flags, false);
    }

    /// `onPresented` with a discard flag.
    pub fn onPresentedEx(t: *FrameTimeline, present_id: u64, t_presented_ns: u64, flags: u8, discarded: bool) void {
        for (t.ring, 0..) |*r, i| {
            if (t.final[i] or r.present_id != present_id) continue;
            r.present_flags = flags;
            if (discarded) {
                r.discarded = true;
            } else {
                r.t_presented_ns = t_presented_ns;
            }
            t.finalize(i);
            return;
        }
    }

    fn finalizeEstimated(t: *FrameTimeline, i: usize) void {
        const r = &t.ring[i];
        if (!r.discarded and r.t_presented_ns == null) {
            r.t_presented_ns = r.t_submit_ns + t.refresh_ns;
            r.estimated = true;
            t.estimated += 1;
        }
        t.finalize(i);
    }

    fn finalize(t: *FrameTimeline, i: usize) void {
        t.final[i] = true;
        t.finalized += 1;
        const r = &t.ring[i];
        if (r.discarded) t.discarded += 1;
        if (std.debug.runtime_safety and !t.clock_warned) {
            const in = r.t_input_os_ns orelse 0;
            const out = r.t_presented_ns orelse r.t_submit_ns;
            if (!(out >= r.t_submit_ns and r.t_submit_ns >= in)) {
                t.clock_warned = true;
                log.info("frame timeline: timestamps out of order (input {d}, submit {d}, presented {d}); check the clock domain", .{ in, r.t_submit_ns, out });
            }
        }
        var reason: ?SlowReason = null;
        if (r.isKeyInput()) if (r.keyToPhoton()) |v| {
            if (r.estimated) t.key_to_photon_estimated.record(v) else t.key_to_photon.record(v);
            zg_core.trace.counter("perf.key_to_photon_ns", @intCast(v));
            if (@as(f64, @floatFromInt(v)) > t.slow_factor * registry.get("input.key_to_photon").limit) reason = .key_to_photon;
        };
        const cpu = r.cpuNs();
        zg_core.trace.counter("perf.frame_cpu_ns", @intCast(cpu));
        if (reason == null and @as(f64, @floatFromInt(cpu)) > t.slow_factor * registry.get("ui.frame_cpu_keystroke").limit) reason = .frame_cpu;
        if (r.gpu_ns) |g| {
            t.gpu.record(g);
            zg_core.trace.counter("perf.gpu_ns", g);
            if (reason == null and @as(f64, @floatFromInt(g)) > t.slow_factor * registry.get("vulkan.gpu_frame").limit) reason = .gpu;
        }
        if (reason) |why| if (t.hook) |h| h.f(h.ctx, r, why);
    }

    /// Copies the final records, oldest first, into `out`; returns the count.
    pub fn snapshot(t: *const FrameTimeline, out: []FrameRecord) usize {
        var n: usize = 0;
        const cap: u64 = t.ring.len;
        const first: u64 = if (t.newest + 1 > cap) t.newest + 1 - cap else 0;
        var seq = first;
        while (seq <= t.newest and n < out.len) : (seq += 1) {
            const i: usize = @intCast(seq % cap);
            if (t.ring[i].seq != seq or !t.final[i] or (seq == 0 and t.ring[i].t_submit_ns == 0)) continue;
            out[n] = t.ring[i];
            n += 1;
        }
        return n;
    }
};

const Slow = struct {
    n: usize = 0,
    last: ?SlowReason = null,
    fn on(ctx: *anyopaque, _: *const FrameRecord, why: SlowReason) void {
        const s: *Slow = @ptrCast(@alignCast(ctx));
        s.n += 1;
        s.last = why;
    }
};

fn stats(seq: u64, t0: u64) FrameStatsView {
    return .{ .seq = seq, .t_input_ns = t0, .input_kind = .key, .t_frame_start_ns = t0 + 100_000, .build_ns = 200_000, .t_submit_ns = t0 + 1_000_000, .present_id = seq + 1000 };
}

test "timeline: joins stats, gpu, presented by present_id" {
    var t = try FrameTimeline.init(std.testing.allocator, 64);
    defer t.deinit();
    t.onFrameStats(stats(1, 10_000_000));
    t.onGpu(1, 400_000);
    t.onFrameStats(stats(2, 20_000_000));
    t.onPresented(1001, 15_000_000, 1);
    var out: [8]FrameRecord = undefined;
    const n = t.snapshot(&out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(?u32, 400_000), out[0].gpu_ns);
    try std.testing.expectEqual(@as(?u64, 5_000_000), out[0].keyToPhoton());
    try std.testing.expectEqual(@as(u64, 1), t.key_to_photon.total);
    try std.testing.expectEqual(@as(u64, 1), t.gpu.total);
}

test "timeline: estimated when feedback missing" {
    var t = try FrameTimeline.init(std.testing.allocator, 64);
    defer t.deinit();
    for (1..12) |s| t.onFrameStats(stats(s, s * 10_000_000));
    // Frames 1..3 are 8+ frames old: estimated at submit + refresh.
    try std.testing.expectEqual(@as(u64, 3), t.estimated);
    try std.testing.expectEqual(@as(u64, 3), t.key_to_photon_estimated.total);
    try std.testing.expectEqual(@as(u64, 0), t.key_to_photon.total);
    var out: [16]FrameRecord = undefined;
    const n = t.snapshot(&out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(out[0].estimated);
    try std.testing.expectEqual(@as(?u64, 10_000_000 + 1_000_000 + t.refresh_ns), out[0].t_presented_ns);
}

test "timeline: discarded present handled" {
    var t = try FrameTimeline.init(std.testing.allocator, 64);
    defer t.deinit();
    t.onFrameStats(stats(1, 10_000_000));
    t.onPresentedEx(1001, 0, 0, true);
    try std.testing.expectEqual(@as(u64, 1), t.discarded);
    try std.testing.expectEqual(@as(u64, 0), t.key_to_photon.total + t.key_to_photon_estimated.total);
    var s = stats(2, 20_000_000);
    s.present_id = 0; // not presented at all
    t.onFrameStats(s);
    try std.testing.expectEqual(@as(u64, 2), t.discarded);
}

test "timeline: slow hook fires once per frame" {
    var t = try FrameTimeline.init(std.testing.allocator, 64);
    defer t.deinit();
    var slow: Slow = .{};
    t.setSlowFrameHook(.{ .ctx = &slow, .f = Slow.on });
    var s = stats(1, 10_000_000);
    s.build_ns = 10_000_000; // CPU slow too
    t.onFrameStats(s);
    t.onGpu(1, 5_000_000); // folded on the next frame, after finalize
    t.onPresented(1001, 10_000_000 + 30_000_000, 0); // 30 ms key to photon
    try std.testing.expectEqual(@as(usize, 1), slow.n);
    try std.testing.expectEqual(@as(?SlowReason, .key_to_photon), slow.last);
}

test "timeline: ring wraparound" {
    var t = try FrameTimeline.init(std.testing.allocator, 16);
    defer t.deinit();
    for (1..100) |s| {
        t.onFrameStats(stats(s, s * 1_000_000_0));
        t.onPresented(s + 1000, s * 1_000_000_0 + 3_000_000, 0);
    }
    var out: [32]FrameRecord = undefined;
    const n = t.snapshot(&out);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqual(@as(u64, 84), out[0].seq);
    try std.testing.expectEqual(@as(u64, 99), out[15].seq);
    try std.testing.expectEqual(@as(u64, 99), t.key_to_photon.total);
}
