//! Frame scheduling on the system Vulkan driver (lavapipe in CI,
//! validation on): many frames through 2 and 3 slots, each rendering into
//! a test-local offscreen image, with deferred destruction draining at
//! shutdown (E02.F04.S03.T01).

const std = @import("std");
const vk = @import("../vk/vk.zig");
const DeviceMemory = @import("../mem/DeviceMemory.zig");
const Texture = @import("../mem/Texture.zig");
const barriers = @import("../mem/barriers.zig");
const validation = @import("../testing/validation.zig");
const testing_gpu = @import("../testing/gpu.zig");
const FrameScheduler = @import("FrameScheduler.zig");

test "gpu: scheduler: 1000 frames with 2 and 3 in flight" {
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var mem = DeviceMemory.init(gpu, std.testing.allocator, .{});
    defer mem.deinit();
    for ([_]u8{ 2, 3 }) |n| {
        var sched = try FrameScheduler.init(gpu, &mem, n);
        const target = try Texture.create(&mem, 16, 16, .rgba8_unorm, .render_target, "sched-target");
        var deferred_count: usize = 0;
        for (0..1000) |i| {
            const fs = try sched.begin();
            // Earlier frames must have retired before their slot is reused.
            try std.testing.expect(sched.completed() + n >= sched.submitted);
            const from: barriers.Access = if (i == 0) .undefined else .transfer_dst;
            barriers.imageTransition(fs.cb, &gpu.ddisp, target.image.handle, from, .transfer_dst, .{ .color = true });
            const c: f32 = @as(f32, @floatFromInt(i % 256)) / 255.0;
            gpu.ddisp.cmd_clear_color_image(fs.cb, target.image.handle, .transfer_dst_optimal, &.{ .float32 = .{ c, c, c, 1 } }, 1, @ptrCast(&barriers.color_range));
            if (i % 50 == 0) {
                // A buffer used by this frame, destroyed once it retires.
                const b = try mem.createBuffer(.{ .size = 256, .usage = .{ .transfer_dst = true }, .sharing_mode = .exclusive }, .gpu_only, "sched-deferred");
                gpu.ddisp.cmd_fill_buffer(fs.cb, b.handle, 0, 256, 0);
                sched.deferDestroy(.{ .buffer = b });
                deferred_count += 1;
            }
            try sched.submit(fs, &.{}, &.{});
        }
        try std.testing.expectEqual(@as(u64, 1000), sched.submitted);
        try std.testing.expect(deferred_count == 20 and sched.pendingDestroys() <= 20);
        // The image goes through the queue too; deinit drains it.
        sched.deferDestroy(.{ .texture = target });
        sched.deinit();
    }
    try validation.expectNoValidationErrors(gpu);
}
