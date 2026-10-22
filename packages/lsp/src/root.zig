//! zg_lsp: the headless LSP client, server registry and code-intelligence
//! services (E07). See issue #8 for the package design.

const std = @import("std");

/// Generated LSP 3.18 protocol types (`zig build lspgen`).
pub const protocol = @import("gen/protocol.zig");
/// `std.json` support for the protocol types: union decoding, null
/// omission, open enums.
pub const json = @import("proto/json.zig");
/// LSP glob patterns (document selectors, watched files, file operations).
pub const glob = @import("proto/glob.zig");
/// `file:` URI <-> path mapping and URI comparison.
pub const uri = @import("proto/uri.zig");
/// Position encodings and their negotiation.
pub const position = @import("proto/position.zig");
/// Fuzzy scoring for completion, symbol pickers and REPL completions.
pub const fuzzy = @import("features/fuzzy.zig");
/// Byte transports (stdio pipes, TCP) shared with zg_dap.
pub const transport = struct {
    pub const Transport = @import("transport/Transport.zig");
    pub const StdioTransport = @import("transport/stdio.zig").StdioTransport;
    pub const tcp = @import("transport/tcp.zig");
};
/// The LSP client: server processes and sessions.
pub const client = struct {
    pub const ServerProcess = @import("client/ServerProcess.zig");
    pub const caps = @import("client/caps.zig");
    pub const client_capabilities = @import("client/client_capabilities.zig");
    pub const doc_selector = @import("client/doc_selector.zig");
    pub const Client = @import("client/Client.zig");
    pub const host = @import("client/host.zig");
    pub const progress = @import("client/progress.zig");
    pub const server_requests = @import("client/server_requests.zig");
    pub const restart = @import("client/restart.zig");
    pub const trace = @import("client/trace.zig");
    pub const transcript = @import("client/transcript.zig");
};
/// Document-bound request scheduling for the feature services.
pub const sync = struct {
    pub const scheduler = @import("sync/scheduler.zig");
    pub const timer_wheel = @import("sync/timer_wheel.zig");
};
/// Test support shared with zg_dap: the scripted-peer engine behind the
/// fake language server and debug adapter.
pub const testing = struct {
    pub const script = @import("testing/script.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("proto/glob_test.zig");
    _ = @import("features/fuzzy_test.zig");
    _ = @import("proto/protocol_test.zig");
    _ = @import("testing/script_test.zig");
    _ = @import("client/ServerProcess_test.zig");
    _ = @import("client/caps_test.zig");
    _ = @import("proto/uri_test.zig");
    _ = @import("client/client_test.zig");
    _ = @import("client/server_requests_test.zig");
    _ = @import("client/progress_test.zig");
    _ = @import("sync/scheduler_test.zig");
}
