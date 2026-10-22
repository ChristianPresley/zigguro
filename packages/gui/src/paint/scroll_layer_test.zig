//! Scroll layers end to end: a window whose canvas keeps layers and one
//! that draws in place scroll the same content; E02's software renderer
//! must produce the same pixels, while the layered window repaints only
//! the strip the scroll exposed.

const std = @import("std");
const zg_vulkan = @import("zg_vulkan");
const zg_platform = @import("zg_platform");
const app_mod = @import("../core/app.zig");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const ids = @import("../core/ids.zig");
const window_mod = @import("../core/window.zig");
const canvas_mod = @import("canvas.zig");
const text = @import("text.zig");
const scroll = @import("../widgets/scroll.zig");
const DrawListCanvas = @import("draw_list.zig").DrawListCanvas;

const r2d = zg_vulkan.r2d;
const PxRect = zg_platform.types.PxRect;
const CpuImage = zg_vulkan.testing.CpuImage;
const gpa = std.testing.allocator;

/// 40 rows of 7 px in four colours inside a 100x60 scroll area.
const Rows = struct {
    area: ids.NodeId = .none,
    pub fn build(self: *Rows, ui: *ui_mod.Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = 120 }, .h = .{ .px = 80 }, .bg = .{ .token = .bg_base }, .padding = .all(10) } });
        defer ui.close();
        self.area = scroll.scrollArea(ui, .{ .test_id = "area" });
        defer ui.close();
        const tones = [_]@import("../theme/tokens.zig").Token{ .accent, .danger, .bg_elevated, .warning };
        for (0..40) |i| {
            ui.id(@as(u32, @intCast(i)));
            ui.open(.{ .style = .{ .h = .{ .px = 7 }, .shrink = 0, .bg = .{ .token = tones[i % tones.len] } } });
            ui.close();
        }
    }
};

fn nullSink() zg_platform.surface.HeadlessSink {
    return .{ .ptr = undefined, .write = struct {
        fn w(_: *anyopaque, _: zg_platform.types.WindowId, _: []const PxRect, _: []const u8, _: u32) void {}
    }.w };
}

/// One window, its list, canvas, renderer and image.
const Side = struct {
    dl: r2d.DrawList,
    dlc: DrawListCanvas,
    /// The DrawListCanvas table without the layer hooks.
    flat: canvas_mod.Canvas.VTable,
    view: Rows = .{},
    win: *window_mod.Window,
    sink: zg_platform.surface.HeadlessSink,
    sw: *zg_vulkan.sw.SwRenderer,
    img: CpuImage,

    fn init(s: *Side, app: *app_mod.App, mono: *text.MonoText, layers: bool, scale: f32) !void {
        s.dl = .init(gpa);
        s.dlc = .init(&s.dl);
        s.view = .{};
        var c = s.dlc.canvas();
        if (!layers) {
            s.flat = c.vtable.*;
            s.flat.beginScrollLayer = null;
            s.flat.endLayer = null;
            s.flat.drawLayer = null;
            c.vtable = &s.flat;
        }
        s.win = try app.openWindow(.{ .size = .{ .w = 120, .h = 80 }, .scale = scale, .root = view_mod.AnyView.of(&s.view), .text = mono.system(), .canvas = c });
        s.sink = nullSink();
        s.sw = try zg_vulkan.sw.SwRenderer.create(gpa, std.testing.io, .{ .target = .{ .headless = &s.sink }, .sw_threads = 1 });
        const sz: u32 = @intFromFloat(@round(120 * scale));
        const sh: u32 = @intFromFloat(@round(80 * scale));
        s.img = try CpuImage.init(gpa, sz, sh);
    }

    fn deinit(s: *Side) void {
        s.img.deinit(gpa);
        s.sw.destroy();
        s.dl.deinit();
    }

    fn step(s: *Side, y: f32) !void {
        if (!s.view.area.isNone()) _ = s.win.scrollTo(s.view.area, .{ .y = y });
        _ = s.win.frame();
        _ = try s.sw.renderToImage(&s.dl, &s.img);
    }
};

fn maxDiff(a: *const CpuImage, b: *const CpuImage) u8 {
    var m: u8 = 0;
    for (a.pixels, b.pixels) |x, y| m = @max(m, if (x > y) x - y else y - x);
    return m;
}

fn run(scale: f32, tolerance: u8) !void {
    var app = app_mod.App.init(gpa);
    defer app.deinit();
    var mono: text.MonoText = .{};
    var layered: Side = undefined;
    try layered.init(&app, &mono, true, scale);
    defer layered.deinit();
    var flat: Side = undefined;
    try flat.init(&app, &mono, false, scale);
    defer flat.deinit();

    try layered.step(0);
    try flat.step(0);
    try std.testing.expectEqual(@as(usize, 1), layered.dl.layers.items.len);
    try std.testing.expectEqual(@as(usize, 0), flat.dl.layers.items.len);
    try std.testing.expect(maxDiff(&layered.img, &flat.img) <= tolerance);

    // Whole-pixel scrolls (at 1 and 1.5) in both directions: the same pixels, and only the
    // exposed strip of the layer repaints.
    const ys = [_]f32{ 10, 24, 18, 100, 4, 200, 14 };
    for (ys, 0..) |y, n| {
        const before = layered.win.store.cold.items[layered.view.area.index].layer.?;
        try layered.step(y);
        try flat.step(y);
        try std.testing.expect(maxDiff(&layered.img, &flat.img) <= tolerance);
        const l = layered.dl.layers.items[0];
        try std.testing.expect(l.drawn);
        const after = layered.win.store.cold.items[layered.view.area.index].layer.?;
        const d: i32 = after.si[1] - before.si[1];
        if (@abs(d) >= before.size[1]) continue;
        var area: u64 = 0;
        for (layered.dl.layerDamage(l)) |r| {
            area += @as(u64, r.w) * r.h;
            // Inside the strip the scroll exposed.
            if (d > 0) try std.testing.expect(r.y >= @as(i32, @intCast(before.size[1])) - d) else try std.testing.expect(r.y + @as(i32, @intCast(r.h)) <= -d);
        }
        // (Rows that came into view overlap the strip.)
        try std.testing.expect(area > 0);
        _ = n;
    }

    // A fractional scroll moves the composite, not the content.
    try layered.step(14.5);
    try flat.step(14.5);
    try std.testing.expectEqual(@as(usize, 0), layered.win.layer_damage.items.len);
    var total: u64 = 0;
    for (layered.img.pixels, flat.img.pixels) |x, y| total += if (x > y) x - y else y - x;
    // Only row edges differ (filtered vs. rasterized coverage).
    try std.testing.expect(total / layered.img.pixels.len < 4);
}

test "scroll layers: same pixels as drawing in place, exposed strips only" {
    try run(1, 0);
}

test "scroll layers: at a fractional scale" {
    // Compositing rounds once more than drawing in place.
    try run(1.5, 2);
}
