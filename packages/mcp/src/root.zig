//! zg_mcp: the Model Context Protocol in pure Zig (E11): the protocol model
//! for every revision, transports, the era-adaptive client and the server SDK.

const std = @import("std");

pub const protocol = @import("protocol/root.zig");
pub const transport = @import("transport/root.zig");
pub const schema = @import("schema/root.zig");

test {
    std.testing.refAllDecls(@This());
}
