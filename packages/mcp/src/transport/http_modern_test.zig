//! Tests for the modern Streamable HTTP transport against `FakeHttpServer`.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const Transport = @import("Transport.zig");
const common = @import("http_common.zig");
const HttpModernTransport = @import("http_modern.zig");
const fake = @import("../testing/fake_http_server.zig");
const FakeHttpServer = fake.FakeHttpServer;

const message = zg_jsonrpc.message;
const wait_limit: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

/// Records what one request's sink receives.
const Collector = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    notes: std.ArrayList([]const u8) = .empty,
    result: ?[]const u8 = null,
    err_code: ?i64 = null,
    failure: ?std.meta.Tag(Transport.TransportError) = null,
    http_status: ?u16 = null,
    first_note: Io.Event = .unset,
    done: Io.Event = .unset,
    sink: Transport.RequestSink = undefined,

    fn init(c: *Collector, io: Io) void {
        c.* = .{ .io = io, .arena = .init(testing.allocator) };
        c.sink = .{ .ctx = c, .onNotification = onNote, .onServerRequest = onReq, .onResponse = onResp, .onError = onErr };
    }

    fn deinit(c: *Collector) void {
        c.arena.deinit();
    }

    fn from(ctx: ?*anyopaque) *Collector {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onNote(ctx: ?*anyopaque, _: protocol.Notification, raw: message.Notification) void {
        const c = from(ctx);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const m = c.arena.allocator().dupe(u8, raw.method) catch return;
        c.notes.append(c.arena.allocator(), m) catch return;
        c.first_note.set(c.io);
    }

    fn onReq(_: ?*anyopaque, _: message.Request) void {}

    fn onResp(ctx: ?*anyopaque, r: message.Response) void {
        const c = from(ctx);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (r.result) |res| c.result = c.arena.allocator().dupe(u8, res.bytes) catch null;
        if (r.err) |e| c.err_code = e.code;
        c.done.set(c.io);
    }

    fn onErr(ctx: ?*anyopaque, e: Transport.TransportError) void {
        const c = from(ctx);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        c.failure = e;
        if (e == .http_status) c.http_status = e.http_status.status;
        c.done.set(c.io);
    }
};

const Fixture = struct {
    rt: zg_core.Runtime,
    env: std.process.Environ.Map,
    client: *zg_net.http.Client,
    srv: FakeHttpServer,
    url_buf: [64]u8 = undefined,
    t: *HttpModernTransport,

    fn init(f: *Fixture, handler: fake.Handler, auth: ?common.HttpAuth) !void {
        f.rt.initTesting();
        f.env = .init(testing.allocator);
        f.client = try zg_net.http.Client.init(&f.rt, .{ .proxy = .none, .environ_map = &f.env });
        f.srv = .init(testing.allocator, testing.io, handler);
        try f.srv.start();
        f.t = try HttpModernTransport.init(&f.rt, f.client, testing.allocator, .{
            .url = f.srv.url(&f.url_buf, "/mcp"),
            .static_headers = &.{.{ .name = "X-Static", .value = "s" }},
            .auth = auth,
        });
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
        f.srv.deinit();
        f.client.deinit();
        f.env.deinit();
        _ = f.rt.deinit();
    }

    fn call(f: *Fixture, c: *Collector, id: i64, name: []const u8, params: []const @import("headers.zig").ParamHeader) !void {
        var body: [256]u8 = undefined;
        const b = try std.fmt.bufPrint(&body,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"x","arguments":{{}}}}}}
        , .{id});
        try f.t.transport().request(.{
            .id = .{ .int = id },
            .method = .tools_call,
            .method_str = "tools/call",
            .name_for_header = name,
            .param_headers = params,
            .body = b,
            .revision = .v2026_07_28,
        }, &c.sink);
    }
};

fn respondResult(req: *std.http.Server.Request, rec: fake.Recorded) !void {
    _ = rec;
    return fake.respondJson(req, .ok,
        \\{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","content":[]}}
    );
}

test "http modern: required headers and a JSON response" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            return respondResult(req, rec);
        }
    }.h, null);
    defer f.deinit();
    var c: Collector = undefined;
    c.init(testing.io);
    defer c.deinit();
    try f.call(&c, 1, "héllo", &.{.{ .name = "Mcp-Param-Region", .value = "eu" }});
    try c.done.waitTimeout(testing.io, wait_limit);

    try testing.expect(c.result != null);
    try testing.expect(std.mem.indexOf(u8, c.result.?, "\"content\"") != null);
    const rec = f.srv.request(0).?;
    try testing.expectEqual(std.http.Method.POST, rec.method);
    try testing.expectEqualStrings("/mcp", rec.target);
    try testing.expectEqualStrings("application/json", rec.header("content-type").?);
    try testing.expectEqualStrings("application/json, text/event-stream", rec.header("accept").?);
    try testing.expectEqualStrings("2026-07-28", rec.header("mcp-protocol-version").?);
    try testing.expectEqualStrings("tools/call", rec.header("mcp-method").?);
    try testing.expect(std.mem.startsWith(u8, rec.header("mcp-name").?, "=?base64?"));
    try testing.expectEqualStrings("eu", rec.header("mcp-param-region").?);
    try testing.expectEqualStrings("s", rec.header("x-static").?);
    try testing.expect(rec.header("mcp-session-id") == null);
    try testing.expect(std.mem.indexOf(u8, rec.body, "\"tools/call\"") != null);
}

test "http modern: SSE progress, keep-alive comments, then the response" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, _: fake.Recorded) !void {
            var buf: [512]u8 = undefined;
            var bw = try fake.startSse(req, &buf);
            try bw.writer.writeAll(": keep-alive\n\n");
            try fake.sseEvent(&bw,
                \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":1}}
            );
            try bw.writer.writeAll(": keep-alive\n\n");
            try fake.sseEvent(&bw,
                \\{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","content":[]}}
            );
            try bw.end();
        }
    }.h, null);
    defer f.deinit();
    var c: Collector = undefined;
    c.init(testing.io);
    defer c.deinit();
    try f.call(&c, 1, "x", &.{});
    try c.done.waitTimeout(testing.io, wait_limit);
    try testing.expectEqual(@as(usize, 1), c.notes.items.len);
    try testing.expectEqualStrings("notifications/progress", c.notes.items[0]);
    try testing.expect(c.result != null);
    try testing.expect(c.failure == null);
}

test "http modern: cancel closes the response stream" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, _: fake.Recorded) !void {
            var buf: [512]u8 = undefined;
            var bw = try fake.startSse(req, &buf);
            try fake.sseEvent(&bw,
                \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":1}}
            );
            // Keep-alives until the client goes away: the write then fails.
            while (true) {
                try testing.io.sleep(.fromMilliseconds(5), .awake);
                try bw.writer.writeAll(": ping\n\n");
                try bw.writer.flush();
                try bw.flush();
            }
        }
    }.h, null);
    defer f.deinit();
    var c: Collector = undefined;
    c.init(testing.io);
    defer c.deinit();
    try f.call(&c, 7, "x", &.{});
    try c.first_note.waitTimeout(testing.io, wait_limit);
    f.t.transport().cancel(.{ .int = 7 }, "user");
    try testing.expect(c.failure == .canceled);
    try testing.expect(c.result == null);
    var tries: usize = 0;
    while (f.srv.disconnects.load(.monotonic) == 0) : (tries += 1) {
        if (tries > 1000) return error.ServerNeverSawDisconnect;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "http modern: 400 with a modern JSON-RPC error is a response" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, _: fake.Recorded) !void {
            return fake.respondJson(req, .bad_request,
                \\{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2026-07-28"]}}}
            );
        }
    }.h, null);
    defer f.deinit();
    var c: Collector = undefined;
    c.init(testing.io);
    defer c.deinit();
    try f.call(&c, 1, "x", &.{});
    try c.done.waitTimeout(testing.io, wait_limit);
    try testing.expectEqual(@as(?i64, -32022), c.err_code);
    try testing.expect(c.failure == null);
}

test "http modern: 400 without a JSON-RPC body is an http_status error" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, _: fake.Recorded) !void {
            return req.respond("Bad Request: no session", .{ .status = .bad_request });
        }
    }.h, null);
    defer f.deinit();
    var c: Collector = undefined;
    c.init(testing.io);
    defer c.deinit();
    try f.call(&c, 1, "x", &.{});
    try c.done.waitTimeout(testing.io, wait_limit);
    try testing.expect(c.failure == .http_status);
    try testing.expectEqual(@as(?u16, 400), c.http_status);
}

const TestAuth = struct {
    var calls: std.atomic.Value(u32) = .init(0);
    var challenges: std.atomic.Value(u32) = .init(0);

    fn headerFor(_: ?*anyopaque, gpa: std.mem.Allocator) anyerror!?[]const u8 {
        const n = calls.fetchAdd(1, .monotonic);
        return try std.fmt.allocPrint(gpa, "Bearer t{d}", .{n + 1});
    }

    fn onChallenge(_: ?*anyopaque, status: u16, www: []const u8) anyerror!common.ChallengeOutcome {
        _ = challenges.fetchAdd(1, .monotonic);
        try testing.expectEqual(@as(u16, 401), status);
        try testing.expect(std.mem.indexOf(u8, www, "resource_metadata") != null);
        return .retry;
    }
};

test "http modern: 401 asks the auth hook and retries once" {
    TestAuth.calls = .init(0);
    TestAuth.challenges = .init(0);
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            if (std.mem.eql(u8, rec.header("authorization") orelse "", "Bearer t1")) {
                return req.respond("", .{ .status = .unauthorized, .extra_headers = &.{
                    .{ .name = "www-authenticate", .value = "Bearer resource_metadata=\"http://x/.well-known/oauth-protected-resource\"" },
                } });
            }
            return respondResult(req, rec);
        }
    }.h, .{ .ctx = null, .headerFor = TestAuth.headerFor, .onChallenge = TestAuth.onChallenge });
    defer f.deinit();
    var c: Collector = undefined;
    c.init(testing.io);
    defer c.deinit();
    try f.call(&c, 1, "x", &.{});
    try c.done.waitTimeout(testing.io, wait_limit);
    try testing.expect(c.result != null);
    try testing.expectEqual(@as(u32, 1), TestAuth.challenges.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), f.srv.count());
    try testing.expectEqualStrings("Bearer t2", f.srv.request(1).?.header("authorization").?);
}

test "http modern: a stream that ends without the response is stream_broken" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, _: fake.Recorded) !void {
            var buf: [512]u8 = undefined;
            var bw = try fake.startSse(req, &buf);
            try fake.sseEvent(&bw,
                \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":1}}
            );
            try bw.end();
        }
    }.h, null);
    defer f.deinit();
    var c: Collector = undefined;
    c.init(testing.io);
    defer c.deinit();
    try f.call(&c, 1, "x", &.{});
    try c.done.waitTimeout(testing.io, wait_limit);
    try testing.expect(c.failure == .stream_broken);
    try testing.expectEqual(@as(usize, 1), c.notes.items.len);
}

test "http modern: notifications are POSTed and expect 202" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, _: fake.Recorded) !void {
            return req.respond("", .{ .status = .accepted });
        }
    }.h, null);
    defer f.deinit();
    try f.t.transport().notify(.{
        .method_str = "notifications/cancelled",
        .body =
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}
        ,
        .revision = .v2026_07_28,
    });
    var tries: usize = 0;
    while (f.srv.count() == 0) : (tries += 1) {
        if (tries > 1000) return error.NotificationNotSent;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    const rec = f.srv.request(0).?;
    try testing.expectEqualStrings("notifications/cancelled", rec.header("mcp-method").?);
    try testing.expect(rec.header("mcp-name") == null);
}
