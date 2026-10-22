//! Glyph rasterization (E03.F03): analytic coverage from outlines, with
//! gamma, LCD, SDF and color glyphs layered on top.

const std = @import("std");

/// The accumulation buffer and its prefix-sum integration.
pub const coverage = @import("coverage.zig");
/// Bézier flattening.
pub const flatten = @import("flatten.zig");
/// `Rasterizer`, `Bitmap`, `RasterParams` and pixel placement.
pub const rasterizer = @import("rasterizer.zig");

/// Per-thread outline rasterizer.
pub const Rasterizer = rasterizer.Rasterizer;
/// Raster output.
pub const Bitmap = rasterizer.Bitmap;
/// Size, subpixel offset, mode and synthetic styles.
pub const RasterParams = rasterizer.RasterParams;

test {
    std.testing.refAllDecls(@This());
    _ = @import("coverage_test.zig");
}
