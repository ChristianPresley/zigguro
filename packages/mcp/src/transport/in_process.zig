//! An in-process transport pair: a client `Transport` on one side and a
//! server handler on the other, exchanging complete JSON-RPC messages
//! without serialization to a pipe or socket. zigguro's own MCP servers
//! (F06) use it when they run inside the IDE, and the client tests use it
//! with scripted mock servers.
//!
//! Delivery is synchronous: `request`/`notify`/`respond` call the server's
//! `onMessage` on the caller's thread, and `serverSend` routes a server
//! message to the client on the server's thread. A server that answers
//! later runs its own task. Routing follows stdio: responses are matched by
//! id, everything else goes to the inbound sink, and `cancel` sends
//! `notifications/cancelled`.

const InProcPair = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const Transport = @import("Transport.zig");
const common = @import("http_common.zig");

const RequestId = protocol.RequestId;
const message = zg_jsonrpc.message;

/// The server side: receives every client message (complete JSON-RPC
/// bytes, valid during the call).
pub const ServerHandler = struct {
    ctx: ?*anyopaque,
    onMessage: *const fn (ctx: ?*anyopaque, pair: *InProcPair, body: []const u8) void,
};

const Pending = struct { id: RequestId, sink: *Transport.RequestSink };

gpa: Allocator,
io: Io,
mutex: Io.Mutex = .init,
server: ?ServerHandler = null,
pending: std.ArrayList(Pending) = .empty,
inbound: ?*Transport.InboundSink = null,
closed: bool = false,

/// A pair with no server yet (`setServer`).
pub fn init(gpa: Allocator, io: Io) InProcPair {
    return .{ .gpa = gpa, .io = io };
}

/// Fails pending requests with `canceled` and frees the bookkeeping. The
/// client must not use its transport afterwards.
pub fn deinit(self: *InProcPair) void {
    self.shutdown(.canceled);
    self.pending.deinit(self.gpa);
}

/// Connects the server side.
pub fn setServer(self: *InProcPair, h: ServerHandler) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.server = h;
}

/// The client side.
pub fn transport(self: *InProcPair) Transport {
    return .{ .ptr = self, .vtable = &vtable };
}

/// Sends a server message (response, notification or request) to the
/// client. Responses to unknown ids are dropped.
pub fn serverSend(self: *InProcPair, body: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = switch (message.parse(a, body)) {
        .single => |m| m,
        .batch, .invalid => return,
    };
    switch (msg) {
        .response => |resp| {
            const p = self.takePending(resp.id) orelse return;
            defer freeId(self.gpa, p.id);
            p.sink.onResponse(p.sink.ctx, resp);
        },
        .notification => |n| if (self.inboundSink()) |in| {
            const typed = protocol.Notification.decode(a, n.method, n.params, .{}) catch
                protocol.Notification{ .unknown = .{ .method = n.method, .params = null } };
            in.onNotification(in.ctx, typed, n);
        },
        .request => |req| if (self.inboundSink()) |in| in.onServerRequest(in.ctx, req),
    }
}

/// Fails the pending request `id` with `e` (tests: simulate a broken
/// stream or an expired session). Returns whether it was pending.
pub fn failRequest(self: *InProcPair, id: RequestId, e: Transport.TransportError) bool {
    const p = self.takePending(id) orelse return false;
    defer freeId(self.gpa, p.id);
    p.sink.onError(p.sink.ctx, e);
    return true;
}

/// Closes the pair as if the server went away: pending requests fail with
/// `e`, the inbound sink learns it, later sends fail with `Closed`.
pub fn shutdown(self: *InProcPair, e: Transport.TransportError) void {
    self.mutex.lockUncancelable(self.io);
    const was_closed = self.closed;
    self.closed = true;
    const all = self.pending.toOwnedSlice(self.gpa) catch &.{};
    const in = self.inbound;
    self.mutex.unlock(self.io);
    defer self.gpa.free(all);
    for (all) |p| {
        p.sink.onError(p.sink.ctx, e);
        freeId(self.gpa, p.id);
    }
    if (!was_closed) if (in) |s| s.onClosed(s.ctx, e);
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
    const self: *InProcPair = @ptrCast(@alignCast(ptr));
    const id: RequestId = switch (req.id) {
        .str => |s| .{ .str = try self.gpa.dupe(u8, s) },
        else => req.id,
    };
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) {
            freeId(self.gpa, id);
            return error.Closed;
        }
        self.pending.append(self.gpa, .{ .id = id, .sink = sink }) catch |e| {
            freeId(self.gpa, id);
            return e;
        };
    }
    self.deliver(req.body) catch |err| {
        if (self.takePending(id)) |p| freeId(self.gpa, p.id);
        return err;
    };
}

fn vNotify(ptr: *anyopaque, n: Transport.OutgoingNotification) Transport.SendError!void {
    const self: *InProcPair = @ptrCast(@alignCast(ptr));
    return self.deliver(n.body);
}

fn vRespond(ptr: *anyopaque, body: []const u8, _: protocol.Revision) Transport.SendError!void {
    const self: *InProcPair = @ptrCast(@alignCast(ptr));
    return self.deliver(body);
}

fn vCancel(ptr: *anyopaque, id: RequestId, reason: ?[]const u8) void {
    const self: *InProcPair = @ptrCast(@alignCast(ptr));
    const p = self.takePending(id) orelse return;
    defer freeId(self.gpa, p.id);
    p.sink.onError(p.sink.ctx, .canceled);
    const body = common.cancelledBody(self.gpa, id, reason) catch return;
    defer self.gpa.free(body);
    self.deliver(body) catch {};
}

fn vSetInbound(ptr: *anyopaque, inbound: *Transport.InboundSink) void {
    const self: *InProcPair = @ptrCast(@alignCast(ptr));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.inbound = inbound;
}

fn vKind(_: *anyopaque) Transport.Kind {
    return .in_process;
}

fn vClose(ptr: *anyopaque) void {
    const self: *InProcPair = @ptrCast(@alignCast(ptr));
    self.mutex.lockUncancelable(self.io);
    self.inbound = null;
    self.mutex.unlock(self.io);
    self.shutdown(.canceled);
}

fn deliver(self: *InProcPair, body: []const u8) Transport.SendError!void {
    self.mutex.lockUncancelable(self.io);
    const closed = self.closed;
    const server = self.server;
    self.mutex.unlock(self.io);
    if (closed) return error.Closed;
    const h = server orelse return error.Closed;
    h.onMessage(h.ctx, self, body);
}

fn inboundSink(self: *InProcPair) ?*Transport.InboundSink {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.inbound;
}

fn takePending(self: *InProcPair, id: RequestId) ?Pending {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.pending.items, 0..) |p, i| if (p.id.eql(id)) return self.pending.swapRemove(i);
    return null;
}

fn freeId(gpa: Allocator, id: RequestId) void {
    switch (id) {
        .str => |s| gpa.free(s),
        else => {},
    }
}

const testing = std.testing;

test "in-process: request, response, notification and cancel" {
    const Echo = struct {
        got_cancel: bool = false,
        fn onMessage(ctx: ?*anyopaque, pair: *InProcPair, body: []const u8) void {
            const e: *@This() = @ptrCast(@alignCast(ctx.?));
            if (std.mem.indexOf(u8, body, "notifications/cancelled") != null) {
                e.got_cancel = true;
                return;
            }
            if (std.mem.indexOf(u8, body, "\"slow\"") != null) return;
            pair.serverSend("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\",\"data\":1}}");
            pair.serverSend("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");
        }
    };
    const Sink = struct {
        result: ?bool = null,
        failure: ?std.meta.Tag(Transport.TransportError) = null,
        notes: u32 = 0,
        fn note(ctx: ?*anyopaque, _: protocol.Notification, _: message.Notification) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.notes += 1;
        }
        fn req(_: ?*anyopaque, _: message.Request) void {}
        fn resp(ctx: ?*anyopaque, r: message.Response) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.result = r.result != null;
        }
        fn err(ctx: ?*anyopaque, e: Transport.TransportError) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.failure = e;
        }
        fn closed(_: ?*anyopaque, _: Transport.TransportError) void {}
    };
    var pair: InProcPair = .init(testing.allocator, testing.io);
    defer pair.deinit();
    var echo: Echo = .{};
    pair.setServer(.{ .ctx = &echo, .onMessage = Echo.onMessage });
    var s: Sink = .{};
    var rs: Transport.RequestSink = .{ .ctx = &s, .onNotification = Sink.note, .onServerRequest = Sink.req, .onResponse = Sink.resp, .onError = Sink.err };
    var in: Transport.InboundSink = .{ .ctx = &s, .onNotification = Sink.note, .onServerRequest = Sink.req, .onClosed = Sink.closed };
    const t = pair.transport();
    t.setInbound(&in);
    try t.request(.{ .id = .{ .int = 1 }, .method = .ping, .method_str = "ping", .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", .revision = .v2025_11_25 }, &rs);
    try testing.expectEqual(@as(?bool, true), s.result);
    try testing.expectEqual(@as(u32, 1), s.notes);

    try t.request(.{ .id = .{ .int = 2 }, .method = .ping, .method_str = "slow", .body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"slow\"}", .revision = .v2025_11_25 }, &rs);
    t.cancel(.{ .int = 2 }, null);
    try testing.expect(s.failure.? == .canceled);
    try testing.expect(echo.got_cancel);
    try testing.expectEqual(Transport.Kind.in_process, t.kind());
}
