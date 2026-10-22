//! Unit tests of the zg CLI's own wiring (`zig build test-zg`).

test {
    _ = @import("mcp_servers.zig");
}
