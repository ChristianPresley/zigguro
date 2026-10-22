//! The composite pass (E02.F05.S01.T05): a full-screen triangle that
//! samples a layer at `gl_FragCoord + offset`, wrapping around the layer
//! size for scroll layers (E02.F06.S03), times `opacity`. Push constants
//! are `interface.CompositeConstants`.

const dsl = @import("spirv").dsl;
const common = @import("common.zig");
const sdf = @import("sdf.zig");
const iface = @import("interface.zig");
const prim = @import("prim.zig");

const F = sdf.F;
const Vec2 = dsl.Vec2;
const Vec4 = dsl.Vec4;

pub fn vertex(s: *dsl.Shader) anyerror!void {
    _ = try common.fullscreenTriangle(s);
}

pub fn fragment(s: *dsl.Shader) anyerror!void {
    const pc = try s.pushConstant(iface.CompositeConstants);
    const textures = try s.sampledImageArray(iface.set, iface.binding_textures);
    const out = try s.output(Vec4, 0, 0);
    const fc = try s.builtin(.FragCoord);
    const size = try pc.get("size");
    const tc = try (try fc.swizzle("xy")).add(try pc.get("offset"));
    // t - size * floor(t / size)
    const wrapped = try tc.sub(try size.mul(try (try tc.div(size)).floor()));
    const wrap = try (try (try pc.get("flags")).@"and"(try s.c(u32, 1))).ne(try s.c(u32, 0));
    const t = try dsl.Val(Vec2).select(try s.splat(dsl.BVec2, wrap), wrapped, tc);
    const img = try textures.at(try pc.get("slot"));
    const tx = try prim.sampleLinear(s, img, size, .{ try t.x(), try t.y() });
    try out.store(try tx.scale(try pc.get("opacity")));
}
