//! The frozen 64-byte instance record shared by the CPU and GPU backends
//! (std430-compatible). One `Prim` is one screen-aligned quad; the shading
//! of every kind is defined by `shading.zig` and mirrored by the shaders.
//!
//! Field use per kind (all positions in physical pixels):
//!
//! | kind | bounds | uv | color0 | color1 | params |
//! |---|---|---|---|---|---|
//! | rect | shape | – | fill | – | – |
//! | border | outer shape | widths l,t,r,b | border | – | – |
//! | shadow | shape after spread | – | shadow | – | f16 sigma, f16 spread |
//! | linear_gradient | shape | p0.x,p0.y,p1.x,p1.y | start | end | – |
//! | glyph_* | quad | u0,v0,u1,v1 | text | – | – |
//! | image | shape | u0,v0,u1,v1 | tint | – | – |
//! | layer | shape | scroll x,y (plus the wrap origin), 0, 0 | opacity (white) | – | layer index |
//!
//! `radii` holds tl,tr | br,bl as f16 pairs (see `f16.zig`), already clamped
//! to half the shape's smaller side. `color0`/`color1` are premultiplied
//! sRGB-encoded RGBA8 (`Color.toU32`).

const std = @import("std");
const f16p = @import("f16.zig");

/// Primitive kinds. The fragment shader switches on this value.
pub const Kind = enum(u8) {
    /// Filled rounded rectangle.
    rect,
    /// Rounded rectangle outline with per-edge widths.
    border,
    /// Gaussian-blurred rounded rectangle (drop shadow).
    shadow,
    /// Two-stop linear gradient filling a rounded rectangle.
    linear_gradient,
    /// Glyph with one coverage channel.
    glyph_gray,
    /// Glyph with per-channel coverage (dual-source blending).
    glyph_subpixel,
    /// Colour glyph (emoji), premultiplied.
    glyph_color,
    /// Textured rounded rectangle.
    image,
    /// Composite of an offscreen layer.
    layer,
    _,

    /// Whether the kind samples a glyph atlas page.
    pub fn isGlyph(k: Kind) bool {
        return switch (k) {
            .glyph_gray, .glyph_subpixel, .glyph_color => true,
            else => false,
        };
    }
};

/// Per-prim flags.
pub const Flags = packed struct(u8) {
    /// Sample the texture with nearest filtering (images, layers).
    nearest: bool = false,
    /// Subpixel text on a BGR panel: swap the red and blue coverage.
    bgr: bool = false,
    /// Glyph coverage is thresholded at 50% (`TextAa.none`).
    aa_none: bool = false,
    /// Grayscale glyph from an `rgb_subpixel` page: average r, g and b.
    rgb_avg: bool = false,
    /// Layer composite of a scroll layer: sample with wraparound.
    wrap: bool = false,
    _: u3 = 0,
};

/// One instance. See the file comment for per-kind field use.
pub const Prim = extern struct {
    /// x, y, w, h in physical pixels.
    bounds: [4]f32,
    /// Kind-specific: texture rect, gradient points, border widths, scroll.
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    /// Primary colour, premultiplied RGBA8.
    color0: u32 = 0,
    /// Secondary colour (gradient end), premultiplied RGBA8.
    color1: u32 = 0,
    /// tl,tr | br,bl corner radii as f16 pairs.
    radii: [2]u32 = .{ 0, 0 },
    /// Kind-specific packed parameters.
    params: u32 = 0,
    /// Index of the clip in the draw list's clip table (0 = none).
    clip: u16 = 0,
    /// Texture slot (`TextureId`), 0 when unused.
    tex: u16 = 0,
    /// What to draw.
    kind: Kind,
    /// See `Flags`.
    flags: Flags = .{},
    /// Index of the layer the prim is drawn into (0 = the window).
    layer_z: u16 = 0,
    _pad: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(Prim) == 64);
        std.debug.assert(@alignOf(Prim) == 4);
    }

    /// Unpacked radii tl, tr, br, bl.
    pub fn radiiF(p: *const Prim) [4]f32 {
        const a = f16p.unpack2(p.radii[0]);
        const b = f16p.unpack2(p.radii[1]);
        return .{ a[0], a[1], b[0], b[1] };
    }

    /// Shadow blur sigma and spread.
    pub fn shadowParams(p: *const Prim) [2]f32 {
        return f16p.unpack2(p.params);
    }

    /// The rectangle (x0, y0, x1, y1) of pixels whose centre the prim may
    /// touch: the bounds plus a 1 px anti-aliasing fringe, plus the blur
    /// extent for shadows. Glyph quads are hard-edged and not expanded.
    /// Both backends rasterise exactly this rectangle.
    pub fn coverRect(p: *const Prim) [4]f32 {
        const b = p.bounds;
        const grow: f32 = switch (p.kind) {
            .glyph_gray, .glyph_subpixel, .glyph_color => 0,
            .shadow => @ceil(3.0 * p.shadowParams()[0]) + 1.0,
            else => 1,
        };
        return .{ b[0] - grow, b[1] - grow, b[0] + b[2] + grow, b[1] + b[3] + grow };
    }
};

test "prim: size 64 align 4" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Prim));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(Prim));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Prim, "kind"));
}

test "prim: cover rect grows for AA and blur" {
    const r: Prim = .{ .bounds = .{ 10, 10, 5, 5 }, .kind = .rect };
    try std.testing.expectEqual([4]f32{ 9, 9, 16, 16 }, r.coverRect());
    const g: Prim = .{ .bounds = .{ 10, 10, 5, 5 }, .kind = .glyph_gray };
    try std.testing.expectEqual([4]f32{ 10, 10, 15, 15 }, g.coverRect());
    const s: Prim = .{ .bounds = .{ 10, 10, 5, 5 }, .kind = .shadow, .params = f16p.pack2(2, 0) };
    try std.testing.expectEqual([4]f32{ 3, 3, 22, 22 }, s.coverRect());
}
