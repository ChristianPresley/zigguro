//! zg_terminal_view: the terminal as a zg_gui widget (E06.F04 routing,
//! E06.F05 rendering). A module of its own so the headless zg_terminal
//! core never imports a GUI package.

const std = @import("std");

/// What the widget shows and where its input goes.
pub const terminal_view = @import("terminal_view.zig");
/// The widget.
pub const widget = @import("widget.zig");
/// Cell colour resolution.
pub const palette = @import("palette.zig");
/// zg_gui events as encoder inputs.
pub const input_route = @import("input_route.zig");

pub const TerminalView = terminal_view.TerminalView;
pub const Options = terminal_view.Options;
pub const Sink = terminal_view.Sink;
pub const Term = widget.Term;
pub const terminal = widget.terminal;

test {
    std.testing.refAllDecls(@This());
    _ = @import("terminal_view_test.zig");
}
