//! Widgets (E04.F05).

const std = @import("std");

/// The `box.zig` module.
pub const box = @import("box.zig");
/// The `text.zig` module.
pub const text = @import("text.zig");
/// The `controls.zig` module.
pub const controls = @import("controls.zig");

/// See `controls.button`.
pub const button = controls.button;
/// See `controls.checkbox`.
pub const checkbox = controls.checkbox;
/// See `controls.toggle`.
pub const toggle = controls.toggle;
/// See `controls.separator`.
pub const separator = controls.separator;
/// See `controls.progress`.
pub const progress = controls.progress;
/// See `controls.badge`.
pub const badge = controls.badge;
/// See `controls.spacer`.
pub const spacer = controls.spacer;
/// See `text.TextProps`.
pub const TextProps = text.TextProps;

test {
    std.testing.refAllDecls(@This());
}
