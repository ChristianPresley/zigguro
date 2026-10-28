//! Typing-latency results for `bench-latency` (E14.F03.S02.T02): a
//! `Collector` takes the timeline's finalized frames, keeps the ones with
//! key input after a warm-up, and builds key-to-photon and per-segment
//! histograms; `Report` holds the percentiles and writes them as E00 bench
//! JSON (`package` "app", results `latency.*`) with the backend's
//! `BackendLatencyProfile`.
//!
//! Segments split key-to-photon at the frame's own timestamps:
//! `input_to_dispatch` (input to frame start), `dispatch_to_submit`
//! (frame start to submit) and `submit_to_present`.

const std = @import("std");
const record_mod = @import("record.zig");
const histogram = @import("histogram.zig");
const timeline = @import("timeline.zig");
const clock_contract = @import("clock_contract.zig");

const FrameRecord = record_mod.FrameRecord;
const LatencyHistogram = histogram.LatencyHistogram;

/// More estimated frames than this fails a run whose profile claims real
/// presentation feedback.
pub const max_estimated_fraction: f64 = 0.05;

/// Percentiles of one histogram.
pub const Pcts = struct {
    count: u64 = 0,
    mean_ns: f64 = 0,
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
    p999_ns: u64 = 0,
    max_ns: u64 = 0,

    pub fn of(h: *const LatencyHistogram) Pcts {
        if (h.total == 0) return .{};
        return .{
            .count = h.total,
            .mean_ns = @as(f64, @floatFromInt(h.sum)) / @as(f64, @floatFromInt(h.total)),
            .p50_ns = h.percentile(50),
            .p95_ns = h.percentile(95),
            .p99_ns = h.percentile(99),
            .p999_ns = h.percentile(99.9),
            .max_ns = h.max,
        };
    }
};

/// How keystrokes reached the app (`external`: the photodiode rig typed).
pub const Injection = enum { os, ring, external };

/// The results of one run.
pub const Report = struct {
    key_to_photon: Pcts,
    frame_cpu: Pcts,
    segments: struct { input_to_dispatch: Pcts, dispatch_to_submit: Pcts, submit_to_present: Pcts },
    /// Key frames measured, estimated among them, and frames left out
    /// for clock violations.
    frames: u32,
    estimated_frames: u32,
    clock_violations: u32,
    injection: Injection,
    refresh_ns: u64,
    profile: clock_contract.BackendLatencyProfile,

    /// Whether too many frames were estimated for a profile that claims
    /// real presentation times (always fine without such a claim).
    pub fn estimatedGateOk(r: Report) bool {
        if (!r.profile.realPresent() or r.frames == 0) return true;
        const frac = @as(f64, @floatFromInt(r.estimated_frames)) / @as(f64, @floatFromInt(r.frames));
        return frac <= max_estimated_fraction;
    }

    /// The name of the key-to-photon result: `ring_to_photon` when keys
    /// went into the event queue instead of through the OS.
    pub fn keyMetricName(r: Report) []const u8 {
        return if (r.injection == .ring) "latency.ring_to_photon" else "latency.key_to_photon";
    }

    /// Writes the report as E00 bench JSON.
    pub fn writeJson(r: Report, w: *std.Io.Writer, meta: Meta) std.Io.Writer.Error!void {
        try w.print("{{\n  \"schema\": 1,\n  \"package\": \"app\",\n  \"zig\": \"{s}\",\n  \"target\": \"{s}\",\n  \"optimize\": \"{s}\",\n  \"quick\": false,\n", .{ meta.zig, meta.target, meta.optimize });
        try w.print("  \"injection\": \"{t}\",\n  \"refresh_ns\": {d},\n  \"frames\": {d},\n  \"estimated_frames\": {d},\n  \"clock_violations\": {d},\n  \"profile\": ", .{ r.injection, r.refresh_ns, r.frames, r.estimated_frames, r.clock_violations });
        try r.profile.writeJson(w);
        try w.writeAll(",\n  \"results\": [\n");
        const rows = [_]struct { []const u8, Pcts }{
            .{ r.keyMetricName(), r.key_to_photon },
            .{ "latency.input_to_dispatch", r.segments.input_to_dispatch },
            .{ "latency.dispatch_to_submit", r.segments.dispatch_to_submit },
            .{ "latency.submit_to_present", r.segments.submit_to_present },
            .{ "latency.frame_cpu", r.frame_cpu },
        };
        for (rows, 0..) |row, i| {
            const p = row[1];
            try w.print("    {{ \"name\": \"{s}\", \"iters\": {d}, \"ns_per_op\": {d:.1}, \"p50_ns\": {d}, \"p95_ns\": {d}, \"p99_ns\": {d}, \"p999_ns\": {d}, \"max_ns\": {d} }}{s}\n", .{ row[0], p.count, p.mean_ns, p.p50_ns, p.p95_ns, p.p99_ns, p.p999_ns, p.max_ns, if (i + 1 < rows.len) "," else "" });
        }
        try w.writeAll("  ]\n}\n");
    }

    /// Writes a one-screen summary table.
    pub fn writeSummary(r: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("bench-latency: {d} key frames ({d} estimated, {d} clock violations), {t} injection, refresh {d:.2} ms, {t} backend\n", .{ r.frames, r.estimated_frames, r.clock_violations, r.injection, ms(r.refresh_ns), r.profile.backend });
        try w.print("{s:<28} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9}\n", .{ "metric (ms)", "p50", "p95", "p99", "p99.9", "max" });
        const rows = [_]struct { []const u8, Pcts }{
            .{ r.keyMetricName(), r.key_to_photon },
            .{ "  input_to_dispatch", r.segments.input_to_dispatch },
            .{ "  dispatch_to_submit", r.segments.dispatch_to_submit },
            .{ "  submit_to_present", r.segments.submit_to_present },
            .{ "frame_cpu", r.frame_cpu },
        };
        for (rows) |row| {
            const p = row[1];
            try w.print("{s:<28} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3}\n", .{ row[0], ms(p.p50_ns), ms(p.p95_ns), ms(p.p99_ns), ms(p.p999_ns), ms(p.max_ns) });
        }
    }
};

/// Build facts for the JSON header.
pub const Meta = struct {
    zig: []const u8 = @import("builtin").zig_version_string,
    target: []const u8 = @tagName(@import("builtin").cpu.arch) ++ "-" ++ @tagName(@import("builtin").os.tag),
    optimize: []const u8 = @tagName(@import("builtin").mode),
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Collects key frames from a `FrameTimeline` (`timeline.sink`).
pub const Collector = struct {
    /// Key frames to skip before measuring.
    warmup: u32 = 0,
    seen: u32 = 0,
    frames: u32 = 0,
    estimated: u32 = 0,
    violations: u32 = 0,
    key_to_photon: LatencyHistogram = .{},
    frame_cpu: LatencyHistogram = .{},
    input_to_dispatch: LatencyHistogram = .{},
    dispatch_to_submit: LatencyHistogram = .{},
    submit_to_present: LatencyHistogram = .{},

    /// The sink to set as `FrameTimeline.sink`.
    pub fn sink(c: *Collector) timeline.FinalSink {
        return .{ .ctx = c, .f = onFinal };
    }

    fn onFinal(ctx: *anyopaque, r: *const FrameRecord, violation: bool) void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        c.add(r, violation);
    }

    /// Takes one finalized frame.
    pub fn add(c: *Collector, r: *const FrameRecord, violation: bool) void {
        if (!r.isKeyInput() or r.discarded) return;
        c.seen += 1;
        if (c.seen <= c.warmup) return;
        if (violation) {
            c.violations += 1;
            return;
        }
        const k2p = r.keyToPhoton() orelse return;
        const t_in = r.t_input_os_ns.?;
        c.frames += 1;
        if (r.estimated) c.estimated += 1;
        c.key_to_photon.record(k2p);
        c.frame_cpu.record(r.cpuNs());
        c.input_to_dispatch.record(r.t_frame_start_ns -| t_in);
        c.dispatch_to_submit.record(r.t_submit_ns -| r.t_frame_start_ns);
        c.submit_to_present.record(r.t_presented_ns.? -| r.t_submit_ns);
    }

    /// The report so far.
    pub fn report(c: *const Collector, injection: Injection, refresh_ns: u64, profile: clock_contract.BackendLatencyProfile) Report {
        return .{
            .key_to_photon = .of(&c.key_to_photon),
            .frame_cpu = .of(&c.frame_cpu),
            .segments = .{
                .input_to_dispatch = .of(&c.input_to_dispatch),
                .dispatch_to_submit = .of(&c.dispatch_to_submit),
                .submit_to_present = .of(&c.submit_to_present),
            },
            .frames = c.frames,
            .estimated_frames = c.estimated,
            .clock_violations = c.violations,
            .injection = injection,
            .refresh_ns = refresh_ns,
            .profile = profile,
        };
    }
};

test "latency: report percentiles from synthetic records" {
    var tl = try timeline.FrameTimeline.init(std.testing.allocator, 64);
    defer tl.deinit();
    var c: Collector = .{ .warmup = 5 };
    tl.sink = c.sink();
    var t: u64 = std.time.ns_per_s;
    for (1..106) |i| {
        // Key-to-photon 2 ms + i us: input 1 ms before frame start, 0.5 ms
        // to submit, presented 0.5 ms + i us later.
        const us: u64 = @intCast(i);
        tl.onFrameStats(.{ .seq = 2 * i, .t_input_ns = t - 1_000_000, .input_kind = .text, .t_frame_start_ns = t, .build_ns = 300_000, .t_submit_ns = t + 500_000, .present_id = i });
        tl.onPresented(i, t + 1_000_000 + us * 1000, 1);
        // A frame without input does not count.
        t += 4_000_000;
        tl.onFrameStats(.{ .seq = 2 * i + 1, .t_frame_start_ns = t, .t_submit_ns = t + 100, .expect_feedback = false });
        t += 4_000_000;
    }
    const r = c.report(.os, tl.refresh_ns, clock_contract.profileFor(.wayland, .{ .wp_presentation_hw_clock = true }));
    try std.testing.expectEqual(@as(u32, 100), r.frames);
    try std.testing.expectEqual(@as(u32, 0), r.estimated_frames);
    // Samples are 2.006 .. 2.105 ms; percentiles within the histogram's 1.6 %.
    try std.testing.expectApproxEqRel(@as(f64, 2_055_000), @as(f64, @floatFromInt(r.key_to_photon.p50_ns)), 0.02);
    try std.testing.expectApproxEqRel(@as(f64, 2_104_000), @as(f64, @floatFromInt(r.key_to_photon.p99_ns)), 0.02);
    try std.testing.expectEqual(@as(u64, 2_105_000), r.key_to_photon.max_ns);
    try std.testing.expectApproxEqRel(@as(f64, 1_000_000), @as(f64, @floatFromInt(r.segments.input_to_dispatch.p50_ns)), 0.02);
    try std.testing.expectApproxEqRel(@as(f64, 500_000), @as(f64, @floatFromInt(r.segments.dispatch_to_submit.p99_ns)), 0.02);
    try std.testing.expect(r.estimatedGateOk());

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.writeJson(&w, .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const results = parsed.value.object.get("results").?.array;
    try std.testing.expectEqualStrings("latency.key_to_photon", results.items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 100), results.items[0].object.get("iters").?.integer);
    try std.testing.expectEqualStrings("hardware", parsed.value.object.get("profile").?.object.get("present_time").?.object.get("accuracy").?.string);
    w = .fixed(&buf);
    try r.writeSummary(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "latency.key_to_photon") != null);
}

test "latency: estimated fraction gate" {
    var c: Collector = .{};
    for (0..100) |i| {
        var r: FrameRecord = .{ .seq = i, .t_input_os_ns = 100, .input_kind = .key, .t_frame_start_ns = 200, .t_submit_ns = 300, .t_presented_ns = 400, .estimated = i < 6 };
        c.add(&r, false);
    }
    // A violation and a discarded frame are not measured.
    var bad: FrameRecord = .{ .t_input_os_ns = 500, .input_kind = .key, .t_frame_start_ns = 200, .t_submit_ns = 300, .t_presented_ns = 400 };
    c.add(&bad, true);
    bad.discarded = true;
    c.add(&bad, false);
    try std.testing.expectEqual(@as(u32, 100), c.frames);
    try std.testing.expectEqual(@as(u32, 1), c.violations);
    // 6 % estimated: fails where feedback is claimed, fine where it is not.
    try std.testing.expect(!c.report(.os, 8_333_333, clock_contract.profileFor(.wayland, .{})).estimatedGateOk());
    try std.testing.expect(c.report(.ring, 8_333_333, clock_contract.profileFor(.headless, .{})).estimatedGateOk());
    try std.testing.expectEqualStrings("latency.ring_to_photon", c.report(.ring, 0, clock_contract.profileFor(.headless, .{})).keyMetricName());
}
