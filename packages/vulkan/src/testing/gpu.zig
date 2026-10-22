//! Helpers for `gpu:` tests (run with `zig build test-vulkan-gpu`): a
//! validated device or a skip, and one-shot command buffers.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");

fn quiet(_: std.log.Level, _: []const u8) void {}

/// A device with validation on, or `error.SkipZigTest` when the machine
/// has no usable Vulkan driver.
pub fn gpuOrSkip() !*Gpu {
    return gpuForOrSkip(.headless);
}

/// Like `gpuOrSkip`, with the device extensions of `surface` targets.
pub fn gpuForOrSkip(surface: @FieldType(@import("../gpu/instance.zig").InstanceOptions, "surface")) !*Gpu {
    return Gpu.create(std.testing.allocator, std.testing.io, .{ .instance = .{ .validation = .on, .surface = surface }, .log_emit = quiet }) catch |err| switch (err) {
        error.VulkanNotInstalled, error.Unsupported, error.NoSuitableDevice, error.LoaderTooOld, error.IncompatibleDriver => return error.SkipZigTest,
        else => return err,
    };
}

/// A one-shot command buffer on the graphics queue.
pub const OneShot = struct {
    gpu: *Gpu,
    pool: vk.CommandPool,
    cb: vk.CommandBuffer,
    fence: vk.Fence,

    pub fn begin(gpu: *Gpu) !OneShot {
        const d = &gpu.ddisp;
        var s: OneShot = .{ .gpu = gpu, .pool = .null_handle, .cb = .null_handle, .fence = .null_handle };
        _ = try vk.check(d.create_command_pool(gpu.dev, &.{ .queue_family_index = gpu.gfx.family, .flags = .{ .reset_command_buffer = true } }, null, &s.pool));
        _ = try vk.check(d.allocate_command_buffers(gpu.dev, &.{ .command_pool = s.pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&s.cb)));
        _ = try vk.check(d.create_fence(gpu.dev, &.{}, null, &s.fence));
        _ = try vk.check(d.begin_command_buffer(s.cb, &.{ .flags = .{ .one_time_submit = true } }));
        return s;
    }

    /// Ends, submits and waits.
    pub fn submit(s: *OneShot) !void {
        const d = &s.gpu.ddisp;
        _ = try vk.check(d.end_command_buffer(s.cb));
        const cbi = [_]vk.CommandBufferSubmitInfo{.{ .command_buffer = s.cb, .device_mask = 0 }};
        const si = [_]vk.SubmitInfo2{.{ .command_buffer_info_count = 1, .p_command_buffer_infos = &cbi }};
        _ = try vk.check(d.queue_submit2(s.gpu.gfx.handle, 1, &si, s.fence));
        _ = try vk.check(d.wait_for_fences(s.gpu.dev, 1, @ptrCast(&s.fence), .true, std.time.ns_per_s * 10));
    }

    /// Resets for another recording.
    pub fn again(s: *OneShot) !void {
        const d = &s.gpu.ddisp;
        _ = try vk.check(d.reset_fences(s.gpu.dev, 1, @ptrCast(&s.fence)));
        _ = try vk.check(d.begin_command_buffer(s.cb, &.{ .flags = .{ .one_time_submit = true } }));
    }

    pub fn deinit(s: *OneShot) void {
        const d = &s.gpu.ddisp;
        d.destroy_fence(s.gpu.dev, s.fence, null);
        d.destroy_command_pool(s.gpu.dev, s.pool, null);
    }
};
