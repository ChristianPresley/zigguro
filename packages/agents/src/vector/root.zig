//! The vector canvas (E13.F07.S01.T02): resolution-independent 2D
//! drawing for charts, diagrams and sparklines. Paths are stroked into
//! fill outlines, recorded in display lists, rasterized into cached
//! 256×256 tiles with E03's coverage rasterizer, or written as SVG.
//! The UI side (tiles as textures, text as glyph quads) is
//! zg_agents_ui's `vector_view`.

pub const path = @import("path.zig");
pub const flatten = @import("flatten.zig");
pub const stroke = @import("stroke.zig");
pub const dash = @import("dash.zig");
pub const display_list = @import("display_list.zig");
pub const canvas = @import("canvas.zig");
pub const composite = @import("composite.zig");
pub const tiles = @import("tiles.zig");
pub const svg = @import("svg.zig");

pub const Path = path.Path;
pub const Rect = path.Rect;
pub const Affine = path.Affine;
pub const StrokeStyle = stroke.StrokeStyle;
pub const strokeToFill = stroke.strokeToFill;
pub const Color = display_list.Color;
pub const DisplayList = display_list.DisplayList;
pub const VectorCanvas = canvas.VectorCanvas;
pub const TileCache = tiles.TileCache;
pub const writeSvg = svg.writeSvg;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("stroke_test.zig");
    _ = @import("canvas_test.zig");
    _ = @import("svg_test.zig");
}
