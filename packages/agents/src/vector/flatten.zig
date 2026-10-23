//! Flattening (E13.F07.S01.T02): a path's curves as polylines within a
//! tolerance, using E03's flattener (Wang's formula, forward
//! differencing), so glyphs and vector art flatten the same way.

const std = @import("std");
const zg_text = @import("zg_text");
const path_mod = @import("path.zig");

const Allocator = std.mem.Allocator;
const Path = path_mod.Path;
const Affine = path_mod.Affine;

pub const Polyline = struct {
    points: []const [2]f32,
    closed: bool,
};

const Collect = struct {
    a: Allocator,
    pts: *std.ArrayListUnmanaged([2]f32),
    err: ?Allocator.Error = null,

    pub fn segment(c: *Collect, _: [2]f32, p1: [2]f32) void {
        c.pts.append(c.a, p1) catch |e| {
            c.err = e;
        };
    }
};

/// Every subpath of `p`, transformed by `m`, as a polyline whose curves
/// stay within `tol` of the true curves (in transformed units).
/// Consecutive duplicate points are kept (the stroker drops them).
pub fn flatten(a: Allocator, p: *const Path, m: Affine, tol: f32) ![]Polyline {
    var out: std.ArrayListUnmanaged(Polyline) = .empty;
    var cur: std.ArrayListUnmanaged([2]f32) = .empty;
    var c: Collect = .{ .a = a, .pts = &cur };
    var i: usize = 0;
    var last: [2]f32 = .{ 0, 0 };
    for (p.verbs.items) |v| {
        switch (v) {
            .move => {
                if (cur.items.len > 0) try out.append(a, .{ .points = try cur.toOwnedSlice(a), .closed = false });
                last = m.apply(p.points.items[i]);
                try cur.append(a, last);
            },
            .line => {
                last = m.apply(p.points.items[i]);
                try cur.append(a, last);
            },
            .quad => {
                const p1 = m.apply(p.points.items[i]);
                const p2 = m.apply(p.points.items[i + 1]);
                zg_text.raster.flatten.quadTo(&c, last, p1, p2, tol);
                last = p2;
            },
            .cubic => {
                const p1 = m.apply(p.points.items[i]);
                const p2 = m.apply(p.points.items[i + 1]);
                const p3 = m.apply(p.points.items[i + 2]);
                zg_text.raster.flatten.cubicTo(&c, last, p1, p2, p3, tol);
                last = p3;
            },
            .close => {
                if (cur.items.len > 0) try out.append(a, .{ .points = try cur.toOwnedSlice(a), .closed = true });
            },
        }
        if (c.err) |e| return e;
        i += Path.pointCount(v);
    }
    if (cur.items.len > 0) try out.append(a, .{ .points = try cur.toOwnedSlice(a), .closed = false });
    return out.items;
}
