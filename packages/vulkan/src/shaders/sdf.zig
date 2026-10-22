//! The shading math of `r2d/shading.zig` in the shader DSL
//! (E02.F05.S01.T05). Each function mirrors the CPU function of the same
//! name operation by operation; a change to `shading.zig` must change
//! this file in the same PR (the GPU/software parity test catches drift).

const dsl = @import("spirv").dsl;

pub const Shader = dsl.Shader;
pub const F = dsl.Val(f32);
pub const B = dsl.Val(bool);

/// The constant `v`.
pub fn k(s: *Shader, v: f32) !F {
    return s.c(f32, v);
}

fn sel(c: B, a: F, b: F) !F {
    return F.select(c, a, b);
}

/// `shading.clampT`.
pub fn clamp01(s: *Shader, x: F) !F {
    return x.clamp(try k(s, 0), try k(s, 1));
}

/// `shading.sdRoundedBoxT`: `(px, py)` relative to the centre, radii
/// tl, tr, br, bl.
pub fn sdRoundedBox(s: *Shader, px: F, py: F, hx: F, hy: F, r: [4]F) !F {
    const zero = try k(s, 0);
    const right = try px.gt(zero);
    const bottom = try py.gt(zero);
    const rr = try sel(right, try sel(bottom, r[2], r[1]), try sel(bottom, r[3], r[0]));
    const qx = try (try (try px.abs()).sub(hx)).add(rr);
    const qy = try (try (try py.abs()).sub(hy)).add(rr);
    const mx = try qx.max(zero);
    const my = try qy.max(zero);
    const inside = try (try qx.max(qy)).min(zero);
    const len = try (try (try mx.mul(mx)).add(try my.mul(my))).sqrt();
    return (try inside.add(len)).sub(rr);
}

/// `shading.coverageFromSdfT`: `clamp(0.5 - d, 0, 1)`.
pub fn coverageFromSdf(s: *Shader, d: F) !F {
    return clamp01(s, try (try k(s, 0.5)).sub(d));
}

/// `shading.boxCoverageT`: box `b` = x, y, w, h (absolute pixels).
pub fn boxCoverage(s: *Shader, px: F, py: F, b: [4]F, r: [4]F) !F {
    const zero = try k(s, 0);
    const half = try k(s, 0.5);
    const nonempty = try (try b[2].gt(zero)).@"and"(try b[3].gt(zero));
    const hx = try b[2].mul(half);
    const hy = try b[3].mul(half);
    const d = try sdRoundedBox(s, try px.sub(try b[0].add(hx)), try py.sub(try b[1].add(hy)), hx, hy, r);
    return sel(nonempty, try coverageFromSdf(s, d), zero);
}

/// `shading.borderCoverageT`: widths `w` = l, t, r, b.
pub fn borderCoverage(s: *Shader, px: F, py: F, b: [4]F, r: [4]F, w: [4]F) !F {
    const zero = try k(s, 0);
    const outer = try boxCoverage(s, px, py, b, r);
    const inner_box = [4]F{
        try b[0].add(w[0]),
        try b[1].add(w[1]),
        try (try b[2].sub(w[0])).sub(w[2]),
        try (try b[3].sub(w[1])).sub(w[3]),
    };
    const inner_r = [4]F{
        try (try r[0].sub(try w[0].max(w[1]))).max(zero),
        try (try r[1].sub(try w[2].max(w[1]))).max(zero),
        try (try r[2].sub(try w[2].max(w[3]))).max(zero),
        try (try r[3].sub(try w[0].max(w[3]))).max(zero),
    };
    const inner = try boxCoverage(s, px, py, inner_box, inner_r);
    return outer.mul(try (try k(s, 1)).sub(inner));
}

fn sign(s: *Shader, x: F) !F {
    const zero = try k(s, 0);
    return sel(try x.gt(zero), try k(s, 1), try sel(try x.lt(zero), try k(s, -1), zero));
}

/// `shading.erfT`.
pub fn erf(s: *Shader, x: F) !F {
    const sg = try sign(s, x);
    const a = try x.abs();
    const inner = try (try k(s, 0.230389)).add(try (try k(s, 0.078108)).mul(try a.mul(a)));
    const mid = try (try k(s, 0.278393)).add(try inner.mul(a));
    var t = try (try k(s, 1)).add(try mid.mul(a));
    t = try t.mul(t);
    return sg.sub(try sg.div(try t.mul(t)));
}

fn gaussian(s: *Shader, x: F, sigma: F) !F {
    const inv = try (try k(s, 1)).div(try (try k(s, 2.5066282746)).mul(sigma));
    const two_s2 = try (try (try k(s, 2.0)).mul(sigma)).mul(sigma);
    const e = try (try (try x.mul(x)).neg()).div(two_s2);
    return (try e.exp()).mul(inv);
}

fn shadowX(s: *Shader, x: F, y: F, sigma: F, corner: F, hx: F, hy: F) !F {
    const zero = try k(s, 0);
    const half = try k(s, 0.5);
    const delta = try (try (try hy.sub(corner)).sub(try y.abs())).min(zero);
    const root = try (try zero.max(try (try corner.mul(corner)).sub(try delta.mul(delta)))).sqrt();
    const curved = try (try hx.sub(corner)).add(root);
    const kk = try (try k(s, 0.70710678)).div(sigma);
    const lo = try half.add(try half.mul(try erf(s, try (try x.sub(curved)).mul(kk))));
    const hi = try half.add(try half.mul(try erf(s, try (try x.add(curved)).mul(kk))));
    return hi.sub(lo);
}

/// `shading.roundedBoxShadowT`: the box spans `lower`..`upper`.
pub fn roundedBoxShadow(s: *Shader, px: F, py: F, lower: [2]F, upper: [2]F, sigma_in: F, r: [4]F) !F {
    const zero = try k(s, 0);
    const half = try k(s, 0.5);
    const sigma = try sigma_in.max(try k(s, 0.25));
    const cx = try (try lower[0].add(upper[0])).mul(half);
    const cy = try (try lower[1].add(upper[1])).mul(half);
    const hx = try (try upper[0].sub(lower[0])).mul(half);
    const hy = try (try upper[1].sub(lower[1])).mul(half);
    const x = try px.sub(cx);
    const yp = try py.sub(cy);
    const right = try x.gt(zero);
    const bottom = try yp.gt(zero);
    const corner = try sel(right, try sel(bottom, r[2], r[1]), try sel(bottom, r[3], r[0]));
    const low = try yp.sub(hy);
    const high = try yp.add(hy);
    const three_s = try (try k(s, 3.0)).mul(sigma);
    const start = try (try (try three_s.neg()).max(low)).min(high);
    const end = try (try three_s.max(low)).min(high);
    const step = try (try end.sub(start)).mul(try k(s, 0.25));
    var y = try start.add(try step.mul(half));
    var value = zero;
    inline for (0..4) |_| {
        const term = try (try (try shadowX(s, x, try yp.sub(y), sigma, corner, hx, hy)).mul(try gaussian(s, y, sigma))).mul(step);
        value = try value.add(term);
        y = try y.add(step);
    }
    return value;
}

/// `shading.luma`.
pub fn luma(s: *Shader, r: F, g: F, b: F) !F {
    const lr = try (try k(s, 0.2126)).mul(r);
    const lg = try (try k(s, 0.7152)).mul(g);
    const lb = try (try k(s, 0.0722)).mul(b);
    return (try lr.add(lg)).add(lb);
}

/// `raster.textLuma`: luminance of a premultiplied colour.
pub fn textLuma(s: *Shader, c: dsl.Val(dsl.Vec4)) !F {
    const zero = try k(s, 0);
    const a = try c.w();
    const safe_a = try sel(try a.gt(zero), a, try k(s, 1));
    const l = try luma(s, try (try c.x()).div(safe_a), try (try c.y()).div(safe_a), try (try c.z()).div(safe_a));
    return sel(try a.gt(zero), l, zero);
}

/// `shading.textCoverageT`: gamma and contrast correction of coverage.
pub fn textCoverage(s: *Shader, cov: F, l: F, gamma: F, contrast: F) !F {
    const zero = try k(s, 0);
    const one = try k(s, 1);
    const g = try gamma.add(try (try (try one.div(gamma)).sub(gamma)).mul(l));
    const pos = try cov.gt(zero);
    const safe = try sel(pos, cov, one);
    const powed = try sel(pos, try (try (try safe.log()).mul(g)).exp(), zero);
    const boosted = try powed.add(try (try contrast.mul(powed)).mul(try one.sub(powed)));
    return clamp01(s, boosted);
}

/// `shading.gradientT`.
pub fn gradient(s: *Shader, px: F, py: F, p0: [2]F, p1: [2]F) !F {
    const zero = try k(s, 0);
    const dx = try p1[0].sub(p0[0]);
    const dy = try p1[1].sub(p0[1]);
    const len2 = try (try dx.mul(dx)).add(try dy.mul(dy));
    const ok = try len2.gt(zero);
    const safe = try sel(ok, len2, try k(s, 1));
    const t = try (try (try (try px.sub(p0[0])).mul(dx)).add(try (try py.sub(p0[1])).mul(dy))).div(safe);
    return sel(ok, try clamp01(s, t), zero);
}
