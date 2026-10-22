//! Client transports (E11.F02): the `Transport` interface and its stdio,
//! Streamable HTTP, HTTP+SSE and in-process implementations.

pub const Transport = @import("Transport.zig");
pub const headers = @import("headers.zig");
pub const http_common = @import("http_common.zig");
pub const HttpOptions = http_common.HttpOptions;
pub const HttpModernTransport = @import("http_modern.zig");
pub const HttpLegacyTransport = @import("http_legacy.zig");
pub const HttpSseTransport = @import("http_sse.zig");
pub const StdioTransport = @import("stdio.zig");
pub const StdioOptions = StdioTransport.StdioOptions;
pub const InProcPair = @import("in_process.zig");

test {
    _ = @import("http_modern_test.zig");
    _ = @import("http_legacy_test.zig");
    _ = @import("in_process.zig");
}
