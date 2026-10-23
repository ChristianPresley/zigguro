//! Node outlines (E13.F07.S02.T03): each Mermaid shape as a vector path
//! over its laid-out box, plus the inner lines some shapes draw
//! (subroutine bars, a cylinder's lid, a double circle's inner ring).
//! Polygons come from the layout's own geometry, so edges meet exactly
//! the outline that is drawn.

const std = @import("std");
const zg_diagram = @import("zg_diagram");
const vector = @import("../vector/root.zig");

const Allocator = std.mem.Allocator;
const Path = vector.Path;
const Shape = zg_diagram.Shape;
const NodeBox = zg_diagram.NodeBox;
const geom = zg_diagram.layout_mod.shapes_geom;

/// Cubic control distance for a quarter ellipse.
const kappa: f32 = 0.5522848;
pub const round_r: f32 = 5;
pub const subroutine_inset: f32 = 8;
/// The vertical radius of a cylinder's ellipses (the layout adds 2× to
/// its height).
pub const cylinder_ry: f32 = 4;

/// The filled outline of `shape` over `box` (centre and size).
pub fn outline(a: Allocator, p: *Path, shape: Shape, box: NodeBox) !void {
    const x0 = box.x - box.w / 2;
    const y0 = box.y - box.h / 2;
    var buf: [6][2]f32 = undefined;
    if (geom.polygon(shape, box.w, box.h, &buf)) |poly| {
        for (poly, 0..) |pt, i| {
            if (i == 0) try p.moveTo(a, box.x + pt[0], box.y + pt[1]) else try p.lineTo(a, box.x + pt[0], box.y + pt[1]);
        }
        return p.close(a);
    }
    switch (shape) {
        .round => try p.roundRect(a, x0, y0, box.w, box.h, round_r),
        .stadium => try p.roundRect(a, x0, y0, box.w, box.h, box.h / 2),
        .circle, .double_circle => try p.circle(a, box.x, box.y, @min(box.w, box.h) / 2),
        .cylinder => {
            const rx = box.w / 2;
            const ry = cylinder_ry;
            const x1 = x0 + box.w;
            const y1 = y0 + box.h;
            try p.moveTo(a, x0, y0 + ry);
            try p.lineTo(a, x0, y1 - ry);
            try halfEllipse(a, p, box.x, y1 - ry, rx, ry, true);
            try p.lineTo(a, x1, y0 + ry);
            try halfEllipse(a, p, box.x, y0 + ry, rx, ry, false);
            try p.close(a);
        },
        else => try p.rect(a, x0, y0, box.w, box.h),
    }
}

/// Lines drawn inside the outline (stroked, not filled); empty for most
/// shapes.
pub fn innerLines(a: Allocator, p: *Path, shape: Shape, box: NodeBox) !void {
    const x0 = box.x - box.w / 2;
    const y0 = box.y - box.h / 2;
    switch (shape) {
        .subroutine => {
            try p.moveTo(a, x0 + subroutine_inset, y0);
            try p.lineTo(a, x0 + subroutine_inset, y0 + box.h);
            try p.moveTo(a, x0 + box.w - subroutine_inset, y0);
            try p.lineTo(a, x0 + box.w - subroutine_inset, y0 + box.h);
        },
        .cylinder => {
            // The near half of the lid.
            try p.moveTo(a, x0, y0 + cylinder_ry);
            try halfEllipse(a, p, box.x, y0 + cylinder_ry, box.w / 2, cylinder_ry, true);
        },
        .double_circle => try p.circle(a, box.x, box.y, @min(box.w, box.h) / 2 - geom.double_gap),
        else => {},
    }
}

/// Half an ellipse centred at (`cx`, `cy`): the lower half from left to
/// right (`lower`), or the upper half from right to left. The pen must
/// be at the start.
fn halfEllipse(a: Allocator, p: *Path, cx: f32, cy: f32, rx: f32, ry: f32, lower: bool) !void {
    const s: f32 = if (lower) 1 else -1;
    const kx = rx * kappa;
    const ky = ry * kappa;
    // From (cx - s·rx, cy) through (cx, cy + s·ry) to (cx + s·rx, cy).
    try p.cubicTo(a, cx - s * rx, cy + s * ky, cx - s * kx, cy + s * ry, cx, cy + s * ry);
    try p.cubicTo(a, cx + s * kx, cy + s * ry, cx + s * rx, cy + s * ky, cx + s * rx, cy);
}

test "every shape has an outline inside its box" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const box: NodeBox = .{ .node = 0, .x = 100, .y = 50, .w = 80, .h = 40 };
    for (std.enums.values(Shape)) |sh| {
        var p: Path = .{};
        try outline(a, &p, sh, box);
        try std.testing.expect(!p.isEmpty());
        const b = p.bounds();
        try std.testing.expect(b.x0 >= 60 - 0.01 and b.x1 <= 140 + 0.01 and b.y0 >= 30 - 0.01 and b.y1 <= 70 + 0.01);
        var inner: Path = .{};
        try innerLines(a, &inner, sh, box);
        const want_inner = sh == .subroutine or sh == .cylinder or sh == .double_circle;
        try std.testing.expectEqual(want_inner, !inner.isEmpty());
    }
}
