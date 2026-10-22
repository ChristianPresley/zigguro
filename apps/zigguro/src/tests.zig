//! The zigguro app's own tests: the adapters that wire the agents into
//! the workbench and the editor breadcrumbs (`zig build test-apps`).

test {
    _ = @import("agent/approvals.zig");
    _ = @import("agent/editor_files.zig");
    _ = @import("agent/review_glue.zig");
    _ = @import("agent/panel.zig");
    _ = @import("agent/plan_card.zig");
    _ = @import("agent/commands.zig");
    _ = @import("path_crumbs.zig");
}
