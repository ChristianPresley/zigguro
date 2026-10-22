//! GPU memory, upload ring and uploader against the system loader
//! (lavapipe in CI, validation on). Run with `zig build test-vulkan-gpu`.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const UploadRing = @import("UploadRing.zig");
const Uploader = @import("Uploader.zig");
const Texture = @import("Texture.zig");
const barriers = @import("barriers.zig");
const validation = @import("../testing/validation.zig");
const testing_gpu = @import("../testing/gpu.zig");

const gpuOrSkip = testing_gpu.gpuOrSkip;
const OneShot = testing_gpu.OneShot;

test "gpu: mem: 10k buffers need few vkAllocateMemory calls" {
    const gpu = try gpuOrSkip();
    defer gpu.destroy();
    var mem = DeviceMemory.init(gpu, std.testing.allocator, .{});
    defer mem.deinit();
    const bufs = try std.testing.allocator.alloc(DeviceMemory.Buffer, 10_000);
    defer std.testing.allocator.free(bufs);
    for (bufs, 0..) |*b, i| {
        const usage: DeviceMemory.Usage = if (i % 2 == 0) .gpu_only else .upload;
        b.* = try mem.createBuffer(.{ .size = 256 + (i % 7) * 512, .usage = .{ .storage_buffer = true, .transfer_dst = true }, .sharing_mode = .exclusive }, usage, "test-buffer");
    }
    const s = mem.stats();
    try std.testing.expect(s.allocate_calls < 8);
    for (bufs) |b| mem.destroyBuffer(b);
    // Empty blocks are released a few frames later, except the last per pool.
    for (0..4) |_| mem.nextFrame();
    try std.testing.expect(mem.stats().total_allocations <= s.total_allocations);
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: mem: dedicated path taken for large image" {
    const gpu = try gpuOrSkip();
    defer gpu.destroy();
    var mem = DeviceMemory.init(gpu, std.testing.allocator, .{});
    defer mem.deinit();
    var tex = try Texture.create(&mem, 4096, 4096, .rgba8_unorm, .sampled, "big-image");
    try std.testing.expectEqual(DeviceMemory.Allocation.Kind.dedicated, tex.image.alloc.kind);
    var small = try Texture.create(&mem, 64, 64, .r8_unorm, .sampled, "small-image");
    try std.testing.expectEqual(DeviceMemory.Allocation.Kind.block, small.image.alloc.kind);
    try std.testing.expectEqual(@as(u32, 1), mem.stats().dedicated_count);
    small.destroy(&mem);
    tex.destroy(&mem);
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: mem: leaks reported in Debug" {
    const gpu = try gpuOrSkip();
    defer gpu.destroy();
    var mem = DeviceMemory.init(gpu, std.testing.allocator, .{});
    defer mem.deinit();
    const b = try mem.createBuffer(.{ .size = 1024, .usage = .{ .transfer_dst = true }, .sharing_mode = .exclusive }, .gpu_only, "forgotten-buffer");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 1), try mem.reportLeaks(&out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"forgotten-buffer\"") != null);
    mem.destroyBuffer(b);
}

test "gpu: uploader: write then read back pixels match" {
    const gpu = try gpuOrSkip();
    defer gpu.destroy();
    const gpa = std.testing.allocator;
    var mem = DeviceMemory.init(gpu, gpa, .{});
    defer mem.deinit();
    var ring = try UploadRing.init(&mem, 2, 6144);
    defer ring.deinit();
    var up = Uploader.init(gpa, &mem, &ring);
    defer up.deinit();
    var tex = try Texture.create(&mem, 64, 32, .rgba8_unorm, .sampled, "pattern");
    defer tex.destroy(&mem);
    const readback = try mem.createBuffer(.{ .size = 64 * 32 * 4, .usage = .{ .transfer_dst = true }, .sharing_mode = .exclusive }, .readback, "readback");
    defer mem.destroyBuffer(readback);

    // Two rects; the first has a padded pitch, the second does not fit the
    // ring slot and goes through a staging buffer.
    var left: [32 * 32 * 4 + 32 * 16]u8 = undefined;
    for (&left, 0..) |*p, i| p.* = @truncate(i *% 7);
    var right: [32 * 32 * 4]u8 = undefined;
    for (&right, 0..) |*p, i| p.* = @truncate(i *% 13 + 1);
    ring.beginFrame(0);
    try up.writeRegion(&tex, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, &left, 32 * 4 + 16);
    try up.writeRegion(&tex, .{ .x = 32, .y = 0, .w = 32, .h = 32 }, &right, 32 * 4);
    try std.testing.expectEqual(@as(u64, 2 * 32 * 32 * 4), up.pendingBytes());

    var os = try OneShot.begin(gpu);
    defer os.deinit();
    try ring.endFrame(os.cb, &gpu.ddisp);
    try up.record(os.cb, &gpu.ddisp);
    barriers.imageTransition(os.cb, &gpu.ddisp, tex.image.handle, .shader_read, .transfer_src, .{ .color = true });
    const region = [_]vk.BufferImageCopy{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = 64, .height = 32, .depth = 1 },
    }};
    gpu.ddisp.cmd_copy_image_to_buffer(os.cb, tex.image.handle, .transfer_src_optimal, readback.handle, 1, &region);
    try os.submit();
    up.retire();
    try mem.invalidate(readback.alloc, 0, readback.size);

    const px = readback.mappedSlice().?;
    for (0..32) |y| {
        try std.testing.expectEqualSlices(u8, left[y * (32 * 4 + 16) ..][0 .. 32 * 4], px[y * 256 ..][0 .. 32 * 4]);
        try std.testing.expectEqualSlices(u8, right[y * 128 ..][0..128], px[y * 256 + 128 ..][0..128]);
    }
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: ring: frames in flight without validation errors" {
    const gpu = try gpuOrSkip();
    defer gpu.destroy();
    const gpa = std.testing.allocator;
    var mem = DeviceMemory.init(gpu, gpa, .{});
    defer mem.deinit();
    var ring = try UploadRing.init(&mem, 3, 64 << 10);
    defer ring.deinit();
    var up = Uploader.init(gpa, &mem, &ring);
    defer up.deinit();
    var tex = try Texture.create(&mem, 256, 256, .r8_unorm, .sampled, "atlas-page-0");
    defer tex.destroy(&mem);
    const dst = try mem.createBuffer(.{ .size = 1 << 16, .usage = .{ .transfer_dst = true, .storage_buffer = true }, .sharing_mode = .exclusive }, .gpu_only, "instances");
    defer mem.destroyBuffer(dst);

    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    var os = try OneShot.begin(gpu);
    defer os.deinit();
    var glyph: [16 * 16]u8 = undefined;
    for (0..30) |frame| {
        if (frame > 0) try os.again();
        ring.beginFrame(@intCast(frame % 3));
        for (0..r.intRangeAtMost(usize, 1, 20)) |_| {
            r.bytes(&glyph);
            try up.writeRegion(&tex, .{ .x = r.intRangeLessThan(u16, 0, 240), .y = r.intRangeLessThan(u16, 0, 240), .w = 16, .h = 16 }, &glyph, 16);
        }
        const inst = try ring.alloc(4096, 16);
        r.bytes(inst.bytes());
        try up.writeBuffer(dst.handle, 0, inst.bytes()[0..1024]);
        try ring.endFrame(os.cb, &gpu.ddisp);
        try up.record(os.cb, &gpu.ddisp);
        try os.submit();
        up.retire();
        mem.nextFrame();
    }
    try validation.expectNoValidationErrors(gpu);
}
