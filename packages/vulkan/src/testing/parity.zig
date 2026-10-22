//! Renders the scene corpus and compares it with the goldens in
//! `testdata/golden/scenes/`. The software renderer must match exactly
//! (it also writes the goldens under `-Dupdate-golden`); GPU backends are
//! compared with `Tolerance.gpu` once the Vulkan 2D backend exists
//! (E02.F06.S01.T02). Multi-frame scenes are also checked against a fresh
//! full redraw of their last frame, which proves damage-limited repaint
//! leaves no stale pixels.

const std = @import("std");
const platform = @import("zg_platform");
const r2d = @import("../r2d/root.zig");
const scenes = @import("scenes.zig");
const atlas = @import("synthetic_atlas.zig");
const CpuImage = @import("CpuImage.zig");
const golden = @import("golden_image.zig");
const image_diff = @import("image_diff.zig");
const SwRenderer = @import("../sw/SwRenderer.zig");

/// Golden directory relative to the package root.
pub const golden_dir = "testdata/golden/scenes";

/// Synthetic textures registered with one renderer.
pub const Textures = struct {
    /// Glyph pages in `scenes.page_*` order.
    pages: [3]r2d.TextureId,
    /// The 32×32 image.
    image: r2d.TextureId,

    /// Creates and uploads the synthetic atlas pages and image.
    pub fn create(gpa: std.mem.Allocator, r: r2d.Renderer) !Textures {
        const n = atlas.page_size;
        const buf = try gpa.alloc(u8, n * n * 4);
        defer gpa.free(buf);
        var t: Textures = undefined;
        t.pages[0] = try r.createTexture(.{ .width = n, .height = n, .format = .r8 });
        atlas.grayPage(buf[0 .. n * n]);
        try r.updateTexture(t.pages[0], .{ .x = 0, .y = 0, .w = n, .h = n }, buf[0 .. n * n], n);
        t.pages[1] = try r.createTexture(.{ .width = n, .height = n, .format = .rgba8 });
        atlas.subpixelPage(buf);
        try r.updateTexture(t.pages[1], .{ .x = 0, .y = 0, .w = n, .h = n }, buf, n * 4);
        t.pages[2] = try r.createTexture(.{ .width = n, .height = n, .format = .rgba8 });
        atlas.colorPage(buf);
        try r.updateTexture(t.pages[2], .{ .x = 0, .y = 0, .w = n, .h = n }, buf, n * 4);
        t.image = try r.createTexture(.{ .width = 32, .height = 32, .format = .rgba8 });
        atlas.testImage(buf[0 .. 32 * 32 * 4]);
        try r.updateTexture(t.image, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, buf[0 .. 32 * 32 * 4], 32 * 4);
        return t;
    }
};

/// Renders `scene` frames `0..upto` on the software renderer into `out`
/// (allocated here). With `full_last`, only the last frame is rendered,
/// as a full redraw.
pub fn renderSoftware(gpa: std.mem.Allocator, io: std.Io, scene: scenes.Scene, full_last: bool, threads: u8) !CpuImage {
    var sink: platform.surface.HeadlessSink = .{ .ptr = undefined, .write = struct {
        fn w(_: *anyopaque, _: platform.types.WindowId, _: []const r2d.PxRect, _: []const u8, _: u32) void {}
    }.w };
    const sw = try SwRenderer.create(gpa, io, .{ .target = .{ .headless = &sink }, .sw_threads = threads });
    defer sw.destroy();
    const r = sw.renderer();
    const tex = try Textures.create(gpa, r);
    var out = try CpuImage.init(gpa, scene.size.w, scene.size.h);
    errdefer out.deinit(gpa);
    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    dl.setGlyphPages(&tex.pages);
    dl.layer_query = r.layerQuery();
    var prng = std.Random.DefaultPrng.init(0x5eed_0000 + scene.name.len);
    var frame: u8 = if (full_last) scene.frames - 1 else 0;
    while (frame < scene.frames) : (frame += 1) {
        // Each frame starts from the same seed so content is stable.
        prng = std.Random.DefaultPrng.init(0x5eed_0000 + scene.name.len);
        var ctx: scenes.SceneCtx = .{ .frame = frame, .image = tex.image, .rnd = prng.random() };
        dl.reset(scene.size, scene.scale);
        if (frame == 0 or full_last) dl.damageAll();
        scene.build(&dl, &ctx);
        std.debug.assert(!dl.alloc_failed);
        _ = try sw.renderToImage(&dl, &out);
    }
    return out;
}

test "scene: corpus on software matches goldens" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var failed: u32 = 0;
    for (scenes.all) |scene| {
        var img = try renderSoftware(gpa, io, scene, false, 0);
        defer img.deinit(gpa);
        golden.compareInDir(io, golden_dir, scene.name, &img, .{}, .{}) catch |err| switch (err) {
            error.GoldenMismatch, error.GoldenMissing => failed += 1,
            else => return err,
        };
        if (scene.frames > 1) {
            var full = try renderSoftware(gpa, io, scene, true, 0);
            defer full.deinit(gpa);
            if (!std.mem.eql(u8, img.pixels, full.pixels)) {
                std.debug.print("scene {s}: damage-limited frames differ from a full redraw\n", .{scene.name});
                failed += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 0), failed);
}

/// Renders every frame of the scroll layer seam scene through `target`
/// (a backend with `renderToImage`) and compares it with the same frame
/// drawn without the scroll layer: within 1 LSB at integer scroll
/// offsets, 2 LSB at fractional ones. Returns the number of mismatches.
pub fn seamMismatches(gpa: std.mem.Allocator, target: anytype, r: r2d.Renderer, order: CpuImage.Order) !u32 {
    const tex = try Textures.create(gpa, r);
    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    dl.setGlyphPages(&tex.pages);
    dl.layer_query = r.layerQuery();
    const size: r2d.Size = .{ .w = 120, .h = 90 };
    var a = try CpuImage.initOrder(gpa, size.w, size.h, order);
    defer a.deinit(gpa);
    var b = try CpuImage.initOrder(gpa, size.w, size.h, order);
    defer b.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(1);
    var bad: u32 = 0;
    for (scenes.seam.scrolls, 0..) |s, frame| {
        dl.reset(size, 1);
        dl.damageAll();
        scenes.seam.layered(&dl, @intCast(frame), tex.image, prng.random());
        _ = try target.renderToImage(&dl, &a);
        dl.reset(size, 1);
        dl.damageAll();
        scenes.seam.reference(&dl, frame);
        _ = try target.renderToImage(&dl, &b);
        const tol: image_diff.Tolerance = .{ .max_channel_diff = if (s == @floor(s)) 1 else 2 };
        const res = try image_diff.diff(gpa, &a, &b, tol, false);
        if (!res.pass) {
            std.debug.print("scroll layer seam: frame {d} (scroll {d}): {d} pixels off, max diff {d}\n", .{ frame, s, res.bad_pixels, res.max_diff });
            bad += 1;
        }
    }
    return bad;
}

test "scene: scroll layer seam matches unlayered rendering (software)" {
    const gpa = std.testing.allocator;
    var sink: platform.surface.HeadlessSink = .{ .ptr = undefined, .write = struct {
        fn w(_: *anyopaque, _: platform.types.WindowId, _: []const r2d.PxRect, _: []const u8, _: u32) void {}
    }.w };
    const sw = try SwRenderer.create(gpa, std.testing.io, .{ .target = .{ .headless = &sink } });
    defer sw.destroy();
    try std.testing.expectEqual(@as(u32, 0), try seamMismatches(gpa, sw, sw.renderer(), .rgba));
}
