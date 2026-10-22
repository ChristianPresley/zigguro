//! The frozen interface between the production shaders and the Vulkan
//! backend (E02.F05.S01.T05): descriptor bindings, push constants and the
//! GPU views of `r2d.Prim` and clip rects. Std-only, so both the shader
//! programs (under tools/shaderc) and zg_vulkan compile it; `hash` guards
//! the generated shaders against layout drift (`shaders.interface_hash`).

const std = @import("std");
const prim = @import("../r2d/prim.zig");

/// Descriptor set 0.
pub const set = 0;
/// `readonly buffer Prims { PrimGpu items[]; }`.
pub const binding_prims = 0;
/// `readonly buffer Clips { ClipGpu items[]; }`.
pub const binding_clips = 1;
/// `uniform sampler2D textures[]` (partially bound, variable count,
/// update-after-bind, non-uniform index).
pub const binding_textures = 2;

/// `r2d.Prim` as the shaders read it: the 16- and 8-bit fields are packed
/// into words (little-endian, low half first).
pub const PrimGpu = extern struct {
    bounds: [4]f32,
    uv: [4]f32,
    color0: u32,
    color1: u32,
    radii: [2]u32,
    params: u32,
    /// `clip` (low 16 bits) and `tex` (high 16 bits).
    clip_tex: u32,
    /// `kind` (bits 0..7), `flags` (bits 8..15), `layer_z` (bits 16..31).
    kind_flags: u32,
    _pad: u32,

    comptime {
        std.debug.assert(@sizeOf(PrimGpu) == @sizeOf(prim.Prim));
        std.debug.assert(@offsetOf(PrimGpu, "bounds") == @offsetOf(prim.Prim, "bounds"));
        std.debug.assert(@offsetOf(PrimGpu, "uv") == @offsetOf(prim.Prim, "uv"));
        std.debug.assert(@offsetOf(PrimGpu, "color0") == @offsetOf(prim.Prim, "color0"));
        std.debug.assert(@offsetOf(PrimGpu, "color1") == @offsetOf(prim.Prim, "color1"));
        std.debug.assert(@offsetOf(PrimGpu, "radii") == @offsetOf(prim.Prim, "radii"));
        std.debug.assert(@offsetOf(PrimGpu, "params") == @offsetOf(prim.Prim, "params"));
        std.debug.assert(@offsetOf(PrimGpu, "clip_tex") == @offsetOf(prim.Prim, "clip"));
        std.debug.assert(@offsetOf(prim.Prim, "tex") == @offsetOf(prim.Prim, "clip") + 2);
        std.debug.assert(@offsetOf(PrimGpu, "kind_flags") == @offsetOf(prim.Prim, "kind"));
        std.debug.assert(@offsetOf(prim.Prim, "flags") == @offsetOf(prim.Prim, "kind") + 1);
        std.debug.assert(@offsetOf(prim.Prim, "layer_z") == @offsetOf(prim.Prim, "kind") + 2);
    }
};

/// One clip rect (index 0 of a frame's clips is "no clip").
pub const ClipGpu = extern struct {
    /// x, y, w, h in physical pixels.
    bounds: [4]f32,
    /// tl, tr, br, bl.
    radii: [4]f32,
};

/// Push constants of the `prim` and `text_subpixel` pipelines (32 bytes,
/// vertex and fragment stages).
pub const PushConstants = extern struct {
    viewport_px: [2]f32,
    inv_viewport: [2]f32,
    /// Index of this frame's clip 0 in the clip buffer.
    clip_base: u32,
    text_gamma: f32,
    text_contrast: f32,
    flags: u32 = 0,
};

/// Push constants of the `composite` pipeline (the same 32-byte range).
pub const CompositeConstants = extern struct {
    /// Scroll offset in layer texels.
    offset: [2]f32,
    /// Layer size in texels (the wrap period).
    size: [2]f32,
    /// Texture slot of the layer.
    slot: u32,
    opacity: f32,
    _pad: u32 = 0,
    /// Bit 0: wrap around (scroll layers).
    flags: u32 = 0,
};

pub const push_constant_bytes = 32;

comptime {
    std.debug.assert(@sizeOf(PushConstants) == push_constant_bytes);
    std.debug.assert(@sizeOf(CompositeConstants) == push_constant_bytes);
    std.debug.assert(@sizeOf(ClipGpu) == 32);
}

/// A hash of every layout and binding above. The generated shaders record
/// the value they were built against.
pub fn hash() u64 {
    @setEvalBranchQuota(100_000);
    comptime var desc: []const u8 = std.fmt.comptimePrint("set={d} prims={d} clips={d} textures={d} pc={d};", .{ set, binding_prims, binding_clips, binding_textures, push_constant_bytes });
    // Type names depend on the module root, so only field names, offsets
    // and sizes go in.
    inline for (.{ prim.Prim, PrimGpu, ClipGpu, PushConstants, CompositeConstants }, 0..) |T, i| {
        desc = desc ++ std.fmt.comptimePrint("#{d}/{d}:", .{ i, @sizeOf(T) });
        inline for (@typeInfo(T).@"struct".fields) |f|
            desc = desc ++ std.fmt.comptimePrint("{s}@{d}:{d},", .{ f.name, @offsetOf(T, f.name), @sizeOf(f.type) });
    }
    inline for (@typeInfo(prim.Kind).@"enum".fields) |f| desc = desc ++ std.fmt.comptimePrint("{s}={d},", .{ f.name, f.value });
    return comptime std.hash.Wyhash.hash(0, desc);
}

test "interface: hash is stable within a build" {
    try std.testing.expectEqual(hash(), hash());
}
