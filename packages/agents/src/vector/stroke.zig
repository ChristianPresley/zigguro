//! The stroker (E13.F07.S01.T02): a path's outline at a width, as a fill
//! path.
//!
//! The outline is a union of convex pieces, all wound the same way: a
//! quad per segment, a wedge (bevel, miter) or disc (round) per join and
//! a box or disc per cap. Under the non-zero rule, which the coverage
//! rasterizer applies (|area| clamped to 1), the overlaps fill once.
//! Zero-length segments are dropped. A subpath that is a single point
//! gets a round or square cap (butt draws nothing), and a 180° turn gets
//! its join like any other. No NaN reaches the output.

const std = @import("std");
const path_mod = @import("path.zig");
const flatten_mod = @import("flatten.zig");
const dash_mod = @import("dash.zig");

const Allocator = std.mem.Allocator;
const Path = path_mod.Path;
const Affine = path_mod.Affine;
const Polyline = flatten_mod.Polyline;

pub const Join = enum { miter, round, bevel };
pub const Cap = enum { butt, round, square };

pub const StrokeStyle = struct {
    width: f32 = 1,
    join: Join = .miter,
    miter_limit: f32 = 4,
    cap: Cap = .butt,
    dash: []const f32 = &.{},
    dash_offset: f32 = 0,
};

/// The outline of `p` stroked with `s`, flattened within `tolerance`.
pub fn strokeToFill(gpa: Allocator, p: *const Path, s: StrokeStyle, tolerance: f32) !Path {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try flatten_mod.flatten(a, p, .identity, tolerance);
    var out: Path = .{};
    errdefer out.deinit(gpa);
    try strokePolylines(gpa, a, &out, lines, s, tolerance);
    return out;
}

/// Strokes already-flattened polylines into `out`.
pub fn strokePolylines(gpa: Allocator, scratch: Allocator, out: *Path, lines: []const Polyline, s: StrokeStyle, tolerance: f32) !void {
    if (!(s.width > 0) or !std.math.isFinite(s.width)) return;
    const pieces = if (s.dash.len > 0) try dash_mod.dashPolylines(scratch, lines, s.dash, s.dash_offset) else lines;
    var st: Stroker = .{ .gpa = gpa, .out = out, .hw = s.width / 2, .s = s, .tol = @max(tolerance, 1e-3) };
    for (pieces) |pl| try st.polyline(scratch, pl);
}

const Stroker = struct {
    gpa: Allocator,
    out: *Path,
    hw: f32,
    s: StrokeStyle,
    tol: f32,

    fn polyline(st: *Stroker, scratch: Allocator, pl: Polyline) !void {
        // Finite, deduplicated points.
        var pts: std.ArrayListUnmanaged([2]f32) = .empty;
        for (pl.points) |p| {
            if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) continue;
            if (pts.items.len > 0 and same(pts.items[pts.items.len - 1], p)) continue;
            try pts.append(scratch, p);
        }
        var closed = pl.closed;
        if (closed and pts.items.len > 1 and same(pts.items[0], pts.items[pts.items.len - 1])) _ = pts.pop();
        const ps = pts.items;
        if (ps.len == 0) return;
        if (ps.len == 1) {
            // A dot: round and square caps draw it.
            switch (st.s.cap) {
                .butt => {},
                .round => try st.disc(ps[0]),
                .square => try st.poly(&.{
                    .{ ps[0][0] - st.hw, ps[0][1] - st.hw }, .{ ps[0][0] + st.hw, ps[0][1] - st.hw },
                    .{ ps[0][0] + st.hw, ps[0][1] + st.hw }, .{ ps[0][0] - st.hw, ps[0][1] + st.hw },
                }),
            }
            return;
        }
        if (ps.len == 2) closed = false;

        const nseg = if (closed) ps.len else ps.len - 1;
        for (0..nseg) |i| try st.segment(ps[i], ps[(i + 1) % ps.len]);
        // Joins at interior vertices (every vertex when closed).
        if (closed) {
            for (0..ps.len) |i| try st.join(ps[(i + ps.len - 1) % ps.len], ps[i], ps[(i + 1) % ps.len]);
        } else {
            for (1..ps.len - 1) |i| try st.join(ps[i - 1], ps[i], ps[i + 1]);
            try st.cap(ps[0], ps[1]);
            try st.cap(ps[ps.len - 1], ps[ps.len - 2]);
        }
    }

    fn segment(st: *Stroker, p0: [2]f32, p1: [2]f32) !void {
        const n = normal(p0, p1, st.hw);
        try st.poly(&.{
            .{ p0[0] + n[0], p0[1] + n[1] }, .{ p1[0] + n[0], p1[1] + n[1] },
            .{ p1[0] - n[0], p1[1] - n[1] }, .{ p0[0] - n[0], p0[1] - n[1] },
        });
    }

    fn join(st: *Stroker, prev: [2]f32, p: [2]f32, next: [2]f32) !void {
        const d0 = unit(sub(p, prev));
        const d1 = unit(sub(next, p));
        const cross = d0[0] * d1[1] - d0[1] * d1[0];
        const dot = d0[0] * d1[0] + d0[1] * d1[1];
        // Straight on: the segment quads already meet.
        if (@abs(cross) < 1e-6 and dot > 0) return;
        if (st.s.join == .round) return st.disc(p);
        // The outer side is left of a right turn and vice versa.
        const side: f32 = if (cross > 0) -1 else 1;
        const n0 = [2]f32{ -d0[1] * st.hw * side, d0[0] * st.hw * side };
        const n1 = [2]f32{ -d1[1] * st.hw * side, d1[0] * st.hw * side };
        const a = [2]f32{ p[0] + n0[0], p[1] + n0[1] };
        const b = [2]f32{ p[0] + n1[0], p[1] + n1[1] };
        if (st.s.join == .miter) {
            // cos of half the angle between the offset normals.
            const half_cos = @sqrt(@max(0, (1 + dot) / 2));
            if (half_cos > 1e-6 and 1 / half_cos <= st.s.miter_limit) {
                const mx = n0[0] + n1[0];
                const my = n0[1] + n1[1];
                const ml = @sqrt(mx * mx + my * my);
                if (ml > 1e-9) {
                    const len = st.hw / half_cos;
                    const m = [2]f32{ p[0] + mx / ml * len, p[1] + my / ml * len };
                    return st.poly(&.{ p, a, m, b });
                }
            }
        }
        try st.poly(&.{ p, a, b });
    }

    /// The cap at `end`, of the segment coming from `from`.
    fn cap(st: *Stroker, end: [2]f32, from: [2]f32) !void {
        switch (st.s.cap) {
            .butt => {},
            .round => try st.disc(end),
            .square => {
                const d = unit(sub(end, from));
                const n = normal(from, end, st.hw);
                const e = [2]f32{ end[0] + d[0] * st.hw, end[1] + d[1] * st.hw };
                try st.poly(&.{
                    .{ end[0] + n[0], end[1] + n[1] }, .{ e[0] + n[0], e[1] + n[1] },
                    .{ e[0] - n[0], e[1] - n[1] },     .{ end[0] - n[0], end[1] - n[1] },
                });
            },
        }
    }

    /// A disc of radius hw, as a polygon within the tolerance.
    fn disc(st: *Stroker, c: [2]f32) !void {
        const n = discSegments(st.hw, st.tol);
        var buf: [256][2]f32 = undefined;
        for (0..n) |i| {
            const t = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            buf[i] = .{ c[0] + st.hw * @cos(t), c[1] + st.hw * @sin(t) };
        }
        try st.poly(buf[0..n]);
    }

    /// A closed polygon wound with positive area (y down), so every
    /// piece adds to the same winding.
    fn poly(st: *Stroker, pts: []const [2]f32) !void {
        var area: f32 = 0;
        for (pts, 0..) |p, i| {
            const q = pts[(i + 1) % pts.len];
            area += p[0] * q[1] - q[0] * p[1];
        }
        if (!std.math.isFinite(area) or @abs(area) < 1e-12) return;
        const gpa = st.gpa;
        if (area > 0) {
            try st.out.moveTo(gpa, pts[0][0], pts[0][1]);
            for (pts[1..]) |p| try st.out.lineTo(gpa, p[0], p[1]);
        } else {
            try st.out.moveTo(gpa, pts[pts.len - 1][0], pts[pts.len - 1][1]);
            var i = pts.len - 1;
            while (i > 0) {
                i -= 1;
                try st.out.lineTo(gpa, pts[i][0], pts[i][1]);
            }
        }
        try st.out.close(gpa);
    }
};

/// Polygon sides for a circle of radius `r` within `tol`: the sagitta of
/// each side, r(1 - cos(π/n)), stays under `tol`.
pub fn discSegments(r: f32, tol: f32) usize {
    if (!(r > tol)) return 8;
    const n = std.math.pi / std.math.acos(1 - tol / r);
    return @intFromFloat(std.math.clamp(@ceil(n), 8, 256));
}

fn same(a: [2]f32, b: [2]f32) bool {
    return a[0] == b[0] and a[1] == b[1];
}

fn sub(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

fn unit(v: [2]f32) [2]f32 {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1]);
    if (!(l > 0)) return .{ 1, 0 };
    return .{ v[0] / l, v[1] / l };
}

/// The left normal of `p0`→`p1`, of length `len`.
fn normal(p0: [2]f32, p1: [2]f32, len: f32) [2]f32 {
    const d = unit(sub(p1, p0));
    return .{ -d[1] * len, d[0] * len };
}
