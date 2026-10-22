//! The `layout` namespace of zg_text: itemization, line layout, wrapping,
//! hit testing and the measured-width cache (E03.F08).

const std = @import("std");

/// Styles, options, metrics and `Line`.
pub const style = @import("style.zig");
/// Bidi, script, fallback and style runs.
pub const itemize = @import("itemize.zig");
/// `TextLayout`: one line of styled text.
pub const line = @import("line.zig");
/// Paragraph wrapping.
pub const wrap = @import("wrap.zig");
/// Hit testing, carets and selection.
pub const hit_test = @import("hit_test.zig");
/// Measured-width cache.
pub const width_cache = @import("width_cache.zig");

pub const TextStyle = style.TextStyle;
pub const StyleRun = style.StyleRun;
pub const LineOptions = style.LineOptions;
pub const WrapOptions = style.WrapOptions;
pub const PxMetrics = style.PxMetrics;
pub const Line = style.Line;
pub const Affinity = style.Affinity;
pub const Hit = style.Hit;
pub const CaretPos = style.CaretPos;
pub const Item = itemize.Item;
pub const TextLayout = line.TextLayout;

test {
    std.testing.refAllDecls(@This());
    _ = @import("layout_test.zig");
}
