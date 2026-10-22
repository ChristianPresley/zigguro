//! The `shape` namespace of zg_text (see the E03 epic): OpenType shaping.

const std = @import("std");

/// Glyph buffer and Unicode properties.
pub const buffer = @import("buffer.zig");
/// The skipping iterator and apply context.
pub const skippy = @import("skippy.zig");
/// Contextual and chained-contextual matching.
pub const context = @import("context.zig");
/// GSUB lookup application.
pub const apply_gsub = @import("apply_gsub.zig");
/// GPOS lookup application.
pub const apply_gpos = @import("apply_gpos.zig");
/// Glyph-set digests that let lookups skip glyphs they cannot match.
pub const digest = @import("digest.zig");
/// Can a lookup fire on glyphs from a set (layout's ASCII fast path).
pub const set_closure = @import("set_closure.zig");
/// Legacy `kern` table fallback.
pub const kern_fallback = @import("kern_fallback.zig");
/// Shape plans: features, masks and lookup stages.
pub const plan = @import("plan.zig");
/// Font-aware normalization.
pub const normalize = @import("normalize.zig");
/// The user feature syntax.
pub const features = @import("features.zig");
/// The shaping driver.
pub const shaper = @import("shaper.zig");
/// Word-level shape cache.
pub const shape_cache = @import("shape_cache.zig");
/// Complex shapers.
pub const complex = struct {
    pub const default = @import("complex/default.zig");
    pub const arabic = @import("complex/arabic.zig");
};

pub const Buffer = buffer.Buffer;
pub const Direction = buffer.Direction;
pub const Feature = buffer.Feature;
pub const ShapePlan = plan.ShapePlan;
pub const Shaper = shaper.Shaper;
pub const GlyphRun = shaper.GlyphRun;
pub const ShapeCache = shape_cache.ShapeCache;
pub const ShapeKey = shape_cache.ShapeKey;
pub const parseFeatures = features.parseFeatures;

test {
    std.testing.refAllDecls(@This());
    _ = @import("shaper_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("complex/arabic_test.zig");
}
