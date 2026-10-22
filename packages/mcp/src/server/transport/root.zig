//! Server transports (E11.F05.S02.T01): stdio, Streamable HTTP and
//! in-process (`Server.serveInProcess` over `transport.InProcPair`, the
//! same NDJSON framing as stdio).

const InProcPair = @import("../../transport/in_process.zig");

pub const stdio = @import("stdio.zig");
pub const http = @import("http.zig");
pub const http_validate = @import("http_validate.zig");

pub const StdioServerOptions = stdio.StdioServerOptions;
pub const HttpServerOptions = http.HttpServerOptions;
pub const HttpListener = http.HttpListener;
pub const serveStdio = stdio.serveStdio;
pub const serveStream = stdio.serveStream;
pub const listenHttp = http.listenHttp;

/// How a server is reached.
pub const ServerTransport = union(enum) {
    stdio: StdioServerOptions,
    http: HttpServerOptions,
    in_process: *InProcPair,
};

test {
    _ = stdio;
    _ = http;
    _ = http_validate;
    _ = @import("transport_test.zig");
}
