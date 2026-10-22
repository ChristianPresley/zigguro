//! Streamable HTTP for session-based servers (2025-03-26 to 2025-11-25).
//!
//! - Sessions: the `Mcp-Session-Id` returned with the `InitializeResult` is
//!   sent on every later request; a 404 on a request carrying it reports
//!   `session_expired`. The id is a credential and is never logged.
//! - Responses come as one JSON body or an SSE stream that may carry server
//!   requests and notifications first. Server requests go to the request's
//!   sink; the client answers them with `respond` (a POST, 202 expected).
//! - A disconnect is not a cancellation: `cancel` POSTs
//!   `notifications/cancelled`. A stream that breaks before its response is
//!   resumed with a GET carrying `Last-Event-ID` after the server's `retry`
//!   delay (bounded backoff with jitter, at most 5 attempts).
//! - `openGetStream` starts the server-to-client stream (405: none offered).
//! - `deinit` cancels everything, then DELETEs the session.
//!
//! Each request runs as its own concurrent task, as in `http_modern.zig`.

const HttpLegacyTransport = @This();
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

/// Resume attempts for one broken response stream, and consecutive failed
/// reconnects of the GET stream, before giving up.
pub const max_reconnects = 5;

rt: *zg_core.Runtime,
client: *zg_net.http.Client,
gpa: Allocator,
io: Io,
/// Owned copy of the options (url and static headers duplicated).
opts: common.HttpOptions,
opts_arena: std.heap.ArenaAllocator,
mutex: Io.Mutex = .init,
revision: protocol.Revision,
/// Set by `setRevision`: `MCP-Protocol-Version` is sent from then on.
negotiated: bool = false,
/// The session id (owned by `gpa`).
session: ?[]u8 = null,
calls: std.ArrayList(*Call) = .empty,
reap_buf: []*Call,
reap: Io.Queue(*Call),
/// The reaper and the GET stream.
loops: zg_core.runtime.Subsystem,
get_open: bool = false,
inbound: ?*Transport.InboundSink = null,
closed: bool = false,

const State = enum { running, done, canceling };

const Call = struct {
    t: *HttpLegacyTransport,
    arena: std.heap.ArenaAllocator,
    id: ?RequestId,
    req: Transport.OutgoingRequest,
    sink: ?*Transport.RequestSink,
    /// The router's session id buffer while a response is being read.
    head_session: ?*const std.ArrayList(u8) = null,
    future: Io.Future(void) = undefined,
    state: State = .running,
};

/// Creates the transport for `revision` (the one requested in
/// `initialize`; see `setRevision`). `client` must outlive it.
pub fn init(rt: *zg_core.Runtime, client: *zg_net.http.Client, gpa: Allocator, opts: common.HttpOptions, revision: protocol.Revision) !*HttpLegacyTransport {
    const self = try gpa.create(HttpLegacyTransport);
    errdefer gpa.destroy(self);
    const reap_buf = try gpa.alloc(*Call, 64);
    errdefer gpa.free(reap_buf);
    self.* = .{
        .rt = rt,
        .client = client,
        .gpa = gpa,
        .io = rt.io,
        .opts = opts,
        .opts_arena = .init(gpa),
        .revision = revision,
        .reap_buf = reap_buf,
        .reap = .init(reap_buf),
        .loops = .init(rt.io),
    };
    errdefer self.opts_arena.deinit();
    const a = self.opts_arena.allocator();
    self.opts.url = try a.dupe(u8, opts.url);
    const hs = try a.alloc(std.http.Header, opts.static_headers.len);
    for (opts.static_headers, hs) |h, *d| d.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
    self.opts.static_headers = hs;
    try self.loops.spawnLoop(reaper, .{self});
    return self;
}

/// The `Transport` interface.
pub fn transport(self: *HttpLegacyTransport) Transport {
    return .{ .ptr = self, .vtable = &vtable };
}

/// The negotiated revision, after `initialize`: from now on every request
/// carries `MCP-Protocol-Version` (when the revision defines it).
pub fn setRevision(self: *HttpLegacyTransport, r: protocol.Revision) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.revision = r;
    self.negotiated = true;
}

/// The current session id, if the server assigned one. Valid until the
/// next `initialize` response or `deinit`; never log it.
pub fn sessionId(self: *const HttpLegacyTransport) ?[]const u8 {
    return self.session;
}

/// Starts the server-to-client GET stream (after `notifications/initialized`).
/// Its messages go to the inbound sink. A 405 means the server offers none,
/// which is not an error.
pub fn openGetStream(self: *HttpLegacyTransport) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.closed) return error.Closed;
    if (self.get_open) return;
    try self.loops.spawnLoop(getLoop, .{self});
    self.get_open = true;
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
    const self: *HttpLegacyTransport = @ptrCast(@alignCast(ptr));
    return self.start(req, req.id, sink);
}

fn vNotify(ptr: *anyopaque, n: Transport.OutgoingNotification) Transport.SendError!void {
    const self: *HttpLegacyTransport = @ptrCast(@alignCast(ptr));
    const req: Transport.OutgoingRequest = .{
        .id = .null,
        .method = .ping,
        .method_str = n.method_str,
        .body = n.body,
        .revision = n.revision,
    };
    if (n.ordered) return self.postNow(req);
    return self.start(req, null, null);
}

fn vRespond(ptr: *anyopaque, body: []const u8, revision: protocol.Revision) Transport.SendError!void {
    return vNotify(ptr, .{ .method_str = "", .body = body, .revision = revision });
}

fn vCancel(ptr: *anyopaque, id: RequestId, reason: ?[]const u8) void {
    const self: *HttpLegacyTransport = @ptrCast(@alignCast(ptr));
    self.mutex.lockUncancelable(self.io);
    const revision = self.revision;
    const call = for (self.calls.items, 0..) |c, i| {
        if (c.id != null and c.id.?.eql(id) and c.state == .running) {
            c.state = .canceling;
            _ = self.calls.swapRemove(i);
            break c;
        }
    } else null;
    self.mutex.unlock(self.io);
    const c = call orelse return;
    // Closing the stream does not cancel in this era: tell the server.
    if (common.cancelledBody(self.gpa, id, reason)) |body| {
        defer self.gpa.free(body);
        vNotify(ptr, .{ .method_str = "notifications/cancelled", .body = body, .revision = revision }) catch {};
    } else |_| {}
    c.future.cancel(self.io);
    self.freeCall(c);
}

fn vSetInbound(ptr: *anyopaque, inbound: *Transport.InboundSink) void {
    const self: *HttpLegacyTransport = @ptrCast(@alignCast(ptr));
    self.inbound = inbound;
}

fn vKind(_: *anyopaque) Transport.Kind {
    return .http_legacy;
}

fn vClose(ptr: *anyopaque) void {
    const self: *HttpLegacyTransport = @ptrCast(@alignCast(ptr));
    self.deinit();
}

/// Cancels every request and the GET stream, DELETEs the session (405 is
/// fine) and frees the transport.
pub fn deinit(self: *HttpLegacyTransport) void {
    const io = self.io;
    self.mutex.lockUncancelable(io);
    self.closed = true;
    var running: std.ArrayList(*Call) = .empty;
    defer running.deinit(self.gpa);
    for (self.calls.items) |c| if (c.state == .running) {
        c.state = .canceling;
        running.append(self.gpa, c) catch {};
    };
    self.calls.clearRetainingCapacity();
    self.mutex.unlock(io);
    for (running.items) |c| {
        c.future.cancel(io);
        self.freeCall(c);
    }
    self.reap.close(io);
    self.loops.shutdown();
    while (true) {
        var one: [1]*Call = undefined;
        const n = self.reap.getUncancelable(io, &one, 0) catch break;
        if (n == 0) break;
        one[0].future.await(io);
        self.freeCall(one[0]);
    }
    if (self.session) |sid| {
        self.deleteSession(sid);
        self.gpa.free(sid);
    }
    self.calls.deinit(self.gpa);
    self.gpa.free(self.reap_buf);
    self.opts_arena.deinit();
    self.gpa.destroy(self);
}

fn deleteSession(self: *HttpLegacyTransport, sid: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const auth_value: ?[]const u8 = if (self.opts.auth) |au| (au.headerFor(au.ctx, a) catch null) else null;
    var hs: std.ArrayList(std.http.Header) = .empty;
    hs.append(a, .{ .name = "Mcp-Session-Id", .value = sid }) catch return;
    if (self.negotiated and protocol.revision.has(self.revision, .mcp_protocol_version_header))
        hs.append(a, .{ .name = "MCP-Protocol-Version", .value = self.revision.string() }) catch return;
    hs.appendSlice(a, self.opts.static_headers) catch return;
    if (auth_value) |v| hs.append(a, .{ .name = "Authorization", .value = v }) catch return;
    var resp = self.client.send(self.gpa, .{ .method = .DELETE, .url = self.opts.url, .headers = hs.items }) catch return;
    resp.deinit(self.gpa);
}

const Snapshot = struct { revision: ?protocol.Revision, session: ?[]const u8 };

/// Copies the revision header value and the session id into `a`.
fn snapshot(self: *HttpLegacyTransport, a: Allocator) Allocator.Error!Snapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return .{
        .revision = if (self.negotiated) self.revision else null,
        .session = if (self.session) |s| try a.dupe(u8, s) else null,
    };
}

/// Adopts the session id from an `initialize` response head.
fn adoptSession(self: *HttpLegacyTransport, c: *Call) void {
    if (c.req.method != .initialize) return;
    const buf = c.head_session orelse return;
    if (!common.validSessionId(buf.items)) return;
    const copy = self.gpa.dupe(u8, buf.items) catch return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.session) |old| self.gpa.free(old);
    self.session = copy;
}

fn dropSession(self: *HttpLegacyTransport) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.session) |old| self.gpa.free(old);
    self.session = null;
}

fn start(self: *HttpLegacyTransport, req: Transport.OutgoingRequest, id: ?RequestId, sink: ?*Transport.RequestSink) Transport.SendError!void {
    self.rt.assertNotUi();
    const call = try self.newCall(req, id, sink);
    errdefer self.freeCall(call);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.closed) return error.Closed;
    try self.calls.append(self.gpa, call);
    // The task cannot finish before `future` is set: it takes `mutex` last.
    call.future = self.io.concurrent(runCall, .{call}) catch {
        _ = self.calls.pop();
        return error.ConcurrencyUnavailable;
    };
}

/// Posts a notification on the caller's task and returns once the server
/// accepted it, so that later messages cannot overtake it.
fn postNow(self: *HttpLegacyTransport, req: Transport.OutgoingRequest) Transport.SendError!void {
    self.rt.assertNotUi();
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
    }
    const call = try self.newCall(req, null, null);
    defer self.freeCall(call);
    perform(call) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Closed,
    };
}

/// A call record owning copies of `req`'s strings.
fn newCall(self: *HttpLegacyTransport, req: Transport.OutgoingRequest, id: ?RequestId, sink: ?*Transport.RequestSink) Allocator.Error!*Call {
    const call = try self.gpa.create(Call);
    call.* = .{ .t = self, .arena = .init(self.gpa), .id = null, .req = undefined, .sink = sink };
    errdefer {
        call.arena.deinit();
        self.gpa.destroy(call);
    }
    const a = call.arena.allocator();
    call.req = req;
    call.req.body = try a.dupe(u8, req.body);
    call.req.method_str = try a.dupe(u8, req.method_str);
    if (req.name_for_header) |n| call.req.name_for_header = try a.dupe(u8, n);
    const ph = try a.alloc(@TypeOf(req.param_headers[0]), req.param_headers.len);
    for (req.param_headers, ph) |p, *d| d.* = .{ .name = try a.dupe(u8, p.name), .value = try a.dupe(u8, p.value) };
    call.req.param_headers = ph;
    if (id) |i| call.id = switch (i) {
        .str => |s| .{ .str = try a.dupe(u8, s) },
        else => i,
    };
    call.req.id = call.id orelse .null;
    return call;
}

fn freeCall(self: *HttpLegacyTransport, c: *Call) void {
    c.arena.deinit();
    self.gpa.destroy(c);
}

fn reaper(self: *HttpLegacyTransport) void {
    while (true) {
        const c = self.reap.getOne(self.io) catch return;
        c.future.await(self.io);
        self.freeCall(c);
    }
}

fn runCall(c: *Call) void {
    const self = c.t;
    perform(c) catch |err| if (c.sink) |s| s.onError(s.ctx, switch (err) {
        error.Canceled => .canceled,
        error.StreamBroken => .stream_broken,
        else => .{ .io = err },
    });
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (c.state != .running) return; // The canceller awaits and frees.
    c.state = .done;
    for (self.calls.items, 0..) |x, i| if (x == c) {
        _ = self.calls.swapRemove(i);
        break;
    };
    // At most `calls.len` finished calls wait here and `deinit` drains the
    // queue, so a closed queue only means `deinit` is already draining.
    self.reap.putOneUncancelable(self.io, c) catch {};
}

const CallSink = struct {
    c: *Call,

    pub fn onResponse(self: CallSink, r: message.Response) void {
        // Before the sink sees the InitializeResult, so that the client's
        // next request already carries the session id.
        self.c.t.adoptSession(self.c);
        if (self.c.sink) |s| s.onResponse(s.ctx, r);
    }
    pub fn onNotification(self: CallSink, n: protocol.Notification, raw: message.Notification) void {
        if (self.c.sink) |s| s.onNotification(s.ctx, n, raw);
    }
    pub fn onServerRequest(self: CallSink, r: message.Request) void {
        if (self.c.sink) |s| s.onServerRequest(s.ctx, r);
    }
};

fn randomU64(io: Io) u64 {
    var r: [8]u8 = undefined;
    io.random(&r);
    return std.mem.readInt(u64, &r, .little);
}

fn perform(c: *Call) !void {
    const self = c.t;
    const a = c.arena.allocator();
    var router = common.BodyRouter(CallSink).init(self.gpa, c.id, .{ .c = c }, self.opts.max_response_bytes);
    defer router.deinit();
    c.head_session = &router.session_id;
    defer c.head_session = null;
    var challenged = false;
    var resumes: u32 = 0;
    var resuming = false;
    while (true) {
        const auth_value: ?[]const u8 = if (self.opts.auth) |au| try au.headerFor(au.ctx, a) else null;
        const snap = try self.snapshot(a);
        router.reset();
        const result = if (!resuming) self.client.stream(.{
            .method = .POST,
            .url = self.opts.url,
            .headers = try common.postHeaders(a, &self.opts, &c.req, snap.revision, self.opts.legacy_method_headers, auth_value, snap.session),
            .body = c.req.body,
        }, router.bodySink()) else self.client.stream(.{
            .method = .GET,
            .url = self.opts.url,
            .headers = try common.getHeaders(a, &self.opts, snap.revision, auth_value, snap.session, router.last_event_id.items),
        }, router.bodySink());

        var head = result catch |err| switch (err) {
            // The response arrived; we stopped reading the stream.
            error.ResponseComplete => return,
            error.Canceled => return err,
            else => {
                // The connection broke mid-stream: resume when we can.
                if (c.sink == null or !resumable(&router)) return err;
                try self.backoff(&router, &resumes);
                resuming = true;
                continue;
            },
        };
        defer head.deinit(self.gpa);
        const status: u16 = @intFromEnum(head.status);
        const sink = c.sink orelse return; // Notifications and answers: 202 expected.

        if ((status == 401 or status == 403) and !challenged) {
            if (self.opts.auth) |au| {
                challenged = true;
                const www = head.headers.get("www-authenticate") orelse "";
                if (try au.onChallenge(au.ctx, status, www) == .retry) continue;
            }
        }
        if (status == 404 and snap.session != null) {
            self.dropSession();
            return sink.onError(sink.ctx, .session_expired);
        }
        if (status / 100 == 2) {
            if (router.finishJson()) return;
            if (router.mode == .sse) {
                if (!resumable(&router) or resumes >= max_reconnects) return sink.onError(sink.ctx, .stream_broken);
                try self.backoff(&router, &resumes);
                resuming = true;
                continue;
            }
            return sink.onError(sink.ctx, .{ .protocol = "response without a JSON-RPC response for the request" });
        }
        // Some servers answer 4xx with a JSON-RPC error for the request.
        if (router.mode == .json and router.finishJson()) return;
        if (resuming) return sink.onError(sink.ctx, .stream_broken);
        return sink.onError(sink.ctx, .{ .http_status = .{
            .status = status,
            .body = router.json.items,
            .www_authenticate = head.headers.get("www-authenticate"),
        } });
    }
}

fn resumable(router: anytype) bool {
    return router.mode == .sse and router.last_event_id.items.len > 0 and
        (router.status orelse 0) / 100 == 2;
}

/// Waits before resume attempt `resumes.*`, or fails after the last one.
fn backoff(self: *HttpLegacyTransport, router: anytype, resumes: *u32) !void {
    if (resumes.* >= max_reconnects) return error.StreamBroken;
    const ms = common.reconnectDelayMs(router.retry_ms, resumes.*, randomU64(self.io));
    resumes.* += 1;
    try self.io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
}

const InboundRef = struct {
    t: *HttpLegacyTransport,

    pub fn onResponse(_: InboundRef, _: message.Response) void {}
    pub fn onNotification(self: InboundRef, n: protocol.Notification, raw: message.Notification) void {
        if (self.t.inbound) |s| s.onNotification(s.ctx, n, raw);
    }
    pub fn onServerRequest(self: InboundRef, r: message.Request) void {
        if (self.t.inbound) |s| s.onServerRequest(s.ctx, r);
    }
};

fn getLoop(self: *HttpLegacyTransport) void {
    getStream(self) catch |err| switch (err) {
        error.Canceled => {},
        else => if (self.inbound) |s| s.onClosed(s.ctx, .{ .io = err }),
    };
}

fn getStream(self: *HttpLegacyTransport) !void {
    var router = common.BodyRouter(InboundRef).init(self.gpa, null, .{ .t = self }, self.opts.max_response_bytes);
    defer router.deinit();
    var failures: u32 = 0;
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const auth_value: ?[]const u8 = if (self.opts.auth) |au| try au.headerFor(au.ctx, a) else null;
        const snap = try self.snapshot(a);
        router.reset();
        const events_before = router.events;
        const last = if (router.last_event_id.items.len > 0) router.last_event_id.items else null;
        if (self.client.stream(.{
            .method = .GET,
            .url = self.opts.url,
            .headers = try common.getHeaders(a, &self.opts, snap.revision, auth_value, snap.session, last),
        }, router.bodySink())) |h| {
            var head = h;
            defer head.deinit(self.gpa);
            const status: u16 = @intFromEnum(head.status);
            if (status == 405) return; // The server offers no GET stream.
            if (status == 404 and snap.session != null) {
                if (self.inbound) |s| s.onClosed(s.ctx, .session_expired);
                return;
            }
        } else |err| switch (err) {
            error.Canceled => return err,
            else => {},
        }
        failures = if (router.events > events_before) 0 else failures + 1;
        if (failures >= max_reconnects) {
            if (self.inbound) |s| s.onClosed(s.ctx, .stream_broken);
            return;
        }
        const ms = common.reconnectDelayMs(router.retry_ms, failures, randomU64(self.io));
        try self.io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
    }
}
