//! The E04 (zg_gui) side of zg_config: the keymap adapter and the command
//! palette. The rest of the package stays headless.

/// Plugs the resolver and the command registry into a window.
pub const keymap_adapter = @import("keymap_adapter.zig");
/// The `>` QuickPick provider and `workbench.showCommands`.
pub const palette = @import("palette/provider.zig");

/// See `keymap_adapter.KeymapAdapter`.
pub const KeymapAdapter = keymap_adapter.KeymapAdapter;
/// See `palette.PaletteProvider`.
pub const PaletteProvider = palette.PaletteProvider;
