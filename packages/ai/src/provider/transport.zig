//! The HTTP seam every provider uses. Production goes through `zg_net`
//! (`zgNetTransport`); the cassette recorder (E10.F10.S02.T01) and the
//! in-process fake server wrap or replace it, so providers are testable
//! offline.
//!
//! The body is delivered push-style, chunk by chunk, as `zg_net` streams it;
//! the head is returned once the body has ended. Providers keep the first
//! bytes of a non-2xx body to classify errors.

const std = @import("std");
const zg_net = @import("zg_net");

const Allocator = std.mem.Allocator;

/// An HTTP header.
pub const Header = std.http.Header;

/// HTTP methods providers use.
pub const Method = enum { GET, POST };

/// One outgoing request.
pub const HttpRequest = struct {
    method: Method = .POST,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_connect_ms: u32 = 10_000,
    idle_timeout_ms: u32 = 120_000,
};

/// Status and headers of a completed response.
pub const Head = struct {
    status: u16,
    headers: []const Header = &.{},
    request_id: ?[]const u8 = null,

    /// First value of header `name` (case-insensitive).
    pub fn get(h: Head, name: []const u8) ?[]const u8 {
        for (h.headers) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x.value;
        return null;
    }
};

/// Receives body bytes as they arrive. Returning an error aborts the read.
pub const ChunkSink = struct {
    ctx: *anyopaque,
    on_chunk: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

/// Transport failures.
pub const TransportError = error{ Canceled, Network, Timeout, OutOfMemory, Aborted };

/// An HTTP client abstraction.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Implementation hooks.
    pub const VTable = struct {
        /// Sends `req`, streams the body to `sink`, and returns the head.
        /// Head strings are allocated in `arena`.
        send: *const fn (ptr: *anyopaque, io: std.Io, arena: Allocator, req: HttpRequest, sink: ChunkSink) TransportError!Head,
    };

    /// See `VTable.send`.
    pub fn send(t: Transport, io: std.Io, arena: Allocator, req: HttpRequest, sink: ChunkSink) TransportError!Head {
        return t.vtable.send(t.ptr, io, arena, req, sink);
    }

    /// Sends `req` and collects the whole body into `arena`.
    pub fn sendCollect(t: Transport, io: std.Io, arena: Allocator, req: HttpRequest) TransportError!struct { head: Head, body: []const u8 } {
        var buf: Collector = .{ .arena = arena };
        const head = try t.send(io, arena, req, .{ .ctx = &buf, .on_chunk = Collector.onChunk });
        return .{ .head = head, .body = buf.list.items };
    }
};

const Collector = struct {
    arena: Allocator,
    list: std.ArrayList(u8) = .empty,
    fn onChunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        try c.list.appendSlice(c.arena, bytes);
    }
};

/// Extracts a request id from common response headers.
pub fn requestIdFrom(headers: []const Header) ?[]const u8 {
    for ([_][]const u8{ "request-id", "x-request-id", "openai-request-id" }) |n| {
        for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, n)) return h.value;
    }
    return null;
}

/// Production transport over a `zg_net` client. Credentials in headers are
/// sent by zg_net itself (std drops privileged headers) and never follow a
/// cross-origin redirect.
pub const ZgNet = struct {
    client: *zg_net.http.Client,

    /// The `Transport` view.
    pub fn transport(self: *ZgNet) Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, io: std.Io, arena: Allocator, req: HttpRequest, sink: ChunkSink) TransportError!Head {
        _ = io;
        const self: *ZgNet = @ptrCast(@alignCast(ptr));
        const Fwd = struct {
            sink: ChunkSink,
            fn onChunk(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
                const f: *@This() = @ptrCast(@alignCast(ctx.?));
                try f.sink.on_chunk(f.sink.ctx, bytes);
            }
        };
        var fwd: Fwd = .{ .sink = sink };
        var head = self.client.stream(.{
            .method = switch (req.method) {
                .GET => .GET,
                .POST => .POST,
            },
            .url = req.url,
            .headers = req.headers,
            .body = if (req.method == .POST) req.body else null,
            // Model requests are not idempotent; retries are the RetryPolicy's job.
            .retry = .never,
        }, .{ .ctx = &fwd, .onChunk = Fwd.onChunk }) catch |e| return switch (e) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.Timeout => error.Timeout,
            else => error.Network,
        };
        defer head.deinit(self.client.gpa);
        const hs = arena.alloc(Header, head.headers.list.len) catch return error.OutOfMemory;
        for (head.headers.list, hs) |h, *o| o.* = .{
            .name = arena.dupe(u8, h.name) catch return error.OutOfMemory,
            .value = arena.dupe(u8, h.value) catch return error.OutOfMemory,
        };
        return .{ .status = @intFromEnum(head.status), .headers = hs, .request_id = requestIdFrom(hs) };
    }
};

test "request id lookup order" {
    const hs = [_]Header{ .{ .name = "X-Request-Id", .value = "b" }, .{ .name = "request-id", .value = "a" } };
    try std.testing.expectEqualStrings("a", requestIdFrom(&hs).?);
    const head: Head = .{ .status = 200, .headers = &hs };
    try std.testing.expectEqualStrings("b", head.get("x-request-id").?);
}
