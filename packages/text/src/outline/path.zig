//! `Path`: a flat glyph outline (verbs plus points, f32 font units) shared by
//! every outline decoder and consumed by the rasterizer. Buffers keep their
//! capacity across `reset`, so a worker that reuses one `Path` stops
//! allocating once it has seen its largest glyph.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One path command. `quad` consumes 2 points (control, end), `cubic` 3
/// (two controls, end), `move` and `line` 1, `close` none.
pub const Verb = enum(u8) { move, line, quad, cubic, close };

/// An axis-aligned rectangle. `empty` has inverted infinite bounds so that
/// `unite` with it is the identity.
pub const Rect = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    /// The rectangle containing nothing.
    pub const empty: Rect = .{ .x0 = std.math.inf(f32), .y0 = std.math.inf(f32), .x1 = -std.math.inf(f32), .y1 = -std.math.inf(f32) };

    /// The smallest rectangle containing `a` and `b`.
    pub fn unite(a: Rect, b: Rect) Rect {
        return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
    }

    /// True when the rectangle contains no point.
    pub fn isEmpty(r: Rect) bool {
        return !(r.x0 <= r.x1 and r.y0 <= r.y1);
    }

    /// `r` grown to contain the point (x, y).
    pub fn include(r: Rect, x: f32, y: f32) Rect {
        return .{ .x0 = @min(r.x0, x), .y0 = @min(r.y0, y), .x1 = @max(r.x1, x), .y1 = @max(r.y1, y) };
    }
};

/// A 2x3 affine map: x' = xx*x + xy*y + dx, y' = yx*x + yy*y + dy.
pub const Affine = struct {
    xx: f32 = 1,
    xy: f32 = 0,
    yx: f32 = 0,
    yy: f32 = 1,
    dx: f32 = 0,
    dy: f32 = 0,

    /// The identity map.
    pub const identity: Affine = .{};

    /// A uniform scale.
    pub fn scale(s: f32) Affine {
        return .{ .xx = s, .yy = s };
    }

    /// `m` applied to (x, y).
    pub inline fn apply(m: Affine, p: [2]f32) [2]f32 {
        return .{ m.xx * p[0] + m.xy * p[1] + m.dx, m.yx * p[0] + m.yy * p[1] + m.dy };
    }

    /// The map that applies `b` first, then `a`.
    pub fn mul(a: Affine, b: Affine) Affine {
        return .{
            .xx = a.xx * b.xx + a.xy * b.yx,
            .xy = a.xx * b.xy + a.xy * b.yy,
            .yx = a.yx * b.xx + a.yy * b.yx,
            .yy = a.yx * b.xy + a.yy * b.yy,
            .dx = a.xx * b.dx + a.xy * b.dy + a.dx,
            .dy = a.yx * b.dx + a.yy * b.dy + a.dy,
        };
    }
};

/// A flat outline. Contours start with `move` and end with `close`, which
/// implies a straight segment back to the contour's start (decoders leave a
/// closing line to it, as fontTools pens do). `bounds` is the control box
/// (all points, on- and off-curve).
pub const Path = struct {
    verbs: std.ArrayList(Verb) = .empty,
    points: std.ArrayList([2]f32) = .empty,
    bounds: Rect = .empty,
    /// True between a `move` and its `close`.
    open: bool = false,

    /// Frees the buffers.
    pub fn deinit(p: *Path, gpa: Allocator) void {
        p.verbs.deinit(gpa);
        p.points.deinit(gpa);
        p.* = .{};
    }

    /// Empties the path, keeping capacity.
    pub fn reset(p: *Path) void {
        p.verbs.clearRetainingCapacity();
        p.points.clearRetainingCapacity();
        p.bounds = .empty;
        p.open = false;
    }

    /// Reserves room for `verbs` more verbs and `points` more points, so the
    /// `*Assume` calls that follow cannot fail.
    pub fn ensureUnused(p: *Path, gpa: Allocator, verbs: usize, points: usize) Allocator.Error!void {
        try p.verbs.ensureUnusedCapacity(gpa, verbs);
        try p.points.ensureUnusedCapacity(gpa, points);
    }

    /// Starts a contour at (x, y), closing any open one.
    pub fn moveTo(p: *Path, gpa: Allocator, x: f32, y: f32) Allocator.Error!void {
        try p.ensureUnused(gpa, 2, 1);
        p.moveToAssume(x, y);
    }

    /// A straight segment to (x, y).
    pub fn lineTo(p: *Path, gpa: Allocator, x: f32, y: f32) Allocator.Error!void {
        try p.ensureUnused(gpa, 1, 1);
        p.lineToAssume(x, y);
    }

    /// A quadratic segment with control (cx, cy) ending at (x, y).
    pub fn quadTo(p: *Path, gpa: Allocator, cx: f32, cy: f32, x: f32, y: f32) Allocator.Error!void {
        try p.ensureUnused(gpa, 1, 2);
        p.quadToAssume(cx, cy, x, y);
    }

    /// A cubic segment with controls (c1x, c1y), (c2x, c2y) ending at (x, y).
    pub fn cubicTo(p: *Path, gpa: Allocator, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) Allocator.Error!void {
        try p.ensureUnused(gpa, 1, 3);
        p.cubicToAssume(c1x, c1y, c2x, c2y, x, y);
    }

    /// Ends the open contour, if any.
    pub fn close(p: *Path, gpa: Allocator) Allocator.Error!void {
        try p.ensureUnused(gpa, 1, 0);
        p.closeAssume();
    }

    /// `moveTo` without allocating; see `ensureUnused`.
    pub fn moveToAssume(p: *Path, x: f32, y: f32) void {
        p.closeAssume();
        p.verbs.appendAssumeCapacity(.move);
        p.point(x, y);
        p.open = true;
    }

    /// `lineTo` without allocating.
    pub fn lineToAssume(p: *Path, x: f32, y: f32) void {
        p.verbs.appendAssumeCapacity(.line);
        p.point(x, y);
    }

    /// `quadTo` without allocating.
    pub fn quadToAssume(p: *Path, cx: f32, cy: f32, x: f32, y: f32) void {
        p.verbs.appendAssumeCapacity(.quad);
        p.point(cx, cy);
        p.point(x, y);
    }

    /// `cubicTo` without allocating.
    pub fn cubicToAssume(p: *Path, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        p.verbs.appendAssumeCapacity(.cubic);
        p.point(c1x, c1y);
        p.point(c2x, c2y);
        p.point(x, y);
    }

    /// `close` without allocating.
    pub fn closeAssume(p: *Path) void {
        if (!p.open) return;
        p.verbs.appendAssumeCapacity(.close);
        p.open = false;
    }

    inline fn point(p: *Path, x: f32, y: f32) void {
        p.points.appendAssumeCapacity(.{ x, y });
        p.bounds = p.bounds.include(x, y);
    }

    /// Maps every point through `m` and recomputes the bounds.
    pub fn transform(p: *Path, m: Affine) void {
        var b: Rect = .empty;
        for (p.points.items) |*pt| {
            pt.* = m.apply(pt.*);
            b = b.include(pt[0], pt[1]);
        }
        p.bounds = b;
    }

    /// Number of points each verb consumes.
    pub fn pointCount(v: Verb) u2 {
        return switch (v) {
            .move, .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
    }

    /// Writes the path as SVG-like text ("M x y L x y Q cx cy x y C ... Z"),
    /// the format of the outline goldens and `text-dump outline`.
    pub fn format(p: *const Path, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        for (p.verbs.items, 0..) |v, k| {
            if (k != 0) try w.writeByte(' ');
            try w.writeByte(switch (v) {
                .move => 'M',
                .line => 'L',
                .quad => 'Q',
                .cubic => 'C',
                .close => 'Z',
            });
            for (0..pointCount(v)) |_| {
                const pt = p.points.items[i];
                i += 1;
                try w.print(" {d} {d}", .{ pt[0], pt[1] });
            }
        }
    }
};

const testing = std.testing;

test "path builder and bounds" {
    const gpa = testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    try testing.expect(p.bounds.isEmpty());
    try p.moveTo(gpa, 0, 0);
    try p.lineTo(gpa, 10, 0);
    try p.quadTo(gpa, 15, 5, 10, 10);
    try p.cubicTo(gpa, 5, 12, 0, 12, -1, 10);
    try p.close(gpa);
    try p.close(gpa); // no-op: already closed
    try testing.expectEqualSlices(Verb, &.{ .move, .line, .quad, .cubic, .close }, p.verbs.items);
    try testing.expectEqual(@as(usize, 7), p.points.items.len);
    try testing.expectEqual(Rect{ .x0 = -1, .y0 = 0, .x1 = 15, .y1 = 12 }, p.bounds);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.format(&w);
    try testing.expectEqualStrings("M 0 0 L 10 0 Q 15 5 10 10 C 5 12 0 12 -1 10 Z", w.buffered());
}

test "moveTo closes the open contour" {
    const gpa = testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    try p.moveTo(gpa, 0, 0);
    try p.lineTo(gpa, 1, 0);
    try p.moveTo(gpa, 5, 5);
    try p.close(gpa);
    try testing.expectEqualSlices(Verb, &.{ .move, .line, .close, .move, .close }, p.verbs.items);
}

test "transform and reset keep capacity" {
    const gpa = testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    try p.moveTo(gpa, 1, 2);
    try p.lineTo(gpa, 3, 4);
    p.transform(.{ .xx = 2, .yy = -1, .dx = 1, .dy = 0 });
    try testing.expectEqual([2]f32{ 3, -2 }, p.points.items[0]);
    try testing.expectEqual(Rect{ .x0 = 3, .y0 = -4, .x1 = 7, .y1 = -2 }, p.bounds);
    const cap = p.points.capacity;
    p.reset();
    try testing.expect(p.bounds.isEmpty());
    try testing.expectEqual(cap, p.points.capacity);
    // Warm path: no allocation.
    try p.moveTo(testing.failing_allocator, 0, 0);
    try p.lineTo(testing.failing_allocator, 1, 1);
}

test "affine compose" {
    const a: Affine = .{ .xx = 2, .yy = 2, .dx = 1 };
    const b: Affine = .{ .xx = 0, .xy = -1, .yx = 1, .yy = 0, .dy = 3 };
    const p = [2]f32{ 5, 7 };
    try testing.expectEqual(a.apply(b.apply(p)), a.mul(b).apply(p));
    try testing.expectEqual(p, Affine.identity.apply(p));
    try testing.expect(Rect.unite(.empty, .{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }).x0 == 1);
}
