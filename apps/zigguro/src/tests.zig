//! The zigguro app's own tests: the adapters that wire the agents into
//! the workbench (`zig build test-apps`).

test {
    _ = @import("agent/approvals.zig");
    _ = @import("agent/editor_files.zig");
    _ = @import("agent/panel.zig");
}
