//! Geometry, identifiers and small enums of the backend-agnostic 2D
//! rendering contract. Nothing here refers to Vulkan: E04 builds against
//! these types and any backend (Vulkan, software, later Metal) consumes them.
//!
//! Units: `RectF`, `Vec2`, `Radii` and `Insets` passed to `DrawList` are
//! logical pixels (multiplied by the list's scale at append time). `PxRect`
//! and `Size` are physical (device) pixels.

const std = @import("std");
const platform = @import("zg_platform");

/// An axis-aligned rectangle in physical pixels (shared with zg_platform).
pub const PxRect = platform.types.PxRect;

/// A size in physical pixels.
pub const Size = struct {
    /// Width.
    w: u32,
    /// Height.
    h: u32,
};

/// A point or vector in logical pixels.
pub const Vec2 = struct {
    /// Horizontal component; grows to the right.
    x: f32 = 0,
    /// Vertical component; grows downwards.
    y: f32 = 0,
};

/// An axis-aligned rectangle in logical pixels.
pub const RectF = struct {
    /// Left edge.
    x: f32,
    /// Top edge.
    y: f32,
    /// Width (negative or zero means empty).
    w: f32,
    /// Height (negative or zero means empty).
    h: f32,

    /// The rectangle covering whole physical pixels `r`.
    pub fn fromPx(r: PxRect) RectF {
        return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
    }
};

/// Per-corner radii, clockwise from the top-left corner.
pub const Radii = struct {
    /// Top-left.
    tl: f32 = 0,
    /// Top-right.
    tr: f32 = 0,
    /// Bottom-right.
    br: f32 = 0,
    /// Bottom-left.
    bl: f32 = 0,

    /// The same radius on every corner.
    pub fn all(r: f32) Radii {
        return .{ .tl = r, .tr = r, .br = r, .bl = r };
    }

    /// Whether every radius is zero.
    pub fn isZero(r: Radii) bool {
        return r.tl == 0 and r.tr == 0 and r.br == 0 and r.bl == 0;
    }
};

/// Edge widths, used for borders.
pub const Insets = struct {
    /// Left.
    l: f32 = 0,
    /// Top.
    t: f32 = 0,
    /// Right.
    r: f32 = 0,
    /// Bottom.
    b: f32 = 0,

    /// The same width on every edge.
    pub fn all(w: f32) Insets {
        return .{ .l = w, .t = w, .r = w, .b = w };
    }
};

/// How glyph coverage is turned into colour.
pub const TextAa = enum(u2) {
    /// One coverage value per pixel.
    grayscale,
    /// Per-channel coverage for RGB-ordered panels (dual-source blending).
    subpixel_rgb,
    /// Per-channel coverage for BGR-ordered panels.
    subpixel_bgr,
    /// Coverage thresholded at 50%.
    none,
};

/// The pixel format of an atlas page a glyph comes from (E03 contract).
pub const AtlasFormat = enum(u8) {
    /// One coverage byte per texel.
    r8,
    /// RGB coverage plus max(r,g,b) in alpha.
    rgb_subpixel,
    /// Premultiplied colour (emoji).
    rgba_color,
};

/// One positioned glyph, produced by E03's shaper and atlas.
pub const GlyphQuad = extern struct {
    /// Destination rectangle x, y, w, h in logical pixels.
    dst: [4]f32,
    /// Atlas rectangle u0, v0, u1, v1, normalised to the page size.
    uv: [4]f32,
    /// Atlas page; mapped to a texture through `DrawList.setGlyphPages`.
    page: u16,
    /// The page's format.
    format: AtlasFormat,
    _p: u8 = 0,
};

/// A texture registered with a renderer. Ids are small integers (the
/// bindless slot on the GPU); `none` means "no texture".
pub const TextureId = enum(u32) {
    /// No texture.
    none = 0,
    _,
};

/// An offscreen layer chosen by E04 (any stable value, e.g. a widget id).
pub const LayerId = enum(u32) { _ };

/// Which implementation backs a `Renderer`.
pub const Backend = enum(u8) {
    /// Vulkan (E02.F01 to E02.F06).
    vulkan,
    /// The CPU renderer (E02.F07).
    software,
    /// Metal (E02.F08, later).
    metal,
};

/// Texel formats a renderer can store.
pub const TextureFormat = enum(u8) {
    /// One 8-bit channel (grayscale glyph coverage).
    r8,
    /// Four 8-bit channels, premultiplied RGBA (images, colour glyphs,
    /// subpixel coverage).
    rgba8,

    /// Bytes per texel.
    pub fn bytesPerTexel(f: TextureFormat) u32 {
        return switch (f) {
            .r8 => 1,
            .rgba8 => 4,
        };
    }
};

/// How a texture is filtered when it is not drawn 1:1.
pub const Filter = enum(u1) {
    /// Bilinear, clamped to the edge.
    linear,
    /// Nearest texel.
    nearest,
};

/// Describes a texture to create.
pub const TextureDesc = struct {
    /// Width in texels.
    width: u32,
    /// Height in texels.
    height: u32,
    /// Texel format.
    format: TextureFormat,
};

/// A clip region: a rounded rectangle in physical pixels. Index 0 of a
/// draw list's clip table is "no clip".
pub const ClipRect = struct {
    /// x, y, w, h in physical pixels.
    bounds: [4]f32,
    /// tl, tr, br, bl radii in physical pixels (all zero for a plain rect).
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    /// Index of the enclosing clip.
    parent: u16 = 0,
};

/// Errors a renderer reports.
pub const RenderError = error{
    /// The GPU device was lost; the renderer recovers on the next frame.
    DeviceLost,
    /// GPU or host memory ran out.
    OutOfMemory,
    /// The target surface is gone (window closed).
    SurfaceLost,
    /// A texture id or argument was invalid.
    InvalidArgument,
    /// The target could not present.
    PresentFailed,
};

/// What one `Renderer.render` call did.
pub const FrameStats = struct {
    /// CPU time spent turning the draw list into GPU or CPU work.
    cpu_encode_ns: u64 = 0,
    /// GPU time from timestamp queries, when the backend measures it.
    gpu_ns: ?u64 = null,
    /// Draw calls issued (tiles shaded on the software backend).
    draws: u32 = 0,
    /// Primitives in the list.
    prims: u32 = 0,
    /// Pixels written.
    repainted_px: u64 = 0,
    /// The frame repainted everything (resize, first frame, lost state).
    needs_full_redraw: bool = false,
    /// The backend that rendered.
    backend: Backend = .software,
    /// Monotonic id of the presented frame (0 when nothing was presented).
    present_id: u64 = 0,
};

test "types: radii helpers" {
    try std.testing.expect(Radii.isZero(.{}));
    try std.testing.expect(!Radii.all(2).isZero());
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(GlyphQuad));
}
