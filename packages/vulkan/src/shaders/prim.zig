//! The prim ubershader (E02.F05.S01.T05): one instanced quad per
//! `r2d.Prim`, shaded by kind exactly as the software renderer does
//! (`sw/raster.zig` `shadeGroup`, math in `sdf.zig`). Output is
//! premultiplied sRGB-encoded colour for source-over blending
//! (`ONE, ONE_MINUS_SRC_ALPHA`).
//!
//! The vertex shader reads the prim and its clip from the storage buffers
//! and emits the corners of `Prim.coverRect` intersected with the clip
//! bounds grown by 1 px (as `sw/bin.zig` `primSpan`), as a 4-vertex
//! triangle strip. The fragment shader works from `gl_FragCoord` (pixel
//! centres at +0.5) and the flat instance index.

const dsl = @import("spirv").dsl;
const sdf = @import("sdf.zig");
const iface = @import("interface.zig");
const prim = @import("../r2d/prim.zig");

const Shader = dsl.Shader;
const F = sdf.F;
const Vec2 = dsl.Vec2;
const Vec4 = dsl.Vec4;
const k = sdf.k;

pub const Kind = prim.Kind;

/// The inputs every prim shader declares.
pub const Bindings = struct {
    pc: dsl.Fields(iface.PushConstants),
    prims: dsl.StorageArray(iface.PrimGpu),
    clips: dsl.StorageArray(iface.ClipGpu),

    pub fn declare(s: *Shader) !Bindings {
        return .{
            .pc = try s.pushConstant(iface.PushConstants),
            .prims = try s.storageBuffer(iface.PrimGpu, iface.set, iface.binding_prims),
            .clips = try s.storageBuffer(iface.ClipGpu, iface.set, iface.binding_clips),
        };
    }
};

pub fn comps(v: dsl.Val(Vec4)) ![4]F {
    return .{ try v.x(), try v.y(), try v.z(), try v.w() };
}

/// Unpacks `Prim.radii` (tl, tr | br, bl as f16 pairs).
pub fn radii(s: *Shader, packed_radii: dsl.Val(dsl.UVec2)) ![4]F {
    const a = try s.unpackHalf2x16(try packed_radii.x());
    const b = try s.unpackHalf2x16(try packed_radii.y());
    return .{ try a.x(), try a.y(), try b.x(), try b.y() };
}

fn u(s: *Shader, v: u32) !dsl.Val(u32) {
    return s.c(u32, v);
}

/// Field `bits` of `word` starting at bit `shift`.
pub fn bits(s: *Shader, word: dsl.Val(u32), shift: u32, mask: u32) !dsl.Val(u32) {
    return (try word.shr(try u(s, shift))).@"and"(try u(s, mask));
}

pub fn vertex(s: *Shader) anyerror!void {
    const b = try Bindings.declare(s);
    const idx = try s.builtin(.InstanceIndex);
    const vid = try s.builtin(.VertexIndex);
    const p = try b.prims.at(idx);
    const bounds = try comps(try p.get("bounds"));
    const kind = try bits(s, try p.get("kind_flags"), 0, 0xff);
    const params = try s.unpackHalf2x16(try p.get("params"));

    // Prim.coverRect: glyphs 0, shadows ceil(3 sigma) + 1, others 1.
    const is_glyph = try (try kind.ge(try u(s, @intFromEnum(Kind.glyph_gray)))).@"and"(try kind.le(try u(s, @intFromEnum(Kind.glyph_color))));
    const is_shadow = try kind.eq(try u(s, @intFromEnum(Kind.shadow)));
    const shadow_grow = try (try (try (try k(s, 3.0)).mul(try params.x())).ceil()).add(try k(s, 1.0));
    const grow = try F.select(is_glyph, try k(s, 0), try F.select(is_shadow, shadow_grow, try k(s, 1)));
    var x0 = try bounds[0].sub(grow);
    var y0 = try bounds[1].sub(grow);
    var x1 = try (try bounds[0].add(bounds[2])).add(grow);
    var y1 = try (try bounds[1].add(bounds[3])).add(grow);

    // Intersect with the clip bounds grown by 1 px (clip 0 = none).
    const clip = try bits(s, try p.get("clip_tex"), 0, 0xffff);
    const has_clip = try clip.ne(try u(s, 0));
    const c = try comps(try (try b.clips.at(try (try b.pc.get("clip_base")).add(clip))).get("bounds"));
    const one = try k(s, 1);
    const cx0 = try c[0].sub(one);
    const cy0 = try c[1].sub(one);
    const cx1 = try (try c[0].add(c[2])).add(one);
    const cy1 = try (try c[1].add(c[3])).add(one);
    x0 = try F.select(has_clip, try x0.max(cx0), x0);
    y0 = try F.select(has_clip, try y0.max(cy0), y0);
    x1 = try F.select(has_clip, try x1.min(cx1), x1);
    y1 = try F.select(has_clip, try y1.min(cy1), y1);
    // An empty intersection must not turn into a mirrored quad.
    x1 = try x1.max(x0);
    y1 = try y1.max(y0);

    // Triangle strip corners: 0 (x0,y0), 1 (x1,y0), 2 (x0,y1), 3 (x1,y1).
    const zero_u = try u(s, 0);
    const px = try F.select(try (try vid.@"and"(try u(s, 1))).ne(zero_u), x1, x0);
    const py = try F.select(try (try vid.@"and"(try u(s, 2))).ne(zero_u), y1, y0);
    const inv = try b.pc.get("inv_viewport");
    const two = try k(s, 2);
    const ndc_x = try (try (try px.mul(try inv.x())).mul(two)).sub(one);
    const ndc_y = try (try (try py.mul(try inv.y())).mul(two)).sub(one);
    try (try s.position()).store(try s.vec(Vec4, .{ ndc_x, ndc_y, try k(s, 0), one }));
    try (try s.output(u32, 0, 0)).store(idx);
}

/// What the fragment shaders share: the prim, pixel centre and clip.
pub const Frag = struct {
    s: *Shader,
    b: Bindings,
    p: dsl.Fields(iface.PrimGpu),
    px: F,
    py: F,
    bounds: [4]F,
    radii: [4]F,
    uv: [4]F,
    color0: dsl.Val(Vec4),
    kind: dsl.Val(u32),
    flags: dsl.Val(u32),
    tex: dsl.Val(u32),

    pub fn init(s: *Shader) !Frag {
        const b = try Bindings.declare(s);
        const idx = try s.input(u32, 0, true);
        const fc = try s.builtin(.FragCoord);
        const p = try b.prims.at(idx);
        const kf = try p.get("kind_flags");
        return .{
            .s = s,
            .b = b,
            .p = p,
            .px = try fc.x(),
            .py = try fc.y(),
            .bounds = try comps(try p.get("bounds")),
            .radii = try radii(s, try p.get("radii")),
            .uv = try comps(try p.get("uv")),
            .color0 = try s.unpackUnorm4x8(try p.get("color0")),
            .kind = try bits(s, kf, 0, 0xff),
            .flags = try bits(s, kf, 8, 0xff),
            .tex = try bits(s, try p.get("clip_tex"), 16, 0xffff),
        };
    }

    /// Whether `Prim.Flags` bit `bit` is set.
    pub fn flag(f: *const Frag, comptime name: []const u8) !sdf.B {
        const bit: u32 = @as(u8, @bitCast(@as(prim.Flags, blk: {
            var fl: prim.Flags = .{};
            @field(fl, name) = true;
            break :blk fl;
        })));
        return (try f.flags.@"and"(try u(f.s, bit))).ne(try u(f.s, 0));
    }

    /// Clip coverage (1 without a clip): `boxCoverage` of the clip rect.
    pub fn clipCoverage(f: *const Frag) !F {
        const s = f.s;
        const clip = try bits(s, try f.p.get("clip_tex"), 0, 0xffff);
        const c = try f.b.clips.at(try (try f.b.pc.get("clip_base")).add(clip));
        const cov = try sdf.boxCoverage(s, f.px, f.py, try comps(try c.get("bounds")), try comps(try c.get("radii")));
        return F.select(try clip.ne(try u(s, 0)), cov, try k(s, 1));
    }

    /// The texel-space coordinates of the pixel in the prim's uv rect
    /// (`raster.shadeGroup`, glyph and image kinds).
    pub fn texelCoords(f: *const Frag, size: dsl.Val(Vec2)) ![2]F {
        const b = f.bounds;
        const uu = try (try f.uv[0].add(try (try (try f.px.sub(b[0])).div(b[2])).mul(try f.uv[2].sub(f.uv[0])))).mul(try size.x());
        const vv = try (try f.uv[1].add(try (try (try f.py.sub(b[1])).div(b[3])).mul(try f.uv[3].sub(f.uv[1])))).mul(try size.y());
        return .{ uu, vv };
    }
};

/// Nearest texel at texel coordinates (`floor` then the texel centre).
pub fn sampleNearest(s: *Shader, t: dsl.SampledImage, size: dsl.Val(Vec2), tc: [2]F) !dsl.Val(Vec4) {
    const half = try k(s, 0.5);
    const uu = try (try (try tc[0].floor()).add(half)).div(try size.x());
    const vv = try (try (try tc[1].floor()).add(half)).div(try size.y());
    return t.sample(try s.vec(Vec2, .{ uu, vv }));
}

/// Bilinear (clamp-to-edge sampler) at texel coordinates.
pub fn sampleLinear(s: *Shader, t: dsl.SampledImage, size: dsl.Val(Vec2), tc: [2]F) !dsl.Val(Vec4) {
    return t.sample(try s.vec(Vec2, .{ try tc[0].div(try size.x()), try tc[1].div(try size.y()) }));
}

/// The four channels of an r8 page replicate the coverage (as the
/// software renderer's `texel`): r8 views swizzle `r` into every channel.
pub fn fragment(s: *Shader) anyerror!void {
    const f = try Frag.init(s);
    const textures = try s.sampledImageArray(iface.set, iface.binding_textures);
    const out = try s.output(Vec4, 0, 0);
    const zero4 = try s.c(Vec4, 0.0);
    const c0 = f.color0;
    const gamma = try f.b.pc.get("text_gamma");
    const contrast = try f.b.pc.get("text_contrast");

    var sw = try s.beginSwitch(Vec4, f.kind, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 });
    // rect
    try sw.case(try c0.scale(try sdf.boxCoverage(s, f.px, f.py, f.bounds, f.radii)));
    // border: uv holds the widths l, t, r, b.
    try sw.case(try c0.scale(try sdf.borderCoverage(s, f.px, f.py, f.bounds, f.radii, f.uv)));
    // shadow: params = f16 sigma, spread.
    {
        const sp = try s.unpackHalf2x16(try f.p.get("params"));
        const b = f.bounds;
        const cov = try sdf.roundedBoxShadow(s, f.px, f.py, .{ b[0], b[1] }, .{ try b[0].add(b[2]), try b[1].add(b[3]) }, try sp.x(), f.radii);
        try sw.case(try c0.scale(try sdf.clamp01(s, cov)));
    }
    // linear_gradient: c0 + (c1 - c0) * t
    {
        const cov = try sdf.boxCoverage(s, f.px, f.py, f.bounds, f.radii);
        const t = try sdf.gradient(s, f.px, f.py, .{ f.uv[0], f.uv[1] }, .{ f.uv[2], f.uv[3] });
        const c1 = try s.unpackUnorm4x8(try f.p.get("color1"));
        const src = try c0.add(try (try c1.sub(c0)).scale(t));
        try sw.case(try src.scale(cov));
    }
    // glyph_gray
    {
        const t = try textures.at(f.tex);
        const size = try t.size();
        const tx = try sampleNearest(s, t, size, try f.texelCoords(size));
        const avg = try (try (try (try tx.x()).add(try tx.y())).add(try tx.z())).div(try k(s, 3));
        const c = try F.select(try f.flag("rgb_avg"), avg, try tx.x());
        const corrected = try sdf.textCoverage(s, c, try sdf.textLuma(s, c0), gamma, contrast);
        const thresholded = try F.select(try c.ge(try k(s, 0.5)), try k(s, 1), try k(s, 0));
        try sw.case(try c0.scale(try F.select(try f.flag("aa_none"), thresholded, corrected)));
    }
    // glyph_subpixel without dual-source blending: averaged coverage.
    {
        const t = try textures.at(f.tex);
        const size = try t.size();
        const tx = try sampleNearest(s, t, size, try f.texelCoords(size));
        const avg = try (try (try (try tx.x()).add(try tx.y())).add(try tx.z())).div(try k(s, 3));
        try sw.case(try c0.scale(try sdf.textCoverage(s, avg, try sdf.textLuma(s, c0), gamma, contrast)));
    }
    // glyph_color: premultiplied texel times the text alpha.
    {
        const t = try textures.at(f.tex);
        const size = try t.size();
        const tx = try sampleNearest(s, t, size, try f.texelCoords(size));
        try sw.case(try tx.scale(try c0.w()));
    }
    // image: texel times tint, bilinear unless `nearest`.
    {
        const t = try textures.at(f.tex);
        const size = try t.size();
        const tc = try f.texelCoords(size);
        const near = try sampleNearest(s, t, size, tc);
        const lin = try sampleLinear(s, t, size, tc);
        const tx = try dsl.Val(Vec4).select(try s.splat(dsl.BVec4, try f.flag("nearest")), near, lin);
        const cov = try sdf.boxCoverage(s, f.px, f.py, f.bounds, f.radii);
        try sw.case(try (try tx.mul(c0)).scale(cov));
    }
    // layer: pixels map 1:1 offset by the scroll position (uv.xy); the
    // backend stores the layer's texture slot in `tex`. Integral offsets
    // land on texel centres, so bilinear equals nearest there.
    {
        const t = try textures.at(f.tex);
        const size = try t.size();
        const tc = [2]F{ try (try f.px.sub(f.bounds[0])).add(f.uv[0]), try (try f.py.sub(f.bounds[1])).add(f.uv[1]) };
        const tx = try sampleLinear(s, t, size, tc);
        const cov = try sdf.boxCoverage(s, f.px, f.py, f.bounds, f.radii);
        try sw.case(try (try tx.mul(c0)).scale(cov));
    }
    const shaded = try sw.end(zero4);
    try out.store(try shaded.scale(try f.clipCoverage()));
}
