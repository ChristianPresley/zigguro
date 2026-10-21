//! zg_net: the repository's HTTP, SSE, WebSocket and OAuth layer on
//! `std.http` (E00.F06).
const std = @import("std");
pub const options = @import("zg_options");
pub const sse = @import("sse.zig");

test {
    std.testing.refAllDecls(@This());
}
