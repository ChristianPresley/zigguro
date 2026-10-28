//! The zigguro app's own tests: the adapters that wire the agents into
//! the workbench, the editor breadcrumbs and the early update step
//! (`zig build test-apps`).

test {
    _ = @import("agent/approvals.zig");
    _ = @import("scm_base.zig");
    _ = @import("agent/editor_files.zig");
    _ = @import("agent/review_glue.zig");
    _ = @import("agent/provenance_files.zig");
    _ = @import("agent/review_agent_port.zig");
    _ = @import("agent/panel.zig");
    _ = @import("agent/plan_card.zig");
    _ = @import("agent/pane_approvals.zig");
    _ = @import("file_sync.zig");
    _ = @import("agent/commands.zig");
    _ = @import("agent/host.zig");
    _ = @import("agent/scm_tools.zig");
    _ = @import("agent/pending_edits.zig");
    _ = @import("agent/inline_model.zig");
    _ = @import("agent/chat_completion_port.zig");
    _ = @import("agent/mcp_input.zig");
    _ = @import("path_crumbs.zig");
    _ = @import("review/queue_panel.zig");
    _ = @import("review/review_view.zig");
    _ = @import("review/inline_edit_bar.zig");
    _ = @import("review/inline_edit_host.zig");
    _ = @import("review/completions.zig");
    _ = @import("review/approval_card.zig");
    _ = @import("review/approvals_view.zig");
    _ = @import("startup/early_update_check.zig");
    _ = @import("startup/install_kind.zig");
    _ = @import("workbench.zig");
    _ = @import("tracing.zig");
    _ = @import("codeintel.zig");
    _ = @import("settings/service.zig");
    _ = @import("settings/view.zig");
    _ = @import("explorer/fs_tree.zig");
    _ = @import("explorer/panel.zig");
    _ = @import("problems_panel.zig");
    _ = @import("notes/service.zig");
    _ = @import("agent/workspace_tools.zig");
    _ = @import("hover_popup.zig");
    _ = @import("refactor_ui.zig");
    _ = @import("lens_ui.zig");
    _ = @import("symbol_pickers.zig");
    _ = @import("scm/git.zig");
    _ = @import("scm/panel.zig");
    _ = @import("completion_popup.zig");
    _ = @import("signature_popup.zig");
    _ = @import("bench/keys.zig");
    _ = @import("bench/latency.zig");
    _ = @import("workspace_fs.zig");
}
