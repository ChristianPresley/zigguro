//! Tests for the legacy Streamable HTTP and HTTP+SSE transports against
//! `FakeHttpServer`.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const Transport = @import("Transport.zig");
const common = @import("http_common.zig");
const HttpLegacyTransport = @import("http_legacy.zig");
const HttpSseTransport = @import("http_sse.zig");
const fake = @import("../testing/fake_http_server.zig");
const FakeHttpServer = fake.FakeHttpServer;

const message = zg_jsonrpc.message;
const io = testing.io;
const wait_limit: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

/// Records what one request's sink (or the inbound sink) receives.
const Collector = struct {
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    notes: std.ArrayList([]const u8) = .empty,
    server_requests: usize = 0,
    result: ?[]const u8 = null,
    failure: ?std.meta.Tag(Transport.TransportError) = null,
    first_note: Io.Event = .unset,
    done: Io.Event = .unset,
    /// Answers server requests through this transport when set.
    responder: ?Transport = null,
    sink: Transport.RequestSink = undefined,
    inbound: Transport.InboundSink = undefined,

    fn init(c: *Collector) void {
        c.* = .{ .arena = .init(testing.allocator) };
        c.sink = .{ .ctx = c, .onNotification = onNote, .onServerRequest = onReq, .onResponse = onResp, .onError = onErr };
        c.inbound = .{ .ctx = c, .onNotification = onNote, .onServerRequest = onReq, .onClosed = onErr };
    }

    fn deinit(c: *Collector) void {
        c.arena.deinit();
    }

    fn from(ctx: ?*anyopaque) *Collector {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onNote(ctx: ?*anyopaque, _: protocol.Notification, raw: message.Notification) void {
        const c = from(ctx);
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        const m = c.arena.allocator().dupe(u8, raw.method) catch return;
        c.notes.append(c.arena.allocator(), m) catch return;
        c.first_note.set(io);
    }

    fn onReq(ctx: ?*anyopaque, r: message.Request) void {
        const c = from(ctx);
        c.mutex.lockUncancelable(io);
        c.server_requests += 1;
        c.mutex.unlock(io);
        const t = c.responder orelse return;
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"jsonrpc":"2.0","id":"{s}","result":{{"role":"assistant","content":{{"type":"text","text":"hi"}},"model":"m"}}}}
        , .{r.id.str}) catch return;
        t.respond(body, .v2025_06_18) catch {};
    }

    fn onResp(ctx: ?*anyopaque, r: message.Response) void {
        const c = from(ctx);
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        if (r.result) |res| c.result = c.arena.allocator().dupe(u8, res.bytes) catch null;
        c.done.set(io);
    }

    fn onErr(ctx: ?*anyopaque, e: Transport.TransportError) void {
        const c = from(ctx);
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.failure = e;
        c.done.set(io);
    }
};

const Fixture = struct {
    rt: zg_core.Runtime,
    env: std.process.Environ.Map,
    client: *zg_net.http.Client,
    srv: FakeHttpServer,
    url_buf: [64]u8 = undefined,
    t: ?*HttpLegacyTransport = null,

    fn init(f: *Fixture, handler: fake.Handler) !void {
        f.* = .{ .rt = undefined, .env = .init(testing.allocator), .client = undefined, .srv = .init(testing.allocator, io, handler) };
        f.rt.initTesting();
        f.client = try zg_net.http.Client.init(&f.rt, .{ .proxy = .none, .environ_map = &f.env });
        try f.srv.start();
    }

    fn legacy(f: *Fixture) !*HttpLegacyTransport {
        f.t = try HttpLegacyTransport.init(&f.rt, f.client, testing.allocator, .{ .url = f.srv.url(&f.url_buf, "/mcp") }, .v2025_06_18);
        return f.t.?;
    }

    fn closeTransport(f: *Fixture) void {
        if (f.t) |t| t.deinit();
        f.t = null;
    }

    fn deinit(f: *Fixture) void {
        f.closeTransport();
        f.srv.deinit();
        f.client.deinit();
        f.env.deinit();
        _ = f.rt.deinit();
    }

    fn count(f: *Fixture, pred: *const fn (fake.Recorded) bool) usize {
        var n: usize = 0;
        for (0..f.srv.count()) |i| {
            if (pred(f.srv.request(i).?)) n += 1;
        }
        return n;
    }
};

fn request(t: Transport, c: *Collector, id: i64, method: protocol.Method, method_str: []const u8) !void {
    var body: [256]u8 = undefined;
    const b = try std.fmt.bufPrint(&body,
        \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{{}}}}
    , .{ id, method_str });
    try t.request(.{ .id = .{ .int = id }, .method = method, .method_str = method_str, .body = b, .revision = .v2025_06_18 }, &c.sink);
}

fn waitFor(f: *Fixture, comptime what: []const u8, pred: *const fn (*Fixture) bool) !void {
    var tries: usize = 0;
    while (!pred(f)) : (tries += 1) {
        if (tries > 1000) {
            std.debug.print("timed out waiting for {s}\n", .{what});
            return error.Timeout;
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

fn hold(bw: *std.http.BodyWriter) !void {
    while (true) {
        try io.sleep(.fromMilliseconds(5), .awake);
        try bw.writer.writeAll(": ping\n\n");
        try bw.writer.flush();
        try bw.flush();
    }
}

fn isPost(r: fake.Recorded) bool {
    return r.method == .POST;
}

fn isGet(r: fake.Recorded) bool {
    return r.method == .GET;
}

fn isCancelled(r: fake.Recorded) bool {
    return r.method == .POST and std.mem.indexOf(u8, r.body, "notifications/cancelled") != null;
}

const init_result =
    \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}
;

test "legacy: session id captured/echoed; 404 => session_expired" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            if (std.mem.indexOf(u8, rec.body, "\"initialize\"") != null) {
                return req.respond(init_result, .{ .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "mcp-session-id", .value = "sess-1" },
                } });
            }
            return req.respond("", .{ .status = .not_found });
        }
    }.h);
    defer f.deinit();
    const t = try f.legacy();
    var c1: Collector = undefined;
    c1.init();
    defer c1.deinit();
    try request(t.transport(), &c1, 1, .initialize, "initialize");
    try c1.done.waitTimeout(io, wait_limit);
    try testing.expect(c1.result != null);
    try testing.expectEqualStrings("sess-1", t.sessionId().?);
    t.setRevision(.v2025_06_18);

    var c2: Collector = undefined;
    c2.init();
    defer c2.deinit();
    try request(t.transport(), &c2, 2, .tools_list, "tools/list");
    try c2.done.waitTimeout(io, wait_limit);
    try testing.expect(c2.failure == .session_expired);
    try testing.expect(t.sessionId() == null);

    const first = f.srv.request(0).?;
    try testing.expect(first.header("mcp-session-id") == null);
    try testing.expect(first.header("mcp-protocol-version") == null);
    const second = f.srv.request(1).?;
    try testing.expectEqualStrings("sess-1", second.header("mcp-session-id").?);
    try testing.expectEqualStrings("2025-06-18", second.header("mcp-protocol-version").?);
    try testing.expect(second.header("mcp-method") == null);
    try testing.expectEqualStrings("application/json, text/event-stream", second.header("accept").?);
}

const Gate = struct {
    var answered: Io.Event = .unset;
};

test "legacy: SSE server request (sampling) routed and answered via POST" {
    Gate.answered = .unset;
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            if (std.mem.indexOf(u8, rec.body, "\"result\"") != null) {
                // The client's answer to our sampling request.
                try req.respond("", .{ .status = .accepted });
                Gate.answered.set(io);
                return;
            }
            var buf: [512]u8 = undefined;
            var bw = try fake.startSse(req, &buf);
            try fake.sseEvent(&bw,
                \\{"jsonrpc":"2.0","id":"s1","method":"sampling/createMessage","params":{"messages":[],"maxTokens":5}}
            );
            try Gate.answered.waitTimeout(io, wait_limit);
            try fake.sseEvent(&bw,
                \\{"jsonrpc":"2.0","id":3,"result":{"content":[]}}
            );
            try bw.end();
        }
    }.h);
    defer f.deinit();
    const t = try f.legacy();
    var c: Collector = undefined;
    c.init();
    defer c.deinit();
    c.responder = t.transport();
    try request(t.transport(), &c, 3, .tools_call, "tools/call");
    try c.done.waitTimeout(io, wait_limit);
    try testing.expect(c.result != null);
    try testing.expectEqual(@as(usize, 1), c.server_requests);
    try testing.expectEqual(@as(usize, 2), f.count(isPost));
}

test "legacy: resume with Last-Event-ID after retry ms; priming event handled" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            var buf: [512]u8 = undefined;
            var bw = try fake.startSse(req, &buf);
            if (rec.method == .GET) {
                if (!std.mem.eql(u8, rec.header("last-event-id") orelse "", "e1")) return error.WrongCursor;
                try bw.writer.writeAll("id: e2\ndata: {\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"content\":[]}}\n\n");
            } else {
                // Priming event: an id and an empty data line, then progress.
                try bw.writer.writeAll("id: p0\nretry: 40\ndata:\n\n");
                try bw.writer.writeAll("id: e1\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":1,\"progress\":1}}\n\n");
            }
            try bw.end();
        }
    }.h);
    defer f.deinit();
    const t = try f.legacy();
    var c: Collector = undefined;
    c.init();
    defer c.deinit();
    const t0 = Io.Timestamp.now(io, .awake);
    try request(t.transport(), &c, 4, .tools_call, "tools/call");
    try c.done.waitTimeout(io, wait_limit);
    const elapsed = t0.durationTo(Io.Timestamp.now(io, .awake));
    try testing.expect(c.result != null);
    try testing.expectEqual(@as(usize, 1), c.notes.items.len);
    try testing.expectEqual(@as(usize, 1), f.count(isGet));
    // retry 40 ms minus at most 25 % jitter.
    try testing.expect(elapsed.toMilliseconds() >= 30);
}

test "legacy: GET stream 405 tolerated" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, _: fake.Recorded) !void {
            return req.respond("", .{ .status = .method_not_allowed });
        }
    }.h);
    defer f.deinit();
    const t = try f.legacy();
    var c: Collector = undefined;
    c.init();
    defer c.deinit();
    t.transport().setInbound(&c.inbound);
    try t.openGetStream();
    try waitFor(&f, "the GET", struct {
        fn p(x: *Fixture) bool {
            return x.srv.count() >= 1;
        }
    }.p);
    try io.sleep(.fromMilliseconds(30), .awake);
    try testing.expectEqual(@as(usize, 1), f.srv.count());
    try testing.expect(c.failure == null);
}

test "legacy: GET stream delivers tools/list_changed" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, _: fake.Recorded) !void {
            var buf: [512]u8 = undefined;
            var bw = try fake.startSse(req, &buf);
            try fake.sseEvent(&bw,
                \\{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
            );
            try hold(&bw);
        }
    }.h);
    defer f.deinit();
    const t = try f.legacy();
    var c: Collector = undefined;
    c.init();
    defer c.deinit();
    t.transport().setInbound(&c.inbound);
    try t.openGetStream();
    try c.first_note.waitTimeout(io, wait_limit);
    try testing.expectEqualStrings("notifications/tools/list_changed", c.notes.items[0]);
    try testing.expectEqualStrings("text/event-stream", f.srv.request(0).?.header("accept").?);
    f.closeTransport();
    try testing.expect(c.failure == null);
}

test "legacy: DELETE on close" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            if (rec.method == .DELETE) return req.respond("", .{});
            return req.respond(init_result, .{ .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "Mcp-Session-Id", .value = "sess-9" },
            } });
        }
    }.h);
    defer f.deinit();
    const t = try f.legacy();
    var c: Collector = undefined;
    c.init();
    defer c.deinit();
    try request(t.transport(), &c, 1, .initialize, "initialize");
    try c.done.waitTimeout(io, wait_limit);
    f.closeTransport();
    const del = f.srv.request(1).?;
    try testing.expectEqual(std.http.Method.DELETE, del.method);
    try testing.expectEqualStrings("sess-9", del.header("mcp-session-id").?);
}

test "legacy: cancel posts notifications/cancelled; disconnect alone does not cancel" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            if (isCancelled(rec)) return req.respond("", .{ .status = .accepted });
            var buf: [512]u8 = undefined;
            var bw = try fake.startSse(req, &buf);
            try fake.sseEvent(&bw,
                \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":1}}
            );
            // Request 8 is dropped by the server; request 7 is held open.
            if (std.mem.indexOf(u8, rec.body, "\"id\":8") != null) return bw.end();
            try hold(&bw);
        }
    }.h);
    defer f.deinit();
    const t = try f.legacy();

    var dropped: Collector = undefined;
    dropped.init();
    defer dropped.deinit();
    try request(t.transport(), &dropped, 8, .tools_call, "tools/call");
    try dropped.done.waitTimeout(io, wait_limit);
    try testing.expect(dropped.failure == .stream_broken);
    try testing.expectEqual(@as(usize, 0), f.count(isCancelled));

    var c: Collector = undefined;
    c.init();
    defer c.deinit();
    try request(t.transport(), &c, 7, .tools_call, "tools/call");
    try c.first_note.waitTimeout(io, wait_limit);
    t.transport().cancel(.{ .int = 7 }, "user");
    try testing.expect(c.failure == .canceled);
    try waitFor(&f, "notifications/cancelled", struct {
        fn p(x: *Fixture) bool {
            return x.count(isCancelled) == 1;
        }
    }.p);
    for (0..f.srv.count()) |i| {
        const r = f.srv.request(i).?;
        if (isCancelled(r)) try testing.expect(std.mem.indexOf(u8, r.body, "\"requestId\":7") != null);
    }
}

// ---------------------------------------------------------------- HTTP+SSE

const SseServer = struct {
    var outbox_buf: [8][]const u8 = undefined;
    var outbox: Io.Queue([]const u8) = undefined;
    var endpoint: []const u8 = "/messages?sid=1";

    fn reset(ep: []const u8) void {
        outbox = .init(&outbox_buf);
        endpoint = ep;
    }

    fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
        if (rec.method == .POST) {
            if (!std.mem.eql(u8, rec.target, "/messages?sid=1")) return req.respond("", .{ .status = .not_found });
            try req.respond("", .{ .status = .accepted });
            if (std.mem.indexOf(u8, rec.body, "\"id\":5") != null) try outbox.putOne(io,
                \\{"jsonrpc":"2.0","id":5,"result":{"tools":[]}}
            );
            return;
        }
        var buf: [512]u8 = undefined;
        var bw = try fake.startSse(req, &buf);
        if (endpoint.len > 0) {
            try bw.writer.print("event: endpoint\ndata: {s}\n\n", .{endpoint});
            try bw.writer.flush();
            try bw.flush();
        }
        while (true) {
            const msg = try outbox.getOne(io);
            try fake.sseEvent(&bw, msg);
        }
    }
};

fn sseConnect(f: *Fixture, timeout: Io.Duration) !*HttpSseTransport {
    return HttpSseTransport.connect(&f.rt, f.client, testing.allocator, .{
        .url = f.srv.url(&f.url_buf, "/sse"),
        .endpoint_timeout = timeout,
    });
}

test "httpsse: endpoint event then POST round-trip" {
    SseServer.reset("/messages?sid=1");
    var f: Fixture = undefined;
    try f.init(SseServer.h);
    defer f.deinit();
    const t = try sseConnect(&f, .fromSeconds(5));
    defer t.deinit();
    var c: Collector = undefined;
    c.init();
    defer c.deinit();
    try request(t.transport(), &c, 5, .tools_list, "tools/list");
    try c.done.waitTimeout(io, wait_limit);
    try testing.expect(c.result != null);
    try testing.expectEqualStrings("/sse", f.srv.request(0).?.target);
    try testing.expectEqualStrings("text/event-stream", f.srv.request(0).?.header("accept").?);
}

test "httpsse: cross-origin endpoint rejected" {
    SseServer.reset("http://evil.example:8080/messages?sid=1");
    var f: Fixture = undefined;
    try f.init(SseServer.h);
    defer f.deinit();
    try testing.expectError(error.CrossOriginEndpoint, sseConnect(&f, .fromSeconds(5)));
}

test "httpsse: missing endpoint event within the deadline => error" {
    SseServer.reset("");
    var f: Fixture = undefined;
    try f.init(SseServer.h);
    defer f.deinit();
    try testing.expectError(error.EndpointTimeout, sseConnect(&f, .fromMilliseconds(100)));
}

test "httpsse: resolveEndpoint" {
    const gpa = testing.allocator;
    const a = try HttpSseTransport.resolveEndpoint(gpa, "http://127.0.0.1:9/sse", "/messages?sessionId=x");
    defer gpa.free(a);
    try testing.expectEqualStrings("http://127.0.0.1:9/messages?sessionId=x", a);
    const b = try HttpSseTransport.resolveEndpoint(gpa, "http://127.0.0.1:9/a/sse", "msg");
    defer gpa.free(b);
    try testing.expectEqualStrings("http://127.0.0.1:9/a/msg", b);
    try testing.expectError(error.CrossOriginEndpoint, HttpSseTransport.resolveEndpoint(gpa, "http://127.0.0.1:9/sse", "https://127.0.0.1:9/m"));
    try testing.expectError(error.CrossOriginEndpoint, HttpSseTransport.resolveEndpoint(gpa, "http://127.0.0.1:9/sse", "//other:9/m"));
}

test "legacy: reconnect delay is bounded" {
    try testing.expectEqual(@as(u64, 1000), common.reconnectDelayMs(null, 0, 0));
    try testing.expectEqual(@as(u64, 30_000), common.reconnectDelayMs(5000, 10, 0));
    try testing.expect(common.reconnectDelayMs(1000, 1, std.math.maxInt(u64)) >= 1500);
    try testing.expect(common.validSessionId("abc-123"));
    try testing.expect(!common.validSessionId("a b"));
    try testing.expect(!common.validSessionId(""));
}
