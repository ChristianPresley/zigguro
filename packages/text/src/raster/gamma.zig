//! Text gamma and contrast: the CPU reference of E02's `textCoverage`
//! shader correction (E02.F06.S02.T01). Atlas coverage stays linear
//! analytic area; E02 blends text in sRGB-encoded space and reshapes the
//! coverage by the foreground's luma first, so dark-on-light text gets the
//! same perceived weight as light-on-dark:
//!
//!   gamma_adj = mix(gamma, 1/gamma, luma)
//!   cov = pow(cov, gamma_adj)
//!   cov = clamp(cov + contrast*cov*(1-cov), 0, 1)
//!
//! `pow` is GLSL's: exp2(y * log2(x)), and 0 at x = 0. Any change to the
//! formula lands here and in E02 in the same PR; both suites test against
//! `testdata/text_coverage_vectors.zon`.

const std = @import("std");

/// Gamma and contrast; the same fields and defaults as E02 `TextParams`
/// (tunable in E15 settings). 1.8 is FreeType's recommended target.
pub const GammaParams = struct {
    gamma: f32 = 1.8,
    contrast: f32 = 0.25,
};

/// Corrected coverage for linear coverage `cov` drawn in a colour of luma
/// `fg_luma` (both in [0, 1]).
pub fn textCoverage(cov: f32, fg_luma: f32, p: GammaParams) f32 {
    const v = textCoverageV(@splat(cov), fg_luma, p);
    return v[0];
}

/// Eight lanes of `textCoverage`; every lane equals the scalar result.
pub fn textCoverageV(cov: @Vector(8, f32), fg_luma: f32, p: GammaParams) @Vector(8, f32) {
    const V = @Vector(8, f32);
    const g = p.gamma + (1 / p.gamma - p.gamma) * fg_luma;
    const zero: V = @splat(0);
    const one: V = @splat(1);
    const c0 = std.math.clamp(cov, zero, one);
    const powed = @exp2(@as(V, @splat(g)) * @log2(c0));
    const c = @select(f32, c0 > zero, powed, zero);
    const k: V = @splat(p.contrast);
    return std.math.clamp(c + k * c * (one - c), zero, one);
}

/// Rec. 709 luma of an sRGB-encoded colour with components in [0, 1]
/// (E02's convention: no linearization).
pub fn luma(rgb_srgb_encoded: [3]f32) f32 {
    const c = rgb_srgb_encoded;
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

const testing = std.testing;

const VectorFile = struct {
    vectors: []const struct { cov: f32, luma: f32, gamma: f32, contrast: f32, expected: f32 },
};

test "textCoverage matches shared vectors" {
    const fonts = @import("../testing/fonts.zig");
    const gpa = testing.allocator;
    const src = try fonts.readTestdataZ(gpa, "text_coverage_vectors.zon");
    defer gpa.free(src);
    const f = try std.zon.parse.fromSliceAlloc(VectorFile, gpa, src, null, .{});
    defer std.zon.parse.free(gpa, f);
    try testing.expect(f.vectors.len >= 50);
    for (f.vectors) |v| {
        const got = textCoverage(v.cov, v.luma, .{ .gamma = v.gamma, .contrast = v.contrast });
        try testing.expectApproxEqAbs(v.expected, got, 1e-5);
    }
}

test "textCoverage monotone in coverage" {
    for ([_]f32{ 0, 0.3, 1 }) |l| {
        var prev: f32 = -1;
        for (0..256) |i| {
            const c = textCoverage(@as(f32, @floatFromInt(i)) / 255, l, .{});
            try testing.expect(c >= prev);
            prev = c;
        }
        try testing.expectEqual(@as(f32, 0), textCoverage(0, l, .{}));
        try testing.expectApproxEqAbs(@as(f32, 1), textCoverage(1, l, .{}), 1e-6);
    }
}

test "contrast 0 gamma 1 is identity" {
    for (0..256) |i| {
        const c = @as(f32, @floatFromInt(i)) / 255;
        try testing.expectApproxEqAbs(c, textCoverage(c, 0.5, .{ .gamma = 1, .contrast = 0 }), 1e-6);
    }
}

test "vector equals scalar" {
    var lanes: [8]f32 = undefined;
    for (0..32) |i| {
        for (&lanes, 0..) |*l, k| l.* = @as(f32, @floatFromInt(i * 8 + k)) / 255;
        const v: [8]f32 = textCoverageV(lanes, 0.8, .{});
        for (lanes, v) |c, got| try testing.expectEqual(textCoverage(c, 0.8, .{}), got);
    }
}

test "luma weights" {
    try testing.expectApproxEqAbs(@as(f32, 1), luma(.{ 1, 1, 1 }), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.7152), luma(.{ 0, 1, 0 }), 1e-6);
}
