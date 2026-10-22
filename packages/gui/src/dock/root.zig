//! Docking (E04.F07): the layout model and its geometry.

const std = @import("std");

/// The `model.zig` module.
pub const model = @import("model.zig");
/// The `geometry.zig` module.
pub const geometry = @import("geometry.zig");

/// See `model.DockModel`.
pub const DockModel = model.DockModel;

test {
    std.testing.refAllDecls(@This());
}
