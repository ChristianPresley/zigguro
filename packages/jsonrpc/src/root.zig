//! zg_jsonrpc: JSON-RPC 2.0 framing, messages and a full-duplex Endpoint
//! for LSP, DAP framing and MCP (E00.F05).
const std = @import("std");
pub const options = @import("zg_options");
pub const framing = @import("framing.zig");

test {
    std.testing.refAllDecls(@This());
}
