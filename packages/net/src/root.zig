//! zg_net: the repository's HTTP, SSE, WebSocket and OAuth layer on
//! `std.http` (E00.F06).
const std = @import("std");
pub const options = @import("zg_options");
pub const sse = @import("sse.zig");
pub const proxy = @import("proxy.zig");
pub const retry = @import("retry.zig");
pub const url = @import("url.zig");
pub const http = @import("http.zig");
pub const ws_frame = @import("ws_frame.zig");
pub const websocket = @import("websocket.zig");
pub const oauth = @import("oauth.zig");

test {
    std.testing.refAllDecls(@This());
}
