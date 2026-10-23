//! Flattening, stroking and dashing: error bounds, join and cap goldens,
//! dash lengths and degenerate input.

const std = @import("std");
const vector = @import("root.zig");
const util = @import("test_util.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Path = vector.Path;
const Polyline = vector.flatten.Polyline;

fn cubicAt(p: [4][2]f32, t: f32) [2]f32 {
    const u = 1 - t;
    const a = u * u * u;
    const b = 3 * u * u * t;
    const c = 3 * u * t * t;
    const d = t * t * t;
    return .{ a * p[0][0] + b * p[1][0] + c * p[2][0] + d * p[3][0], a * p[0][1] + b * p[1][1] + c * p[2][1] + d * p[3][1] };
}

fn segDist(q: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const l2 = dx * dx + dy * dy;
    const t = if (l2 == 0) 0 else std.math.clamp(((q[0] - a[0]) * dx + (q[1] - a[1]) * dy) / l2, 0, 1);
    const ex = a[0] + dx * t - q[0];
    const ey = a[1] + dy * t - q[1];
    return @sqrt(ex * ex + ey * ey);
}

test "flatten_error_bound" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x7EC7);
    const r = prng.random();
    for ([_]f32{ 0.05, 0.25, 1 }) |tol| {
        for (0..200) |_| {
            var c: [4][2]f32 = undefined;
            for (&c) |*pt| pt.* = .{ r.float(f32) * 400, r.float(f32) * 400 };
            var p: Path = .{};
            try p.moveTo(a, c[0][0], c[0][1]);
            try p.cubicTo(a, c[1][0], c[1][1], c[2][0], c[2][1], c[3][0], c[3][1]);
            const lines = try vector.flatten.flatten(a, &p, .identity, tol);
            try testing.expectEqual(1, lines.len);
            const pts = lines[0].points;
            try testing.expect(pts.len >= 2);
            var worst: f32 = 0;
            for (0..513) |i| {
                const q = cubicAt(c, @as(f32, @floatFromInt(i)) / 512);
                var best = std.math.inf(f32);
                for (pts[0 .. pts.len - 1], pts[1..]) |p0, p1| best = @min(best, segDist(q, p0, p1));
                worst = @max(worst, best);
            }
            try testing.expect(worst <= tol * 1.01 + 1e-3);
        }
    }
}

/// Zigzags in three rows (one join and one cap a row) and a sharp turn
/// past the miter limit.
fn joinsScene(c: *vector.VectorCanvas) !void {
    const joins = [_]vector.stroke.Join{ .miter, .round, .bevel };
    const caps = [_]vector.stroke.Cap{ .butt, .round, .square };
    for (joins, caps, 0..) |j, cap, row| {
        const y: f32 = 12 + @as(f32, @floatFromInt(row)) * 36;
        const p = try c.path();
        try p.moveTo(c.arena, 10, y + 20);
        try p.lineTo(c.arena, 40, y);
        try p.lineTo(c.arena, 70, y + 20);
        try p.lineTo(c.arena, 100, y);
        try c.stroke(p, .{ .width = 6, .join = j, .cap = cap }, .rgb(0x000000));
        const sharp = try c.path();
        try sharp.moveTo(c.arena, 112, y);
        try sharp.lineTo(c.arena, 150, y + 10);
        try sharp.lineTo(c.arena, 112, y + 20);
        try c.stroke(sharp, .{ .width = 4, .join = j, .cap = cap }, .rgb(0x000000));
    }
}

test "stroke_joins_caps_goldens" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: vector.VectorCanvas = .init(arena.allocator());
    try joinsScene(&c);
    // A closed outline and a dashed curve below the zigzags.
    const box = try c.path();
    try box.roundRect(c.arena, 10, 112, 60, 20, 6);
    try c.stroke(box, .{ .width = 3, .join = .round }, .rgb(0x000000));
    const curve = try c.path();
    try curve.moveTo(c.arena, 80, 132);
    try curve.cubicTo(c.arena, 100, 100, 130, 150, 152, 112);
    try c.stroke(curve, .{ .width = 2, .cap = .round, .dash = &.{ 6, 3 } }, .rgb(0x000000));
    const dl = try c.finish();
    for ([_]u32{ 1, 2 }) |scale| {
        const w = 160 * scale;
        const h = 140 * scale;
        const rgba = try util.renderTiled(gpa, &dl, @floatFromInt(scale), w, h);
        defer gpa.free(rgba);
        const img = try util.pgm(gpa, rgba, w, h);
        defer gpa.free(img);
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "joins_caps_{d}x.pgm", .{scale});
        try @import("zg_core").testkit.golden.expectGoldenOpts(testing.io, @src(), name, img, .{ .root = @import("zg_options").package_root, .dir = "testdata/vector", .normalize = .exact });
    }
}

/// The "on" length of `pattern` (from `offset`) over `len` units.
fn expectedOn(pattern: []const f32, offset: f32, len: f32) f32 {
    var pos = -offset;
    var idx: usize = 0;
    var total: f32 = 0;
    while (pos < len) {
        const seg = pattern[idx % pattern.len];
        if (idx % 2 == 0) {
            const lo = @max(pos, 0);
            const hi = @min(pos + seg, len);
            if (hi > lo) total += hi - lo;
        }
        pos += seg;
        idx += 1;
    }
    return total;
}

test "dash_lengths" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const open_pts = [_][2]f32{ .{ 0, 0 }, .{ 30, 0 }, .{ 30, 20 } };
    const open: Polyline = .{ .points = &open_pts, .closed = false };
    const cases = [_]struct { pattern: []const f32, offset: f32, even: []const f32 }{
        .{ .pattern = &.{ 4, 2 }, .offset = 1, .even = &.{ 4, 2 } },
        .{ .pattern = &.{3}, .offset = 0, .even = &.{ 3, 3 } },
        .{ .pattern = &.{ 5, 1, 2, 2 }, .offset = -3, .even = &.{ 5, 1, 2, 2 } },
    };
    for (cases) |cs| {
        const dashes = try vector.dash.dashPolylines(a, &.{open}, cs.pattern, cs.offset);
        var total: f32 = 0;
        for (dashes, 0..) |d, i| {
            const l = vector.dash.length(d.points);
            total += l;
            try testing.expect(!d.closed);
            // Interior dashes have their full length.
            if (i > 0 and i + 1 < dashes.len) {
                var ok = false;
                var k: usize = 0;
                while (k < cs.even.len) : (k += 2) ok = ok or @abs(l - cs.even[k]) < 1e-3;
                try testing.expect(ok);
            }
        }
        try testing.expectApproxEqAbs(expectedOn(cs.even, cs.offset - @floor(cs.offset / sum(cs.even)) * sum(cs.even), 50), total, 1e-3);
    }
    // A closed square is dashed along its closing side too.
    const sq = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const dashes = try vector.dash.dashPolylines(a, &.{.{ .points = &sq, .closed = true }}, &.{ 5, 5 }, 0);
    try testing.expectEqual(4, dashes.len);
    for (dashes) |d| try testing.expectApproxEqAbs(5, vector.dash.length(d.points), 1e-4);
    // No positive length: the line stays whole.
    const whole = try vector.dash.dashPolylines(a, &.{open}, &.{ 0, 0 }, 0);
    try testing.expectEqual(1, whole.len);
}

fn sum(xs: []const f32) f32 {
    var s: f32 = 0;
    for (xs) |x| s += x;
    return s;
}

test "degenerate_segments_no_nan" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var paths: [6]Path = @splat(.{});
    // A zero-length segment.
    try paths[0].moveTo(a, 10, 10);
    try paths[0].lineTo(a, 10, 10);
    // Repeated points and a 180° turn.
    try paths[1].moveTo(a, 10, 10);
    try paths[1].lineTo(a, 10, 10);
    try paths[1].lineTo(a, 30, 10);
    try paths[1].lineTo(a, 30, 10);
    try paths[1].lineTo(a, 10, 10);
    // A cubic with a cusp.
    try paths[2].moveTo(a, 0, 0);
    try paths[2].cubicTo(a, 100, 100, 0, 100, 100, 0);
    // A lone move, and a closed single point.
    try paths[3].moveTo(a, 5, 5);
    try paths[4].moveTo(a, 5, 5);
    try paths[4].close(a);
    // A closed path doubling back on itself.
    try paths[5].moveTo(a, 0, 0);
    try paths[5].lineTo(a, 20, 0);
    try paths[5].lineTo(a, 0, 0);
    try paths[5].close(a);
    for (&paths) |*p| {
        const b = p.bounds();
        for ([_]vector.stroke.Join{ .miter, .round, .bevel }) |j| for ([_]vector.stroke.Cap{ .butt, .round, .square }) |cap| {
            for ([_][]const f32{ &.{}, &.{ 3, 2 } }) |dash| {
                var out = try vector.strokeToFill(gpa, p, .{ .width = 4, .join = j, .cap = cap, .dash = dash }, 0.1);
                defer out.deinit(gpa);
                for (out.points.items) |pt| {
                    try testing.expect(std.math.isFinite(pt[0]) and std.math.isFinite(pt[1]));
                    // Within the miter limit's reach of the input.
                    try testing.expect(pt[0] >= b.x0 - 9 and pt[0] <= b.x1 + 9);
                    try testing.expect(pt[1] >= b.y0 - 9 and pt[1] <= b.y1 + 9);
                }
            }
        };
    }
    // Non-finite input never reaches the output.
    var bad: Path = .{};
    try bad.moveTo(a, 0, 0);
    try bad.lineTo(a, std.math.nan(f32), 3);
    try bad.lineTo(a, 10, 10);
    var out = try vector.strokeToFill(gpa, &bad, .{ .width = 2 }, 0.1);
    defer out.deinit(gpa);
    for (out.points.items) |pt| try testing.expect(std.math.isFinite(pt[0]) and std.math.isFinite(pt[1]));
}
