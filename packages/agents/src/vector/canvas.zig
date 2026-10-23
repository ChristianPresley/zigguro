//! The vector canvas (E13.F07.S01.T02): an immediate-mode recorder that
//! charts, diagrams and sparklines draw into, producing a display list.
//! Everything it records lives in its arena.

const std = @import("std");
const path_mod = @import("path.zig");
const stroke_mod = @import("stroke.zig");
const dl_mod = @import("display_list.zig");

const Allocator = std.mem.Allocator;
const Path = path_mod.Path;
const Rect = path_mod.Rect;
const Color = dl_mod.Color;
const Item = dl_mod.Item;
const StrokeStyle = stroke_mod.StrokeStyle;

/// Stroke outlines are flattened within this many canvas units: a
/// quarter pixel up to 5× zoom (tiles re-stroke from the path beyond).
pub const default_tolerance: f32 = 0.05;

pub const VectorCanvas = struct {
    arena: Allocator,
    items: std.ArrayListUnmanaged(Item) = .empty,
    bounds: Rect = .empty,
    clip_depth: u32 = 0,
    /// Flattening tolerance of stroke outlines, in canvas units.
    tol: f32 = default_tolerance,

    pub fn init(arena: Allocator) VectorCanvas {
        return .{ .arena = arena };
    }

    /// A new empty path in the canvas's arena.
    pub fn path(c: *VectorCanvas) !*Path {
        const p = try c.arena.create(Path);
        p.* = .{};
        return p;
    }

    pub fn fill(c: *VectorCanvas, p: *const Path, color: Color) !void {
        if (p.isEmpty() or color.a == 0) return;
        try c.items.append(c.arena, .{ .fill = .{ .path = p, .color = color } });
        c.bounds = c.bounds.unite(p.bounds());
    }

    pub fn stroke(c: *VectorCanvas, p: *const Path, style: StrokeStyle, color: Color) !void {
        if (p.isEmpty() or color.a == 0 or !(style.width > 0)) return;
        const outline = try c.arena.create(Path);
        outline.* = try stroke_mod.strokeToFill(c.arena, p, style, c.tol);
        var s = style;
        s.dash = try c.arena.dupe(f32, style.dash);
        try c.items.append(c.arena, .{ .stroke = .{ .path = p, .outline = outline, .style = s, .color = color, .tol = c.tol } });
        c.bounds = c.bounds.unite(outline.bounds());
    }

    pub fn fillRect(c: *VectorCanvas, r: Rect, color: Color) !void {
        const p = try c.path();
        try p.rect(c.arena, r.x0, r.y0, r.width(), r.height());
        try c.fill(p, color);
    }

    pub fn line(c: *VectorCanvas, x0: f32, y0: f32, x1: f32, y1: f32, style: StrokeStyle, color: Color) !void {
        const p = try c.path();
        try p.moveTo(c.arena, x0, y0);
        try p.lineTo(c.arena, x1, y1);
        try c.stroke(p, style, color);
    }

    pub fn circle(c: *VectorCanvas, cx: f32, cy: f32, r: f32, color: Color) !void {
        const p = try c.path();
        try p.circle(c.arena, cx, cy, r);
        try c.fill(p, color);
    }

    pub fn text(c: *VectorCanvas, t: dl_mod.Text) !void {
        var copy = t;
        copy.text = try c.arena.dupe(u8, t.text);
        try c.items.append(c.arena, .{ .text = copy });
        // An estimate (glyph metrics come from E03 when it is drawn).
        const w = @as(f32, @floatFromInt(t.text.len)) * t.size * 0.6;
        c.bounds = c.bounds.include(.{ t.x, t.y - t.size }).include(.{ t.x + w, t.y + t.size * 0.3 });
    }

    pub fn pushClip(c: *VectorCanvas, r: Rect) !void {
        try c.items.append(c.arena, .{ .clip_push = r });
        c.clip_depth += 1;
    }

    pub fn popClip(c: *VectorCanvas) !void {
        if (c.clip_depth == 0) return;
        try c.items.append(c.arena, .clip_pop);
        c.clip_depth -= 1;
    }

    /// The display list (unbalanced clips are closed).
    pub fn finish(c: *VectorCanvas) !dl_mod.DisplayList {
        while (c.clip_depth > 0) try c.popClip();
        return .{ .items = c.items.items, .bounds = c.bounds, .hash = dl_mod.hashItems(c.items.items) };
    }
};
