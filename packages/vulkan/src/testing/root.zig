//! Test support shared by the backends: images, the PNG codec, image diffs
//! and the golden-image harness (E02.F07.S02).

/// See `CpuImage.zig`.
pub const CpuImage = @import("CpuImage.zig");
/// The PNG codec.
pub const png = @import("png.zig");
/// Image comparison.
pub const image_diff = @import("image_diff.zig");
/// See `image_diff.zig`.
pub const Tolerance = image_diff.Tolerance;
/// The golden-image harness.
pub const golden_image = @import("golden_image.zig");
/// See `golden_image.zig`.
pub const expectImage = golden_image.expectImage;

/// Procedural glyph pages and images.
pub const synthetic_atlas = @import("synthetic_atlas.zig");
/// The golden scene corpus.
pub const scenes = @import("scenes.zig");
/// The scene runner.
pub const parity = @import("parity.zig");
/// Validation-layer assertions for GPU tests.
pub const validation = @import("validation.zig");

test {
    _ = CpuImage;
    _ = png;
    _ = image_diff;
    _ = golden_image;
    _ = synthetic_atlas;
    _ = scenes;
    _ = parity;
    _ = validation;
}
