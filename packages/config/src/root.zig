//! zg_config: settings, commands, context keys, keymaps and the extension
//! protocol (E15). Headless, so usable from `apps/zg`, except `ui`, which
//! connects it to zg_gui windows.

const std = @import("std");

/// Diagnostics with spans.
pub const diag = @import("diag.zig");
/// The dynamic value type.
pub const value = @import("value.zig");
/// The generic ZON loader.
pub const zon_load = @import("zon_load.zig");
/// The JSONC reader and comment stripper.
pub const jsonc = @import("jsonc.zig");

/// Small regex matcher (stand-in for zg_regex).
pub const regex_lite = @import("regex_lite.zig");
/// Per-user and managed directories.
pub const paths = @import("paths.zig");

/// Settings schema, registry and validation.
pub const schema = @import("schema.zig");

/// One settings layer.
pub const layer = @import("layer.zig");
/// The settings store and snapshots.
pub const store = @import("store.zig");

/// Context keys and the evaluation environment.
pub const context = @import("when/context.zig");
/// When-clause compiler and VM.
pub const when = @import("when/when.zig");
/// DNF analysis of when-clauses.
pub const dnf = @import("when/dnf.zig");

/// The command registry.
pub const commands = @import("commands/registry.zig");

/// Physical keys, modifiers and layouts.
pub const keys = @import("keymap/keys.zig");
/// Key spec grammar and matching candidates.
pub const keyspec = @import("keymap/keyspec.zig");
/// The effective keymap built from binding layers.
pub const keymap = @import("keymap/keymap.zig");
/// Key event resolution, chords and labels.
pub const resolver = @import("keymap/resolver.zig");
/// Keymap presets and Vim/Emacs layer selection.
pub const presets = @import("keymap/presets.zig");
/// VS Code keybindings.json import.
pub const import_vscode = @import("keymap/import_vscode.zig");

/// ZEP, the extension protocol: message types and the extension SDK
/// (also published alone as the `zg_ext_sdk` module).
pub const zep = @import("zep/root.zig");

/// The keymap adapter and command palette for zg_gui windows.
pub const ui = @import("ui/root.zig");

/// This package's settings declarations (aggregate with `schema.SchemaRegistry.comptimeInit`).
pub const settings_schema = @import("settings_schema.zon");

/// A dynamic ZON/JSON value.
pub const Value = value.Value;

test {
    std.testing.refAllDecls(@This());
    _ = @import("store_test.zig");
    _ = @import("commands/registry_test.zig");
    _ = @import("keymap/resolver_test.zig");
    _ = @import("keymap/presets_test.zig");
    _ = @import("ui/ui_test.zig");
}

test "settings_schema: aggregates and resolver options read it" {
    const reg = comptime schema.SchemaRegistry.comptimeInit(.{settings_schema});
    try std.testing.expectEqual(@as(i64, 1000), reg.default(reg.lookup("keyboard.chordTimeoutMs").?).int);
    try std.testing.expectEqualStrings("vscode", reg.default(reg.lookup("keyboard.preset").?).string);
}
