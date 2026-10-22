//! HTTP+SSE (2024-11-05): one long-lived GET stream carries every
//! server-to-client message; the first event, `endpoint`, names the URL the
//! client POSTs its messages to. Responses are matched to requests by id.
//!
//! The endpoint must have the stream's origin (scheme, host and port), so a
//! server cannot redirect the client's messages and credentials elsewhere.
//! Cancellation POSTs `notifications/cancelled`; `deinit` closes the stream.

const HttpSseTransport = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const Transport = @import("Transport.zig");
const common = @import("http_common.zig");

const RequestId = protocol.RequestId;
const message = zg_jsonrpc.message;

rt: *zg_core.Runtime,
client: *zg_net.http.Client,
gpa: Allocator,
io: Io,
/// Owned copy of the options (url and static headers duplicated).
opts: common.HttpOptions,
opts_arena: std.heap.ArenaAllocator,
mutex: Io.Mutex = .init,
/// The POST URL from the `endpoint` event (owned by `gpa`).
endpoint: ?[]u8 = null,
/// Why the stream failed before `endpoint` arrived.
connect_error: ?anyerror = null,
ready: Io.Event = .unset,
pending: std.ArrayList(Pending) = .empty,
/// The GET stream.
stream_loop: zg_core.runtime.Subsystem,
/// POST tasks.
posts: zg_core.runtime.Subsystem,
inbound: ?*Transport.InboundSink = null,
closed: bool = false,

const Pending = struct { id: RequestId, sink: *Transport.RequestSink };

/// Errors from `connect` besides the stream's own.
pub const ConnectError = error{ EndpointTimeout, CrossOriginEndpoint, InvalidEndpoint, StreamEnded };

/// GETs `opts.url` (`Accept: text/event-stream`) and waits up to
/// `opts.endpoint_timeout` for the `endpoint` event. `client` must outlive
/// the transport.
pub fn connect(rt: *zg_core.Runtime, client: *zg_net.http.Client, gpa: Allocator, opts: common.HttpOptions) !*HttpSseTransport {
    rt.assertNotUi();
    const self = try gpa.create(HttpSseTransport);
    self.* = .{
        .rt = rt,
        .client = client,
        .gpa = gpa,
        .io = rt.io,
        .opts = opts,
        .opts_arena = .init(gpa),
        .stream_loop = .init(rt.io),
        .posts = .init(rt.io),
    };
    {
        errdefer {
            self.opts_arena.deinit();
            gpa.destroy(self);
        }
        const a = self.opts_arena.allocator();
        self.opts.url = try a.dupe(u8, opts.url);
        const hs = try a.alloc(std.http.Header, opts.static_headers.len);
        for (opts.static_headers, hs) |h, *d| d.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        self.opts.static_headers = hs;
        try self.stream_loop.spawnLoop(streamLoop, .{self});
    }
    errdefer self.deinit();
    self.ready.waitTimeout(self.io, .{ .duration = .{ .raw = opts.endpoint_timeout, .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => return error.EndpointTimeout,
        else => |e| return e,
    };
    if (self.connect_error) |e| return e;
    return self;
}

/// The `Transport` interface.
pub fn transport(self: *HttpSseTransport) Transport {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Transport.VTable = .{
    .request = vRequest,
    .notify = vNotify,
    .respond = vRespond,
    .cancel = vCancel,
    .setInbound = vSetInbound,
    .close = vClose,
    .kind = vKind,
};

fn vRequest(ptr: *anyopaque, req: Transport.OutgoingRequest, sink: *Transport.RequestSink) Transport.SendError!void {
    const self: *HttpSseTransport = @ptrCast(@alignCast(ptr));
    const id: RequestId = switch (req.id) {
        .str => |s| .{ .str = try self.gpa.dupe(u8, s) },
        else => req.id,
    };
    errdefer freeId(self.gpa, id);
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        try self.pending.append(self.gpa, .{ .id = id, .sink = sink });
    }
    self.post(req.body, id) catch |err| {
        _ = self.takePending(id);
        return err;
    };
}

fn vNotify(ptr: *anyopaque, n: Transport.OutgoingNotification) Transport.SendError!void {
    const self: *HttpSseTransport = @ptrCast(@alignCast(ptr));
    if (n.ordered) {
        self.rt.assertNotUi();
        const failure = postOnce(self, n.body) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Closed,
        };
        if (failure != null) return error.Closed;
        return;
    }
    return self.post(n.body, null);
}

fn vRespond(ptr: *anyopaque, body: []const u8, _: protocol.Revision) Transport.SendError!void {
    const self: *HttpSseTransport = @ptrCast(@alignCast(ptr));
    return self.post(body, null);
}

fn vCancel(ptr: *anyopaque, id: RequestId, reason: ?[]const u8) void {
    const self: *HttpSseTransport = @ptrCast(@alignCast(ptr));
    const p = self.takePending(id) orelse return;
    defer freeId(self.gpa, p.id);
    p.sink.onError(p.sink.ctx, .canceled);
    const body = common.cancelledBody(self.gpa, id, reason) catch return;
    defer self.gpa.free(body);
    self.post(body, null) catch {};
}

fn vSetInbound(ptr: *anyopaque, inbound: *Transport.InboundSink) void {
    const self: *HttpSseTransport = @ptrCast(@alignCast(ptr));
    self.inbound = inbound;
}

fn vKind(_: *anyopaque) Transport.Kind {
    return .http_sse;
}

fn vClose(ptr: *anyopaque) void {
    const self: *HttpSseTransport = @ptrCast(@alignCast(ptr));
    self.deinit();
}

/// Closes the stream, cancels POSTs, fails pending requests with
/// `canceled` and frees the transport.
pub fn deinit(self: *HttpSseTransport) void {
    self.mutex.lockUncancelable(self.io);
    self.closed = true;
    self.mutex.unlock(self.io);
    self.stream_loop.shutdown();
    self.posts.shutdown();
    self.failPending(.canceled);
    self.pending.deinit(self.gpa);
    if (self.endpoint) |e| self.gpa.free(e);
    self.opts_arena.deinit();
    self.gpa.destroy(self);
}

fn freeId(gpa: Allocator, id: RequestId) void {
    switch (id) {
        .str => |s| gpa.free(s),
        else => {},
    }
}

fn takePending(self: *HttpSseTransport, id: RequestId) ?Pending {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.pending.items, 0..) |p, i| if (p.id.eql(id)) return self.pending.swapRemove(i);
    return null;
}

fn failPending(self: *HttpSseTransport, e: Transport.TransportError) void {
    self.mutex.lockUncancelable(self.io);
    const all = self.pending.toOwnedSlice(self.gpa) catch &.{};
    self.mutex.unlock(self.io);
    defer self.gpa.free(all);
    for (all) |p| {
        p.sink.onError(p.sink.ctx, e);
        freeId(self.gpa, p.id);
    }
}

const Post = struct {
    t: *HttpSseTransport,
    body: []u8,
    /// The request this POST carries, to fail it on an HTTP error.
    id: ?RequestId,
};

/// POSTs `body` to the endpoint on its own task.
fn post(self: *HttpSseTransport, body: []const u8, id: ?RequestId) Transport.SendError!void {
    self.rt.assertNotUi();
    const p = try self.gpa.create(Post);
    errdefer self.gpa.destroy(p);
    p.* = .{ .t = self, .body = try self.gpa.dupe(u8, body), .id = null };
    errdefer self.gpa.free(p.body);
    if (id) |i| p.id = switch (i) {
        .str => |s| .{ .str = try self.gpa.dupe(u8, s) },
        else => i,
    };
    errdefer if (p.id) |i| freeId(self.gpa, i);
    self.posts.spawnLoop(postTask, .{p}) catch return error.ConcurrencyUnavailable;
}

fn postTask(p: *Post) void {
    const self = p.t;
    defer {
        if (p.id) |i| freeId(self.gpa, i);
        self.gpa.free(p.body);
        self.gpa.destroy(p);
    }
    const failure = postOnce(self, p.body) catch |err| switch (err) {
        error.Canceled => return,
        else => Transport.TransportError{ .io = err },
    };
    const f = failure orelse return;
    const id = p.id orelse return;
    const pend = self.takePending(id) orelse return;
    defer freeId(self.gpa, pend.id);
    pend.sink.onError(pend.sink.ctx, f);
}

/// One POST; null on 200/202, otherwise the failure to report.
fn postOnce(self: *HttpSseTransport, body: []const u8) !?Transport.TransportError {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const auth_value: ?[]const u8 = if (self.opts.auth) |au| try au.headerFor(au.ctx, a) else null;
    var hs: std.ArrayList(std.http.Header) = .empty;
    try hs.append(a, .{ .name = "Content-Type", .value = "application/json" });
    try hs.appendSlice(a, self.opts.static_headers);
    if (auth_value) |v| try hs.append(a, .{ .name = "Authorization", .value = v });
    var resp = try self.client.send(self.gpa, .{ .method = .POST, .url = self.endpoint.?, .headers = hs.items, .body = body });
    defer resp.deinit(self.gpa);
    const status: u16 = @intFromEnum(resp.status);
    if (status / 100 == 2) return null;
    return .{ .http_status = .{ .status = status, .body = "", .www_authenticate = null } };
}

const StreamSink = struct {
    t: *HttpSseTransport,
    parser: zg_net.sse.Parser,

    fn onHead(ctx: ?*anyopaque, status: std.http.Status, _: *const zg_net.http.OwnedHeaders) anyerror!void {
        _ = ctx;
        if (@intFromEnum(status) / 100 != 2) return error.HttpStatus;
    }

    fn onChunk(ctx: ?*anyopaque, chunk: []const u8) anyerror!void {
        const s: *StreamSink = @ptrCast(@alignCast(ctx.?));
        try s.parser.feed(chunk, s);
    }

    pub fn onEvent(s: *StreamSink, ev: zg_net.sse.Event) !void {
        const self = s.t;
        if (std.mem.eql(u8, ev.type, "endpoint")) {
            if (self.endpoint != null) return; // Only the first counts.
            self.endpoint = try resolveEndpoint(self.gpa, self.opts.url, ev.data);
            self.ready.set(self.io);
            return;
        }
        if (self.endpoint == null) return error.InvalidEndpoint; // `endpoint` must come first.
        if (!std.mem.eql(u8, ev.type, "message") or ev.data.len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = switch (message.parse(a, ev.data)) {
            .single => |m| m,
            .batch, .invalid => return,
        };
        switch (msg) {
            .response => |r| {
                const p = self.takePending(r.id) orelse return;
                defer freeId(self.gpa, p.id);
                p.sink.onResponse(p.sink.ctx, r);
            },
            .notification => |n| if (self.inbound) |in| {
                const typed = protocol.Notification.decode(a, n.method, n.params, .{}) catch
                    protocol.Notification{ .unknown = .{ .method = n.method, .params = null } };
                in.onNotification(in.ctx, typed, n);
            },
            .request => |r| if (self.inbound) |in| in.onServerRequest(in.ctx, r),
        }
    }
};

/// Resolves the `endpoint` event's URI reference against the stream URL and
/// requires the same origin. Returns the absolute URL in `gpa`.
pub fn resolveEndpoint(gpa: Allocator, base_url: []const u8, ref: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, ref, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidEndpoint;
    const base = std.Uri.parse(base_url) catch return error.InvalidEndpoint;
    const aux = try gpa.alloc(u8, trimmed.len + base_url.len + 64);
    defer gpa.free(aux);
    @memcpy(aux[0..trimmed.len], trimmed);
    var buf = aux;
    const resolved = base.resolveInPlace(trimmed.len, &buf) catch return error.InvalidEndpoint;
    if (!zg_net.url.sameOrigin(base, resolved)) return error.CrossOriginEndpoint;
    return std.fmt.allocPrint(gpa, "{f}", .{resolved.fmt(.{ .scheme = true, .authority = true, .path = true, .query = true })});
}

fn streamLoop(self: *HttpSseTransport) void {
    const err = runStream(self);
    if (err == error.Canceled) return;
    if (self.endpoint == null) {
        self.connect_error = err;
        self.ready.set(self.io);
        return;
    }
    self.failPending(.stream_broken);
    if (self.inbound) |in| in.onClosed(in.ctx, .stream_broken);
}

/// Runs the GET stream until it ends; returns why.
fn runStream(self: *HttpSseTransport) anyerror {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const auth_value: ?[]const u8 = if (self.opts.auth) |au| (au.headerFor(au.ctx, a) catch |e| return e) else null;
    const hs = common.getHeaders(a, &self.opts, null, auth_value, null, null) catch |e| return e;
    var sink: StreamSink = .{ .t = self, .parser = .init(self.gpa, .{ .max_event_bytes = @intCast(@min(self.opts.max_response_bytes, std.math.maxInt(usize))) }) };
    defer sink.parser.deinit();
    var head = self.client.stream(.{ .url = self.opts.url, .headers = hs }, .{
        .ctx = &sink,
        .onChunk = StreamSink.onChunk,
        .onHead = StreamSink.onHead,
    }) catch |e| return e;
    head.deinit(self.gpa);
    return error.StreamEnded;
}
