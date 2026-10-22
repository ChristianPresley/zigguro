//! zg_update: auto-update client (E17.F04).
//!
//! - `manifest`: update manifest schema v1 and its strict parser.
//! - `verify`: the client acceptance rules 1-9 (`decide`).
//! - `state`: persisted updater state (`update.*`).

const std = @import("std");

/// Update manifest schema v1.
pub const manifest = @import("manifest.zig");
/// Client acceptance rules.
pub const verify = @import("verify.zig");
/// Persisted updater state.
pub const state = @import("state.zig");

test {
    std.testing.refAllDecls(@This());
    _ = manifest;
    _ = verify;
    _ = state;
}
