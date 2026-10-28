//! `FrameRecord`: everything measured about one frame, joined from E04
//! (CPU phases, input time), E02 (GPU time, present id) and E01/E02
//! (presentation time). All times are `zg_core.time` monotonic ns.

const std = @import("std");

/// What kind of input the frame's oldest input was.
pub const InputKind = enum(u8) { none, key, text, key_repeat, pointer, other };

/// One frame.
pub const FrameRecord = struct {
    /// Frame sequence number (E04).
    seq: u64 = 0,
    /// Platform window id.
    win: u32 = 0,
    /// Oldest input in the frame: OS event time (E01 `Event.*.time_ns`).
    t_input_os_ns: ?u64 = null,
    /// When the platform thread dequeued that input (optional, Win32).
    t_input_dequeue_ns: ?u64 = null,
    /// Kind of that input.
    input_kind: InputKind = .none,
    /// Frame start on the UI thread.
    t_frame_start_ns: u64 = 0,
    /// CPU phases (E04 FrameStats).
    dispatch_ns: u32 = 0,
    build_ns: u32 = 0,
    layout_ns: u32 = 0,
    paint_ns: u32 = 0,
    submit_ns: u32 = 0,
    /// When the frame was submitted.
    t_submit_ns: u64 = 0,
    /// GPU time (E02 timestamp queries), when measured.
    gpu_ns: ?u32 = null,
    /// Present id joining the record with presentation feedback.
    present_id: u64 = 0,
    /// When the frame reached the screen (or the estimate).
    t_presented_ns: ?u64 = null,
    /// Presentation feedback flags (E01).
    present_flags: u8 = 0,
    /// Pixels repainted.
    damage_px: u64 = 0,
    /// `t_presented_ns` is `t_submit + refresh` because no feedback came.
    estimated: bool = false,
    /// The compositor discarded the frame.
    discarded: bool = false,

    /// UI-thread CPU for the frame.
    pub fn cpuNs(r: FrameRecord) u64 {
        return @as(u64, r.dispatch_ns) + r.build_ns + r.layout_ns + r.paint_ns + r.submit_ns;
    }

    /// Presentation time minus OS input time, for frames with input and a
    /// presentation time.
    pub fn keyToPhoton(r: FrameRecord) ?u64 {
        const t_in = r.t_input_os_ns orelse return null;
        const t_out = r.t_presented_ns orelse return null;
        if (t_out < t_in) return null;
        return t_out - t_in;
    }

    /// True for key and text input (repeats excluded).
    pub fn isKeyInput(r: FrameRecord) bool {
        return r.input_kind == .key or r.input_kind == .text;
    }
};

test "record: keyToPhoton and cpu" {
    var r: FrameRecord = .{ .t_input_os_ns = 100, .t_presented_ns = 5_100, .dispatch_ns = 1, .build_ns = 2, .layout_ns = 3, .paint_ns = 4, .submit_ns = 5 };
    try std.testing.expectEqual(@as(?u64, 5000), r.keyToPhoton());
    try std.testing.expectEqual(@as(u64, 15), r.cpuNs());
    r.t_presented_ns = null;
    try std.testing.expectEqual(@as(?u64, null), r.keyToPhoton());
}
