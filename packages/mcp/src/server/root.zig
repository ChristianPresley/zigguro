//! The MCP server SDK (E11.F05): typed tools, registries and dispatch.

const std = @import("std");

pub const typed = @import("typed.zig");

test {
    std.testing.refAllDecls(@This());
}
