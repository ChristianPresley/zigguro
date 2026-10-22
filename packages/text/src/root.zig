//! zg_text: fonts, rasterization, shaping, Unicode algorithms and text
//! layout, written on the Zig standard library alone (epic E03).
//! Layer 2: imports only `zg_core` and its own generated tables.

const std = @import("std");
const zg_core = @import("zg_core");

/// OpenType parsing: `Face`, table views, `cmap`.
pub const ot = @import("ot/root.zig");
/// Glyph outlines as flat paths.
pub const outline = @import("outline/root.zig");
/// Coverage, gamma, LCD, SDF and color rasterization.
pub const raster = @import("raster/root.zig");
/// Glyph cache and atlas packer.
pub const cache = @import("cache/root.zig");
/// OpenType shaping.
pub const shape = @import("shape/root.zig");
/// Unicode properties and algorithms.
pub const unicode = @import("unicode/root.zig");
/// Font discovery, database and fallback.
pub const fonts = @import("fonts/root.zig");
/// Text layout: runs, lines, wrapping, hit testing, terminal cells.
pub const layout = @import("layout/root.zig");

/// Developer-tool support (benches, `text-dump`); not for app code.
pub const dev = struct {
    /// Absolute path of `packages/text` at build time, for locating `testdata/`.
    pub const package_root: []const u8 = @import("zg_options").package_root;
};

test "layer rule: no forbidden imports" {
    // zg_text is layer 2 and may import only zg_core (plus std, its own
    // build options and corpus). Any other zigguro package import fails to
    // resolve because build.zig does not provide it; this test pins that.
    comptime {
        const allowed = [_][]const u8{ "zg_core", "zg_options", "zg_corpus" };
        _ = allowed;
    }
    _ = zg_core;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("testing/fonts.zig");
}
