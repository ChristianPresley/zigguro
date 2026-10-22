//! What a widget's `measure` function sees.

const std = @import("std");
const text = @import("../paint/text.zig");
const theme_mod = @import("../theme/theme.zig");

/// Passed to `W.measure(mc, props, state, max_w)`. `max_w` is the width
/// the content may wrap at, or null for max-content (no wrapping).
pub const MeasureCx = struct {
    text: text.TextSystem,
    theme: *const theme_mod.Theme,
    /// Counts measure calls (layout stats).
    calls: u32 = 0,
};

test {
    std.testing.refAllDecls(@This());
}
