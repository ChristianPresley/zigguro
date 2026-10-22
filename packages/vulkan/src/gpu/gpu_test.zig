//! Device bring-up against the system loader (lavapipe in CI). Run with
//! `zig build test-vulkan-gpu`; each test skips without a loader, without
//! a usable device or, where it needs one, without the validation layer.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("Gpu.zig");
const lost = @import("lost.zig");
const info = @import("info.zig");
const validation = @import("../testing/validation.zig");

/// Collects validation messages (an error log would fail the test).
var captured_errors: std.atomic.Value(u32) = .init(0);

fn capture(level: std.log.Level, msg: []const u8) void {
    _ = msg;
    if (level == .err) _ = captured_errors.fetchAdd(1, .monotonic);
}

fn createOrSkip(opts: Gpu.CreateOptions) !*Gpu {
    var o = opts;
    o.log_emit = capture;
    return Gpu.create(std.testing.allocator, std.testing.io, o) catch |err| switch (err) {
        error.VulkanNotInstalled, error.Unsupported, error.NoSuitableDevice, error.LoaderTooOld, error.IncompatibleDriver => return error.SkipZigTest,
        else => return err,
    };
}

test "gpu: create and destroy the device with validation" {
    const gpu = try createOrSkip(.{ .instance = .{ .validation = .on } });
    defer gpu.destroy();
    try std.testing.expect(gpu.info.name().len > 0);
    try std.testing.expect(gpu.info.api_version.atLeast(1, 2));
    try std.testing.expect(gpu.info.caps.core13 or (gpu.info.caps.dynamic_rendering_khr and gpu.info.caps.sync2_khr));
    try std.testing.expect(gpu.gfx.handle != .null_handle);
    // The enabled features are a subset of what the device supports.
    const p = &gpu.probes[gpu.chosen];
    const req = p.feat.required();
    try std.testing.expect(req.subsetOf(&p.feat));
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: validation catches a deliberate error" {
    const gpu = try createOrSkip(.{ .instance = .{ .validation = .on } });
    defer gpu.destroy();
    if (!gpu.instance.validation) return error.SkipZigTest;
    var image: vk.Image = .null_handle;
    const ci: vk.ImageCreateInfo = .{
        .image_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = 0, .height = 16, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = .optimal,
        .usage = .{ .sampled = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    const r = gpu.ddisp.create_image(gpu.dev, &ci, null, &image);
    if (r == .success) gpu.ddisp.destroy_image(gpu.dev, image, null);
    try std.testing.expect(gpu.sink.errors.load(.acquire) > 0);
    try std.testing.expect(std.mem.startsWith(u8, gpu.sink.lastVuid(), "VUID-VkImageCreateInfo-extent"));
}

test "gpu: name objects and report" {
    const gpu = try createOrSkip(.{});
    defer gpu.destroy();
    gpu.name(gpu.dev, "renamed-device");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try info.writeReport(&out.writer, gpu.report(&.{}), .json);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"chosen\"") != null);
}

const Recreate = struct {
    gpu: *Gpu,
    opts: Gpu.CreateOptions,
    recreated: u32 = 0,

    fn teardown(ctx: *anyopaque) void {
        const self: *Recreate = @ptrCast(@alignCast(ctx));
        self.gpu.destroy();
    }
    fn recreate(ctx: *anyopaque) anyerror!void {
        const self: *Recreate = @ptrCast(@alignCast(ctx));
        self.gpu = try Gpu.create(std.testing.allocator, std.testing.io, self.opts);
        self.recreated += 1;
    }
    fn toSoftware(_: *anyopaque) anyerror!void {}
};

test "gpu: injected loss recovers" {
    const opts: Gpu.CreateOptions = .{ .fault = "lost@submit:2", .log_emit = capture };
    var rc: Recreate = .{ .gpu = try createOrSkip(opts), .opts = opts };
    defer rc.gpu.destroy();
    try rc.gpu.checkLostAt(.success, .submit);
    try std.testing.expectError(error.DeviceLost, rc.gpu.checkLostAt(.success, .submit));
    // Latched: later calls report the loss too.
    try std.testing.expectError(error.DeviceLost, rc.gpu.checkLost(.success));

    var rec: lost.Recovery = .{};
    const t0 = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
    const outcome = try rec.onLost(@intCast(t0), .{ .ctx = &rc, .teardown = Recreate.teardown, .recreate = Recreate.recreate, .switchToSoftware = Recreate.toSoftware });
    const ms = @divTrunc(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - t0, std.time.ns_per_ms);
    try std.testing.expectEqual(lost.Outcome.recovered, outcome);
    try std.testing.expectEqual(@as(u32, 1), rc.recreated);
    try std.testing.expect(!rc.gpu.lost.load(.acquire));
    try rc.gpu.checkLost(.success);
    try std.testing.expect(ms < 2000); // budget 200 ms on CI; generous here
    try validation.expectNoValidationErrors(rc.gpu);
}
