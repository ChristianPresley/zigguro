//! The reference shading math: the exact formulas the GPU shaders
//! (E02.F05.S01.T05) and the software renderer (E02.F07) implement. Every
//! function is generic over `T`, which is `f32` (one pixel) or
//! `@Vector(n, f32)` (n pixels); both evaluate the same operations in the
//! same order, so scalar and vector results are bit-identical. The float
//! mode is the default (strict): no FMA contraction, no reassociation, and
//! `@mulAdd` is never used.
//!
//! Coordinates are physical pixels with pixel centres at +0.5. Colours are
//! premultiplied sRGB-encoded values in 0..1.

const std = @import("std");

/// Text coverage correction parameters (E03 tunes them; E15 exposes them).
pub const TextParams = struct {
    /// Gamma applied to coverage of dark text; light text uses 1/gamma.
    gamma: f32 = 1.8,
    /// Contrast boost added as `contrast * cov * (1 - cov)`.
    contrast: f32 = 0.25,
    /// Whether subpixel (per-channel) text may be used.
    subpixel: bool = true,
};

/// The boolean type matching `T`: `bool` or `@Vector(n, bool)`.
pub fn Bool(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .vector => |v| @Vector(v.len, bool),
        else => bool,
    };
}

/// `v` broadcast to `T`.
pub inline fn splat(comptime T: type, v: f32) T {
    return if (T == f32) v else @splat(v);
}

/// `c ? a : b` lane-wise.
pub inline fn sel(comptime T: type, c: Bool(T), a: T, b: T) T {
    return if (T == f32) (if (c) a else b) else @select(f32, c, a, b);
}

/// Clamps `x` to `lo..hi` lane-wise (NaN-free inputs).
pub inline fn clampT(comptime T: type, x: T, lo: f32, hi: f32) T {
    return @min(@max(x, splat(T, lo)), splat(T, hi));
}

/// Signed distance from `(px, py)` (relative to the box centre) to a box of
/// half extents `hx, hy` with per-corner radii `r` = tl, tr, br, bl
/// (Inigo Quilez's `sdRoundedBox`, adapted to y-down). Negative inside.
pub fn sdRoundedBoxT(comptime T: type, px: T, py: T, hx: f32, hy: f32, r: [4]f32) T {
    const right = px > splat(T, 0);
    const bottom = py > splat(T, 0);
    const rr = sel(T, right, sel(T, bottom, splat(T, r[2]), splat(T, r[1])), sel(T, bottom, splat(T, r[3]), splat(T, r[0])));
    const qx = @abs(px) - splat(T, hx) + rr;
    const qy = @abs(py) - splat(T, hy) + rr;
    const mx = @max(qx, splat(T, 0));
    const my = @max(qy, splat(T, 0));
    return @min(@max(qx, qy), splat(T, 0)) + @sqrt(mx * mx + my * my) - rr;
}

/// Scalar `sdRoundedBoxT`: `p` relative to the centre, `half` extents,
/// radii tl, tr, br, bl.
pub fn sdRoundedBox(p: [2]f32, half: [2]f32, r: [4]f32) f32 {
    return sdRoundedBoxT(f32, p[0], p[1], half[0], half[1], r);
}

/// Area coverage of a pixel whose centre is at signed distance `d` from an
/// edge: `clamp(0.5 - d, 0, 1)`.
pub fn coverageFromSdfT(comptime T: type, d: T) T {
    return clampT(T, splat(T, 0.5) - d, 0, 1);
}

/// Scalar `coverageFromSdfT`.
pub fn coverageFromSdf(d: f32) f32 {
    return coverageFromSdfT(f32, d);
}

/// Coverage of the rounded box `b` = x, y, w, h with radii `r` at pixel
/// centre `(px, py)` (absolute coordinates). Empty boxes cover nothing.
pub fn boxCoverageT(comptime T: type, px: T, py: T, b: [4]f32, r: [4]f32) T {
    if (!(b[2] > 0 and b[3] > 0)) return splat(T, 0);
    const hx = b[2] * 0.5;
    const hy = b[3] * 0.5;
    const d = sdRoundedBoxT(T, px - splat(T, b[0] + hx), py - splat(T, b[1] + hy), hx, hy, r);
    return coverageFromSdfT(T, d);
}

/// Coverage of a border: the outer box `b` with radii `r` minus the inner
/// box inset by `w` = l, t, r, b, whose radii shrink by the adjacent widths.
pub fn borderCoverageT(comptime T: type, px: T, py: T, b: [4]f32, r: [4]f32, w: [4]f32) T {
    const outer = boxCoverageT(T, px, py, b, r);
    const inner_box = [4]f32{ b[0] + w[0], b[1] + w[1], b[2] - w[0] - w[2], b[3] - w[1] - w[3] };
    const inner_r = [4]f32{
        @max(r[0] - @max(w[0], w[1]), 0),
        @max(r[1] - @max(w[2], w[1]), 0),
        @max(r[2] - @max(w[2], w[3]), 0),
        @max(r[3] - @max(w[0], w[3]), 0),
    };
    const inner = boxCoverageT(T, px, py, inner_box, inner_r);
    return outer * (splat(T, 1) - inner);
}

/// Sign of `x` (0 for 0).
fn signT(comptime T: type, x: T) T {
    return sel(T, x > splat(T, 0), splat(T, 1), sel(T, x < splat(T, 0), splat(T, -1), splat(T, 0)));
}

/// Abramowitz–Stegun style approximation of erf used by Evan Wallace's
/// shadow: `s - s / (x*x)^2` with `x = 1 + (0.278393 + (0.230389 + 0.078108 a²) a) a`.
pub fn erfT(comptime T: type, x: T) T {
    const s = signT(T, x);
    const a = @abs(x);
    var t = splat(T, 1) + (splat(T, 0.278393) + (splat(T, 0.230389) + splat(T, 0.078108) * (a * a)) * a) * a;
    t = t * t;
    return s - s / (t * t);
}

/// `@exp` lane-wise. Vectors use a lane-parallel port of compiler_rt's
/// `expf` (the same operations in the same order, with exact power-of-two
/// scaling), so results equal `@exp` per lane bit for bit; `@exp` on a
/// vector would call `expf` once per lane.
pub fn expT(comptime T: type, x: T) T {
    if (T == f32) return @exp(x);
    const n = @typeInfo(T).vector.len;
    const U = @Vector(n, u32);
    const I = @Vector(n, i32);
    const ln2hi = splat(T, 6.9314575195e-1);
    const ln2lo = splat(T, 1.4286067653e-6);
    const invln2 = splat(T, 1.4426950216e+0);
    const P1 = splat(T, 1.6666625440e-1);
    const P2 = splat(T, -2.7667332906e-3);
    const bits: U = @bitCast(x);
    const neg = (bits >> @splat(31)) != @as(U, @splat(0));
    const hx = bits & @as(U, @splat(0x7FFFFFFF));
    const nan = hx > @as(U, @splat(0x7F800000));
    const over = !neg & (hx >= @as(U, @splat(0x42b17218))) & !nan;
    const under = neg & (hx >= @as(U, @splat(0x42CFF1B5))) & !nan;
    const tiny = hx <= @as(U, @splat(0x39000000));
    const special = nan | over | under | tiny;
    // Special lanes compute on 0 and are replaced at the end.
    const xs = @select(f32, special, splat(T, 0), x);
    const big = (hx > @as(U, @splat(0x3F851592))) & !special;
    const mid = (hx > @as(U, @splat(0x3EB17218))) & !special;
    const half = @select(f32, neg, splat(T, -0.5), splat(T, 0.5));
    const k_big: I = @intFromFloat(invln2 * xs + half);
    const k_mid = @select(i32, neg, @as(I, @splat(-1)), @as(I, @splat(1)));
    const k: I = @select(i32, big, k_big, @select(i32, mid, k_mid, @as(I, @splat(0))));
    // With k = 0 these give hi = x, lo = 0, as expf's small branch does.
    const fk: T = @floatFromInt(k);
    const hi = xs - fk * ln2hi;
    const lo = fk * ln2lo;
    const r = hi - lo;
    const rr = r * r;
    const c = r - rr * (P1 + rr * P2);
    const y = splat(T, 1) + (r * c / (splat(T, 2) - c) - lo + hi);
    // y * 2^k in at most two exact-or-once-rounded steps (scalbn).
    const low = k < @as(I, @splat(-126));
    const high = k > @as(I, @splat(127));
    const ka = @select(i32, low, k + @as(I, @splat(100)), @select(i32, high, k - @as(I, @splat(1)), k));
    const kb_scale = @select(f32, low, splat(T, 0x1.0p-100), @select(f32, high, splat(T, 2), splat(T, 1)));
    const pa: T = @bitCast(@as(U, @bitCast(ka + @as(I, @splat(127)))) << @splat(23));
    var out = (y * pa) * kb_scale;
    out = @select(f32, tiny, splat(T, 1) + x, out);
    out = @select(f32, under, splat(T, 0), out);
    out = @select(f32, over, x * splat(T, 0x1.0p127), out);
    return @select(f32, nan, x, out);
}

fn gaussianT(comptime T: type, x: T, sigma: f32) T {
    const inv = 1.0 / (2.5066282746 * sigma); // 1 / (sqrt(2π) σ)
    return expT(T, -(x * x) / splat(T, 2.0 * sigma * sigma)) * splat(T, inv);
}

fn shadowXT(comptime T: type, x: T, y: T, sigma: f32, corner: T, hx: f32, hy: f32) T {
    const delta = @min(splat(T, hy) - corner - @abs(y), splat(T, 0));
    const curved = splat(T, hx) - corner + @sqrt(@max(splat(T, 0), corner * corner - delta * delta));
    const k = splat(T, 0.70710678 / sigma);
    const lo = splat(T, 0.5) + splat(T, 0.5) * erfT(T, (x - curved) * k);
    const hi = splat(T, 0.5) + splat(T, 0.5) * erfT(T, (x + curved) * k);
    return hi - lo;
}

/// Opacity of a Gaussian-blurred rounded box spanning `lower`..`upper` at
/// point `(px, py)` (Evan Wallace's closed form: exact in x, four samples
/// in y). `r` = tl, tr, br, bl; the corner radius of the quadrant is used.
pub fn roundedBoxShadowT(comptime T: type, px: T, py: T, lower: [2]f32, upper: [2]f32, sigma_in: f32, r: [4]f32) T {
    const sigma = @max(sigma_in, 0.25);
    const cx = (lower[0] + upper[0]) * 0.5;
    const cy = (lower[1] + upper[1]) * 0.5;
    const hx = (upper[0] - lower[0]) * 0.5;
    const hy = (upper[1] - lower[1]) * 0.5;
    const x = px - splat(T, cx);
    const yp = py - splat(T, cy);
    const right = x > splat(T, 0);
    const bottom = yp > splat(T, 0);
    const corner = sel(T, right, sel(T, bottom, splat(T, r[2]), splat(T, r[1])), sel(T, bottom, splat(T, r[3]), splat(T, r[0])));
    const low = yp - splat(T, hy);
    const high = yp + splat(T, hy);
    const start = @min(@max(splat(T, -3.0 * sigma), low), high);
    const end = @min(@max(splat(T, 3.0 * sigma), low), high);
    const step = (end - start) * splat(T, 0.25);
    var y = start + step * splat(T, 0.5);
    var value = splat(T, 0);
    inline for (0..4) |_| {
        value += shadowXT(T, x, yp - y, sigma, corner, hx, hy) * gaussianT(T, y, sigma) * step;
        y += step;
    }
    return value;
}

/// Scalar `roundedBoxShadowT` with one radius on every corner.
pub fn roundedBoxShadow(lower: [2]f32, upper: [2]f32, p: [2]f32, sigma: f32, corner: f32) f32 {
    return roundedBoxShadowT(f32, p[0], p[1], lower, upper, sigma, .{ corner, corner, corner, corner });
}

/// Relative luminance of an sRGB-encoded colour (no linearisation; used
/// only to pick the coverage gamma).
pub fn luma(rgb: [3]f32) f32 {
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
}

/// Gamma and contrast correction of glyph coverage for text of luminance
/// `l`: `cov^mix(gamma, 1/gamma, l)`, then `cov + contrast*cov*(1-cov)`,
/// clamped. `pow` is evaluated as `exp(log(cov) * g)` on both backends.
pub fn textCoverageT(comptime T: type, cov: T, l: f32, p: TextParams) T {
    const g = p.gamma + (1.0 / p.gamma - p.gamma) * l;
    const pos = cov > splat(T, 0);
    const safe = sel(T, pos, cov, splat(T, 1));
    const powed = sel(T, pos, expT(T, @log(safe) * splat(T, g)), splat(T, 0));
    return clampT(T, powed + splat(T, p.contrast) * powed * (splat(T, 1) - powed), 0, 1);
}

/// Scalar `textCoverageT`.
pub fn textCoverage(cov: f32, l: f32, p: TextParams) f32 {
    return textCoverageT(f32, cov, l, p);
}

/// Source-over for premultiplied colours: `src + dst * (1 - src.a)`.
pub fn blendPremulT(comptime T: type, dst: [4]T, src: [4]T) [4]T {
    const k = splat(T, 1) - src[3];
    return .{ src[0] + dst[0] * k, src[1] + dst[1] * k, src[2] + dst[2] * k, src[3] + dst[3] * k };
}

/// Scalar `blendPremulT`.
pub fn blendPremul(dst: [4]f32, src: [4]f32) [4]f32 {
    return blendPremulT(f32, dst, src);
}

/// Dual-source subpixel blend of premultiplied `color` with per-channel
/// coverage: `out.c = color.c*cov.c + dst.c*(1 - color.a*cov.c)`; alpha uses
/// max(cov). This is the blend equation of the GPU's dual-source pipeline.
pub fn blendSubpixelT(comptime T: type, dst: [4]T, color: [4]T, cov: [3]T) [4]T {
    const ca = @max(@max(cov[0], cov[1]), cov[2]);
    return .{
        color[0] * cov[0] + dst[0] * (splat(T, 1) - color[3] * cov[0]),
        color[1] * cov[1] + dst[1] * (splat(T, 1) - color[3] * cov[1]),
        color[2] * cov[2] + dst[2] * (splat(T, 1) - color[3] * cov[2]),
        color[3] * ca + dst[3] * (splat(T, 1) - color[3] * ca),
    };
}

/// Scalar `blendSubpixelT`.
pub fn blendSubpixel(dst: [4]f32, color: [4]f32, cov_rgb: [3]f32) [4]f32 {
    return blendSubpixelT(f32, dst, color, cov_rgb);
}

/// Interpolation parameter of a linear gradient from `p0` to `p1`:
/// the projection of the pixel onto the axis, clamped to 0..1.
pub fn gradientT(comptime T: type, px: T, py: T, p0: [2]f32, p1: [2]f32) T {
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const len2 = dx * dx + dy * dy;
    if (!(len2 > 0)) return splat(T, 0);
    const t = ((px - splat(T, p0[0])) * splat(T, dx) + (py - splat(T, p0[1])) * splat(T, dy)) / splat(T, len2);
    return clampT(T, t, 0, 1);
}

const testing = std.testing;

test "shading: sdRoundedBox analytic points" {
    const half = [2]f32{ 10, 5 };
    const none = [4]f32{ 0, 0, 0, 0 };
    try testing.expectEqual(@as(f32, -5), sdRoundedBox(.{ 0, 0 }, half, none));
    try testing.expectEqual(@as(f32, 2), sdRoundedBox(.{ 12, 0 }, half, none));
    try testing.expectEqual(@as(f32, 5), sdRoundedBox(.{ 13, 9 }, half, none));
    // Corner radius 4 on the bottom-right only: the corner point is
    // (sqrt(2)-1)*4 outside the arc.
    const r = [4]f32{ 0, 0, 4, 0 };
    try testing.expectApproxEqAbs(@as(f32, (std.math.sqrt2 - 1) * 4), sdRoundedBox(.{ 10, 5 }, half, r), 1e-5);
    try testing.expectEqual(@as(f32, 0), sdRoundedBox(.{ -10, 5 }, half, r));
    try testing.expectApproxEqAbs(@as(f32, -1), sdRoundedBox(.{ 9, 0 }, half, r), 1e-6);
}

test "shading: coverage is 1 inside, 0 outside, 0.5 on the edge" {
    try testing.expectEqual(@as(f32, 1), coverageFromSdf(-0.5));
    try testing.expectEqual(@as(f32, 0.5), coverageFromSdf(0));
    try testing.expectEqual(@as(f32, 0), coverageFromSdf(0.5));
    // Integer-aligned boxes have exact 0/1 coverage at pixel centres.
    try testing.expectEqual(@as(f32, 1), boxCoverageT(f32, 0.5, 0.5, .{ 0, 0, 4, 4 }, .{ 0, 0, 0, 0 }));
    try testing.expectEqual(@as(f32, 0), boxCoverageT(f32, 4.5, 0.5, .{ 0, 0, 4, 4 }, .{ 0, 0, 0, 0 }));
}

test "shading: shadow integrates to ≈ rect area" {
    const lower = [2]f32{ 0, 0 };
    const upper = [2]f32{ 20, 10 };
    inline for (.{ 1.0, 3.0, 6.0 }) |sigma| {
        inline for (.{ 0.0, 4.0 }) |corner| {
            var sum: f64 = 0;
            const step: f32 = 0.25;
            var y: f32 = -30;
            while (y < 40) : (y += step) {
                var x: f32 = -30;
                while (x < 50) : (x += step) sum += roundedBoxShadow(lower, upper, .{ x, y }, sigma, corner) * step * step;
            }
            const area: f64 = 200 - (4 - std.math.pi) * corner * corner;
            // Square boxes integrate to their area within 1%; the rounded
            // corner term of the closed form is approximate (about 1.5%).
            const tol: f64 = if (corner == 0) 0.01 else 0.02;
            try testing.expect(@abs(sum - area) / area < tol);
        }
    }
}

test "shading: blendPremul identities" {
    const d = [4]f32{ 0.2, 0.4, 0.6, 1 };
    try testing.expectEqual(d, blendPremul(d, .{ 0, 0, 0, 0 }));
    const s = [4]f32{ 0.1, 0.2, 0.3, 1 };
    try testing.expectEqual(s, blendPremul(d, s));
    const h = blendPremul(.{ 1, 1, 1, 1 }, .{ 0, 0, 0, 0.5 });
    try testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, h);
    // Subpixel with equal coverage equals the premultiplied blend.
    const c = [4]f32{ 0.25, 0.25, 0.25, 0.5 };
    const a = blendSubpixel(d, c, .{ 1, 1, 1 });
    try testing.expectEqual(blendPremul(d, c), a);
}

test "shading: textCoverage monotone and bounded" {
    const p: TextParams = .{};
    for ([_]f32{ 0, 0.5, 1 }) |l| {
        var prev: f32 = 0;
        var i: u32 = 0;
        while (i <= 255) : (i += 1) {
            const c = textCoverage(@as(f32, @floatFromInt(i)) / 255, l, p);
            try testing.expect(c >= prev and c <= 1);
            prev = c;
        }
        try testing.expectEqual(@as(f32, 0), textCoverage(0, l, p));
        try testing.expectEqual(@as(f32, 1), textCoverage(1, l, p));
    }
}

test "shading: gradient parameter" {
    try testing.expectEqual(@as(f32, 0.5), gradientT(f32, 5, 0, .{ 0, 0 }, .{ 10, 0 }));
    try testing.expectEqual(@as(f32, 1), gradientT(f32, 50, 3, .{ 0, 0 }, .{ 10, 0 }));
    try testing.expectEqual(@as(f32, 0), gradientT(f32, 1, 1, .{ 2, 2 }, .{ 2, 2 }));
}

test "shading: scalar and vector agree bit for bit" {
    const V = @Vector(8, f32);
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var n: u32 = 0;
    while (n < 200) : (n += 1) {
        var xs: [8]f32 = undefined;
        for (&xs) |*x| x.* = rnd.float(f32) * 60 - 10;
        const y = rnd.float(f32) * 40 - 5;
        const b = [4]f32{ rnd.float(f32) * 20, rnd.float(f32) * 20, rnd.float(f32) * 30, rnd.float(f32) * 20 };
        const r = [4]f32{ rnd.float(f32) * 5, rnd.float(f32) * 5, rnd.float(f32) * 5, rnd.float(f32) * 5 };
        const vx: V = xs;
        const vy: V = @splat(y);
        const cov: [8]f32 = boxCoverageT(V, vx, vy, b, r);
        const sh: [8]f32 = roundedBoxShadowT(V, vx, vy, .{ b[0], b[1] }, .{ b[0] + b[2], b[1] + b[3] }, 2.5, r);
        const tc: [8]f32 = textCoverageT(V, clampT(V, vx * @as(V, @splat(0.02)), 0, 1), 0.3, .{});
        for (xs, 0..) |x, i| {
            try testing.expectEqual(boxCoverageT(f32, x, y, b, r), cov[i]);
            try testing.expectEqual(roundedBoxShadowT(f32, x, y, .{ b[0], b[1] }, .{ b[0] + b[2], b[1] + b[3] }, 2.5, r), sh[i]);
            try testing.expectEqual(textCoverageT(f32, std.math.clamp(x * 0.02, 0, 1), 0.3, .{}), tc[i]);
        }
    }
}

test "shading: vector exp equals @exp bit for bit" {
    const V8 = @Vector(8, f32);
    var buf: [8]f32 = undefined;
    var n: usize = 0;
    var checked: u64 = 0;
    // Every 1021st bit pattern (both signs, NaNs and infinities included),
    // plus the range boundaries.
    var b: u64 = 0;
    while (b <= 0xFFFF_FFFF) : (b += 1021) {
        buf[n] = @bitCast(@as(u32, @intCast(b)));
        n += 1;
        if (n == 8) {
            try expectExpLanes(V8, buf);
            n = 0;
            checked += 8;
        }
    }
    const edges = [_]u32{ 0x42AEAC50, 0x42AEAC4F, 0x42b17218, 0x42b17217, 0xC2CFF1B5, 0xC2CFF1B4, 0xC2AEAC50, 0x3F851592, 0x3F851593, 0x3EB17218, 0x3EB17219, 0x39000000, 0x39000001, 0xBF851593, 0xBEB17219, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0xC2C80000, 0xC2B00000 };
    var i: usize = 0;
    while (i < edges.len) : (i += 8) {
        for (&buf, 0..) |*e, j| e.* = @bitCast(edges[@min(i + j, edges.len - 1)]);
        try expectExpLanes(V8, buf);
    }
    try std.testing.expect(checked > 4_000_000);
}

fn expectExpLanes(comptime V: type, in: [8]f32) !void {
    const got: [8]f32 = expT(V, in);
    for (in, got) |x, g| {
        const want = @exp(x);
        if (std.math.isNan(want)) {
            try std.testing.expect(std.math.isNan(g));
        } else if (@as(u32, @bitCast(want)) != @as(u32, @bitCast(g))) {
            std.debug.print("exp({e}) = {e}, vector gave {e}\n", .{ x, want, g });
            return error.TestExpectedEqual;
        }
    }
}
