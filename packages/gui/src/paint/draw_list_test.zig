//! End-to-end: a window presents into an `r2d.DrawList` through
//! `DrawListCanvas`, and E02's software renderer rasterizes it.

const std = @import("std");
const zg_vulkan = @import("zg_vulkan");
const zg_platform = @import("zg_platform");
const app_mod = @import("../core/app.zig");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const text = @import("text.zig");
const DrawListCanvas = @import("draw_list.zig").DrawListCanvas;

const r2d = zg_vulkan.r2d;
const PxRect = zg_platform.types.PxRect;

const Scene = struct {
    accent: bool = false,
    pub fn build(self: *Scene, ui: *ui_mod.Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = 100 }, .h = .{ .px = 60 }, .bg = .{ .token = .bg_base } } });
        defer ui.close();
        ui.open(.{ .style = .{ .w = .{ .px = 20 }, .h = .{ .px = 10 }, .bg = .{ .token = if (self.accent) .accent else .bg_base } } });
        ui.close();
    }
};

fn nullSink() zg_platform.surface.HeadlessSink {
    return .{ .ptr = undefined, .write = struct {
        fn w(_: *anyopaque, _: zg_platform.types.WindowId, _: []const PxRect, _: []const u8, _: u32) void {}
    }.w };
}

test "window frames render through the software renderer" {
    const gpa = std.testing.allocator;
    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    var dlc = DrawListCanvas.init(&dl);
    var mono: text.MonoText = .{};
    var scene: Scene = .{};
    var app = app_mod.App.init(gpa);
    defer app.deinit();
    const win = try app.openWindow(.{
        .size = .{ .w = 100, .h = 60 },
        .scale = 2,
        .root = view_mod.AnyView.of(&scene),
        .text = mono.system(),
        .canvas = dlc.canvas(),
    });
    _ = win.frame();
    try std.testing.expectEqual(@as(u32, 200), dl.extent.w);
    try std.testing.expectEqual(@as(u32, 120), dl.extent.h);
    try std.testing.expect(dl.prims.items.len >= 2);

    var sink = nullSink();
    const sw = try zg_vulkan.sw.SwRenderer.create(gpa, std.testing.io, .{ .target = .{ .headless = &sink }, .sw_threads = 1 });
    defer sw.destroy();
    var img = try zg_vulkan.testing.CpuImage.init(gpa, 200, 120);
    defer img.deinit(gpa);
    _ = try sw.renderToImage(&dl, &img);
    const bg = app.theme.color(.bg_base);
    try std.testing.expectEqualSlices(u8, &.{ bg.r, bg.g, bg.b, 255 }, &img.get(150, 100));

    // A paint-only change damages only the small box (20x10 logical).
    scene.accent = true;
    win.markAllDirty();
    _ = win.frame();
    try std.testing.expect(!dl.damage_full);
    var area: u64 = 0;
    for (dl.damageRects()) |r| area += @as(u64, r.w) * r.h;
    try std.testing.expect(area > 0 and area <= 60 * 40);
    _ = try sw.renderToImage(&dl, &img);
    const ac = app.theme.color(.accent);
    try std.testing.expectEqualSlices(u8, &.{ ac.r, ac.g, ac.b, 255 }, &img.get(10, 6));
    try std.testing.expectEqualSlices(u8, &.{ bg.r, bg.g, bg.b, 255 }, &img.get(150, 100));
}
