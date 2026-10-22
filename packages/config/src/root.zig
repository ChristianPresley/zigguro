//! zg_config: settings, commands, context keys, keymaps and the extension
//! protocol (E15). Headless: usable from `apps/zg` as well as the GUI.

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

/// A dynamic ZON/JSON value.
pub const Value = value.Value;

test {
    std.testing.refAllDecls(@This());
    _ = @import("store_test.zig");
}
