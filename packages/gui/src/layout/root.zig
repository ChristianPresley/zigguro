//! Layout (E04.F02): the `Style` model and the layout engine.

const std = @import("std");

/// The `style.zig` module.
pub const style = @import("style.zig");
/// The `engine.zig` module.
pub const engine = @import("engine.zig");
/// The `measure.zig` module.
pub const measure = @import("measure.zig");

/// See `style.Style`.
pub const Style = style.Style;
/// See `style.Dim`.
pub const Dim = style.Dim;
/// See `style.Override`.
pub const Override = style.Override;

test {
    std.testing.refAllDecls(@This());
}
