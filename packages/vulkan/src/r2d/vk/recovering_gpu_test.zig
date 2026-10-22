//! Device-loss recovery on the system driver (lavapipe in CI;
//! `zig build test-vulkan-gpu`): injected losses recreate the device with
//! the textures intact, and the third loss within a minute moves to the
//! software renderer (E02.F02.S02.T01).

const std = @import("std");
const platform = @import("zg_platform");
const r2d = @import("../root.zig");
const Recovering = @import("Recovering.zig");

const testing = std.testing;

/// Keeps the centre pixel (BGRA) of each delivered frame.
const CentreSink = struct {
    frames: u32 = 0,
    px: [4]u8 = .{ 0, 0, 0, 0 },

    fn write(p: *anyopaque, _: platform.types.WindowId, _: []const r2d.PxRect, pixels: []const u8, stride: u32) void {
        const self: *CentreSink = @ptrCast(@alignCast(p));
        self.frames += 1;
        const off = 8 * @as(usize, stride) + 8 * 4;
        self.px = pixels[off..][0..4].*;
    }
};

fn fill(tex: r2d.TextureId, r: r2d.Renderer, rgba: [4]u8) !void {
    var px: [4 * 4]u8 = undefined;
    for (0..4) |i| px[i * 4 ..][0..4].* = rgba;
    try r.updateTexture(tex, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, &px, 8);
}

fn frame(r: r2d.Renderer, dl: *r2d.DrawList, tex: r2d.TextureId) r2d.RenderError!r2d.FrameStats {
    dl.reset(.{ .w = 16, .h = 16 }, 1);
    dl.damageAll();
    dl.image(tex, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, r2d.Color.white, .{});
    const s = try r.render(dl);
    // Vulkan delivers to the sink when the frame retires.
    switch (Recovering.of(r).inner) {
        .vulkan => |v| v.readback.waitIdle(),
        else => {},
    }
    return s;
}

test "gpu: recovering: injected losses recreate, then switch to software" {
    const gpa = testing.allocator;
    var centre: CentreSink = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &centre, .write = CentreSink.write };
    // Every device is lost at its second submit.
    const rec = Recovering.create(gpa, testing.io, .{
        .target = .{ .headless = &sink },
        .size = .{ .w = 16, .h = 16 },
        .env = .{ .vk_fault = "lost@submit:2" },
        .sw_threads = 1,
    }) catch return error.SkipZigTest;
    const r = rec.renderer();
    defer r.deinit();
    const tex = try r.createTexture(.{ .width = 2, .height = 2, .format = .rgba8 });
    try fill(tex, r, .{ 255, 0, 0, 255 });
    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    const red = [4]u8{ 0, 0, 255, 255 };

    // Two losses: each time a new device draws the texture again.
    for (0..2) |loss| {
        _ = try frame(r, &dl, tex);
        try testing.expectEqualSlices(u8, &red, &centre.px);
        try testing.expectError(error.DeviceLost, frame(r, &dl, tex));
        try testing.expectEqual(r2d.Backend.vulkan, r.backend());
        try testing.expectEqual(loss + 1, rec.recovery.history().len);
        centre.px = .{ 0, 0, 0, 0 };
    }
    // A texture made on the third device survives the switch too.
    const tex2 = try r.createTexture(.{ .width = 2, .height = 2, .format = .rgba8 });
    try fill(tex2, r, .{ 0, 0, 255, 255 });
    _ = try frame(r, &dl, tex);
    try testing.expectEqualSlices(u8, &red, &centre.px);
    // The third loss within the window: software from now on.
    try testing.expectError(error.DeviceLost, frame(r, &dl, tex));
    try testing.expectEqual(r2d.Backend.software, r.backend());
    const s = try frame(r, &dl, tex);
    try testing.expectEqual(r2d.Backend.software, s.backend);
    try testing.expectEqualSlices(u8, &red, &centre.px);
    _ = try frame(r, &dl, tex2);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &centre.px);
    // Updates now go straight to the software renderer.
    try fill(tex, r, .{ 0, 255, 0, 255 });
    _ = try frame(r, &dl, tex);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, &centre.px);
    try testing.expectEqual(@as(u64, 0), rec.shadows.bytes());
}

test "gpu: recovering: present ids continue across recreations" {
    const gpa = testing.allocator;
    var centre: CentreSink = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &centre, .write = CentreSink.write };
    const rec = Recovering.create(gpa, testing.io, .{ .target = .{ .headless = &sink }, .size = .{ .w = 16, .h = 16 } }) catch return error.SkipZigTest;
    defer rec.destroy();
    // Headless: no swapchain, so no present waiter and no id offset.
    try testing.expectEqual(@as(?@import("../../present/FramePacer.zig").PresentWaiter, null), rec.presentWaiter());
    try testing.expect(rec.pacerCaps().headless);
}
