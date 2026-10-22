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
/// Terminal executor: control functions, modes, reports, OSC/DCS.
pub const term = @import("term.zig");
/// Shell-integration marks.
pub const shell = @import("shell.zig");
/// The terminal.
pub const Terminal = term.Terminal;

test {
    std.testing.refAllDecls(@This());
}
