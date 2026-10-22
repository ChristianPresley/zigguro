//! Theming (E04.F08): design tokens and the built-in themes.

const std = @import("std");

/// The `tokens.zig` module.
pub const tokens = @import("tokens.zig");
/// The `theme.zig` module.
pub const theme = @import("theme.zig");

/// See `tokens.Token`.
pub const Token = tokens.Token;
/// See `theme.Theme`.
pub const Theme = theme.Theme;

test {
    std.testing.refAllDecls(@This());
}
