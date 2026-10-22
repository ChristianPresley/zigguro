//! The interface every MCP client transport implements (stdio, modern and
//! legacy Streamable HTTP, HTTP+SSE, in-process). The client (F03) chooses
//! the variant from era detection and drives all of them the same way.
//!
//! Threading: every method is called on worker threads, never on the UI
//! thread. Sink callbacks run on the transport's own tasks; arguments are
//! valid only during the callback, so copy what you keep.

const Transport = @This();
const std = @import("std");
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const headers = @import("headers.zig");

ptr: *anyopaque,
vtable: *const VTable,

/// Implementation functions.
pub const VTable = struct {
    /// Sends one JSON-RPC request; its notifications and response arrive
    /// through `sink`, which must outlive the request (until `onResponse`
    /// or `onError`).
    request: *const fn (*anyopaque, req: OutgoingRequest, sink: *RequestSink) SendError!void,
    /// Sends one notification.
    notify: *const fn (*anyopaque, n: OutgoingNotification) SendError!void,
    /// Sends the JSON-RPC response `body` to a server request (legacy
    /// sampling, elicitation, roots, ping).
    respond: *const fn (*anyopaque, body: []const u8, revision: protocol.Revision) SendError!void,
    /// Transport-specific cancellation: stdio sends `notifications/cancelled`;
    /// modern HTTP closes the response stream; legacy HTTP POSTs
    /// `notifications/cancelled` (closing a stream is not cancellation there).
    cancel: *const fn (*anyopaque, id: protocol.RequestId, reason: ?[]const u8) void,
    /// Where server messages outside any request go (legacy GET stream,
    /// unsolicited stdio messages).
    setInbound: *const fn (*anyopaque, inbound: *InboundSink) void,
    /// Cancels everything in flight and releases the transport.
    close: *const fn (*anyopaque) void,
    /// Which transport this is.
    kind: *const fn (*anyopaque) Kind,
};

/// The transport variants.
pub const Kind = enum { stdio, http_modern, http_legacy, http_sse, in_process };

/// Errors from sending. `InvalidMessage`: the body is not one line of
/// compact JSON (stdio framing).
pub const SendError = error{ OutOfMemory, Closed, ConcurrencyUnavailable, InvalidMessage };

/// A serialized request plus what HTTP transports mirror into headers.
pub const OutgoingRequest = struct {
    id: protocol.RequestId,
    method: protocol.Method,
    method_str: []const u8,
    /// `params.name` / `params.uri` for `Mcp-Name`, unencoded.
    name_for_header: ?[]const u8 = null,
    /// `Mcp-Param-*` headers from the tool's `x-mcp-header` map.
    param_headers: []const headers.ParamHeader = &.{},
    /// The whole JSON-RPC request.
    body: []const u8,
    revision: protocol.Revision,
    timeout: ?std.Io.Duration = null,
};

/// A serialized notification.
pub const OutgoingNotification = struct {
    method_str: []const u8,
    body: []const u8,
    revision: protocol.Revision,
    /// Return only once the peer accepted it (HTTP: the 202), so that later
    /// messages cannot overtake it (`notifications/initialized`). Pipe
    /// transports are always ordered.
    ordered: bool = false,
};

/// Receives what belongs to one request.
pub const RequestSink = struct {
    ctx: ?*anyopaque,
    onNotification: *const fn (?*anyopaque, n: protocol.Notification, raw: zg_jsonrpc.message.Notification) void,
    /// Legacy only (server requests on a POST's SSE stream). Modern servers
    /// must not send them; they are still forwarded, after an `onProtocol`.
    onServerRequest: *const fn (?*anyopaque, r: zg_jsonrpc.message.Request) void,
    /// The final response; the last call for this request.
    onResponse: *const fn (?*anyopaque, r: zg_jsonrpc.message.Response) void,
    /// The request failed without a response; the last call for this request.
    onError: *const fn (?*anyopaque, e: TransportError) void,
};

/// Receives server messages that belong to no request.
pub const InboundSink = struct {
    ctx: ?*anyopaque,
    onNotification: *const fn (?*anyopaque, n: protocol.Notification, raw: zg_jsonrpc.message.Notification) void,
    onServerRequest: *const fn (?*anyopaque, r: zg_jsonrpc.message.Request) void,
    /// The connection is gone (process exit, stream closed for good).
    onClosed: *const fn (?*anyopaque, e: TransportError) void,
};

/// How a child process ended.
pub const ExitInfo = struct {
    code: ?u32 = null,
    signal: ?u32 = null,
    /// The process exited before its first response.
    during_startup: bool = false,
    /// The end of its stderr (valid during the callback).
    stderr_tail: []const u8 = "",
};

/// Why a request produced no response.
pub const TransportError = union(enum) {
    /// An HTTP status the transport cannot map to a JSON-RPC response; F03
    /// uses 400/404/405 without a modern error body for legacy fallback.
    http_status: struct { status: u16, body: []const u8, www_authenticate: ?[]const u8 },
    /// The stream ended before the response. Modern: re-issue with a new id.
    stream_broken,
    /// Legacy: the session is gone (404 with a session id); re-initialize.
    session_expired,
    process_exited: ExitInfo,
    timeout,
    canceled,
    /// The peer broke the protocol (message in the text).
    protocol: []const u8,
    /// Network or I/O failure.
    io: anyerror,
};

/// Sends `req`; see `VTable.request`.
pub fn request(t: Transport, req: OutgoingRequest, sink: *RequestSink) SendError!void {
    return t.vtable.request(t.ptr, req, sink);
}

/// Sends `n`; see `VTable.notify`.
pub fn notify(t: Transport, n: OutgoingNotification) SendError!void {
    return t.vtable.notify(t.ptr, n);
}

/// Answers a server request; see `VTable.respond`.
pub fn respond(t: Transport, body: []const u8, revision: protocol.Revision) SendError!void {
    return t.vtable.respond(t.ptr, body, revision);
}

/// Cancels request `id`; see `VTable.cancel`.
pub fn cancel(t: Transport, id: protocol.RequestId, reason: ?[]const u8) void {
    t.vtable.cancel(t.ptr, id, reason);
}

/// Sets the sink for unsolicited server messages.
pub fn setInbound(t: Transport, inbound: *InboundSink) void {
    t.vtable.setInbound(t.ptr, inbound);
}

/// Closes the transport.
pub fn close(t: Transport) void {
    t.vtable.close(t.ptr);
}

/// The transport variant.
pub fn kind(t: Transport) Kind {
    return t.vtable.kind(t.ptr);
}
