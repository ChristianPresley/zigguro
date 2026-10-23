//! Paths for the vector canvas (E13.F07.S01.T02): move/line/quadratic/
//! cubic/close verbs over f32 points, with arcs, rectangles, rounded
//! rectangles and circles built from them (arcs as cubics of at most
//! 90°).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Verb = enum(u8) { move, line, quad, cubic, close };

pub const Rect = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    pub const empty: Rect = .{ .x0 = std.math.inf(f32), .y0 = std.math.inf(f32), .x1 = -std.math.inf(f32), .y1 = -std.math.inf(f32) };

    pub fn xywh(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h };
    }

    pub fn isEmpty(r: Rect) bool {
        return !(r.x0 < r.x1 and r.y0 < r.y1);
    }

    pub fn include(r: Rect, p: [2]f32) Rect {
        return .{ .x0 = @min(r.x0, p[0]), .y0 = @min(r.y0, p[1]), .x1 = @max(r.x1, p[0]), .y1 = @max(r.y1, p[1]) };
    }

    pub fn unite(a: Rect, b: Rect) Rect {
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        return .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    }

    pub fn inflate(r: Rect, d: f32) Rect {
        return .{ .x0 = r.x0 - d, .y0 = r.y0 - d, .x1 = r.x1 + d, .y1 = r.y1 + d };
    }

    pub fn width(r: Rect) f32 {
        return r.x1 - r.x0;
    }

    pub fn height(r: Rect) f32 {
        return r.y1 - r.y0;
    }
};

/// `x' = a x + c y + e`, `y' = b x + d y + f` (SVG's matrix order).
pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Affine = .{};

    pub fn scaleTranslate(s: f32, tx: f32, ty: f32) Affine {
        return .{ .a = s, .d = s, .e = tx, .f = ty };
    }

    pub fn apply(m: Affine, p: [2]f32) [2]f32 {
        return .{ m.a * p[0] + m.c * p[1] + m.e, m.b * p[0] + m.d * p[1] + m.f };
    }
};

pub const Path = struct {
    verbs: std.ArrayListUnmanaged(Verb) = .empty,
    points: std.ArrayListUnmanaged([2]f32) = .empty,
    /// Where the current subpath started (for `close`).
    start: [2]f32 = .{ 0, 0 },

    pub fn deinit(p: *Path, gpa: Allocator) void {
        p.verbs.deinit(gpa);
        p.points.deinit(gpa);
        p.* = .{};
    }

    pub fn clone(p: *const Path, gpa: Allocator) !Path {
        return .{ .verbs = try p.verbs.clone(gpa), .points = try p.points.clone(gpa), .start = p.start };
    }

    pub fn isEmpty(p: *const Path) bool {
        return p.verbs.items.len == 0;
    }

    /// The last point, if any.
    pub fn current(p: *const Path) ?[2]f32 {
        if (p.verbs.items.len > 0 and p.verbs.items[p.verbs.items.len - 1] == .close) return p.start;
        if (p.points.items.len == 0) return null;
        return p.points.items[p.points.items.len - 1];
    }

    pub fn moveTo(p: *Path, gpa: Allocator, x: f32, y: f32) !void {
        try p.verbs.append(gpa, .move);
        try p.points.append(gpa, .{ x, y });
        p.start = .{ x, y };
    }

    /// A line from the current point (a `moveTo` when there is none).
    pub fn lineTo(p: *Path, gpa: Allocator, x: f32, y: f32) !void {
        if (p.current() == null) return p.moveTo(gpa, x, y);
        try p.ensureOpen(gpa);
        try p.verbs.append(gpa, .line);
        try p.points.append(gpa, .{ x, y });
    }

    pub fn quadTo(p: *Path, gpa: Allocator, cx: f32, cy: f32, x: f32, y: f32) !void {
        try p.ensureOpen(gpa);
        try p.verbs.append(gpa, .quad);
        try p.points.appendSlice(gpa, &.{ .{ cx, cy }, .{ x, y } });
    }

    pub fn cubicTo(p: *Path, gpa: Allocator, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) !void {
        try p.ensureOpen(gpa);
        try p.verbs.append(gpa, .cubic);
        try p.points.appendSlice(gpa, &.{ .{ c1x, c1y }, .{ c2x, c2y }, .{ x, y } });
    }

    /// After a `close`, drawing continues from the subpath's start.
    fn ensureOpen(p: *Path, gpa: Allocator) !void {
        if (p.verbs.items.len == 0) return p.moveTo(gpa, 0, 0);
        if (p.verbs.items[p.verbs.items.len - 1] == .close) try p.moveTo(gpa, p.start[0], p.start[1]);
    }

    pub fn close(p: *Path, gpa: Allocator) !void {
        if (p.verbs.items.len == 0 or p.verbs.items[p.verbs.items.len - 1] == .close) return;
        try p.verbs.append(gpa, .close);
    }

    /// An arc of the circle at (`cx`, `cy`) with radius `r` from angle
    /// `a0` to `a1` (radians, clockwise on screen when `a1 > a0`), joined
    /// to the current point by a line (or starting a subpath).
    pub fn arcTo(p: *Path, gpa: Allocator, cx: f32, cy: f32, r: f32, a0: f32, a1: f32) !void {
        const sx = cx + r * @cos(a0);
        const sy = cy + r * @sin(a0);
        if (p.current() == null or p.verbs.items[p.verbs.items.len - 1] == .close) {
            try p.moveTo(gpa, sx, sy);
        } else if (@abs(p.current().?[0] - sx) > 1e-4 or @abs(p.current().?[1] - sy) > 1e-4) {
            try p.lineTo(gpa, sx, sy);
        }
        const sweep = a1 - a0;
        if (sweep == 0 or r == 0) return;
        const n: u32 = @intFromFloat(@max(1, @ceil(@abs(sweep) / (std.math.pi / 2.0) - 1e-6)));
        const step = sweep / @as(f32, @floatFromInt(n));
        // Control distance for a cubic approximating an arc of `step`.
        const k = 4.0 / 3.0 * @tan(step / 4);
        var a = a0;
        for (0..n) |_| {
            const b = a + step;
            const ca = @cos(a);
            const sa = @sin(a);
            const cb = @cos(b);
            const sb = @sin(b);
            try p.cubicTo(gpa, cx + r * (ca - k * sa), cy + r * (sa + k * ca), cx + r * (cb + k * sb), cy + r * (sb - k * cb), cx + r * cb, cy + r * sb);
            a = b;
        }
    }

    /// A closed rectangle (clockwise on screen).
    pub fn rect(p: *Path, gpa: Allocator, x: f32, y: f32, w: f32, h: f32) !void {
        try p.moveTo(gpa, x, y);
        try p.lineTo(gpa, x + w, y);
        try p.lineTo(gpa, x + w, y + h);
        try p.lineTo(gpa, x, y + h);
        try p.close(gpa);
    }

    /// A closed rectangle with corners of radius `r` (clamped to half the
    /// shorter side).
    pub fn roundRect(p: *Path, gpa: Allocator, x: f32, y: f32, w: f32, h: f32, r_in: f32) !void {
        const r = @max(0, @min(r_in, @min(@abs(w), @abs(h)) / 2));
        if (r == 0) return p.rect(gpa, x, y, w, h);
        const pi = std.math.pi;
        try p.moveTo(gpa, x + r, y);
        try p.arcTo(gpa, x + w - r, y + r, r, -pi / 2.0, 0);
        try p.arcTo(gpa, x + w - r, y + h - r, r, 0, pi / 2.0);
        try p.arcTo(gpa, x + r, y + h - r, r, pi / 2.0, pi);
        try p.arcTo(gpa, x + r, y + r, r, pi, 3 * pi / 2.0);
        try p.close(gpa);
    }

    /// A closed circle (clockwise on screen).
    pub fn circle(p: *Path, gpa: Allocator, cx: f32, cy: f32, r: f32) !void {
        try p.moveTo(gpa, cx + r, cy);
        try p.arcTo(gpa, cx, cy, r, 0, 2 * std.math.pi);
        try p.close(gpa);
    }

    /// The bounds of every point (control points included, so it may be
    /// a little larger than the curves).
    pub fn bounds(p: *const Path) Rect {
        var r: Rect = .empty;
        for (p.points.items) |pt| r = r.include(pt);
        return r;
    }

    pub fn transform(p: *Path, m: Affine) void {
        for (p.points.items) |*pt| pt.* = m.apply(pt.*);
        p.start = m.apply(p.start);
    }

    pub fn hash(p: *const Path, h: *std.hash.Wyhash) void {
        h.update(std.mem.sliceAsBytes(p.verbs.items));
        h.update(std.mem.sliceAsBytes(p.points.items));
    }

    pub fn pointCount(v: Verb) usize {
        return switch (v) {
            .move, .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
    }
};
