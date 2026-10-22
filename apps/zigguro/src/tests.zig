//! The zigguro app's own tests: the adapters that wire the agents into
//! the workbench, the editor breadcrumbs and the early update step
//! (`zig build test-apps`).

test {
    _ = @import("agent/approvals.zig");
    _ = @import("agent/editor_files.zig");
    _ = @import("agent/review_glue.zig");
    _ = @import("agent/panel.zig");
    _ = @import("agent/plan_card.zig");
    _ = @import("agent/pane_approvals.zig");
    _ = @import("agent/commands.zig");
    _ = @import("agent/host.zig");
    _ = @import("agent/mcp_input.zig");
    _ = @import("path_crumbs.zig");
    _ = @import("review/queue_panel.zig");
    _ = @import("review/review_view.zig");
    _ = @import("review/approval_card.zig");
    _ = @import("review/approvals_view.zig");
    _ = @import("startup/early_update_check.zig");
    _ = @import("workbench.zig");
}
