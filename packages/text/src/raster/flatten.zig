//! Curve flattening into accumulator lines. The segment count comes from
//! Wang's formula, which bounds the distance between a Bézier curve and its
//! uniform-in-t polyline: for degree d, n = ceil(sqrt(d(d-1)/8 * M / tol)),
//! where M is the largest second difference of the control points. Points
//! are evaluated by forward differencing; the last one is the curve's exact
//! end point.

const std = @import("std");
const Accumulator = @import("coverage.zig").Accumulator;

/// Most segments one curve becomes.
pub const max_segments = 512;

/// Flattening tolerance in pixels for coverage output.
pub const tol_gray: f32 = 0.2;
/// Flattening tolerance in pixels for SDF output.
pub const tol_sdf: f32 = 0.1;

inline fn len(v: [2]f32) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1]);
}

inline fn secondDiff(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    return len(.{ a[0] - 2 * b[0] + c[0], a[1] - 2 * b[1] + c[1] });
}

fn segments(k: f32) u32 {
    // NaN or infinite input lands on the cap; the accumulator clamps the
    // points, so the result is bounded either way.
    const n = @ceil(@sqrt(k));
    if (!(n < max_segments)) return max_segments;
    return @max(1, @as(u32, @intFromFloat(n)));
}

/// Segment count for a quadratic: n = sqrt(|p0 - 2p1 + p2| / (4 tol)).
pub fn quadSegments(p0: [2]f32, p1: [2]f32, p2: [2]f32, tol: f32) u32 {
    return segments(secondDiff(p0, p1, p2) / (4 * tol));
}

/// Segment count for a cubic: n = sqrt(3/4 * M / tol).
pub fn cubicSegments(p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32, tol: f32) u32 {
    const m = @max(secondDiff(p0, p1, p2), secondDiff(p1, p2, p3));
    return segments(0.75 * m / tol);
}

/// Flattens the quadratic `p0` `p1` `p2` (pixel space) into `acc`.
pub fn quad(acc: *Accumulator, p0: [2]f32, p1: [2]f32, p2: [2]f32, tol: f32) void {
    quadTo(acc, p0, p1, p2, tol);
}

/// Flattens the cubic `p0` `p1` `p2` `p3` (pixel space) into `acc`.
pub fn cubic(acc: *Accumulator, p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32, tol: f32) void {
    cubicTo(acc, p0, p1, p2, p3, tol);
}

/// Flattens a quadratic into `sink.segment(a, b)` calls; `sink` is any
/// pointer to a type with that `pub` method (the accumulator, the SDF edge list,
/// test probes).
pub fn quadTo(sink: anytype, p0: [2]f32, p1: [2]f32, p2: [2]f32, tol: f32) void {
    const n = quadSegments(p0, p1, p2, tol);
    if (n == 1) return sink.segment(p0, p2);
    const dt = 1 / @as(f32, @floatFromInt(n));
    const dt2 = dt * dt;
    // B(t) = a t^2 + b t + p0 with a = p0 - 2p1 + p2, b = 2(p1 - p0).
    var prev = p0;
    var pt = p0;
    var d1: [2]f32 = undefined;
    var d2: [2]f32 = undefined;
    inline for (0..2) |k| {
        const a = p0[k] - 2 * p1[k] + p2[k];
        const b = 2 * (p1[k] - p0[k]);
        d1[k] = a * dt2 + b * dt;
        d2[k] = 2 * a * dt2;
    }
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        inline for (0..2) |k| {
            pt[k] += d1[k];
            d1[k] += d2[k];
        }
        sink.segment(prev, pt);
        prev = pt;
    }
    sink.segment(prev, p2);
}

/// Flattens a cubic into `sink.segment(a, b)` calls.
pub fn cubicTo(sink: anytype, p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32, tol: f32) void {
    const n = cubicSegments(p0, p1, p2, p3, tol);
    if (n == 1) return sink.segment(p0, p3);
    const dt = 1 / @as(f32, @floatFromInt(n));
    const dt2 = dt * dt;
    const dt3 = dt2 * dt;
    // B(t) = a t^3 + b t^2 + c t + p0.
    var prev = p0;
    var pt = p0;
    var d1: [2]f32 = undefined;
    var d2: [2]f32 = undefined;
    var d3: [2]f32 = undefined;
    inline for (0..2) |k| {
        const a = p3[k] - p0[k] + 3 * (p1[k] - p2[k]);
        const b = 3 * (p0[k] - 2 * p1[k] + p2[k]);
        const c = 3 * (p1[k] - p0[k]);
        d1[k] = a * dt3 + b * dt2 + c * dt;
        d2[k] = 6 * a * dt3 + 2 * b * dt2;
        d3[k] = 6 * a * dt3;
    }
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        inline for (0..2) |k| {
            pt[k] += d1[k];
            d1[k] += d2[k];
            d2[k] += d3[k];
        }
        sink.segment(prev, pt);
        prev = pt;
    }
    sink.segment(prev, p3);
}

const testing = std.testing;

test "segment counts" {
    try testing.expectEqual(@as(u32, 1), quadSegments(.{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, 0.2));
    // |p0 - 2p1 + p2| = 20: sqrt(20 / 0.8) = 5.
    try testing.expectEqual(@as(u32, 5), quadSegments(.{ 0, 0 }, .{ 10, 10 }, .{ 20, 0 }, 0.2));
    try testing.expectEqual(@as(u32, max_segments), quadSegments(.{ 0, 0 }, .{ 1e9, 1e9 }, .{ 0, 0 }, 0.2));
    try testing.expectEqual(@as(u32, max_segments), cubicSegments(.{ 0, 0 }, .{ std.math.nan(f32), 0 }, .{ 0, 0 }, .{ 0, 0 }, 0.2));
}
