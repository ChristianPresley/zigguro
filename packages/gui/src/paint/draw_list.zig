//! `DrawListCanvas`: the production `Canvas`, forwarding every call to
//! E02's `r2d.DrawList` (see "zg_vulkan.r2d" and "zg_gui.paint.Canvas" in
//! docs/interfaces.md). Geometry stays in logical pixels; the list applies
//! the scale. Damage rectangles are rounded outwards to physical pixels.
//!
//! The window presents into the canvas; the app then hands the same
//! `DrawList` to a `Renderer` (Vulkan or software) for that frame.

const std = @import("std");
const zg_vulkan = @import("zg_vulkan");
const geom = @import("../core/geom.zig");
const canvas_mod = @import("canvas.zig");

const r2d = zg_vulkan.r2d;
const Rect = geom.Rect;
const Vec2 = geom.Vec2;
const Color = geom.Color;
const Radii = geom.Radii;
const Insets = geom.Insets;
const Size = geom.Size;
const Canvas = canvas_mod.Canvas;

comptime {
    // E03's quads and E02's quads share one layout, so runs pass through
    // without copying.
    std.debug.assert(@sizeOf(canvas_mod.GlyphQuad) == @sizeOf(r2d.GlyphQuad));
    std.debug.assert(@offsetOf(canvas_mod.GlyphQuad, "uv") == @offsetOf(r2d.GlyphQuad, "uv"));
    std.debug.assert(@offsetOf(canvas_mod.GlyphQuad, "page") == @offsetOf(r2d.GlyphQuad, "page"));
    std.debug.assert(@offsetOf(canvas_mod.GlyphQuad, "format") == @offsetOf(r2d.GlyphQuad, "format"));
    std.debug.assert(@sizeOf(Color) == @sizeOf(r2d.Color));
    std.debug.assert(@sizeOf(canvas_mod.PxRect) == @sizeOf(r2d.PxRect));
    std.debug.assert(@offsetOf(canvas_mod.PxRect, "w") == @offsetOf(r2d.PxRect, "w"));
}

/// A `Canvas` that records into an `r2d.DrawList`.
pub const DrawListCanvas = struct {
    list: *r2d.DrawList,

    /// Forwards to `list`.
    pub fn init(list: *r2d.DrawList) DrawListCanvas {
        return .{ .list = list };
    }

    /// The canvas interface.
    pub fn canvas(d: *DrawListCanvas) Canvas {
        return .{ .ptr = d, .vtable = &vtable };
    }

    const vtable: Canvas.VTable = .{
        .begin = begin,
        .rect = rect,
        .border = border,
        .shadow = shadow,
        .linearGradient = linearGradient,
        .glyphs = glyphs,
        .image = image,
        .pushClip = pushClip,
        .popClip = popClip,
        .addDamage = addDamage,
        .end = end,
        .beginScrollLayer = beginScrollLayer,
        .endLayer = endLayer,
        .drawLayer = drawLayer,
    };

    fn dl(p: *anyopaque) *r2d.DrawList {
        const d: *DrawListCanvas = @ptrCast(@alignCast(p));
        return d.list;
    }

    fn rf(r: Rect) r2d.RectF {
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    fn rr(r: Radii) r2d.Radii {
        return .{ .tl = r.tl, .tr = r.tr, .br = r.br, .bl = r.bl };
    }

    fn col(c: Color) r2d.Color {
        return @bitCast(c);
    }

    /// The physical pixels covered by logical `r` at `scale`, rounded out.
    pub fn toPx(r: Rect, scale: f32) r2d.PxRect {
        const x0 = @floor(r.x * scale);
        const y0 = @floor(r.y * scale);
        const x1 = @ceil((r.x + r.w) * scale);
        const y1 = @ceil((r.y + r.h) * scale);
        const lim: f32 = 1 << 30;
        return .{
            .x = @intFromFloat(std.math.clamp(x0, -lim, lim)),
            .y = @intFromFloat(std.math.clamp(y0, -lim, lim)),
            .w = @intFromFloat(std.math.clamp(x1 - x0, 0, lim)),
            .h = @intFromFloat(std.math.clamp(y1 - y0, 0, lim)),
        };
    }

    fn begin(p: *anyopaque, size: Size, scale: f32) void {
        const px: r2d.Size = .{
            .w = @intFromFloat(@max(0, @round(size.w * scale))),
            .h = @intFromFloat(@max(0, @round(size.h * scale))),
        };
        dl(p).reset(px, scale);
    }
    fn rect(p: *anyopaque, r: Rect, fill: Color, radii: Radii) void {
        dl(p).rect(rf(r), col(fill), rr(radii));
    }
    fn border(p: *anyopaque, r: Rect, w: Insets, color: Color, radii: Radii) void {
        dl(p).border(rf(r), .{ .l = w.l, .t = w.t, .r = w.r, .b = w.b }, col(color), rr(radii));
    }
    fn shadow(p: *anyopaque, r: Rect, radii: Radii, sigma: f32, spread: f32, color: Color) void {
        dl(p).shadow(rf(r), rr(radii), sigma, spread, col(color));
    }
    fn linearGradient(p: *anyopaque, r: Rect, p0: Vec2, p1: Vec2, c0: Color, c1: Color, radii: Radii) void {
        dl(p).linearGradient(rf(r), .{ .x = p0.x, .y = p0.y }, .{ .x = p1.x, .y = p1.y }, col(c0), col(c1), rr(radii));
    }
    fn glyphs(p: *anyopaque, run: []const canvas_mod.GlyphQuad, color: Color, aa: canvas_mod.TextAa) void {
        const q: [*]const r2d.GlyphQuad = @ptrCast(run.ptr);
        dl(p).glyphs(q[0..run.len], col(color), @enumFromInt(@intFromEnum(aa)));
    }
    fn image(p: *anyopaque, tex: canvas_mod.TextureId, dst: Rect, uv: Rect, tint: Color, radii: Radii) void {
        dl(p).image(@enumFromInt(@intFromEnum(tex)), rf(dst), rf(uv), col(tint), rr(radii));
    }
    fn beginScrollLayer(p: *anyopaque, id: u32, size: [2]u32, origin: [2]i32, damage: []const canvas_mod.PxRect) bool {
        const d: [*]const r2d.PxRect = @ptrCast(damage.ptr);
        return dl(p).beginScrollLayer(@enumFromInt(id), .{ .w = size[0], .h = size[1] }, origin, d[0..damage.len]);
    }
    fn endLayer(p: *anyopaque) void {
        dl(p).endLayer();
    }
    fn drawLayer(p: *anyopaque, id: u32, dst: Rect, scroll_px: Vec2) void {
        dl(p).drawLayer(@enumFromInt(id), rf(dst), .{ .x = scroll_px.x, .y = scroll_px.y }, 1);
    }
    fn pushClip(p: *anyopaque, r: Rect, radii: Radii) void {
        dl(p).pushClip(rf(r), rr(radii));
    }
    fn popClip(p: *anyopaque) void {
        dl(p).popClip();
    }
    fn addDamage(p: *anyopaque, r: Rect) void {
        const l = dl(p);
        l.addDamage(toPx(r, l.scale));
    }
    fn end(_: *anyopaque) void {}
};

test "damage rounds outwards to physical pixels" {
    const px = DrawListCanvas.toPx(.{ .x = 1.25, .y = 0.5, .w = 2, .h = 1 }, 2);
    try std.testing.expectEqual(@as(i32, 2), px.x);
    try std.testing.expectEqual(@as(i32, 1), px.y);
    try std.testing.expectEqual(@as(u32, 5), px.w);
    try std.testing.expectEqual(@as(u32, 2), px.h);
}
