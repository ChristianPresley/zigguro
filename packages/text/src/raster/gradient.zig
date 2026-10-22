//! COLRv1 gradients: colour-line sampling with pad/repeat/reflect, and the
//! gradient parameter `t` of a glyph-space point for linear, two-circle
//! radial and sweep gradients.
//!
//! Colours are premultiplied sRGB-encoded RGBA and interpolate as such, as
//! the reference renderers (Skia with premultiplied interpolation,
//! blackrenderer) do; interpolating in linear light would look different
//! from every browser.

const std = @import("std");
const Extend = @import("../ot/colr.zig").Extend;

/// Premultiplied RGBA.
pub const V = @Vector(4, f32);

/// A colour stop: offset and premultiplied colour.
pub const Stop = struct { t: f32, c: V };

/// Sorts `stops` by offset, keeping equal offsets in order, and rescales
/// the offsets to [0, 1]. Returns the original first and last offsets, by
/// which the caller rescales the gradient geometry (or 0 and 1, leaving the
/// stops as they are, when every stop has the same offset).
pub fn normalize(stops: []Stop) [2]f32 {
    std.mem.sort(Stop, stops, {}, struct {
        fn lt(_: void, a: Stop, b: Stop) bool {
            return a.t < b.t;
        }
    }.lt);
    if (stops.len == 0) return .{ 0, 1 };
    const lo = stops[0].t;
    const hi = stops[stops.len - 1].t;
    if (!(hi > lo)) return .{ 0, 1 };
    for (stops) |*s| s.t = (s.t - lo) / (hi - lo);
    return .{ lo, hi };
}

/// `t` folded into [0, 1] by `extend`.
pub inline fn applyExtend(extend: Extend, t: f32) f32 {
    return switch (extend) {
        .pad => std.math.clamp(t, 0, 1),
        .repeat => t - @floor(t),
        .reflect => blk: {
            const m = t - 2 * @floor(t / 2);
            break :blk if (m > 1) 2 - m else m;
        },
    };
}

/// The colour at `t` (already extended) on sorted `stops` (at least one).
/// At a hard stop (two stops at one offset) the later colour wins.
pub fn sample(stops: []const Stop, t_in: f32) V {
    const t = if (std.math.isNan(t_in)) 0 else t_in;
    if (t <= stops[0].t) return stops[0].c;
    if (t >= stops[stops.len - 1].t) return stops[stops.len - 1].c;
    // First stop past t.
    var lo: usize = 0;
    var hi: usize = stops.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (stops[mid].t > t) hi = mid else lo = mid + 1;
    }
    const a = stops[lo - 1];
    const b = stops[lo];
    if (!(b.t > a.t)) return b.c;
    const f = (t - a.t) / (b.t - a.t);
    return a.c + (b.c - a.c) * @as(V, @splat(f));
}

/// The linear gradient's p1 moved so p0p1 is perpendicular to p0p2 (the
/// colour bands then run along p0p2); unchanged when p0p2 is degenerate.
pub fn linearAxis(p0: [2]f32, p1: [2]f32, p2: [2]f32) [2]f32 {
    const x02 = p2[0] - p0[0];
    const y02 = p2[1] - p0[1];
    const n = x02 * x02 + y02 * y02;
    if (n < 1e-6) return p1;
    const k = ((p1[0] - p0[0]) * x02 + (p1[1] - p0[1]) * y02) / n;
    return .{ p1[0] - k * x02, p1[1] - k * y02 };
}

/// Linear: the projection of `p` onto p0p1, 0 at p0 and 1 at p1. Null for
/// a degenerate axis.
pub fn linearT(p0: [2]f32, p1: [2]f32, p: [2]f32) ?f32 {
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const n = dx * dx + dy * dy;
    if (!(n > 1e-12)) return null;
    return ((p[0] - p0[0]) * dx + (p[1] - p0[1]) * dy) / n;
}

/// Precomputed two-circle gradient: circles c(t) = c0 + t(c1 - c0) with
/// radius r(t) = r0 + t(r1 - r0).
pub const Radial = struct {
    c0: [2]f64,
    cd: [2]f64,
    r0: f64,
    dr: f64,
    a: f64,

    pub fn init(c0: [2]f32, r0: f32, c1: [2]f32, r1: f32) Radial {
        const cd = [2]f64{ @as(f64, c1[0]) - c0[0], @as(f64, c1[1]) - c0[1] };
        const dr = @as(f64, r1) - r0;
        return .{ .c0 = .{ c0[0], c0[1] }, .cd = cd, .r0 = r0, .dr = dr, .a = cd[0] * cd[0] + cd[1] * cd[1] - dr * dr };
    }

    /// The largest t whose circle passes through `p` with r(t) ≥ 0, or
    /// null when there is none (the point is left unpainted).
    pub fn t(g: *const Radial, p: [2]f32) ?f32 {
        const px = @as(f64, p[0]) - g.c0[0];
        const py = @as(f64, p[1]) - g.c0[1];
        const b = px * g.cd[0] + py * g.cd[1] + g.r0 * g.dr;
        const c = px * px + py * py - g.r0 * g.r0;
        if (@abs(g.a) < 1e-9) {
            if (b == 0) return null;
            const t0 = c / (2 * b);
            return if (g.r0 + t0 * g.dr >= 0) @floatCast(t0) else null;
        }
        const disc = b * b - g.a * c;
        if (disc < 0) return null;
        const sq = @sqrt(disc);
        const t1 = (b + sq) / g.a;
        const t2 = (b - sq) / g.a;
        const hi = @max(t1, t2);
        const lo = @min(t1, t2);
        if (g.r0 + hi * g.dr >= 0) return @floatCast(hi);
        if (g.r0 + lo * g.dr >= 0) return @floatCast(lo);
        return null;
    }
};

/// The counter-clockwise angle of `p` around `center` in degrees, [0, 360).
pub fn sweepAngle(center: [2]f32, p: [2]f32) f32 {
    const a = std.math.radiansToDegrees(std.math.atan2(p[1] - center[1], p[0] - center[0]));
    return if (a < 0) a + 360 else a;
}

test "extend modes" {
    try std.testing.expectEqual(@as(f32, 0), applyExtend(.pad, -0.5));
    try std.testing.expectEqual(@as(f32, 1), applyExtend(.pad, 1.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), applyExtend(.repeat, 1.25), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), applyExtend(.repeat, -0.25), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), applyExtend(.reflect, 1.25), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), applyExtend(.reflect, -0.25), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), applyExtend(.reflect, 2.25), 1e-6);
}

test "stops sort stably, normalize and sample" {
    var stops = [_]Stop{
        .{ .t = 0.75, .c = .{ 0, 0, 1, 1 } },
        .{ .t = 0.25, .c = .{ 1, 0, 0, 1 } },
        .{ .t = 0.5, .c = .{ 0, 1, 0, 1 } },
        .{ .t = 0.5, .c = .{ 0, 0, 0, 1 } },
    };
    const r = normalize(&stops);
    try std.testing.expectEqual([2]f32{ 0.25, 0.75 }, r);
    try std.testing.expectEqual(@as(f32, 0), stops[0].t);
    try std.testing.expectEqual(V{ 0, 1, 0, 1 }, stops[1].c); // equal offsets keep their order
    try std.testing.expectEqual(V{ 1, 0, 0, 1 }, sample(&stops, -1));
    try std.testing.expectEqual(V{ 0.5, 0.5, 0, 1 }, sample(&stops, 0.25));
    try std.testing.expectEqual(V{ 0, 0, 0, 1 }, sample(&stops, 0.5)); // hard stop: later colour
    try std.testing.expectEqual(V{ 0, 0, 1, 1 }, sample(&stops, 2));
}

test "gradient parameters" {
    try std.testing.expectEqual(@as(?f32, 0.5), linearT(.{ 0, 0 }, .{ 10, 0 }, .{ 5, 7 }));
    try std.testing.expectEqual(@as(?f32, null), linearT(.{ 1, 1 }, .{ 1, 1 }, .{ 5, 7 }));
    // p2 straight up from p0 leaves a horizontal axis alone; a skewed p2
    // projects p1 onto the perpendicular of p0p2.
    try std.testing.expectEqual([2]f32{ 10, 0 }, linearAxis(.{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 }));
    try std.testing.expectEqual([2]f32{ 5, -5 }, linearAxis(.{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }));
    // Concentric circles r 10 → 20: a point at distance 15 is halfway.
    const g = Radial.init(.{ 0, 0 }, 10, .{ 0, 0 }, 20);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.t(.{ 15, 0 }).?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), g.t(.{ 0, 0 }).?, 1e-6);
    // A cone from a point: nothing behind its apex.
    const cone = Radial.init(.{ 0, 0 }, 0, .{ 10, 0 }, 5);
    try std.testing.expectEqual(@as(?f32, null), cone.t(.{ -5, 0 }));
    try std.testing.expectApproxEqAbs(@as(f32, 90), sweepAngle(.{ 0, 0 }, .{ 0, 3 }), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 270), sweepAngle(.{ 0, 0 }, .{ 0, -3 }), 1e-4);
}
