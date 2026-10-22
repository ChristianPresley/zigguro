//! The glyph cache and GPU atlas (E03.F04): where each rasterized glyph
//! lives in the atlas pages that E02 uploads and samples.

const std = @import("std");

/// Skyline rectangle packing.
pub const skyline = @import("skyline.zig");
/// Atlas pages, eviction and dirty-region uploads.
pub const atlas = @import("atlas.zig");

/// See `atlas.Atlas`.
pub const Atlas = atlas.Atlas;
/// See `atlas.AtlasEntry`.
pub const AtlasEntry = atlas.AtlasEntry;
/// See `atlas.AtlasFormat`.
pub const AtlasFormat = atlas.AtlasFormat;
/// See `atlas.AtlasUpdate`.
pub const AtlasUpdate = atlas.AtlasUpdate;
/// See `atlas.GlyphQuad`.
pub const GlyphQuad = atlas.GlyphQuad;
/// See `atlas.quadFor`.
pub const quadFor = atlas.quadFor;

test {
    std.testing.refAllDecls(@This());
    _ = @import("atlas_test.zig");
}
