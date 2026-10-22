//! Helpers shared by the shader programs (E02.F05.S01.T02). Programs run
//! at build time under tools/shaderc; see ADR-E02-004.

const spirv = @import("spirv");
const dsl = spirv.dsl;

pub const Shader = dsl.Shader;
pub const Vec2 = dsl.Vec2;
pub const Vec4 = dsl.Vec4;

/// Writes `gl_Position` for a full-screen triangle drawn with three
/// vertices and no vertex buffer, and returns its uv (0..1 over the
/// screen, 0..2 at the overhanging corners).
pub fn fullscreenTriangle(s: *Shader) !dsl.Val(Vec2) {
    const vid = try s.builtin(.VertexIndex);
    const two = try s.c(u32, 2);
    // (vid << 1) & 2, vid & 2: (0,0), (2,0), (0,2).
    const ux = try (try vid.shl(try s.c(u32, 1))).@"and"(two);
    const uy = try vid.@"and"(two);
    const uv = try s.vec(Vec2, .{ try ux.to(f32), try uy.to(f32) });
    const p = try (try uv.scale(try s.c(f32, 2.0))).sub(try s.c(Vec2, 1.0));
    const pos = try s.vec(Vec4, .{ try p.x(), try p.y(), try s.c(f32, 0.0), try s.c(f32, 1.0) });
    try (try s.position()).store(pos);
    return uv;
}
