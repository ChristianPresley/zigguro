//! Unit tests of the zg CLI's own wiring (`zig build test-zg`).

test {
    _ = @import("mcp_servers.zig");
    _ = @import("review_render.zig");
    _ = @import("review_cli_test.zig");
    _ = @import("review_hooks.zig");
    _ = @import("cmd_scm.zig");
    _ = @import("cmd_scm_ai.zig");
    _ = @import("scm_model.zig");
    _ = @import("scm_tools.zig");
    _ = @import("cmd_runs.zig");
    _ = @import("cmd_automation.zig");
    _ = @import("cmd_tasks.zig");
}
