//! The `solid` test shaders (E02.F05.S01.T02): a full-screen triangle
//! filled with the push-constant colour. They are the end-to-end smoke
//! test of builder, validator, shaderc, embedding and
//! `vkCreateShaderModule`.

const common = @import("common.zig");

/// The fragment push constants (16 bytes).
pub const PushConstants = extern struct {
    /// Premultiplied linear RGBA written to every pixel.
    color: [4]f32,
};

pub fn vertex(s: *common.Shader) anyerror!void {
    _ = try common.fullscreenTriangle(s);
}

pub fn fragment(s: *common.Shader) anyerror!void {
    const pc = try s.pushConstant(PushConstants);
    const out = try s.output(common.Vec4, 0, 0);
    try out.store(try pc.get("color"));
}
