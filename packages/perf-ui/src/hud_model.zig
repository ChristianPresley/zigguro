//! The HUD's model (E14.F03.S01.T02): bars and text rows computed from a
//! `FrameTimeline` snapshot, with no GUI types, so tests and the view
//! share one source of numbers.
//!
//! A bar stacks a frame's CPU phases (dispatch, build, layout, paint,
//! submit) and its GPU time. A frame whose CPU time is over the refresh
//! period is over budget. The text rows show FPS over the last second of
//! frames, CPU and GPU p99 over the bars, key-to-photon p50/p99 over the
//! last 1 000 keys, and the optional wakeup and memory sources. Frames
//! that broke the latency clock contract are counted in the first row
//! ("clock x N"): their numbers are left out.

const std = @import("std");
const zg_perf = @import("zg_perf");

const FrameRecord = zg_perf.frame.FrameRecord;
const FrameTimeline = zg_perf.frame.FrameTimeline;

/// The segments of a bar, bottom to top.
pub const Phase = enum(u3) { dispatch, build, layout, paint, submit, gpu };

/// One frame's bar.
pub const Bar = struct {
    seq: u64 = 0,
    /// Nanoseconds per `Phase`.
    ns: [6]u32 = @splat(0),
    over: bool = false,

    /// CPU time (every phase but GPU).
    pub fn cpuNs(b: Bar) u64 {
        var t: u64 = 0;
        for (b.ns[0..5]) |v| t += v;
        return t;
    }
};

/// Memory numbers for the HUD's memory row.
pub const Memory = struct { private_bytes: u64, gpu_bytes: u64 };

/// Optional numbers other subsystems provide (E14.F04 memory sampler,
/// E14.F05 idle monitor). A null function or result hides the row's value.
pub const Sources = struct {
    ctx: ?*anyopaque = null,
    wakeups_per_s: ?*const fn (ctx: ?*anyopaque) ?f64 = null,
    memory: ?*const fn (ctx: ?*anyopaque) ?Memory = null,
};

/// The number of text rows.
pub const row_count = 6;
/// The longest row.
pub const row_len = 64;

/// The 16.67 ms line drawn next to the refresh line.
pub const line_60hz_ns: u64 = 16_666_667;
/// The graph's lowest full scale.
pub const min_scale_ns: u64 = 33_333_333;

/// The HUD's model.
pub const Model = struct {
    gpa: std.mem.Allocator,
    /// Bars, oldest first (`bars[0..len]`).
    bars: []Bar,
    len: usize = 0,
    scratch: []FrameRecord,
    /// The graph's full scale and the refresh period.
    scale_ns: u64 = min_scale_ns,
    refresh_ns: u64 = 8_333_333,
    /// No frames since the last update: values are frozen.
    idle: bool = false,
    /// The newest frame in the bars.
    newest: u64 = 0,
    rows: [row_count][row_len]u8 = undefined,
    row_lens: [row_count]u8 = @splat(0),

    /// A model holding `frames` bars.
    pub fn init(gpa: std.mem.Allocator, frames: u16) !Model {
        const bars = try gpa.alloc(Bar, frames);
        errdefer gpa.free(bars);
        return .{ .gpa = gpa, .bars = bars, .scratch = try gpa.alloc(FrameRecord, frames) };
    }

    pub fn deinit(m: *Model) void {
        m.gpa.free(m.bars);
        m.gpa.free(m.scratch);
        m.* = undefined;
    }

    /// Row `i`'s text.
    pub fn row(m: *const Model, i: usize) []const u8 {
        return m.rows[i][0..m.row_lens[i]];
    }

    fn setRow(m: *Model, i: usize, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&m.rows[i], fmt, args) catch m.rows[i][0..row_len];
        m.row_lens[i] = @intCast(s.len);
    }

    /// Recomputes bars and rows from `tl`. `idle` freezes the numbers and
    /// says so in the first row.
    pub fn update(m: *Model, tl: *const FrameTimeline, src: Sources, idle: bool) void {
        m.refresh_ns = tl.refresh_ns;
        m.scale_ns = @max(min_scale_ns, 2 * tl.refresh_ns);
        m.idle = idle;
        const recs = m.scratch[0..tl.snapshotLatest(m.scratch)];
        m.len = recs.len;
        for (recs, 0..) |r, i| m.bars[i] = barOf(r, tl.refresh_ns);
        m.newest = if (recs.len > 0) recs[recs.len - 1].seq else 0;

        // FPS: frame intervals over the last second of frames.
        var fps: u32 = 0;
        if (recs.len > 1) {
            const last = recs[recs.len - 1].t_submit_ns;
            var first = last;
            var n: u64 = 0;
            for (recs) |r| if (r.t_submit_ns + std.time.ns_per_s >= last) {
                first = @min(first, r.t_submit_ns);
                n += 1;
            };
            if (last > first) fps = @intFromFloat(@round(@as(f64, @floatFromInt(n - 1)) * std.time.ns_per_s / @as(f64, @floatFromInt(last - first))));
        }
        var cpu: zg_perf.frame.LatencyHistogram = .{};
        var gpu: zg_perf.frame.LatencyHistogram = .{};
        var over: u32 = 0;
        for (m.bars[0..m.len]) |b| {
            cpu.record(b.cpuNs());
            if (b.ns[@intFromEnum(Phase.gpu)] != 0) gpu.record(b.ns[@intFromEnum(Phase.gpu)]);
            if (b.over) over += 1;
        }
        var clock_buf: [24]u8 = undefined;
        const clock = if (tl.clock_violations > 0) std.fmt.bufPrint(&clock_buf, ", clock x {d}", .{tl.clock_violations}) catch "" else "";
        if (idle) m.setRow(0, "idle (last {d} fps){s}", .{ fps, clock }) else m.setRow(0, "{d} fps{s}", .{ fps, clock });
        m.setRow(1, "CPU p99 {d:.2} ms, {d} over", .{ ms(cpu.percentile(99)), over });
        if (gpu.total > 0) m.setRow(2, "GPU p99 {d:.2} ms", .{ms(gpu.percentile(99))}) else m.setRow(2, "GPU -", .{});
        const k = &tl.key_to_photon_recent;
        if (k.current.total + k.previous.total > 0) {
            const est = tl.key_to_photon.total == 0;
            m.setRow(3, "key-photon p50 {d:.1} p99 {d:.1} ms{s}", .{ ms(k.percentile(50)), ms(k.percentile(99)), if (est) " est" else "" });
        } else m.setRow(3, "key-photon -", .{});
        const wake: ?f64 = if (src.wakeups_per_s) |f| f(src.ctx) else null;
        if (wake) |w| m.setRow(4, "wakeups {d:.1}/s", .{w}) else m.setRow(4, "wakeups -", .{});
        const mem: ?Memory = if (src.memory) |f| f(src.ctx) else null;
        if (mem) |x| m.setRow(5, "private {d} MB, GPU {d} MB", .{ x.private_bytes >> 20, x.gpu_bytes >> 20 }) else m.setRow(5, "memory -", .{});
    }

    /// The bar under x fraction `f` (0..1 across the graph), if any.
    pub fn barAt(m: *const Model, f: f32) ?Bar {
        if (m.len == 0 or f < 0 or f >= 1) return null;
        const slots: f32 = @floatFromInt(m.bars.len);
        const i: usize = @intFromFloat(@floor(f * slots));
        // Bars are right-aligned: the newest is in the last slot.
        const first = m.bars.len - m.len;
        if (i < first) return null;
        return m.bars[i - first];
    }
};

fn barOf(r: FrameRecord, refresh_ns: u64) Bar {
    var b: Bar = .{ .seq = r.seq, .ns = .{ r.dispatch_ns, r.build_ns, r.layout_ns, r.paint_ns, r.submit_ns, r.gpu_ns orelse 0 } };
    b.over = b.cpuNs() > refresh_ns;
    return b;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// A timeline filled with `n` synthetic frames (tests, the bench, golden
/// images): every 10th frame has a key press and every 25th is slow.
pub fn syntheticTimeline(gpa: std.mem.Allocator, n: u32) !FrameTimeline {
    var tl: FrameTimeline = try .init(gpa, 1024);
    errdefer tl.deinit();
    var t: u64 = std.time.ns_per_s;
    for (1..n + 1) |i| {
        const slow = i % 25 == 0;
        const build: u32 = if (slow) 9_000_000 else 1_200_000 + @as(u32, @intCast(i % 7)) * 100_000;
        tl.onFrameStats(.{
            .seq = i,
            .t_input_ns = if (i % 10 == 0) t - 2_000_000 else 0,
            .input_kind = if (i % 10 == 0) .key else .none,
            .t_frame_start_ns = t,
            .dispatch_ns = 150_000,
            .build_ns = build,
            .layout_ns = 600_000,
            .paint_ns = 900_000,
            .submit_ns = 200_000,
            .t_submit_ns = t + 3_000_000,
            .present_id = i,
            .expect_feedback = false,
        });
        tl.onGpu(i, 1_100_000);
        t += tl.refresh_ns;
    }
    return tl;
}

test "hud model: bars, over budget and rows" {
    const gpa = std.testing.allocator;
    var tl = try syntheticTimeline(gpa, 300);
    defer tl.deinit();
    var m: Model = try .init(gpa, 240);
    defer m.deinit();
    m.update(&tl, .{}, false);
    try std.testing.expectEqual(@as(usize, 240), m.len);
    try std.testing.expectEqual(@as(u64, 300), m.newest);
    try std.testing.expectEqual(@as(u64, 61), m.bars[0].seq);
    // Frame 75 (bar 14) is slow; frame 76 is not.
    try std.testing.expect(m.bars[14].over and m.bars[14].seq == 75);
    try std.testing.expect(!m.bars[15].over);
    try std.testing.expectEqual(@as(u32, 9_000_000), m.bars[14].ns[@intFromEnum(Phase.build)]);
    try std.testing.expectEqualStrings("120 fps", m.row(0));
    try std.testing.expect(std.mem.startsWith(u8, m.row(1), "CPU p99 "));
    try std.testing.expect(std.mem.endsWith(u8, m.row(1), ", 10 over"));
    try std.testing.expect(std.mem.startsWith(u8, m.row(3), "key-photon p50 "));
    try std.testing.expect(std.mem.endsWith(u8, m.row(3), " est"));
    try std.testing.expectEqualStrings("wakeups -", m.row(4));
    m.update(&tl, .{}, true);
    try std.testing.expectEqualStrings("idle (last 120 fps)", m.row(0));
    tl.clock_violations = 3;
    m.update(&tl, .{}, false);
    try std.testing.expectEqualStrings("120 fps, clock x 3", m.row(0));
}

test "hud model: sources and bar hit" {
    const gpa = std.testing.allocator;
    var tl = try syntheticTimeline(gpa, 10);
    defer tl.deinit();
    var m: Model = try .init(gpa, 240);
    defer m.deinit();
    const S = struct {
        fn wake(_: ?*anyopaque) ?f64 {
            return 0.5;
        }
        fn mem(_: ?*anyopaque) ?Memory {
            return .{ .private_bytes = 300 << 20, .gpu_bytes = 64 << 20 };
        }
    };
    m.update(&tl, .{ .wakeups_per_s = S.wake, .memory = S.mem }, false);
    try std.testing.expectEqualStrings("wakeups 0.5/s", m.row(4));
    try std.testing.expectEqualStrings("private 300 MB, GPU 64 MB", m.row(5));
    // Ten bars fill the last ten of 240 slots.
    try std.testing.expect(m.barAt(0.5) == null);
    try std.testing.expectEqual(@as(u64, 10), m.barAt(0.999).?.seq);
    try std.testing.expectEqual(@as(u64, 1), m.barAt(230.5 / 240.0).?.seq);
}
