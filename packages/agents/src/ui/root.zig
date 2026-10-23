//! zg_agents_ui: the agent views over zg_gui (E13): Mission Control, the
//! Automations manager, the task board and document mode. A
//! module of its own so headless consumers never import zg_gui.

const std = @import("std");

/// The Mission Control panel.
pub const mission_control = @import("mission_control.zig");

/// The notification router's in-app toasts.
pub const toast_bridge = @import("toast_bridge.zig");

/// The Automations manager.
pub const automations_view = @import("automations_view.zig");

/// The task board.
pub const board = @import("board/board_view.zig");

/// Standalone HTML export of Markdown documents.
pub const export_html = @import("export_html.zig");

/// Document mode: outline, tracked changes, selection bar and layout.
pub const doc_mode = struct {
    pub const view = @import("doc_mode/doc_mode_view.zig");
    pub const outline = @import("doc_mode/outline.zig");
    pub const selection_bar = @import("doc_mode/selection_bar.zig");
    pub const layout = @import("doc_mode/layout.zig");
    pub const comments_view = @import("doc_mode/comments_view.zig");
    pub const versions_view = @import("doc_mode/versions_view.zig");
    pub const DocMode = view.DocMode;
    pub const DocumentMode = layout.DocumentMode;
};

pub const MissionControl = mission_control.MissionControl;
pub const TaskBoard = board.TaskBoard;
pub const AutomationsView = automations_view.AutomationsView;
pub const ToastBridge = toast_bridge.ToastBridge;
pub const missionControl = mission_control.missionControl;

test {
    std.testing.refAllDecls(@This());
    _ = @import("mission_control_test.zig");
    _ = @import("automations_view_test.zig");
    _ = @import("board/board_view_test.zig");
    _ = @import("doc_mode/doc_mode_view_test.zig");
    _ = @import("export_test.zig");
    _ = @import("doc_mode/comments_view_test.zig");
    std.testing.refAllDecls(doc_mode);
}
