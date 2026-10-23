//! Node shape geometry (E13.F07.S02.T02): a node's box from its label
//! size, each shape's outline, and where an edge meets it.

const std = @import("std");
const ast = @import("../ast.zig");

const Shape = ast.Shape;

/// A node's box: centre `x`, `y`, size `w`, `h`.
pub const NodeBox = struct { node: u32, x: f32, y: f32, w: f32, h: f32 };

pub const pad_x: f32 = 12;
pub const pad_y: f32 = 8;
/// The gap between a double circle's two outlines.
pub const double_gap: f32 = 4;

/// The box size for a label of `label` size drawn as `shape`.
pub fn nodeSize(shape: Shape, label: [2]f32) [2]f32 {
    const w = label[0] + 2 * pad_x;
    const h = label[1] + 2 * pad_y;
    return switch (shape) {
        .rect, .round, .subroutine => .{ w + if (shape == .subroutine) @as(f32, 16) else 0, h },
        .stadium => .{ w + h / 2, h },
        .cylinder => .{ w, h + 8 },
        .circle => .{ @max(w, h), @max(w, h) },
        .double_circle => .{ @max(w, h) + 2 * double_gap, @max(w, h) + 2 * double_gap },
        .rhombus => .{ w * std.math.sqrt2, h * std.math.sqrt2 },
        .hexagon => .{ w + h / 2, h },
        .parallelogram, .parallelogram_alt, .trapezoid, .trapezoid_alt => .{ w + h * 2 / 3, h },
        .asymmetric => .{ w + h / 4, h },
    };
}

/// The outline as a polygon (box-centred coordinates) for the polygon
/// shapes; null for rectangles, circles and the stadium.
pub fn polygon(shape: Shape, w: f32, h: f32, buf: *[6][2]f32) ?[]const [2]f32 {
    const x = w / 2;
    const y = h / 2;
    const m = h / 3;
    const pts: []const [2]f32 = switch (shape) {
        .rhombus => &.{ .{ 0, -y }, .{ x, 0 }, .{ 0, y }, .{ -x, 0 } },
        .hexagon => &.{ .{ -x + h / 4, -y }, .{ x - h / 4, -y }, .{ x, 0 }, .{ x - h / 4, y }, .{ -x + h / 4, y }, .{ -x, 0 } },
        .parallelogram => &.{ .{ -x + m, -y }, .{ x, -y }, .{ x - m, y }, .{ -x, y } },
        .parallelogram_alt => &.{ .{ -x, -y }, .{ x - m, -y }, .{ x, y }, .{ -x + m, y } },
        .trapezoid => &.{ .{ -x + m, -y }, .{ x - m, -y }, .{ x, y }, .{ -x, y } },
        .trapezoid_alt => &.{ .{ -x, -y }, .{ x, -y }, .{ x - m, y }, .{ -x + m, y } },
        .asymmetric => &.{ .{ -x, -y }, .{ x, -y }, .{ x, y }, .{ -x, y }, .{ -x + h / 4, 0 } },
        else => return null,
    };
    @memcpy(buf[0..pts.len], pts);
    return buf[0..pts.len];
}

/// Where the segment from the box's centre toward `toward` leaves the
/// shape's outline (the centre itself when `toward` is the centre).
pub fn shapeBoundary(shape: Shape, box: NodeBox, toward: [2]f32) [2]f32 {
    const dx = toward[0] - box.x;
    const dy = toward[1] - box.y;
    if (dx == 0 and dy == 0) return .{ box.x, box.y };
    const t = rayExit(shape, box.w, box.h, dx, dy);
    return .{ box.x + dx * t, box.y + dy * t };
}

/// The `t` at which centre + t·(dx, dy) meets the outline.
fn rayExit(shape: Shape, w: f32, h: f32, dx: f32, dy: f32) f32 {
    var buf: [6][2]f32 = undefined;
    if (polygon(shape, w, h, &buf)) |poly| return polyExit(poly, dx, dy);
    return switch (shape) {
        .circle, .double_circle => ellipseExit(w / 2, h / 2, dx, dy),
        .stadium => stadiumExit(w, h, dx, dy),
        else => rectExit(w, h, dx, dy),
    };
}

fn rectExit(w: f32, h: f32, dx: f32, dy: f32) f32 {
    const tx = if (dx != 0) (w / 2) / @abs(dx) else std.math.inf(f32);
    const ty = if (dy != 0) (h / 2) / @abs(dy) else std.math.inf(f32);
    return @min(tx, ty);
}

fn ellipseExit(rx: f32, ry: f32, dx: f32, dy: f32) f32 {
    return 1 / @sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry));
}

/// A rectangle with half-circle ends of radius h/2.
fn stadiumExit(w: f32, h: f32, dx: f32, dy: f32) f32 {
    const r = h / 2;
    const t = rectExit(w, h, dx, dy);
    const px = dx * t;
    const inner = w / 2 - r;
    if (@abs(px) <= inner) return t;
    // The ray meets the end circle centred at (±inner, 0).
    const cx = if (px > 0) inner else -inner;
    const a = dx * dx + dy * dy;
    const b = -2 * dx * cx;
    const c = cx * cx - r * r;
    const disc = @max(0, b * b - 4 * a * c);
    return (-b + @sqrt(disc)) / (2 * a);
}

fn polyExit(poly: []const [2]f32, dx: f32, dy: f32) f32 {
    var best = std.math.inf(f32);
    for (poly, 0..) |p, i| {
        const q = poly[(i + 1) % poly.len];
        // Solve t·d = p + s·(q − p), 0 ≤ s ≤ 1.
        const ex = q[0] - p[0];
        const ey = q[1] - p[1];
        const den = dx * ey - dy * ex;
        if (den == 0) continue;
        const t = (p[0] * ey - p[1] * ex) / den;
        const s = (p[0] * dy - p[1] * dx) / den;
        if (t > 0 and s >= -1e-4 and s <= 1 + 1e-4) best = @min(best, t);
    }
    return if (std.math.isFinite(best)) best else rectExit(2 * maxAbs(poly, 0), 2 * maxAbs(poly, 1), dx, dy);
}

fn maxAbs(poly: []const [2]f32, k: usize) f32 {
    var m: f32 = 0;
    for (poly) |p| m = @max(m, @abs(p[k]));
    return m;
}

/// The distance from `p` to the shape's outline (tests and hit checks).
pub fn outlineDistance(shape: Shape, box: NodeBox, p: [2]f32) f32 {
    const x = p[0] - box.x;
    const y = p[1] - box.y;
    var buf: [6][2]f32 = undefined;
    if (polygon(shape, box.w, box.h, &buf)) |poly| {
        var d = std.math.inf(f32);
        for (poly, 0..) |a, i| d = @min(d, segDist(a, poly[(i + 1) % poly.len], .{ x, y }));
        return d;
    }
    return switch (shape) {
        .circle, .double_circle => @abs(@sqrt(x * x + y * y) - box.w / 2),
        .stadium => blk: {
            const r = box.h / 2;
            const inner = box.w / 2 - r;
            if (@abs(x) <= inner) break :blk @abs(@abs(y) - r);
            const cx = if (x > 0) inner else -inner;
            break :blk @abs(@sqrt((x - cx) * (x - cx) + y * y) - r);
        },
        else => @min(
            segDist(.{ -box.w / 2, -box.h / 2 }, .{ box.w / 2, -box.h / 2 }, .{ x, y }),
            @min(
                segDist(.{ box.w / 2, -box.h / 2 }, .{ box.w / 2, box.h / 2 }, .{ x, y }),
                @min(segDist(.{ box.w / 2, box.h / 2 }, .{ -box.w / 2, box.h / 2 }, .{ x, y }), segDist(.{ -box.w / 2, box.h / 2 }, .{ -box.w / 2, -box.h / 2 }, .{ x, y })),
            ),
        ),
    };
}

fn segDist(a: [2]f32, b: [2]f32, p: [2]f32) f32 {
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    const l2 = ex * ex + ey * ey;
    const t = if (l2 == 0) 0 else std.math.clamp(((p[0] - a[0]) * ex + (p[1] - a[1]) * ey) / l2, 0, 1);
    const qx = a[0] + t * ex - p[0];
    const qy = a[1] + t * ey - p[1];
    return @sqrt(qx * qx + qy * qy);
}

test {
    std.testing.refAllDecls(@This());
}
