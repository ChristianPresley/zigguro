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

const platform = @import("zg_platform");
const ExternalRing = @import("ExternalRing.zig");
const drm = @import("drm_formats.zig");

/// A presenter that accepts dmabuf imports and records them.
const DmabufPresenter = struct {
    imports: [8]platform.surface.BufferDesc = undefined,
    strides: [8]u32 = undefined,
    n: u32 = 0,

    fn drmDev(_: *anyopaque) ?platform.surface.DrmDevice {
        return null;
    }
    fn formats(_: *anyopaque, out: []platform.surface.FormatModifier) usize {
        const list = [_]platform.surface.FormatModifier{
            .{ .fourcc = drm.argb8888, .modifier = 0x0100_0000_0000_0002 }, // I915 Y-tiled
            .{ .fourcc = drm.argb8888, .modifier = drm.mod_linear },
        };
        @memcpy(out[0..list.len], &list);
        return list.len;
    }
    fn sync(_: *anyopaque) platform.surface.SyncMode {
        return .implicit_sync_file;
    }
    fn import(ctx: *anyopaque, desc: *const platform.surface.BufferDesc) anyerror!platform.surface.BufferHandle {
        const f: *DmabufPresenter = @ptrCast(@alignCast(ctx));
        f.imports[f.n] = desc.*;
        f.strides[f.n] = desc.planes[0].stride;
        f.n += 1;
        return @enumFromInt(f.n - 1);
    }
    fn present(_: *anyopaque, _: platform.surface.BufferHandle, _: []const platform.types.PxRect, acquire: platform.surface.SyncPoint, _: ?platform.surface.ConfigureAck) anyerror!void {
        if (acquire == .sync_file) _ = std.os.linux.close(acquire.sync_file);
    }
    fn release(_: *anyopaque, _: platform.surface.BufferHandle) void {}
    fn poll(_: *anyopaque, _: []platform.surface.BufferHandle) usize {
        return 0;
    }
    fn alloc(_: *anyopaque, _: u32, _: u32, _: u32) anyerror!platform.surface.CpuBuffer {
        return error.Unsupported;
    }
    const vtable: platform.surface.PresenterVTable = .{ .drmDevice = drmDev, .formats = formats, .syncMode = sync, .importBuffer = import, .present = present, .releaseBuffer = release, .pollReleased = poll, .allocCpuBuffer = alloc };
};

test "gpu: external: export images, or ExportUnsupported cleanly" {
    const gpu = try testing_gpu.gpuForOrSkip(.external);
    defer gpu.destroy();
    var mem = DeviceMemory.init(gpu, std.testing.allocator, .{});
    defer mem.deinit();
    var sched = try FrameScheduler.init(gpu, &mem, 2);
    defer sched.deinit();
    var fake: DmabufPresenter = .{};
    var pr: platform.surface.Presenter = .{ .ptr = &fake, .vtable = &DmabufPresenter.vtable };
    var ring = ExternalRing.init(gpu, &mem, &sched, &pr) catch |err| {
        // lavapipe: no VK_EXT_image_drm_format_modifier.
        try std.testing.expectEqual(error.ExportUnsupported, err);
        try validation.expectNoValidationErrors(gpu);
        return;
    };
    defer ring.deinit();
    // A device with dmabuf export: three images imported with sane layouts.
    var acquired: [ExternalRing.ring_len]ExternalRing.Acquired = undefined;
    for (&acquired) |*a| {
        a.* = try ring.acquire(.{ .w = 64, .h = 32 });
        try std.testing.expectEqual(@as(u32, 0), a.age);
    }
    try std.testing.expectError(error.NoFreeBuffer, ring.acquire(.{ .w = 64, .h = 32 }));
    try std.testing.expectEqual(@as(u32, 3), fake.n);
    for (fake.imports[0..fake.n], fake.strides[0..fake.n]) |d, stride| {
        try std.testing.expect(stride >= 64 * 4);
        try std.testing.expectEqual(drm.argb8888, d.fourcc);
        try std.testing.expect(d.modifier == drm.mod_linear or d.modifier == 0x0100_0000_0000_0002);
    }
    for (acquired) |a| ring.abandon(a);
    try validation.expectNoValidationErrors(gpu);
}
