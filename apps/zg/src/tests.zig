//! Unit tests of the zg CLI's own wiring (`zig build test-zg`).

test {
    _ = @import("mcp_servers.zig");
    _ = @import("review_render.zig");
    _ = @import("review_cli_test.zig");
    _ = @import("review_hooks.zig");
}
