//! The dual-source subpixel text fragment shader (E02.F05.S01.T05), used
//! with `prim.vert` by the `text_subpixel` pipeline. It mirrors
//! `shading.blendSubpixelT` through the blend unit:
//!
//! - colour: `SRC = ONE`, `DST = ONE_MINUS_SRC1_COLOR`, so
//!   `out.c = color.c * cov.c + dst.c * (1 - color.a * cov.c)`;
//! - alpha: `ONE, ONE_MINUS_SRC_ALPHA` with `src.a = color.a * max(cov)`.
//!
//! Location 0 index 0 is `color.rgb * cov.rgb`, index 1 is
//! `color.a * cov.rgb`. Prims of any other kind draw nothing. Needs the
//! `dualSrcBlend` feature; without it the backend draws subpixel glyphs
//! with `prim.frag` (averaged coverage).

const dsl = @import("spirv").dsl;
const sdf = @import("sdf.zig");
const iface = @import("interface.zig");
const prim = @import("prim.zig");

const F = sdf.F;
const Vec4 = dsl.Vec4;
const k = sdf.k;

pub fn fragment(s: *dsl.Shader) anyerror!void {
    const f = try prim.Frag.init(s);
    const textures = try s.sampledImageArray(iface.set, iface.binding_textures);
    const out0 = try s.output(Vec4, 0, 0);
    const out1 = try s.output(Vec4, 0, 1);
    const c0 = f.color0;

    const t = try textures.at(f.tex);
    const size = try t.size();
    const tx = try prim.sampleNearest(s, t, size, try f.texelCoords(size));
    // BGR panels swap the red and blue coverage.
    const bgr = try f.flag("bgr");
    const rc = try F.select(bgr, try tx.z(), try tx.x());
    const bc = try F.select(bgr, try tx.x(), try tx.z());
    const l = try sdf.textLuma(s, c0);
    const gamma = try f.b.pc.get("text_gamma");
    const contrast = try f.b.pc.get("text_contrast");
    const clip = try f.clipCoverage();
    // Only glyph_subpixel prims draw.
    const is_sub = try f.kind.eq(try s.c(u32, @intFromEnum(prim.Kind.glyph_subpixel)));
    const keep = try F.select(is_sub, clip, try k(s, 0));
    const cr = try (try sdf.textCoverage(s, rc, l, gamma, contrast)).mul(keep);
    const cg = try (try sdf.textCoverage(s, try tx.y(), l, gamma, contrast)).mul(keep);
    const cb = try (try sdf.textCoverage(s, bc, l, gamma, contrast)).mul(keep);
    const ca = try (try cr.max(cg)).max(cb);
    const a = try c0.w();
    try out0.store(try s.vec(Vec4, .{ try (try c0.x()).mul(cr), try (try c0.y()).mul(cg), try (try c0.z()).mul(cb), try a.mul(ca) }));
    try out1.store(try s.vec(Vec4, .{ try a.mul(cr), try a.mul(cg), try a.mul(cb), try a.mul(ca) }));
}
