//! The era-adaptive MCP client (E11.F03): connection and era detection,
//! the typed request pipeline and its per-request metadata.

pub const Client = @import("Client.zig");
pub const era = @import("era.zig");
pub const meta = @import("meta.zig");
pub const request = @import("request.zig");

pub const EraDetection = era.EraDetection;
pub const CallOptions = request.CallOptions;
pub const CancelToken = request.CancelToken;
pub const RequestError = request.RequestError;
pub const ErrorInfo = request.ErrorInfo;

test {
    _ = Client;
    _ = era;
    _ = meta;
    _ = request;
    _ = @import("client_test.zig");
    _ = @import("client_http_test.zig");
}
