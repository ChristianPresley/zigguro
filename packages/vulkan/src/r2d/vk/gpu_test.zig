//! The Vulkan backend end to end on the system driver (lavapipe in CI,
//! validation on; `zig build test-vulkan-gpu`): the scene corpus through
//! `Renderer` against the software goldens, idle frames, damage-limited
//! readback and many random-damage frames (E02.F06.S01.T02,
//! E02.F04.S02.T02).

const std = @import("std");
const platform = @import("zg_platform");
const r2d = @import("../root.zig");
const validation = @import("../../testing/validation.zig");
const testing_gpu = @import("../../testing/gpu.zig");
const scenes = @import("../../testing/scenes.zig");
const parity = @import("../../testing/parity.zig");
const golden = @import("../../testing/golden_image.zig");
const CpuImage = @import("../../testing/CpuImage.zig");
const VkRenderer = @import("VkRenderer.zig");

const testing = std.testing;

const CountingSink = struct {
    frames: u32 = 0,
    rect_px: u64 = 0,

    fn write(p: *anyopaque, _: platform.types.WindowId, damage: []const r2d.PxRect, _: []const u8, _: u32) void {
        const self: *CountingSink = @ptrCast(@alignCast(p));
        self.frames += 1;
        for (damage) |r| self.rect_px += @as(u64, r.w) * r.h;
    }
};

fn newRenderer(gpu: anytype, sink: *platform.surface.HeadlessSink) !*VkRenderer {
    return VkRenderer.createWithGpu(testing.allocator, testing.io, gpu, .{ .target = .{ .headless = sink } });
}

test "gpu: vk renderer: scene corpus matches the software goldens" {
    const gpa = testing.allocator;
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var counter: CountingSink = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &counter, .write = CountingSink.write };
    const vr = try newRenderer(gpu, &sink);
    defer vr.destroy();
    const r = vr.renderer();
    try testing.expectEqual(r2d.Backend.vulkan, r.backend());
    const tex = try parity.Textures.create(gpa, r);

    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    dl.setGlyphPages(&tex.pages);
    dl.layer_query = r.layerQuery();
    var failed: u32 = 0;
    var ran: u32 = 0;
    for (scenes.all) |scene| {
        if (scene.needs.dual_src and vr.pipes.text_subpixel == null) continue;
        var img = try CpuImage.initOrder(gpa, scene.size.w, scene.size.h, .bgra);
        defer img.deinit(gpa);
        // Same frames and seeds as `parity.renderSoftware`.
        var frame: u8 = 0;
        while (frame < scene.frames) : (frame += 1) {
            var prng = std.Random.DefaultPrng.init(0x5eed_0000 + scene.name.len);
            var ctx: scenes.SceneCtx = .{ .frame = frame, .image = tex.image, .rnd = prng.random() };
            dl.reset(scene.size, scene.scale);
            if (frame == 0) dl.damageAll();
            scene.build(&dl, &ctx);
            try testing.expect(!dl.alloc_failed);
            _ = try vr.renderToImage(&dl, &img);
        }
        ran += 1;
        const tol = scene.gpu_tolerance orelse golden.Tolerance.gpu(scene.size.w, scene.size.h);
        golden.compareInDir(testing.io, parity.golden_dir, scene.name, &img, tol, .{ .update = false }) catch |err| switch (err) {
            error.GoldenMismatch, error.GoldenMissing => failed += 1,
            else => return err,
        };
    }
    try testing.expect(ran >= 31);
    try testing.expectEqual(@as(u32, 0), failed);
    try validation.expectNoValidationErrors(gpu);
}

fn keystrokeScene(dl: *r2d.DrawList, i: u32) void {
    dl.rect(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, .{ .r = 30, .g = 30, .b = 40, .a = 255 }, .{});
    const x: f32 = @floatFromInt(8 + (i % 20) * 8);
    dl.rect(.{ .x = x, .y = 40, .w = 6, .h = 12 }, .{ .r = 220, .g = 220, .b = 220, .a = 255 }, .{});
}

test "gpu: vk renderer: idle frames submit nothing; damage limits the copy" {
    const gpa = testing.allocator;
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var counter: CountingSink = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &counter, .write = CountingSink.write };
    const vr = try newRenderer(gpu, &sink);
    defer vr.destroy();
    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();

    dl.reset(.{ .w = 200, .h = 100 }, 1);
    dl.damageAll();
    keystrokeScene(&dl, 0);
    const first = try vr.render(&dl);
    try testing.expect(first.needs_full_redraw and first.draws >= 1);
    const submitted = vr.sched.submitted;

    // No damage: no submit.
    dl.reset(.{ .w = 200, .h = 100 }, 1);
    keystrokeScene(&dl, 0);
    const idle = try vr.render(&dl);
    try testing.expectEqual(@as(u32, 0), idle.draws);
    try testing.expectEqual(submitted, vr.sched.submitted);

    // Three keystroke frames: only the damaged cells are drawn and copied.
    vr.readback.waitIdle();
    const before = vr.readback.copied_bytes;
    for (1..4) |i| {
        dl.reset(.{ .w = 200, .h = 100 }, 1);
        dl.addDamage(.{ .x = @intCast(8 + (i % 20) * 8 - 8), .y = 40, .w = 16, .h = 12 });
        keystrokeScene(&dl, @intCast(i));
        const s = try vr.render(&dl);
        try testing.expect(!s.needs_full_redraw);
        try testing.expectEqual(@as(u64, 16 * 12), s.repainted_px);
    }
    vr.readback.waitIdle();
    try testing.expectEqual(@as(u64, 3 * 16 * 12 * 4), vr.readback.copied_bytes - before);
    try testing.expectEqual(@as(u32, 4), counter.frames);
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: vk renderer: 500 random-damage frames stay validation clean" {
    const gpa = testing.allocator;
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var counter: CountingSink = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &counter, .write = CountingSink.write };
    const vr = try newRenderer(gpu, &sink);
    defer vr.destroy();
    const r = vr.renderer();
    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    var prng = std.Random.DefaultPrng.init(0xf4a3e5);
    const rnd = prng.random();
    const ext: r2d.Size = .{ .w = 160, .h = 120 };
    // A texture created, updated and destroyed along the way.
    var tex: ?r2d.TextureId = null;
    var pixels: [16 * 16]u8 = undefined;
    for (0..500) |i| {
        dl.reset(ext, 1);
        if (i == 0 or rnd.uintLessThan(u8, 50) == 0) dl.damageAll();
        for (0..rnd.uintAtMost(u8, 4)) |_| dl.addDamage(.{ .x = rnd.intRangeAtMost(i32, -10, 150), .y = rnd.intRangeAtMost(i32, -10, 110), .w = rnd.uintAtMost(u32, 60), .h = rnd.uintAtMost(u32, 40) });
        dl.rect(.{ .x = 0, .y = 0, .w = 160, .h = 120 }, .{ .r = 10, .g = 10, .b = 10, .a = 255 }, .{});
        for (0..20) |_| dl.rect(.{ .x = rnd.float(f32) * 150, .y = rnd.float(f32) * 110, .w = 10, .h = 8 }, .{ .r = rnd.int(u8), .g = rnd.int(u8), .b = rnd.int(u8), .a = 255 }, r2d.Radii.all(2));
        if (i % 40 == 0) {
            if (tex) |t| r.destroyTexture(t);
            tex = try r.createTexture(.{ .width = 16, .height = 16, .format = .r8 });
            rnd.bytes(&pixels);
            try r.updateTexture(tex.?, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, &pixels, 16);
        }
        if (tex) |t| dl.image(t, .{ .x = 20, .y = 20, .w = 16, .h = 16 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .{});
        _ = try vr.render(&dl);
    }
    vr.readback.waitIdle();
    try testing.expect(counter.frames > 0);
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: vk renderer: scroll layer seam matches unlayered rendering" {
    const gpa = testing.allocator;
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var counter: CountingSink = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &counter, .write = CountingSink.write };
    const vr = try newRenderer(gpu, &sink);
    defer vr.destroy();
    try testing.expectEqual(@as(u32, 0), try parity.seamMismatches(gpa, vr, vr.renderer(), .bgra));
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: vk renderer: scrolling a layer repaints only the strip" {
    // 3 px per frame: each frame redraws a 3-row strip of the layer and
    // composites it; nothing else of the layer is re-rendered.
    const gpa = testing.allocator;
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var counter: CountingSink = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &counter, .write = CountingSink.write };
    const vr = try newRenderer(gpu, &sink);
    defer vr.destroy();
    const r = vr.renderer();
    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    dl.layer_query = r.layerQuery();
    const size: r2d.Size = .{ .w = 200, .h = 300 };
    const id: r2d.LayerId = @enumFromInt(1);
    var top: i32 = 0;
    var frame: u32 = 0;
    while (frame < 40) : (frame += 1) {
        dl.reset(.{ .w = 200, .h = 200 }, 1);
        const step: i32 = if (frame == 0) 0 else 3;
        top += step;
        var strips: [2]r2d.PxRect = undefined;
        const n = r2d.layers.scrollDamage(.{ 0, step }, size, &strips);
        const full = [_]r2d.PxRect{.{ .x = 0, .y = 0, .w = size.w, .h = size.h }};
        const dmg: []const r2d.PxRect = if (frame == 0) &full else strips[0..n];
        if (frame == 0) dl.damageAll() else dl.addDamage(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
        if (dl.beginScrollLayer(id, size, .{ 0, @mod(top, 300) }, dmg)) {
            var i: i32 = @divFloor(top, 10);
            while (i * 10 < top + 300) : (i += 1) {
                dl.rect(.{ .x = 0, .y = @floatFromInt(i * 10 - top), .w = 200, .h = 10 }, if (@mod(i, 2) == 0) r2d.Color.white else r2d.Color.black, .{});
            }
            dl.endLayer();
        }
        dl.drawLayer(id, .{ .x = 0, .y = 0, .w = 200, .h = 200 }, .{ .y = 50 }, 1);
        const stats = try r.render(&dl);
        if (frame > 0) {
            // The strip (3 × 200) plus the window (200 × 200).
            try testing.expectEqual(@as(u64, 3 * 200 + 200 * 200), stats.repainted_px);
        }
    }
    vr.readback.waitIdle();
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: vk renderer: layer memory stays within the budget" {
    const gpa = testing.allocator;
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var counter: CountingSink = .{};
    var sink: platform.surface.HeadlessSink = .{ .ptr = &counter, .write = CountingSink.write };
    const layer: r2d.Size = .{ .w = 64, .h = 64 }; // 16 KiB
    const budget = 2 * r2d.layers.layerBytes(layer);
    const vr = try VkRenderer.createWithGpu(gpa, testing.io, gpu, .{ .target = .{ .headless = &sink }, .layer_budget_bytes = budget });
    defer vr.destroy();
    const r = vr.renderer();
    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    dl.layer_query = r.layerQuery();
    var frame: u32 = 0;
    while (frame < 12) : (frame += 1) {
        dl.reset(.{ .w = 64, .h = 64 }, 1);
        dl.damageAll();
        // A different layer each frame: older ones are evicted.
        const id: r2d.LayerId = @enumFromInt(frame % 5);
        if (dl.beginLayer(id, layer, &.{})) {
            dl.rect(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, r2d.Color.white, .{});
            dl.endLayer();
        }
        dl.drawLayer(id, .{ .x = 0, .y = 0, .w = 64, .h = 64 }, .{}, 1);
        _ = try r.render(&dl);
        try testing.expect(vr.layers.bytes() <= budget);
    }
    // The current layer is kept; an evicted one is no longer cached.
    try testing.expect(r.vtable.layerValid(r.ptr, @enumFromInt(11 % 5), layer));
    try testing.expect(!r.vtable.layerValid(r.ptr, @enumFromInt(8 % 5), layer));
    vr.readback.waitIdle();
    try validation.expectNoValidationErrors(gpu);
}
