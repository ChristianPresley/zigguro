//! zg_terminal: zigguro's integrated terminal (epic E06).
//!
//! The headless core (`vt`, and later `screen`, `term`, `session`) builds
//! without any GUI package so the `zg` CLI and MCP servers can run terminals
//! without a window.

const std = @import("std");

/// VT/xterm byte-stream parser.
pub const vt = @import("vt.zig");
/// Screen model: cells, pages, page list, screens.
pub const screen = @import("screen.zig");

test {
    std.testing.refAllDecls(@This());
}
