//! Glyph rasterization (E03.F03): analytic coverage from outlines, with
//! gamma, LCD, SDF and color glyphs layered on top.

const std = @import("std");

/// The accumulation buffer and its prefix-sum integration.
pub const coverage = @import("coverage.zig");
/// Bézier flattening.
pub const flatten = @import("flatten.zig");
/// Text gamma/contrast reference (E02's `textCoverage`).
pub const gamma = @import("gamma.zig");
/// Synthetic bold and stem darkening.
pub const embolden = @import("embolden.zig");
/// LCD subpixel filtering.
pub const lcd = @import("lcd.zig");
/// `Rasterizer`, `Bitmap`, `RasterParams` and pixel placement.
pub const rasterizer = @import("rasterizer.zig");

/// Per-thread outline rasterizer.
pub const Rasterizer = rasterizer.Rasterizer;
/// Gamma and contrast parameters.
pub const GammaParams = gamma.GammaParams;
/// Raster output.
pub const Bitmap = rasterizer.Bitmap;
/// Size, subpixel offset, mode and synthetic styles.
pub const RasterParams = rasterizer.RasterParams;

test {
    std.testing.refAllDecls(@This());
    _ = @import("coverage_test.zig");
    _ = @import("style_test.zig");
}
