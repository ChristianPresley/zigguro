//! The software renderer (E02.F07.S01): the same `DrawList`, the same
//! shading math, on the CPU.

/// See `SwRenderer.zig`.
pub const SwRenderer = @import("SwRenderer.zig");
/// Tile binning.
pub const bin = @import("bin.zig");
/// Tile shading.
pub const raster = @import("raster.zig");
/// CPU textures.
pub const texture = @import("texture.zig");
/// See `texture.zig`.
pub const CpuTexture = texture.CpuTexture;

test {
    _ = SwRenderer;
    _ = bin;
    _ = raster;
    _ = texture;
}
