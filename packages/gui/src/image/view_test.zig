//! The image cache and view (E04.F06.S02.T02), headless: decoding through
//! the app's posted calls, budgets and pins, animation on the virtual
//! clock, zoom and pan geometry and what the view paints.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const geom = @import("../core/geom.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;
const image = @import("image.zig");
const cache_mod = @import("cache.zig");
const view = @import("view.zig");
const textures = @import("textures.zig");
const canvas = @import("../paint/canvas.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Ui = ui_mod.Ui;
const ImageCache = cache_mod.ImageCache;
const Handle = cache_mod.Handle;

fn fixture(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/testdata/images/{s}", .{ @import("zg_options").package_root, name });
}

/// A `w`×`h` image of one colour (premultiplied).
fn solid(w: u32, h: u32, px: [4]u8) !image.Image {
    const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..w * h) |i| rgba[i * 4 ..][0..4].* = px;
    return .{ .w = w, .h = h, .rgba = rgba, .format = .png };
}

/// Two frames, 100 ms and 200 ms, looping forever.
fn twoFrames() !image.Image {
    const frames = try gpa.alloc(image.Frame, 2);
    for (frames, 0..) |*f, i| {
        const rgba = try gpa.alloc(u8, 16);
        @memset(rgba, @intCast(i * 100));
        f.* = .{ .rgba = rgba, .delay_ms = @intCast(100 * (i + 1)) };
    }
    return .{ .w = 2, .h = 2, .rgba = frames[0].rgba, .frames = frames, .format = .gif };
}

/// Runs the first posted call only.
fn runOne(t: *TestApp) void {
    const c = t.app.local_calls.orderedRemove(0);
    c.f(c.ctx, &t.app);
}

const Gallery = struct {
    cache: *ImageCache,
    h: Handle,
    show: bool = true,
    zoomable: bool = true,
    info: bool = false,
    st: ?*view.ImageViewState = null,

    pub fn build(g: *Gallery, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .align_items = .start } });
        defer ui.close();
        if (g.show) g.st = view.imageView(ui, .{ .cache = g.cache, .handle = g.h, .zoomable = g.zoomable, .info_overlay = g.info, .w = 200, .h = 100, .alt = "photo" });
    }
};

test "preview then full-res status transitions" {
    const t = try TestApp.init(gpa, .{});
    defer t.deinit();
    var c = try ImageCache.init(gpa, &t.app, .{ .io = testing.io });
    defer c.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 37×29 wanted at 5 px: a 1/8 DCT preview comes first.
    const h = try c.request(.{ .path = try fixture(&buf, "baseline444.jpg") }, 5);
    defer c.release(h);
    try testing.expect(c.status(h) == .loading);
    try testing.expectEqual(@as(usize, 2), t.app.local_calls.items.len);
    runOne(t);
    const p = c.status(h).preview;
    try testing.expectEqual(@as(u32, 37), p.w);
    try testing.expectEqual(@as(u32, 5), p.px_w);
    runOne(t);
    const r = c.status(h).ready;
    try testing.expectEqual(@as(u32, 37), r.px_w);
    try testing.expectEqual(image.Format.jpeg, r.format);
    try testing.expect(r.file_size > 0);
    // The same path shares the entry.
    const again = try c.request(.{ .path = try fixture(&buf, "baseline444.jpg") }, 5);
    try testing.expectEqual(h, again);
    c.release(again);
    // A small image wanted large has no preview.
    const g = try c.request(.{ .path = try fixture(&buf, "gray.jpg") }, 100);
    defer c.release(g);
    try testing.expectEqual(@as(usize, 1), t.app.local_calls.items.len);
    _ = t.app.drainMessages();
    try testing.expect(c.status(g) == .ready);
}

test "orientation applied" {
    const t = try TestApp.init(gpa, .{});
    defer t.deinit();
    var c = try ImageCache.init(gpa, &t.app, .{ .io = testing.io });
    defer c.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const h = try c.request(.{ .path = try fixture(&buf, "orient6.jpg") }, 0);
    defer c.release(h);
    _ = t.app.drainMessages();
    const r = c.status(h).ready;
    try testing.expectEqual(@as(u32, 29), r.w);
    try testing.expectEqual(@as(u32, 37), r.h);
}

test "corrupt file shows error" {
    var c: ImageCache = undefined;
    var g: Gallery = undefined;
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&g) });
    defer t.deinit();
    c = try ImageCache.init(gpa, &t.app, .{ .io = testing.io });
    defer c.deinit();
    const h = try c.request(.{ .bytes = try gpa.dupe(u8, "GIF89a not really") }, 0);
    g = .{ .cache = &c, .h = h };
    _ = t.settle();
    try testing.expect(c.status(h) == .failed);
    try testing.expect(t.find(.{ .kind = "image", .name = "photo" }) != null);
    const snap = t.paintSnapshot();
    try testing.expect(std.mem.indexOf(u8, snap, "Malformed") != null or std.mem.indexOf(u8, snap, "glyphs") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "image ") == null);
    // A missing file and an unknown key fail too.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const m = try c.request(.{ .path = try fixture(&buf, "missing.png") }, 0);
    _ = t.app.drainMessages();
    try testing.expectEqual(error.NotFound, c.status(m).failed);
    const k = try c.request(.{ .key = 42 }, 0);
    try testing.expectEqual(error.NotFound, c.status(k).failed);
    c.release(m);
    c.release(k);
    c.release(h);
}

test "zoom anchored at pointer" {
    var st: view.ImageViewState = .{};
    const box: geom.Size = .{ .w = 400, .h = 300 };
    const anchor: geom.Vec2 = .{ .x = 130, .y = 70 };
    // 800×600 in a 400×300 box fits at 0.5.
    view.zoomAt(&st, .contain, box, 800, 600, anchor, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.5), st.zoom, 1e-6);
    const before = geom.Vec2{ .x = (anchor.x - st.pan.x) / st.zoom, .y = (anchor.y - st.pan.y) / st.zoom };
    for (0..5) |_| view.zoomAt(&st, .contain, box, 800, 600, anchor, view.wheel_step);
    const after = geom.Vec2{ .x = (anchor.x - st.pan.x) / st.zoom, .y = (anchor.y - st.pan.y) / st.zoom };
    try testing.expectApproxEqAbs(before.x, after.x, 1e-3);
    try testing.expectApproxEqAbs(before.y, after.y, 1e-3);
    // Clamped to [0.1, 32].
    view.zoomAt(&st, .contain, box, 800, 600, anchor, 1000);
    try testing.expectEqual(view.max_zoom, st.zoom);
    view.zoomAt(&st, .contain, box, 800, 600, anchor, 0.00001);
    try testing.expectEqual(view.min_zoom, st.zoom);
}

test "pan clamp 25%" {
    var st: view.ImageViewState = .{ .zoom = 1 };
    const box: geom.Size = .{ .w = 400, .h = 300 };
    st.pan = .{ .x = 10_000, .y = -10_000 };
    view.clampPan(&st, box, 200, 100);
    // A quarter of the image's 200 px stays in: x ≤ 400 - 50.
    try testing.expectEqual(@as(f32, 350), st.pan.x);
    try testing.expectEqual(@as(f32, 25 - 100), st.pan.y);
    // A huge image keeps the whole view covered by at most... its quarter
    // is wider than the view: the view stays full.
    st = .{ .zoom = 10, .pan = .{ .x = 10_000, .y = 0 } };
    view.clampPan(&st, box, 200, 100);
    try testing.expectEqual(@as(f32, 0), st.pan.x);
}

test "fit modes" {
    const box: geom.Rect = .{ .w = 200, .h = 100 };
    const c = view.fitRect(.contain, box, 400, 400);
    try testing.expectEqual(geom.Rect{ .x = 50, .y = 0, .w = 100, .h = 100 }, c);
    try testing.expectEqual(geom.Rect{ .x = 0, .y = -50, .w = 200, .h = 200 }, view.fitRect(.cover, box, 400, 400));
    try testing.expectEqual(geom.Rect{ .x = 90, .y = 40, .w = 20, .h = 20 }, view.fitRect(.actual, box, 20, 20));
    try testing.expectEqual(box, view.fitRect(.fill, box, 20, 20));
    // Contain never upscales.
    try testing.expectEqual(geom.Rect{ .x = 90, .y = 40, .w = 20, .h = 20 }, view.fitRect(.contain, box, 20, 20));
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

test "checkerboard under transparent PNG" {
    var c: ImageCache = undefined;
    var g: Gallery = undefined;
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&g) });
    defer t.deinit();
    c = try ImageCache.init(gpa, &t.app, .{});
    defer c.deinit();
    const h = try c.insert(7, try solid(100, 50, .{ 0, 0, 0, 0 }));
    defer c.release(h);
    g = .{ .cache = &c, .h = h };
    _ = t.settle();
    const snap = t.paintSnapshot();
    // The checker tile, then the image (both app images), clipped.
    const checker = @intFromEnum(c.checker_tex);
    var line: [64]u8 = undefined;
    const want_checker = try std.fmt.bufPrint(&line, "image {d} ", .{checker});
    const at_checker = std.mem.indexOf(u8, snap, want_checker) orelse return error.NoChecker;
    var line2: [64]u8 = undefined;
    const tex = @intFromEnum(c.entries.items[@intFromEnum(h)].tex);
    const at_image = std.mem.indexOf(u8, snap, try std.fmt.bufPrint(&line2, "image {d} ", .{tex})) orelse return error.NoImage;
    try testing.expect(at_checker < at_image);
    try testing.expect(c.checker_tex != .none and t.app.images.bytes > 0);
    // Without a checkerboard only the image draws.
    try testing.expect(std.mem.indexOf(u8, snap, "clip ") != null);
}

test "pixel grid at 8x" {
    var c: ImageCache = undefined;
    var g: Gallery = undefined;
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&g) });
    defer t.deinit();
    c = try ImageCache.init(gpa, &t.app, .{});
    defer c.deinit();
    const h = try c.insert(8, try solid(10, 10, .{ 255, 0, 0, 255 }));
    defer c.release(h);
    g = .{ .cache = &c, .h = h };
    _ = t.settle();
    const fit = t.paintSnapshot();
    const rects_fit = count(fit, "rect ");
    // 100 % → 10×: nearest sampling and grid lines over the visible part.
    t.win.setFocus(t.find(.{ .kind = "image" }).?, false);
    t.press(.digit_1, .{});
    try testing.expectEqual(@as(f32, 1), g.st.?.zoom);
    g.st.?.zoom = 10;
    g.st.?.pan = .{};
    t.win.themeChanged(false);
    _ = t.settle();
    const zoomed = t.paintSnapshot();
    const tex = @intFromEnum(c.entries.items[@intFromEnum(h)].tex) | canvas.app_image_nearest;
    var line: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, zoomed, try std.fmt.bufPrint(&line, "image {d} ", .{tex})) != null);
    // 100×100 visible at 10 px a pixel: 11 + 11 lines (the view is
    // 200×100, the image covers 100×100).
    try testing.expectEqual(rects_fit + 22, count(zoomed, "rect "));
    // Below 8× no grid.
    g.st.?.zoom = 4;
    t.win.themeChanged(false);
    _ = t.settle();
    try testing.expectEqual(rects_fit, count(t.paintSnapshot(), "rect "));
}

test "ctrl+wheel and keys zoom; space drag pans" {
    var c: ImageCache = undefined;
    var g: Gallery = undefined;
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&g) });
    defer t.deinit();
    c = try ImageCache.init(gpa, &t.app, .{});
    defer c.deinit();
    const h = try c.insert(9, try solid(100, 50, .{ 9, 9, 9, 255 }));
    defer c.release(h);
    g = .{ .cache = &c, .h = h };
    _ = t.settle();
    const r = try t.rectOf(.{ .kind = "image" });
    const p: geom.Vec2 = .{ .x = r.x + 30, .y = r.y + 30 };
    t.win.dispatch(.{ .pointer_move = .{ .pos = p, .mods = .{ .ctrl = true } } });
    t.win.dispatch(.{ .scroll = .{ .pos = p, .dx = 0, .dy = 2 } });
    try testing.expectApproxEqAbs(@as(f32, 1.21), g.st.?.zoom, 1e-4);
    // The keys need focus.
    t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
    t.win.dispatch(.{ .pointer_down = .{ .pos = p } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = p } });
    t.press(.minus, .{});
    try testing.expectApproxEqAbs(@as(f32, 1.1), g.st.?.zoom, 1e-4);
    t.press(.digit_0, .{});
    try testing.expectEqual(@as(f32, 0), g.st.?.zoom);
    // Space + drag.
    t.win.dispatch(.{ .key = .{ .key = .space } });
    t.win.dispatch(.{ .pointer_down = .{ .pos = p } });
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = p.x + 20, .y = p.y + 5 } } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = p.x + 20, .y = p.y + 5 } } });
    t.win.dispatch(.{ .key = .{ .key = .space, .action = .release } });
    // Fitted at 100 % (contain does not upscale), centred: 50 + 20, 25 + 5.
    try testing.expectEqual(@as(f32, 70), g.st.?.pan.x);
    try testing.expectEqual(@as(f32, 30), g.st.?.pan.y);
}

test "gif plays with delays and pauses offscreen" {
    var c: ImageCache = undefined;
    var g: Gallery = undefined;
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&g) });
    defer t.deinit();
    c = try ImageCache.init(gpa, &t.app, .{});
    defer c.deinit();
    const h = try c.insert(10, try twoFrames());
    defer c.release(h);
    g = .{ .cache = &c, .h = h };
    _ = t.settle();
    const e = &c.entries.items[@intFromEnum(h)];
    try testing.expectEqual(@as(u32, 0), e.player.frame);
    t.advance(99);
    try testing.expectEqual(@as(u32, 0), e.player.frame);
    t.advance(1);
    try testing.expectEqual(@as(u32, 1), e.player.frame);
    try testing.expectEqual(@as(u32, 1), e.tex_frame);
    t.advance(200);
    try testing.expectEqual(@as(u32, 0), e.player.frame);
    // Off screen (not built): it stops after the frame in flight.
    g.show = false;
    t.win.markAllDirty();
    _ = t.settle();
    t.advance(100);
    const stopped = e.player.frame;
    t.advance(1000);
    try testing.expectEqual(stopped, e.player.frame);
    try testing.expectEqual(@as(?u64, null), t.win.nextDeadline());
    // Back on screen: it plays again.
    g.show = true;
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.win.nextDeadline() != null);
}

test "reduced motion shows first frame" {
    var c: ImageCache = undefined;
    var g: Gallery = undefined;
    const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&g) });
    defer t.deinit();
    t.app.reduced_motion = true;
    c = try ImageCache.init(gpa, &t.app, .{});
    defer c.deinit();
    const h = try c.insert(11, try twoFrames());
    defer c.release(h);
    g = .{ .cache = &c, .h = h };
    _ = t.settle();
    t.advance(1000);
    try testing.expectEqual(@as(u32, 0), c.entries.items[@intFromEnum(h)].player.frame);
    try testing.expectEqual(@as(?u64, null), t.win.nextDeadline());
}

test "LRU eviction respects pins" {
    const t = try TestApp.init(gpa, .{});
    defer t.deinit();
    // Each image is 2×2 (16 bytes): two fit on the GPU, three on the CPU.
    var c = try ImageCache.init(gpa, &t.app, .{ .gpu_bytes = 32, .cpu_bytes = 48 });
    defer c.deinit();
    const a = try c.insert(1, try solid(2, 2, .{ 1, 1, 1, 255 }));
    const b = try c.insert(2, try solid(2, 2, .{ 2, 2, 2, 255 }));
    const d = try c.insert(3, try solid(2, 2, .{ 3, 3, 3, 255 }));
    t.app.frame_epoch = 1;
    _ = c.use(a, t.win).?;
    _ = c.use(b, t.win).?;
    t.app.frame_epoch = 2;
    _ = c.use(d, t.win).?;
    // a was least recently used and not pinned.
    try testing.expect(!c.onGpu(a) and c.onGpu(b) and c.onGpu(d));
    try testing.expect(c.usage().gpu <= 32);
    // All three used this frame: pinned, so the GPU runs over by one
    // image rather than evict one.
    t.app.frame_epoch = 3;
    _ = c.use(b, t.win).?;
    _ = c.use(d, t.win).?;
    _ = c.use(a, t.win).?;
    try testing.expect(c.onGpu(a) and c.onGpu(b) and c.onGpu(d));
    try testing.expectEqual(@as(u64, 48), c.usage().gpu);
    // A fourth image over the CPU budget: the unreferenced one goes
    // (texture and all); referenced inserted ones stay (they could not
    // be decoded again).
    c.release(d);
    t.app.frame_epoch = 4;
    const e = try c.insert(4, try solid(2, 2, .{ 4, 4, 4, 255 }));
    try testing.expect(c.usage().cpu <= 48);
    try testing.expectEqual(@as(u64, 32), c.usage().gpu);
    try testing.expectEqual(@as(?u32, null), c.by_key.get(3));
    try testing.expect(c.status(a) == .ready and c.status(b) == .ready);
    c.release(a);
    c.release(b);
    c.release(e);
}

test "device lost re-upload" {
    const t = try TestApp.init(gpa, .{});
    defer t.deinit();
    var c = try ImageCache.init(gpa, &t.app, .{});
    defer c.deinit();
    const h = try c.insert(1, try solid(4, 4, .{ 5, 5, 5, 255 }));
    defer c.release(h);
    _ = c.use(h, t.win).?;
    const Fake = struct {
        uploads: u32 = 0,
        live: u32 = 0,
        fn create(ctx: *anyopaque, _: u32, _: u32) anyerror!u32 {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            f.live += 1;
            return f.live;
        }
        fn update(ctx: *anyopaque, _: u32, _: u32, _: u32, px: []const u8) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            try testing.expectEqual(@as(u8, 5), px[0]);
            f.uploads += 1;
        }
        fn destroy(ctx: *anyopaque, _: u32) void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            f.live -= 1;
        }
    };
    var f: Fake = .{};
    const ops: textures.Mirror.Ops = .{ .ctx = &f, .create = Fake.create, .update = Fake.update, .destroy = Fake.destroy };
    var m: textures.Mirror = .{};
    defer m.deinit(gpa);
    _ = try m.sync(gpa, &t.app.images, ops, true);
    try testing.expectEqual(@as(u32, 1), f.uploads);
    // The device is lost: the renderer's textures are gone, the CPU
    // copies upload again.
    m.destroyAll(ops);
    t.app.images.invalidate();
    _ = try m.sync(gpa, &t.app.images, ops, true);
    try testing.expectEqual(@as(u32, 2), f.uploads);
    try testing.expectEqual(@as(u32, 1), f.live);
    m.destroyAll(ops);
}
