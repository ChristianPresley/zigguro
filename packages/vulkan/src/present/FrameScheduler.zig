//! Frames in flight (E02.F04.S03.T01): N frame slots, each with a
//! transient command pool and one primary command buffer, retired through
//! one timeline semaphore, plus deferred destruction.
//!
//! `begin` waits until the slot's previous submission completed (1 s
//! waits, a logged GPU-hang diagnostic, device lost after 5 s), resets the
//! pool and starts recording. `submit` signals the next timeline value.
//! Only the render thread uses a scheduler.

const FrameScheduler = @This();

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const DeviceMemory = @import("../mem/DeviceMemory.zig");
const deferred_mod = @import("Deferred.zig");

pub const Deferred = deferred_mod.Deferred;

const log = std.log.scoped(.zg_vulkan);

pub const max_frames_in_flight = 3;
const wait_step_ns = std.time.ns_per_s;
const lost_after_ns = 5 * std.time.ns_per_s;

pub const FrameSlot = struct {
    /// 0..frames_in_flight.
    index: u8,
    pool: vk.CommandPool = .null_handle,
    cb: vk.CommandBuffer = .null_handle,
    /// The timeline value of this slot's last submission (0 = none).
    timeline_value: u64 = 0,
    /// The frame number being recorded.
    frame: u64 = 0,
};

gpu: *Gpu,
mem: *DeviceMemory,
slots: [max_frames_in_flight]FrameSlot,
frames_in_flight: u8,
timeline: vk.Semaphore,
/// The last value submitted.
submitted: u64 = 0,
/// Frames begun so far.
frame: u64 = 0,
/// The slot being recorded, between `begin` and `submit`.
recording: ?*FrameSlot = null,
deferred: deferred_mod.Queue = .{},

pub fn init(gpu: *Gpu, mem: *DeviceMemory, frames_in_flight: u8) !FrameScheduler {
    std.debug.assert(frames_in_flight >= 1 and frames_in_flight <= max_frames_in_flight);
    const d = &gpu.ddisp;
    const type_info: vk.SemaphoreTypeCreateInfo = .{ .semaphore_type = .timeline, .initial_value = 0 };
    var timeline: vk.Semaphore = .null_handle;
    _ = try vk.check(d.create_semaphore(gpu.dev, &.{ .p_next = &type_info }, null, &timeline));
    errdefer d.destroy_semaphore(gpu.dev, timeline, null);
    gpu.name(timeline, "frame-timeline");

    var self: FrameScheduler = .{ .gpu = gpu, .mem = mem, .slots = undefined, .frames_in_flight = frames_in_flight, .timeline = timeline };
    for (&self.slots, 0..) |*s, i| s.* = .{ .index = @intCast(i) };
    errdefer for (self.slots[0..frames_in_flight]) |s| if (s.pool != .null_handle) d.destroy_command_pool(gpu.dev, s.pool, null);
    for (self.slots[0..frames_in_flight]) |*s| {
        _ = try vk.check(d.create_command_pool(gpu.dev, &.{ .flags = .{ .transient = true }, .queue_family_index = gpu.gfx.family }, null, &s.pool));
        _ = try vk.check(d.allocate_command_buffers(gpu.dev, &.{ .command_pool = s.pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&s.cb)));
        gpu.name(s.pool, "frame-pool");
    }
    return self;
}

/// Waits for the GPU, destroys every deferred object and the slots.
pub fn deinit(self: *FrameScheduler) void {
    const d = &self.gpu.ddisp;
    if (!self.gpu.lost.load(.acquire)) self.waitValue(self.submitted) catch {};
    self.collectUpTo(std.math.maxInt(u64));
    self.deferred.deinit(self.gpu.gpa);
    for (self.slots[0..self.frames_in_flight]) |s| d.destroy_command_pool(self.gpu.dev, s.pool, null);
    d.destroy_semaphore(self.gpu.dev, self.timeline, null);
    self.* = undefined;
}

/// The highest timeline value the GPU has completed.
pub fn completed(self: *FrameScheduler) u64 {
    var v: u64 = 0;
    _ = vk.check(self.gpu.ddisp.get_semaphore_counter_value(self.gpu.dev, self.timeline, &v)) catch return 0;
    return v;
}

/// Blocks until the timeline reaches `value`.
pub fn waitValue(self: *FrameScheduler, value: u64) error{DeviceLost}!void {
    if (value == 0) return;
    const sems = [_]vk.Semaphore{self.timeline};
    const vals = [_]u64{value};
    var waited: u64 = 0;
    while (true) {
        const r = self.gpu.ddisp.wait_semaphores(self.gpu.dev, &.{ .semaphore_count = 1, .p_semaphores = &sems, .p_values = &vals }, wait_step_ns);
        try self.gpu.checkLost(r);
        if (r == .success) return;
        if (r != .timeout) {
            log.err("vkWaitSemaphores: {t}", .{r});
            return error.DeviceLost;
        }
        waited += wait_step_ns;
        log.warn("GPU has not finished timeline value {d} after {d} s (completed {d})", .{ value, waited / std.time.ns_per_s, self.completed() });
        if (waited >= lost_after_ns) {
            try self.gpu.checkLost(.error_device_lost);
            return error.DeviceLost;
        }
    }
}

/// Waits for the next slot, recycles its command pool, destroys deferred
/// objects that have retired and starts recording.
pub fn begin(self: *FrameScheduler) !*FrameSlot {
    std.debug.assert(self.recording == null);
    const s = &self.slots[self.frame % self.frames_in_flight];
    try self.waitValue(s.timeline_value);
    self.collect();
    const d = &self.gpu.ddisp;
    _ = try vk.check(d.reset_command_pool(self.gpu.dev, s.pool, .{}));
    _ = try vk.check(d.begin_command_buffer(s.cb, &.{ .flags = .{ .one_time_submit = true } }));
    s.frame = self.frame;
    self.frame += 1;
    self.recording = s;
    return s;
}

/// Abandons `fs` without submitting (nothing recorded may have been
/// executed; the slot's command pool is reset at its next `begin`).
pub fn cancel(self: *FrameScheduler, fs: *FrameSlot) void {
    std.debug.assert(self.recording == fs);
    self.recording = null;
    _ = self.gpu.ddisp.end_command_buffer(fs.cb);
}

/// Ends `fs` and submits it on the graphics queue, waiting on `waits` and
/// signalling the next timeline value plus `extra_signals`.
pub fn submit(self: *FrameScheduler, fs: *FrameSlot, waits: []const vk.SemaphoreSubmitInfo, extra_signals: []const vk.SemaphoreSubmitInfo) !void {
    std.debug.assert(self.recording == fs);
    self.recording = null;
    const d = &self.gpu.ddisp;
    _ = try vk.check(d.end_command_buffer(fs.cb));
    const value = self.submitted + 1;
    var signals: [5]vk.SemaphoreSubmitInfo = undefined;
    std.debug.assert(extra_signals.len < signals.len);
    signals[0] = .{ .semaphore = self.timeline, .value = value, .stage_mask = .{ .all_commands = true }, .device_index = 0 };
    @memcpy(signals[1..][0..extra_signals.len], extra_signals);
    const cbi = [_]vk.CommandBufferSubmitInfo{.{ .command_buffer = fs.cb, .device_mask = 0 }};
    const si = [_]vk.SubmitInfo2{.{
        .wait_semaphore_info_count = @intCast(waits.len),
        .p_wait_semaphore_infos = waits.ptr,
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &cbi,
        .signal_semaphore_info_count = @intCast(1 + extra_signals.len),
        .p_signal_semaphore_infos = &signals,
    }};
    const q = &self.gpu.gfx;
    q.mutex.lockUncancelable(self.gpu.io);
    const r = d.queue_submit2(q.handle, si.len, &si, .null_handle);
    q.mutex.unlock(self.gpu.io);
    try self.gpu.checkLostAt(r, .submit);
    _ = try vk.check(r);
    self.submitted = value;
    fs.timeline_value = value;
}

/// Destroys `item` once every frame submitted so far, and the one being
/// recorded, has completed.
pub fn deferDestroy(self: *FrameScheduler, item: Deferred) void {
    const value = self.submitted + @intFromBool(self.recording != null);
    self.deferred.push(self.gpu.gpa, value, item) catch {
        // Out of memory: wait for the GPU and destroy it now.
        self.waitValue(self.submitted) catch {};
        var it = item;
        it.destroy(self.mem);
    };
}

/// Destroys the deferred objects whose value has completed.
pub fn collect(self: *FrameScheduler) void {
    if (self.deferred.len() == 0) return;
    self.collectUpTo(self.completed());
}

fn collectUpTo(self: *FrameScheduler, value: u64) void {
    while (self.deferred.popReady(value)) |item| {
        var it = item;
        it.destroy(self.mem);
    }
}

/// Deferred objects still waiting.
pub fn pendingDestroys(self: *const FrameScheduler) usize {
    return self.deferred.len();
}

test {
    _ = deferred_mod;
}
