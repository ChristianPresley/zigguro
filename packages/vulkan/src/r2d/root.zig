//! r2d: the backend-agnostic 2D rendering contract (E02.F06.S01.T01).
//! Never imports Vulkan; see docs/rendering.md.

const types = @import("types.zig");

/// See `types.zig`.
pub const PxRect = types.PxRect;
/// See `types.zig`.
pub const Size = types.Size;
/// See `types.zig`.
pub const Vec2 = types.Vec2;
/// See `types.zig`.
pub const RectF = types.RectF;
/// See `types.zig`.
pub const Radii = types.Radii;
/// See `types.zig`.
pub const Insets = types.Insets;
/// See `types.zig`.
pub const TextAa = types.TextAa;
/// See `types.zig`.
pub const AtlasFormat = types.AtlasFormat;
/// See `types.zig`.
pub const GlyphQuad = types.GlyphQuad;
/// See `types.zig`.
pub const TextureId = types.TextureId;
/// See `types.zig`.
pub const LayerId = types.LayerId;
/// See `types.zig`.
pub const Backend = types.Backend;
/// See `types.zig`.
pub const TextureFormat = types.TextureFormat;
/// See `types.zig`.
pub const TextureDesc = types.TextureDesc;
/// See `types.zig`.
pub const Filter = types.Filter;
/// See `types.zig`.
pub const ClipRect = types.ClipRect;
/// See `types.zig`.
pub const RenderError = types.RenderError;
/// See `types.zig`.
pub const FrameStats = types.FrameStats;
/// See `color.zig`.
pub const Color = @import("color.zig").Color;
/// Colour helpers.
pub const color = @import("color.zig");
/// f16 packing helpers.
pub const f16p = @import("f16.zig");
/// The 64-byte instance format.
pub const prim = @import("prim.zig");
/// See `prim.zig`.
pub const Prim = prim.Prim;
/// The per-frame draw list.
pub const DrawList = @import("DrawList.zig");
/// The renderer interface.
pub const Renderer = @import("Renderer.zig");
/// See `Renderer.zig`.
pub const RendererOptions = Renderer.RendererOptions;
/// See `Renderer.zig`.
pub const EnvOverrides = Renderer.EnvOverrides;
/// `PxRect` helpers.
pub const rect = @import("rect.zig");
/// Layer wrap math and the layer table.
pub const layers = @import("layers.zig");
/// See `layers.zig`.
pub const LayerKind = layers.LayerKind;
/// The reference shading math.
pub const shading = @import("shading.zig");
/// See `shading.zig`.
pub const TextParams = shading.TextParams;

test {
    _ = types;
    _ = color;
    _ = f16p;
    _ = prim;
    _ = shading;
    _ = rect;
    _ = layers;
    _ = DrawList;
    _ = Renderer;
}
