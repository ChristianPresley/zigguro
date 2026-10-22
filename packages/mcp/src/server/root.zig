//! The MCP server SDK (E11.F05): typed tools, registries and dual-era
//! dispatch.

const std = @import("std");

pub const Server = @import("Server.zig");
pub const typed = @import("typed.zig");
pub const registry = @import("registry.zig");
pub const pagination = @import("pagination.zig");
pub const dispatch = @import("dispatch.zig");
pub const subscriptions = @import("subscriptions.zig");

pub const CallCtx = Server.CallCtx;
pub const Conn = Server.Conn;
pub const Options = Server.Options;
pub const Authorizer = Server.Authorizer;
pub const Decision = Server.Decision;
pub const DynamicTool = registry.DynamicTool;
pub const DynHandler = registry.DynHandler;
pub const ToolReturn = typed.ToolReturn;

test {
    std.testing.refAllDecls(@This());
}
