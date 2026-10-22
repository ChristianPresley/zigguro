//! The glyph cache and GPU atlas (E03.F04): where each rasterized glyph
//! lives in the atlas pages that E02 uploads and samples.

const std = @import("std");

/// Skyline rectangle packing.
pub const skyline = @import("skyline.zig");
/// Atlas pages, eviction and dirty-region uploads.
pub const atlas = @import("atlas.zig");
/// Glyph cache keys.
pub const glyph_key = @import("glyph_key.zig");
/// The glyph cache table, sync raster budget and prewarm.
pub const glyph_cache = @import("glyph_cache.zig");
/// Worker-thread rasterization.
pub const raster_queue = @import("raster_queue.zig");

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
/// See `glyph_key.GlyphKey`.
pub const GlyphKey = glyph_key.GlyphKey;
/// See `glyph_key.RenderMode`.
pub const RenderMode = glyph_key.RenderMode;
/// See `glyph_cache.GlyphCache`.
pub const GlyphCache = glyph_cache.GlyphCache;
/// See `glyph_cache.GlyphSource`.
pub const GlyphSource = glyph_cache.GlyphSource;
/// See `glyph_cache.Lookup`.
pub const Lookup = glyph_cache.Lookup;
/// See `raster_queue.RasterQueue`.
pub const RasterQueue = raster_queue.RasterQueue;

test {
    std.testing.refAllDecls(@This());
    _ = @import("atlas_test.zig");
    _ = @import("glyph_cache_test.zig");
}
