//! The HUD's commands (E14.F03.S01.T02), registered by the app with E15
//! like the other packages' command tables (`key` is the default binding).

/// One command.
pub const Command = struct { id: []const u8, title: []const u8, key: ?[]const u8 = null };

/// `perf.hud.toggle` shows or hides the HUD in the focused window.
pub const commands = [_]Command{
    .{ .id = "perf.hud.toggle", .title = "Toggle Performance HUD", .key = "ctrl+alt+shift+h" },
};
