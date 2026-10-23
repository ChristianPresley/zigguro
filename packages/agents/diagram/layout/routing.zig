//! Edge routing (E13.F07.S02.T02): a polyline through an edge's dummy
//! positions, cut where it meets its end nodes' outlines (or an end
//! cluster's box), smoothed into cubic Bézier segments (Catmull-Rom,
//! tension 0.5).

const std = @import("std");
const ast = @import("../ast.zig");
const shapes_geom = @import("shapes_geom.zig");

const Allocator = std.mem.Allocator;
const NodeBox = shapes_geom.NodeBox;

pub const Rect = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// Cubic Bézier control points through `pts` (3·(n−1)+1 of them): a
/// straight cubic for two points, Catmull-Rom segments otherwise.
pub fn bezier(a: Allocator, pts: []const [2]f32) ![]const [2]f32 {
    if (pts.len < 2) return a.dupe([2]f32, pts);
    const out = try a.alloc([2]f32, 3 * (pts.len - 1) + 1);
    out[0] = pts[0];
    const last = pts.len - 1;
    for (0..last) |i| {
        const p0 = pts[if (i == 0) 0 else i - 1];
        const p1 = pts[i];
        const p2 = pts[i + 1];
        const p3 = pts[@min(i + 2, last)];
        if (pts.len == 2) {
            out[1] = lerp(p1, p2, 1.0 / 3.0);
            out[2] = lerp(p1, p2, 2.0 / 3.0);
        } else {
            out[3 * i + 1] = .{ p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6 };
            out[3 * i + 2] = .{ p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6 };
        }
        out[3 * i + 3] = p2;
    }
    return out;
}

fn lerp(p: [2]f32, q: [2]f32, t: f32) [2]f32 {
    return .{ p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t };
}

fn inside(r: Rect, p: [2]f32) bool {
    return p[0] > r.x0 and p[0] < r.x1 and p[1] > r.y0 and p[1] < r.y1;
}

/// Cuts the polyline where it first enters `r` coming from its other
/// end (`at_end`: the box holds the last point, else the first). False
/// when the whole polyline is inside the box.
pub fn clipToRect(pts: *std.ArrayList([2]f32), r: Rect, at_end: bool) bool {
    const p = pts.items;
    if (p.len < 2) return false;
    if (at_end) std.mem.reverse([2]f32, p);
    defer if (at_end) std.mem.reverse([2]f32, pts.items);
    // Now the box holds p[0]; walk back from the far end.
    var i = p.len - 1;
    if (inside(r, p[i])) return false;
    while (i > 0) : (i -= 1) {
        if (!inside(r, p[i - 1])) continue;
        // Segment p[i] (outside) → p[i-1] (inside) crosses the border.
        const hit = segRect(p[i], p[i - 1], r);
        p[i - 1] = hit;
        // Drop the points inside: keep p[i-1 ..].
        const keep = p.len - (i - 1);
        std.mem.copyForwards([2]f32, p[0..keep], p[i - 1 ..]);
        pts.items.len = keep;
        return true;
    }
    return false;
}

/// Where the segment from `o` (outside) to `q` (inside) meets the
/// border of `r`.
fn segRect(o: [2]f32, q: [2]f32, r: Rect) [2]f32 {
    var lo: f32 = 0;
    var hi: f32 = 1;
    for (0..40) |_| {
        const m = (lo + hi) / 2;
        if (inside(r, lerp(o, q, m))) hi = m else lo = m;
    }
    return lerp(o, q, hi);
}

/// A self-loop on the side `dir` points to (+x, or +y when `down`).
pub fn selfLoop(a: Allocator, shape: ast.Shape, b: NodeBox, size: f32, down: bool) ![]const [2]f32 {
    const out = try a.alloc([2]f32, 4);
    if (!down) {
        const s0 = shapes_geom.shapeBoundary(shape, b, .{ b.x + b.w, b.y - b.h / 4 });
        const s1 = shapes_geom.shapeBoundary(shape, b, .{ b.x + b.w, b.y + b.h / 4 });
        out[0] = s0;
        out[1] = .{ s0[0] + size * 1.6, s0[1] - size * 0.6 };
        out[2] = .{ s1[0] + size * 1.6, s1[1] + size * 0.6 };
        out[3] = s1;
    } else {
        const s0 = shapes_geom.shapeBoundary(shape, b, .{ b.x + b.w / 4, b.y + b.h });
        const s1 = shapes_geom.shapeBoundary(shape, b, .{ b.x - b.w / 4, b.y + b.h });
        out[0] = s0;
        out[1] = .{ s0[0] + size * 0.6, s0[1] + size * 1.6 };
        out[2] = .{ s1[0] - size * 0.6, s1[1] + size * 1.6 };
        out[3] = s1;
    }
    return out;
}

test {
    std.testing.refAllDecls(@This());
}
