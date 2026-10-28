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
/// Selection and copy (E06.F05.S02).
pub const selection = @import("selection.zig");
/// Scrollback search (E06.F05.S03).
pub const search = @import("search.zig");
/// Links in the output (E06.F05.S03.T02).
pub const links = @import("links.zig");
/// The find bar over a terminal.
pub const find_bar = @import("find_bar.zig");
/// Terminal tabs and split groups of the panel (E06.F07).
pub const panel_model = @import("panel_model.zig");

pub const TerminalView = terminal_view.TerminalView;
pub const Options = terminal_view.Options;
pub const Sink = terminal_view.Sink;
pub const Term = widget.Term;
pub const terminal = widget.terminal;
pub const PanelModel = panel_model.PanelModel;

test {
    std.testing.refAllDecls(@This());
    _ = @import("terminal_view_test.zig");
    _ = @import("shell_integration_test.zig");
}
