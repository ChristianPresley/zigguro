//! GPU timestamps per frame slot (E02.F06.S04.T01): zones around the
//! uploads, the layer passes and the main pass, read back once the slot
//! retires (never waiting), converted to ns and published in
//! `FrameStats.gpu_ns` and as `zg_core.trace` counters (`gpu.*_ns`).
//!
//! With `VK_KHR/EXT_calibrated_timestamps` on Linux, the device clock is
//! mapped to CLOCK_MONOTONIC (the `.awake` clock of `zg_core.time`) about
//! once a second, giving `Durations.gpu_start_ns` on the CPU timeline.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const vk = @import("../../vk/vk.zig");
const Gpu = @import("../../gpu/Gpu.zig");

const GpuTimer = @This();

pub const Zone = enum(u3) { frame, uploads, layers, main };
pub const Edge = enum { start, end };

/// Durations of one frame's zones (0 for a zone the frame skipped).
pub const Durations = struct {
    frame_ns: u64,
    uploads_ns: u64,
    layers_ns: u64,
    main_ns: u64,
    /// Frame start on the CPU monotonic clock (calibrated devices only).
    gpu_start_ns: ?u64 = null,
};

/// Queries per frame slot (start and end of 4 zones).
const per_slot = 8;
const max_slots = 4;

gpu: *Gpu,
pool: vk.QueryPool,
slots: u32,
valid_bits: u32,
period_ns: f32,
host_reset: bool,
calibrate: bool,
/// Zones written per slot (bit per query); 0 = nothing pending.
written: [max_slots]u8 = @splat(0),
/// Results that were not available when collected.
unavailable: u64 = 0,
/// Device tick and CPU ns of the last calibration.
cal_ticks: u64 = 0,
cal_ns: u64 = 0,
cal_valid: bool = false,

/// A timer for `frames_in_flight` slots, or null when the queue has no
/// timestamps.
pub fn init(gpu: *Gpu, frames_in_flight: u32) !?GpuTimer {
    const bits = gpu.gfx.timestamp_valid_bits;
    const period = gpu.info.limits.timestamp_period_ns;
    if (bits == 0 or period == 0) return null;
    const slots = std.math.clamp(frames_in_flight, 1, max_slots);
    var pool: vk.QueryPool = .null_handle;
    _ = try vk.check(gpu.ddisp.create_query_pool(gpu.dev, &.{ .query_type = .timestamp, .query_count = slots * per_slot }, null, &pool));
    gpu.name(pool, "gpu-timestamps");
    const host_reset = gpu.info.caps.host_query_reset;
    // Queries start undefined: reset them all once.
    if (host_reset) gpu.ddisp.reset_query_pool(gpu.dev, pool, 0, slots * per_slot);
    return .{
        .gpu = gpu,
        .pool = pool,
        .slots = slots,
        .valid_bits = bits,
        .period_ns = period,
        .host_reset = host_reset,
        .calibrate = gpu.info.caps.calibrated_timestamps and builtin.os.tag == .linux,
    };
}

pub fn deinit(self: *GpuTimer) void {
    self.gpu.ddisp.destroy_query_pool(self.gpu.dev, self.pool, null);
}

/// Starts slot `slot`'s queries in `cb` (the slot has retired). Call
/// first in the command buffer, outside rendering.
pub fn begin(self: *GpuTimer, cb: vk.CommandBuffer, slot: u32) void {
    const s = slot % self.slots;
    if (self.host_reset) {
        self.gpu.ddisp.reset_query_pool(self.gpu.dev, self.pool, s * per_slot, per_slot);
    } else {
        self.gpu.ddisp.cmd_reset_query_pool(cb, self.pool, s * per_slot, per_slot);
    }
    self.written[s] = 0;
}

/// Writes the timestamp for `z`'s `edge`.
pub fn mark(self: *GpuTimer, cb: vk.CommandBuffer, slot: u32, z: Zone, edge: Edge) void {
    const s = slot % self.slots;
    const q: u32 = @as(u32, @intFromEnum(z)) * 2 + @intFromBool(edge == .end);
    const stage: vk.PipelineStageFlags2 = if (edge == .start) .{ .top_of_pipe = true } else .{ .all_commands = true };
    self.gpu.ddisp.cmd_write_timestamp2(cb, stage, self.pool, s * per_slot + q);
    self.written[s] |= @as(u8, 1) << @intCast(q);
}

/// The durations recorded in slot `slot`, once it has retired; null
/// when nothing was recorded or results are not available. Never waits.
pub fn collect(self: *GpuTimer, slot: u32, io: std.Io) ?Durations {
    const s = slot % self.slots;
    const written = self.written[s];
    if (written == 0) return null;
    self.written[s] = 0;
    var data: [per_slot][2]u64 = undefined;
    const flags: vk.QueryResultFlags = .{ .@"64" = true, .with_availability = true };
    std.debug.assert(!flags.wait);
    const r = self.gpu.ddisp.get_query_pool_results(self.gpu.dev, self.pool, s * per_slot, per_slot, @sizeOf(@TypeOf(data)), &data, 16, flags);
    if (r != .success and r != .not_ready) return null;
    var ns: [4]u64 = @splat(0);
    for (0..4) |z| {
        const a = z * 2;
        const pair: u8 = @as(u8, 3) << @intCast(a);
        if (written & pair != pair) continue;
        if (data[a][1] == 0 or data[a + 1][1] == 0) {
            self.unavailable += 1;
            if (z == 0) return null;
            continue;
        }
        ns[z] = ticksToNs(data[a][0], data[a + 1][0], self.valid_bits, self.period_ns);
    }
    var d: Durations = .{ .frame_ns = ns[0], .uploads_ns = ns[1], .layers_ns = ns[2], .main_ns = ns[3] };
    if (self.calibrate) d.gpu_start_ns = self.toCpuNs(data[0][0], io);
    zg_core.trace.counter("gpu.frame_ns", @intCast(d.frame_ns));
    zg_core.trace.counter("gpu.uploads_ns", @intCast(d.uploads_ns));
    zg_core.trace.counter("gpu.layers_ns", @intCast(d.layers_ns));
    zg_core.trace.counter("gpu.main_ns", @intCast(d.main_ns));
    return d;
}

/// Maps device tick `t` to CPU monotonic ns, recalibrating about once a
/// second.
fn toCpuNs(self: *GpuTimer, t: u64, io: std.Io) ?u64 {
    const now = zg_core.time.nowNs(io);
    if (!self.cal_valid or now -% self.cal_ns > std.time.ns_per_s) {
        const infos = [_]vk.CalibratedTimestampInfoKHR{ .{ .time_domain = .device }, .{ .time_domain = .clock_monotonic } };
        var ts: [2]u64 = undefined;
        var dev: u64 = 0;
        const r = self.gpu.ddisp.get_calibrated_timestamps_khr(self.gpu.dev, 2, &infos, &ts, &dev);
        if (r != .success) {
            self.calibrate = false;
            return null;
        }
        self.cal_ticks = ts[0];
        self.cal_ns = ts[1];
        self.cal_valid = true;
    }
    const back = ticksToNs(t, self.cal_ticks, self.valid_bits, self.period_ns);
    return self.cal_ns -| back;
}

/// `end - start` in ns for `valid_bits`-bit counters ticking every
/// `period_ns`; one wrap of the counter is handled by the mask.
pub fn ticksToNs(start: u64, end: u64, valid_bits: u32, period_ns: f32) u64 {
    const mask: u64 = if (valid_bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(valid_bits)) - 1;
    const ticks = (end -% start) & mask;
    return @intFromFloat(@as(f64, @floatFromInt(ticks)) * period_ns);
}

test "timing: mask/period conversion with wrap" {
    try std.testing.expectEqual(@as(u64, 100), ticksToNs(10, 110, 64, 1));
    try std.testing.expectEqual(@as(u64, 250), ticksToNs(0, 100, 64, 2.5));
    // A 36-bit counter wrapping between start and end.
    const top: u64 = (1 << 36) - 10;
    try std.testing.expectEqual(@as(u64, 30), ticksToNs(top, 20, 36, 1));
    // Bits above the valid ones are ignored.
    try std.testing.expectEqual(@as(u64, 5), ticksToNs(0xff00_0000_0000_0000, 0xab00_0000_0000_0005, 48, 1));
    try std.testing.expectEqual(@as(u64, 0), ticksToNs(7, 7, 32, 83.3));
}
