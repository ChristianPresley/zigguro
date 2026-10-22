//! Streamable HTTP for modern servers (2026-07-28): every message is its own
//! POST carrying `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` and the
//! tool's `Mcp-Param-*` headers; the answer is one JSON object or an SSE
//! stream scoped to the request. Closing that stream is the cancellation;
//! a broken stream loses the request (no resumability), so the client
//! re-issues it with a new id.
//!
//! Each request runs as its own concurrent task holding one pooled
//! connection of the shared `zg_net.http.Client`; `cancel` cancels that task,
//! which closes its connection. A reaper task awaits finished requests, so
//! an idle transport runs no timers and polls nothing.

const HttpModernTransport = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const protocol = @import("../protocol/root.zig");
const Transport = @import("Transport.zig");
const common = @import("http_common.zig");

const RequestId = protocol.RequestId;

rt: *zg_core.Runtime,
client: *zg_net.http.Client,
gpa: Allocator,
io: Io,
/// Owned copy of the options (url and static headers duplicated).
opts: common.HttpOptions,
opts_arena: std.heap.ArenaAllocator,
mutex: Io.Mutex = .init,
calls: std.ArrayList(*Call) = .empty,
reap_buf: []*Call,
reap: Io.Queue(*Call),
loops: zg_core.runtime.Subsystem,
inbound: ?*Transport.InboundSink = null,
closed: bool = false,

const State = enum { running, done, canceling };

const Call = struct {
    t: *HttpModernTransport,
    arena: std.heap.ArenaAllocator,
    id: ?RequestId,
    req: Transport.OutgoingRequest,
    sink: ?*Transport.RequestSink,
    future: Io.Future(void) = undefined,
    state: State = .running,
};

/// Creates the transport. `client` is shared and must outlive it.
pub fn init(rt: *zg_core.Runtime, client: *zg_net.http.Client, gpa: Allocator, opts: common.HttpOptions) !*HttpModernTransport {
    const self = try gpa.create(HttpModernTransport);
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
pub fn transport(self: *HttpModernTransport) Transport {
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
    const self: *HttpModernTransport = @ptrCast(@alignCast(ptr));
    return self.start(req, req.id, sink);
}

fn vNotify(ptr: *anyopaque, n: Transport.OutgoingNotification) Transport.SendError!void {
    const self: *HttpModernTransport = @ptrCast(@alignCast(ptr));
    const req: Transport.OutgoingRequest = .{
        .id = .null,
        .method = .ping,
        .method_str = n.method_str,
        .body = n.body,
        .revision = n.revision,
    };
    return self.start(req, null, null);
}

fn vRespond(ptr: *anyopaque, body: []const u8, revision: protocol.Revision) Transport.SendError!void {
    // Modern servers send no requests (MRTR replaced them); a lenient
    // answer to one is POSTed like a notification, without `Mcp-Method`.
    return vNotify(ptr, .{ .method_str = "", .body = body, .revision = revision });
}

fn vCancel(ptr: *anyopaque, id: RequestId, reason: ?[]const u8) void {
    _ = reason; // Modern HTTP has no cancel message: closing the stream is the signal.
    const self: *HttpModernTransport = @ptrCast(@alignCast(ptr));
    self.mutex.lockUncancelable(self.io);
    const call = for (self.calls.items, 0..) |c, i| {
        if (c.id != null and c.id.?.eql(id) and c.state == .running) {
            c.state = .canceling;
            _ = self.calls.swapRemove(i);
            break c;
        }
    } else null;
    self.mutex.unlock(self.io);
    const c = call orelse return;
    c.future.cancel(self.io);
    self.freeCall(c);
}

fn vSetInbound(ptr: *anyopaque, inbound: *Transport.InboundSink) void {
    // Modern servers send nothing outside requests; change notifications
    // arrive on the `subscriptions/listen` response stream.
    const self: *HttpModernTransport = @ptrCast(@alignCast(ptr));
    self.inbound = inbound;
}

fn vKind(_: *anyopaque) Transport.Kind {
    return .http_modern;
}

fn vClose(ptr: *anyopaque) void {
    const self: *HttpModernTransport = @ptrCast(@alignCast(ptr));
    self.deinit();
}

/// Cancels every request, stops the reaper and frees the transport.
pub fn deinit(self: *HttpModernTransport) void {
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
    // Calls that finished but were not reaped yet.
    while (true) {
        var one: [1]*Call = undefined;
        const n = self.reap.getUncancelable(io, &one, 0) catch break;
        if (n == 0) break;
        one[0].future.await(io);
        self.freeCall(one[0]);
    }
    self.calls.deinit(self.gpa);
    self.gpa.free(self.reap_buf);
    self.opts_arena.deinit();
    self.gpa.destroy(self);
}

fn start(self: *HttpModernTransport, req: Transport.OutgoingRequest, id: ?RequestId, sink: ?*Transport.RequestSink) Transport.SendError!void {
    self.rt.assertNotUi();
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

fn freeCall(self: *HttpModernTransport, c: *Call) void {
    c.arena.deinit();
    self.gpa.destroy(c);
}

fn reaper(self: *HttpModernTransport) void {
    while (true) {
        const c = self.reap.getOne(self.io) catch return;
        c.future.await(self.io);
        self.freeCall(c);
    }
}

/// The request task: performs the POST(s), reports exactly one terminal
/// outcome to the sink, then hands itself to the reaper.
fn runCall(c: *Call) void {
    const self = c.t;
    perform(c) catch |err| switch (err) {
        error.Canceled => if (c.sink) |s| s.onError(s.ctx, .canceled),
        else => if (c.sink) |s| s.onError(s.ctx, .{ .io = err }),
    };
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (c.state != .running) return; // The canceller awaits and frees.
    c.state = .done;
    for (self.calls.items, 0..) |x, i| if (x == c) {
        _ = self.calls.swapRemove(i);
        break;
    };
    // The queue holds every finished call: at most `calls.len` are live and
    // `deinit` drains it, so a closed queue only means `deinit` is draining.
    self.reap.putOneUncancelable(self.io, c) catch {};
}

const SinkRef = struct {
    sink: ?*Transport.RequestSink,

    pub fn onResponse(self: SinkRef, r: @import("zg_jsonrpc").message.Response) void {
        if (self.sink) |s| s.onResponse(s.ctx, r);
    }
    pub fn onNotification(self: SinkRef, n: protocol.Notification, raw: @import("zg_jsonrpc").message.Notification) void {
        if (self.sink) |s| s.onNotification(s.ctx, n, raw);
    }
    pub fn onServerRequest(self: SinkRef, r: @import("zg_jsonrpc").message.Request) void {
        // A protocol violation in the modern era; forwarded leniently.
        if (self.sink) |s| s.onServerRequest(s.ctx, r);
    }
};

fn perform(c: *Call) !void {
    const self = c.t;
    const a = c.arena.allocator();
    var challenged = false;
    while (true) {
        const auth_value: ?[]const u8 = if (self.opts.auth) |au| try au.headerFor(au.ctx, a) else null;
        const hs = try common.postHeaders(a, &self.opts, &c.req, c.req.revision, true, auth_value, null);
        const ref: SinkRef = .{ .sink = c.sink };
        var router = common.BodyRouter(SinkRef).init(self.gpa, c.id, ref, self.opts.max_response_bytes);
        defer router.deinit();
        var head = self.client.stream(.{
            .method = .POST,
            .url = self.opts.url,
            .headers = hs,
            .body = c.req.body,
        }, router.bodySink()) catch |err| switch (err) {
            // The response arrived; we stopped reading the stream.
            error.ResponseComplete => return,
            else => return err,
        };
        defer head.deinit(self.gpa);
        const status: u16 = @intFromEnum(head.status);
        const sink = c.sink orelse return; // Notifications: 202 expected, nothing to report.

        if ((status == 401 or status == 403) and !challenged) {
            if (self.opts.auth) |au| {
                challenged = true;
                const www = head.headers.get("www-authenticate") orelse "";
                if (try au.onChallenge(au.ctx, status, www) == .retry) continue;
            }
        }
        if (status / 100 == 2) {
            if (router.finishJson()) return;
            if (router.mode == .sse) return sink.onError(sink.ctx, .stream_broken);
            return sink.onError(sink.ctx, .{ .protocol = "response without a JSON-RPC response for the request" });
        }
        // 400 (-32022, -32020, -32021) and 404 (-32601) carry JSON-RPC errors.
        if (router.mode == .json and common.modernErrorCode(a, router.json.items) != null) {
            if (router.finishJson()) return;
        }
        return sink.onError(sink.ctx, .{ .http_status = .{
            .status = status,
            .body = if (router.mode == .json) router.json.items else "",
            .www_authenticate = head.headers.get("www-authenticate"),
        } });
    }
}
