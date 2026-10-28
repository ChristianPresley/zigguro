//! The latency clock contract (E14.F03.S02.T01): every latency timestamp
//! (input event, platform dequeue, frame start, submit, GPU-calibrated
//! and presentation time) is nanoseconds on `zg_core.time.nowNs`, i.e.
//! `std.Io.Clock.awake`: `CLOCK_MONOTONIC` on Linux and the scaled
//! `QueryPerformanceCounter` on Windows (std 0.16.0 `Io/Threaded.zig`).
//!
//! `profileFor` says how good each source is per backend, so reports
//! carry error bars; `checkMonotonicChain` enforces the per-frame order
//! `input <= dequeue <= frame_start <= submit <= presented`. A violation
//! means a clock-domain mismatch: the timeline counts it and keeps the
//! frame out of its histograms. The normative text is section 1 of
//! docs/perf/latency.md.

const std = @import("std");
const FrameRecord = @import("record.zig").FrameRecord;

/// How a timestamp was obtained.
pub const Accuracy = enum {
    /// From the display or input hardware.
    hardware,
    /// From the compositor's or window server's clock.
    compositor_clock,
    /// Read by zigguro when it saw the event (an upper bound).
    software_estimate,
    /// No such timestamp; estimated from others.
    unavailable,
};

/// One timestamp source.
pub const SourceQuality = struct {
    resolution_ns: u64,
    accuracy: Accuracy,
    note: []const u8,
};

/// Platform backends (mirrors `zg_platform.Backend`, which zg_perf cannot
/// import).
pub const Backend = enum { headless, wayland, x11, win32, cocoa };

/// What the backend and renderer support at run time.
pub const Capabilities = struct {
    /// `zwp_input_timestamps_v1` (nanosecond input times).
    wp_input_timestamps: bool = false,
    /// `wp_presentation` feedback carried the `hw_clock` flag.
    wp_presentation_hw_clock: bool = false,
    /// `vkWaitForPresentKHR` completion times.
    vk_present_wait: bool = false,
    /// `VK_EXT_present_timing` past presentation timing.
    vk_present_timing: bool = false,
    /// X11 Present `CompleteNotify` (UST).
    x11_present: bool = false,
};

/// The timestamp quality of one backend.
pub const BackendLatencyProfile = struct {
    backend: Backend,
    input_time: SourceQuality,
    dequeue_time: SourceQuality,
    present_time: SourceQuality,
    present_flags_meaning: []const u8,

    /// Whether key-to-photon from this profile measures a real
    /// presentation (not submit + one refresh).
    pub fn realPresent(p: BackendLatencyProfile) bool {
        return p.present_time.accuracy == .hardware or p.present_time.accuracy == .compositor_clock;
    }

    /// Writes the profile as a JSON object.
    pub fn writeJson(p: BackendLatencyProfile, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{{\"backend\":\"{t}\",", .{p.backend});
        inline for (.{ "input_time", "dequeue_time", "present_time" }) |f| {
            const q = @field(p, f);
            try w.print("\"{s}\":{{\"resolution_ns\":{d},\"accuracy\":\"{t}\",\"note\":", .{ f, q.resolution_ns, q.accuracy });
            try std.json.Stringify.encodeJsonString(q.note, .{}, w);
            try w.writeAll("},");
        }
        try w.writeAll("\"present_flags_meaning\":");
        try std.json.Stringify.encodeJsonString(p.present_flags_meaning, .{}, w);
        try w.writeAll("}");
    }
};

const us = std.time.ns_per_us;
const ms = std.time.ns_per_ms;

const dequeue_qpc: SourceQuality = .{ .resolution_ns = 1 * us, .accuracy = .software_estimate, .note = "nowNs when the platform thread read the event" };

/// The profile of `backend` with `caps`.
pub fn profileFor(backend: Backend, caps: Capabilities) BackendLatencyProfile {
    const flags_wp = "wp_presentation_feedback: vsync, hw_clock, hw_completion, zero_copy";
    const estimate: SourceQuality = .{ .resolution_ns = 1 * us, .accuracy = .unavailable, .note = "no presentation feedback: submit + one refresh period" };
    return switch (backend) {
        .headless => .{
            .backend = backend,
            .input_time = .{ .resolution_ns = 1, .accuracy = .software_estimate, .note = "virtual clock; the host stamps nowNs" },
            .dequeue_time = dequeue_qpc,
            .present_time = .{ .resolution_ns = 1, .accuracy = .unavailable, .note = "virtual vsync clock; the host ignores it" },
            .present_flags_meaning = "vsync only (virtual)",
        },
        .wayland => .{
            .backend = backend,
            .input_time = if (caps.wp_input_timestamps)
                .{ .resolution_ns = 1, .accuracy = .compositor_clock, .note = "zwp_input_timestamps_v1, checked against wp_presentation.clock_id" }
            else
                .{ .resolution_ns = 1 * ms, .accuracy = .software_estimate, .note = "wl_keyboard time is ms with an undefined base: dequeue time used" },
            .dequeue_time = dequeue_qpc,
            .present_time = if (caps.wp_presentation_hw_clock)
                .{ .resolution_ns = 1, .accuracy = .hardware, .note = "wp_presentation presented with hw_clock, in clock_id (CLOCK_MONOTONIC)" }
            else if (caps.vk_present_timing)
                .{ .resolution_ns = 1 * us, .accuracy = .compositor_clock, .note = "VK_EXT_present_timing via calibrated timestamps" }
            else if (caps.vk_present_wait)
                .{ .resolution_ns = 1 * us, .accuracy = .software_estimate, .note = "vkWaitForPresentKHR completion (upper bound)" }
            else
                .{ .resolution_ns = 1, .accuracy = .compositor_clock, .note = "wp_presentation presented without hw_clock" },
            .present_flags_meaning = flags_wp,
        },
        .x11 => .{
            .backend = backend,
            .input_time = .{ .resolution_ns = 1 * ms, .accuracy = .software_estimate, .note = "server ms timestamp: dequeue time used" },
            .dequeue_time = dequeue_qpc,
            .present_time = if (caps.x11_present)
                .{ .resolution_ns = 1 * us, .accuracy = .compositor_clock, .note = "Present CompleteNotify UST (us, CLOCK_MONOTONIC on Mesa; verify per driver)" }
            else
                estimate,
            .present_flags_meaning = "Present CompleteNotify mode (copy, flip, skip)",
        },
        .win32 => .{
            .backend = backend,
            .input_time = .{ .resolution_ns = 1 * ms, .accuracy = .software_estimate, .note = "GetMessageTime (ms since boot, wraps) anchored to QPC" },
            .dequeue_time = dequeue_qpc,
            .present_time = if (caps.vk_present_timing)
                .{ .resolution_ns = 1 * us, .accuracy = .compositor_clock, .note = "VK_EXT_present_timing via calibrated timestamps" }
            else if (caps.vk_present_wait)
                .{ .resolution_ns = 1 * us, .accuracy = .software_estimate, .note = "vkWaitForPresentKHR completion (upper bound)" }
            else
                .{ .resolution_ns = 1 * us, .accuracy = .software_estimate, .note = "QPC after the GDI present (no scanout time)" },
            .present_flags_meaning = "none (GDI) or present-timing stages",
        },
        .cocoa => .{
            .backend = backend,
            .input_time = .{ .resolution_ns = 1 * us, .accuracy = .software_estimate, .note = "NSEvent timestamp (not yet anchored)" },
            .dequeue_time = dequeue_qpc,
            .present_time = estimate,
            .present_flags_meaning = "none",
        },
    };
}

/// The pair of timestamps found out of order.
pub const Violation = enum { input_after_dequeue, dequeue_after_frame_start, input_after_frame_start, frame_start_after_submit, submit_after_presented };

/// The first ordering violation in `r`, if any (absent timestamps are
/// skipped).
pub fn checkMonotonicChain(r: *const FrameRecord) ?Violation {
    if (r.t_input_os_ns) |in| {
        if (r.t_input_dequeue_ns) |dq| if (in > dq) return .input_after_dequeue;
        if (in > r.t_frame_start_ns) return .input_after_frame_start;
    }
    if (r.t_input_dequeue_ns) |dq| if (dq > r.t_frame_start_ns) return .dequeue_after_frame_start;
    if (r.t_frame_start_ns > r.t_submit_ns) return .frame_start_after_submit;
    if (r.t_presented_ns) |p| if (!r.estimated and r.t_submit_ns > p) return .submit_after_presented;
    return null;
}

test "contract: monotonic chain violation detection" {
    var r: FrameRecord = .{ .t_input_os_ns = 100, .t_input_dequeue_ns = 150, .t_frame_start_ns = 200, .t_submit_ns = 300, .t_presented_ns = 400 };
    try std.testing.expectEqual(@as(?Violation, null), checkMonotonicChain(&r));
    r.t_input_os_ns = 160;
    try std.testing.expectEqual(@as(?Violation, .input_after_dequeue), checkMonotonicChain(&r));
    r.t_input_dequeue_ns = null;
    try std.testing.expectEqual(@as(?Violation, null), checkMonotonicChain(&r));
    r.t_input_os_ns = 250;
    try std.testing.expectEqual(@as(?Violation, .input_after_frame_start), checkMonotonicChain(&r));
    r.t_input_os_ns = null;
    r.t_presented_ns = 290;
    try std.testing.expectEqual(@as(?Violation, .submit_after_presented), checkMonotonicChain(&r));
    // An estimate is derived from submit, so it cannot be out of order.
    r.estimated = true;
    try std.testing.expectEqual(@as(?Violation, null), checkMonotonicChain(&r));
    r.t_frame_start_ns = 301;
    try std.testing.expectEqual(@as(?Violation, .frame_start_after_submit), checkMonotonicChain(&r));
}

test "contract: profileFor matrix" {
    const Case = struct { b: Backend, caps: Capabilities, input: Accuracy, present: Accuracy };
    const cases = [_]Case{
        .{ .b = .headless, .caps = .{}, .input = .software_estimate, .present = .unavailable },
        .{ .b = .wayland, .caps = .{}, .input = .software_estimate, .present = .compositor_clock },
        .{ .b = .wayland, .caps = .{ .wp_input_timestamps = true, .wp_presentation_hw_clock = true }, .input = .compositor_clock, .present = .hardware },
        .{ .b = .x11, .caps = .{}, .input = .software_estimate, .present = .unavailable },
        .{ .b = .x11, .caps = .{ .x11_present = true }, .input = .software_estimate, .present = .compositor_clock },
        .{ .b = .win32, .caps = .{}, .input = .software_estimate, .present = .software_estimate },
        .{ .b = .win32, .caps = .{ .vk_present_wait = true, .vk_present_timing = true }, .input = .software_estimate, .present = .compositor_clock },
        .{ .b = .cocoa, .caps = .{}, .input = .software_estimate, .present = .unavailable },
    };
    for (cases) |c| {
        const p = profileFor(c.b, c.caps);
        try std.testing.expectEqual(c.b, p.backend);
        try std.testing.expectEqual(c.input, p.input_time.accuracy);
        try std.testing.expectEqual(c.present, p.present_time.accuracy);
        try std.testing.expectEqual(Accuracy.software_estimate, p.dequeue_time.accuracy);
        try std.testing.expect(p.input_time.note.len > 0 and p.present_time.note.len > 0);
    }
    try std.testing.expect(profileFor(.wayland, .{}).realPresent());
    try std.testing.expect(!profileFor(.headless, .{}).realPresent());
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try profileFor(.wayland, .{ .wp_presentation_hw_clock = true }).writeJson(&w);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hardware", parsed.value.object.get("present_time").?.object.get("accuracy").?.string);
}
