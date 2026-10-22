//! Outline emboldening for synthetic bold and stem darkening. Every point
//! (on- and off-curve, as FreeType's `FT_Outline_EmboldenXY` treats them)
//! moves outward along the bisector of its two edge normals by
//! `d / max(cos(theta/2), 0.25)`, a miter with a limit of 4.
//!
//! "Outward" follows the orientation of the whole outline (the sign of its
//! total area), not of each contour, so outer contours grow and holes
//! shrink whichever winding convention the font uses.

const std = @import("std");
const Path = @import("../outline/path.zig").Path;
const Verb = @import("../outline/path.zig").Verb;

/// Most pixels stem darkening adds per side.
pub const stem_darkening_max_px: f32 = 0.3;

/// Stem darkening per side in font units: 0.3 px at 9 px per em and
/// below, falling linearly to 0 at 24 px.
pub fn stemDarkeningAmount(px_per_em: f32, units_per_em: u16) f32 {
    if (!(px_per_em > 0)) return 0;
    const px = stem_darkening_max_px * std.math.clamp((24 - px_per_em) / 15, 0, 1);
    return px * @as(f32, @floatFromInt(units_per_em)) / px_per_em;
}

/// Synthetic bold per side in font units (horizontal only).
pub fn syntheticBoldAmount(units_per_em: u16) f32 {
    return @as(f32, @floatFromInt(units_per_em)) / 48;
}

/// How much synthetic bold widens the advance, in font units.
pub fn syntheticBoldAdvance(units_per_em: u16) f32 {
    return 2 * syntheticBoldAmount(units_per_em);
}

/// Contour point ranges of `path`: the points from each `move` up to the
/// next `move` or the end.
const ContourIter = struct {
    verbs: []const Verb,
    vi: usize = 0,
    pi: usize = 0,

    fn next(it: *ContourIter) ?[2]usize {
        while (it.vi < it.verbs.len and it.verbs[it.vi] != .move) : (it.vi += 1) it.pi += Path.pointCount(it.verbs[it.vi]);
        if (it.vi >= it.verbs.len) return null;
        const start = it.pi;
        it.pi += 1;
        it.vi += 1;
        while (it.vi < it.verbs.len and it.verbs[it.vi] != .move) : (it.vi += 1) it.pi += Path.pointCount(it.verbs[it.vi]);
        return .{ start, it.pi };
    }
};

/// Twice the signed area of the closed polygon through `pts`.
fn area2(pts: []const [2]f32) f64 {
    var a: f64 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        a += @as(f64, p[0]) * q[1] - @as(f64, q[0]) * p[1];
    }
    return a;
}

fn normalize(v: [2]f32) ?[2]f32 {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1]);
    if (!(l > 0) or !std.math.isFinite(l)) return null;
    return .{ v[0] / l, v[1] / l };
}

/// Moves every point of `path` outward by `dx` horizontally and `dy`
/// vertically (font units, per side), then recomputes the bounds. The
/// path is changed in place and nothing is allocated.
pub fn embolden(path: *Path, dx: f32, dy: f32) void {
    if (dx == 0 and dy == 0) return;
    const pts = path.points.items;
    var total: f64 = 0;
    var it: ContourIter = .{ .verbs = path.verbs.items };
    while (it.next()) |r| total += area2(pts[r[0]..r[1]]);
    if (total == 0 or !std.math.isFinite(total)) return;
    // y up: positive area is counter-clockwise, interior on the left, so
    // the outward normal of direction (x, y) is (y, -x).
    const sgn: f32 = if (total > 0) 1 else -1;
    it = .{ .verbs = path.verbs.items };
    while (it.next()) |r| {
        var c = pts[r[0]..r[1]];
        // A contour that returns to its start repeats that point; move
        // the copy with the original.
        const dup_end = c.len > 1 and std.meta.eql(c[0], c[c.len - 1]);
        if (dup_end) c = c[0 .. c.len - 1];
        if (c.len < 2) continue;
        const first = c[0];
        // `run` is the original of the latest distinct point and `prev`
        // the one before it, so repeated points share their neighbours.
        var run = c[c.len - 1];
        var k = c.len - 1;
        while (k > 0 and std.meta.eql(run, first)) : (k -= 1) run = c[k - 1];
        var prev = run;
        for (c, 0..) |*p, i| {
            const cur = p.*;
            if (!std.meta.eql(cur, run)) {
                prev = run;
                run = cur;
            }
            var j = i + 1;
            var nxt = if (j < c.len) c[j] else first;
            while (j < c.len and std.meta.eql(nxt, cur)) {
                j += 1;
                nxt = if (j < c.len) c[j] else first;
            }
            const in_d = normalize(.{ cur[0] - prev[0], cur[1] - prev[1] });
            const out_d = normalize(.{ nxt[0] - cur[0], nxt[1] - cur[1] });
            if (in_d != null and out_d != null) {
                const n_in = [2]f32{ in_d.?[1] * sgn, -in_d.?[0] * sgn };
                const n_out = [2]f32{ out_d.?[1] * sgn, -out_d.?[0] * sgn };
                if (normalize(.{ n_in[0] + n_out[0], n_in[1] + n_out[1] })) |b| {
                    const cos_half = b[0] * n_in[0] + b[1] * n_in[1];
                    const s = 1 / @max(cos_half, 0.25);
                    p.* = .{ cur[0] + b[0] * s * dx, cur[1] + b[1] * s * dy };
                }
            }
        }
        if (dup_end) pts[r[1] - 1] = c[0];
    }
    var b: @TypeOf(path.bounds) = .empty;
    for (pts) |p| b = b.include(p[0], p[1]);
    path.bounds = b;
}

const testing = std.testing;

fn pathArea(p: *const Path) f64 {
    var total: f64 = 0;
    var it: ContourIter = .{ .verbs = p.verbs.items };
    while (it.next()) |r| total += area2(p.points.items[r[0]..r[1]]);
    return total / 2;
}

fn square(gpa: std.mem.Allocator, p: *Path, x0: f32, y0: f32, x1: f32, y1: f32, ccw: bool) !void {
    try p.moveTo(gpa, x0, y0);
    if (ccw) {
        try p.lineTo(gpa, x1, y0);
        try p.lineTo(gpa, x1, y1);
        try p.lineTo(gpa, x0, y1);
    } else {
        try p.lineTo(gpa, x0, y1);
        try p.lineTo(gpa, x1, y1);
        try p.lineTo(gpa, x1, y0);
    }
    try p.close(gpa);
}

test "embolden square grows by 2d" {
    const gpa = testing.allocator;
    for ([_]bool{ true, false }) |ccw| {
        var p: Path = .{};
        defer p.deinit(gpa);
        try square(gpa, &p, 0, 0, 100, 100, ccw);
        embolden(&p, 5, 5);
        try testing.expectApproxEqAbs(@as(f64, 110 * 110), @abs(pathArea(&p)), 1e-2);
        try testing.expectApproxEqAbs(@as(f32, -5), p.bounds.x0, 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 105), p.bounds.y1, 1e-4);
        // x only: width grows by 2d, height stays.
        p.reset();
        try square(gpa, &p, 0, 0, 100, 100, ccw);
        embolden(&p, 4, 0);
        try testing.expectApproxEqAbs(@as(f32, 108), p.bounds.x1 - p.bounds.x0, 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 100), p.bounds.y1 - p.bounds.y0, 1e-4);
    }
}

test "embolden preserves holes orientation" {
    const gpa = testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    // TrueType convention: outer clockwise, hole counter-clockwise.
    try square(gpa, &p, 0, 0, 100, 100, false);
    try square(gpa, &p, 30, 30, 70, 70, true);
    embolden(&p, 5, 5);
    // Outer 110², hole shrinks to 30²; signs keep their orientation.
    try testing.expectApproxEqAbs(@as(f64, -(110 * 110) + 30 * 30), pathArea(&p), 1e-2);
    const hole = p.points.items[4..8];
    try testing.expect(area2(hole) > 0);
    try testing.expectApproxEqAbs(@as(f32, 35), hole[0][0], 1e-4);
}

test "duplicate and closing points move together" {
    const gpa = testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    try p.moveTo(gpa, 0, 0);
    try p.lineTo(gpa, 10, 0);
    try p.lineTo(gpa, 10, 0);
    try p.lineTo(gpa, 10, 10);
    try p.lineTo(gpa, 0, 10);
    try p.lineTo(gpa, 0, 0);
    try p.close(gpa);
    embolden(&p, 1, 1);
    const q = p.points.items;
    try testing.expectEqual(q[1], q[2]);
    try testing.expectEqual(q[0], q[5]);
    try testing.expectApproxEqAbs(@as(f32, -1), q[0][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), q[0][1], 1e-5);
}

test "stem darkening zero above 24px" {
    try testing.expectEqual(@as(f32, 0), stemDarkeningAmount(24, 1000));
    try testing.expectEqual(@as(f32, 0), stemDarkeningAmount(40, 1000));
    // 0.3 px at 9 px per em and below.
    try testing.expectApproxEqAbs(@as(f32, 0.3 * 1000 / 9.0), stemDarkeningAmount(9, 1000), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.3 * 1000 / 6.0), stemDarkeningAmount(6, 1000), 1e-3);
    // Halfway: 16.5 px gives 0.15 px.
    try testing.expectApproxEqAbs(@as(f32, 0.15 * 2048 / 16.5), stemDarkeningAmount(16.5, 2048), 1e-3);
    try testing.expectEqual(@as(f32, 0), stemDarkeningAmount(0, 1000));
}
