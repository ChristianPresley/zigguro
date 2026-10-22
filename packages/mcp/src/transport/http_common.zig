//! Pieces shared by the HTTP transports: options, the authorization hook,
//! request header assembly and routing of JSON-RPC messages received in a
//! JSON body or an SSE stream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_jsonrpc = @import("zg_jsonrpc");
const zg_net = @import("zg_net");
const protocol = @import("../protocol/root.zig");
const Transport = @import("Transport.zig");
const headers_mod = @import("headers.zig");
const message = zg_jsonrpc.message;

/// Options for the HTTP transports.
pub const HttpOptions = struct {
    /// The MCP endpoint.
    url: []const u8,
    /// Sent on every request (from the server's config).
    static_headers: []const std.http.Header = &.{},
    /// E11.F04 hook; null means no authorization.
    auth: ?HttpAuth = null,
    connect_timeout: std.Io.Duration = .fromSeconds(10),
    idle_stream_timeout: std.Io.Duration = .fromSeconds(300),
    /// Largest JSON body or SSE event accepted.
    max_response_bytes: u64 = 64 * 1024 * 1024,
};

/// Supplies `Authorization` and reacts to 401/403 (E11.F04 `McpAuth`).
pub const HttpAuth = struct {
    ctx: ?*anyopaque,
    /// The `Authorization` value (`"Bearer ..."`, owned by `gpa`), or null.
    /// Refreshes an expiring token itself.
    headerFor: *const fn (?*anyopaque, gpa: Allocator) anyerror!?[]const u8,
    /// Called on 401/403 with `WWW-Authenticate`; `.retry` resends once.
    onChallenge: *const fn (?*anyopaque, status: u16, www_authenticate: []const u8) anyerror!ChallengeOutcome,
};

/// What to do after an authorization challenge.
pub const ChallengeOutcome = enum { retry, fail };

/// Header names whose values are never logged.
pub fn isSecretHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "authorization") or
        std.ascii.eqlIgnoreCase(name, "mcp-session-id") or
        std.ascii.startsWithIgnoreCase(name, "mcp-param-");
}

/// Builds the header list for one POST in `arena`.
pub fn postHeaders(
    arena: Allocator,
    opts: *const HttpOptions,
    req: ?*const Transport.OutgoingRequest,
    revision: ?protocol.Revision,
    method_headers: bool,
    authorization: ?[]const u8,
    session_id: ?[]const u8,
) Allocator.Error![]std.http.Header {
    var list: std.ArrayList(std.http.Header) = .empty;
    try list.append(arena, .{ .name = "Content-Type", .value = "application/json" });
    try list.append(arena, .{ .name = "Accept", .value = "application/json, text/event-stream" });
    if (revision) |r| if (protocol.revision.has(r, .mcp_protocol_version_header))
        try list.append(arena, .{ .name = "MCP-Protocol-Version", .value = r.string() });
    if (session_id) |sid| try list.append(arena, .{ .name = "Mcp-Session-Id", .value = sid });
    if (req) |r| if (method_headers) {
        try list.append(arena, .{ .name = "Mcp-Method", .value = r.method_str });
        if (r.name_for_header) |n| try list.append(arena, .{ .name = "Mcp-Name", .value = try headers_mod.encodeHeaderValue(arena, n) });
        for (r.param_headers) |p| try list.append(arena, .{ .name = p.name, .value = p.value });
    };
    for (opts.static_headers) |h| try list.append(arena, h);
    if (authorization) |a| try list.append(arena, .{ .name = "Authorization", .value = a });
    return list.toOwnedSlice(arena);
}

/// What `route` found in one JSON-RPC message.
pub const Routed = enum { response, other, invalid };

/// Routes one JSON-RPC message body to `sink`: the response for `id` to
/// `onResponse` (returns `.response`), notifications to `onNotification`,
/// requests to `onServerRequest`. Responses for other ids are ignored.
pub fn route(
    arena: Allocator,
    body: []const u8,
    id: ?protocol.RequestId,
    sink: anytype,
) Routed {
    const parsed = message.parse(arena, body);
    const msg = switch (parsed) {
        .single => |m| m,
        .batch, .invalid => return .invalid,
    };
    switch (msg) {
        .response => |r| {
            if (id) |want| if (r.id.eql(want)) {
                sink.onResponse(sink.ctx, r);
                return .response;
            };
            return .other;
        },
        .notification => |n| {
            const typed = protocol.Notification.decode(arena, n.method, n.params, .{}) catch
                protocol.Notification{ .unknown = .{ .method = n.method, .params = null } };
            sink.onNotification(sink.ctx, typed, n);
            return .other;
        },
        .request => |r| {
            sink.onServerRequest(sink.ctx, r);
            return .other;
        },
    }
}

/// Whether `body` (after whitespace) starts like JSON rather than an SSE
/// stream. Used before the response head is known: zg_net streams the body
/// first and returns the head at the end.
pub fn looksLikeJson(first: []const u8) ?bool {
    for (first) |c| switch (c) {
        ' ', '\t', '\r', '\n' => continue,
        '{', '[' => return true,
        else => return false,
    };
    return null;
}

/// Classifies an error response body: whether it carries a JSON-RPC error
/// the modern era defines (so the server is modern even on 400/404).
pub fn modernErrorCode(arena: Allocator, body: []const u8) ?i64 {
    const parsed = message.parse(arena, body);
    if (parsed != .single or parsed.single != .response) return null;
    const e = parsed.single.response.err orelse return null;
    return switch (protocol.errors.Code.of(e.code)) {
        .header_mismatch, .missing_required_client_capability, .unsupported_protocol_version, .method_not_found, .invalid_params, .invalid_request, .parse_error, .internal_error => e.code,
        else => null,
    };
}

/// Body bytes of one response: buffered JSON, or SSE events routed as they
/// arrive. Feed with `onChunk`; aborts the stream with
/// `error.ResponseComplete` once the response for `id` has been routed.
pub fn BodyRouter(comptime Sink: type) type {
    return struct {
        const Self = @This();
        gpa: Allocator,
        id: ?protocol.RequestId,
        sink: Sink,
        max_bytes: u64,
        mode: ?enum { json, sse } = null,
        json: std.ArrayList(u8) = .empty,
        parser: ?zg_net.sse.Parser = null,
        got_response: bool = false,
        /// Last SSE event id and `retry` seen (legacy resumability).
        last_event_id: std.ArrayList(u8) = .empty,
        retry_ms: ?u64 = null,
        events: u64 = 0,

        /// Starts routing for request `id` (null for GET streams).
        pub fn init(gpa: Allocator, id: ?protocol.RequestId, sink: Sink, max_bytes: u64) Self {
            return .{ .gpa = gpa, .id = id, .sink = sink, .max_bytes = max_bytes };
        }

        /// Frees buffers.
        pub fn deinit(self: *Self) void {
            self.json.deinit(self.gpa);
            if (self.parser) |*p| p.deinit();
            self.last_event_id.deinit(self.gpa);
        }

        /// Forces SSE mode (GET streams, where no JSON is possible).
        pub fn forceSse(self: *Self) void {
            self.mode = .sse;
            self.parser = .init(self.gpa, .{ .max_event_bytes = @intCast(@min(self.max_bytes, std.math.maxInt(usize))) });
        }

        /// A `zg_net.http.BodySink` feeding this router.
        pub fn bodySink(self: *Self) zg_net.http.BodySink {
            return .{ .ctx = self, .onChunk = onChunkErased };
        }

        fn onChunkErased(ctx: ?*anyopaque, chunk: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            return self.onChunk(chunk);
        }

        /// Consumes body bytes.
        pub fn onChunk(self: *Self, chunk: []const u8) !void {
            if (self.mode == null) {
                const j = looksLikeJson(chunk) orelse return;
                if (j) self.mode = .json else self.forceSse();
            }
            switch (self.mode.?) {
                .json => {
                    if (self.json.items.len + chunk.len > self.max_bytes) return error.ResponseTooLarge;
                    try self.json.appendSlice(self.gpa, chunk);
                },
                .sse => {
                    try self.parser.?.feed(chunk, self);
                    if (self.got_response) return error.ResponseComplete;
                },
            }
        }

        /// Called by the SSE parser.
        pub fn onEvent(self: *Self, ev: zg_net.sse.Event) !void {
            self.events += 1;
            if (ev.id) |eid| {
                self.last_event_id.clearRetainingCapacity();
                try self.last_event_id.appendSlice(self.gpa, eid);
            }
            if (ev.retry_ms) |r| self.retry_ms = r;
            // Priming events (an id with empty data) only move the cursor.
            if (ev.data.len == 0) return;
            if (!std.mem.eql(u8, ev.type, "message")) return;
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            if (route(arena.allocator(), ev.data, self.id, self.sink) == .response)
                self.got_response = true;
        }

        /// After the body ended: routes a buffered JSON body. Returns whether
        /// the response for `id` was delivered.
        pub fn finishJson(self: *Self) bool {
            if (self.mode != .json) return self.got_response;
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            if (route(arena.allocator(), self.json.items, self.id, self.sink) == .response)
                self.got_response = true;
            return self.got_response;
        }
    };
}
