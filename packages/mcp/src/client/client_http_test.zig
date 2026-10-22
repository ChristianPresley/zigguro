//! Era detection over HTTP against `FakeHttpServer`: modern Streamable
//! HTTP, legacy Streamable HTTP after a refused `server/discover`, and the
//! HTTP+SSE fallback when Streamable HTTP is refused altogether.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const protocol = @import("../protocol/root.zig");
const Client = @import("Client.zig");
const fake = @import("../testing/fake_http_server.zig");
const FakeHttpServer = fake.FakeHttpServer;

const io = testing.io;

const Fixture = struct {
    rt: zg_core.Runtime,
    env: std.process.Environ.Map,
    http: *zg_net.http.Client,
    srv: FakeHttpServer,
    url_buf: [64]u8 = undefined,
    client: ?*Client = null,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture, handler: fake.Handler) !void {
        f.rt.initTesting();
        f.env = .init(testing.allocator);
        f.arena = .init(testing.allocator);
        f.client = null;
        f.http = try zg_net.http.Client.init(&f.rt, .{ .proxy = .none, .environ_map = &f.env });
        f.srv = .init(testing.allocator, io, handler);
        try f.srv.start();
    }

    fn connect(f: *Fixture) !*Client {
        f.client = try Client.connect(&f.rt, testing.allocator, .{ .http = .{
            .client = f.http,
            .opts = .{ .url = f.srv.url(&f.url_buf, "/mcp") },
        } }, .{ .client_info = .{ .name = "zigguro-test", .version = "0.0.1" } });
        return f.client.?;
    }

    fn deinit(f: *Fixture) void {
        if (f.client) |c| c.close();
        f.srv.deinit();
        f.http.deinit();
        f.env.deinit();
        f.arena.deinit();
        _ = f.rt.deinit();
    }

    fn methodsOf(f: *Fixture, buf: []u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        for (0..f.srv.count()) |i| {
            const r = f.srv.request(i).?;
            if (i > 0) w.writeByte(' ') catch break;
            w.print("{s}:{s}", .{ @tagName(r.method), rpcMethod(r.body) orelse "-" }) catch break;
        }
        return w.buffered();
    }
};

/// The JSON-RPC method of a request body ("resp" for a response).
fn rpcMethod(body: []const u8) ?[]const u8 {
    const key = "\"method\":\"";
    const i = std.mem.indexOf(u8, body, key) orelse return if (body.len > 0) "resp" else null;
    const rest = body[i + key.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse rest.len];
}

/// The id of a request body.
fn idOf(body: []const u8) i64 {
    const key = "\"id\":";
    const i = std.mem.indexOf(u8, body, key) orelse return 0;
    const rest = body[i + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, ",}") orelse rest.len;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch 0;
}

fn result(req: *std.http.Server.Request, id: i64, json: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, json });
    return fake.respondJson(req, .ok, body);
}

const init_result =
    \\{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"legacy","version":"1"}}
;

test "era: http modern 200" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            const m = rpcMethod(rec.body).?;
            if (std.mem.eql(u8, m, "server/discover")) return result(req, idOf(rec.body),
                \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}
            );
            return result(req, idOf(rec.body), "{\"resultType\":\"complete\",\"tools\":[]}");
        }
    }.h);
    defer f.deinit();
    const c = try f.connect();
    try testing.expectEqual(protocol.revision.Era.modern, c.serverInfo().era);
    try testing.expectEqual(.http_modern, c.serverInfo().detection.transport);
    _ = try c.request(.tools_list, .{}, .{ .arena = f.arena.allocator() });
    const discover = f.srv.request(0).?;
    try testing.expectEqualStrings("server/discover", discover.header("mcp-method").?);
    try testing.expectEqualStrings("2026-07-28", discover.header("mcp-protocol-version").?);
    try testing.expectEqualStrings("tools/list", f.srv.request(1).?.header("mcp-method").?);
}

test "era: http 400 empty body => initialize => legacy" {
    var f: Fixture = undefined;
    try f.init(struct {
        fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
            if (rec.method == .GET) return req.respond("", .{ .status = .method_not_allowed });
            if (rec.method == .DELETE) return req.respond("", .{ .status = .ok });
            const m = rpcMethod(rec.body).?;
            if (std.mem.eql(u8, m, "server/discover")) return req.respond("", .{ .status = .bad_request });
            if (std.mem.eql(u8, m, "initialize")) return result(req, idOf(rec.body), init_result);
            if (std.mem.startsWith(u8, m, "notifications/")) return req.respond("", .{ .status = .accepted });
            return result(req, idOf(rec.body), "{\"tools\":[]}");
        }
    }.h);
    defer f.deinit();
    const c = try f.connect();
    try testing.expectEqual(protocol.revision.Era.legacy, c.serverInfo().era);
    try testing.expectEqual(protocol.Revision.v2025_11_25, c.serverInfo().revision);
    try testing.expectEqual(.http_legacy, c.serverInfo().detection.transport);
    _ = try c.request(.tools_list, .{}, .{ .arena = f.arena.allocator() });
    var buf: [512]u8 = undefined;
    const seq = f.methodsOf(&buf);
    try testing.expect(std.mem.startsWith(u8, seq, "POST:server/discover POST:initialize POST:notifications/initialized"));
    try testing.expect(std.mem.indexOf(u8, seq, "POST:tools/list") != null);
    // After initialize every request carries the negotiated version.
    for (0..f.srv.count()) |i| {
        const r = f.srv.request(i).?;
        if (r.method == .POST and std.mem.eql(u8, rpcMethod(r.body).?, "tools/list"))
            try testing.expectEqualStrings("2025-11-25", r.header("mcp-protocol-version").?);
    }
}

const Sse = struct {
    var outbox_buf: [8][]const u8 = undefined;
    var outbox: Io.Queue([]const u8) = undefined;
    var mutex: Io.Mutex = .init;
    var bodies: [8][256]u8 = undefined;
    var next: usize = 0;

    fn push(id: i64, json: []const u8) !void {
        mutex.lockUncancelable(io);
        const slot = &bodies[next % bodies.len];
        next += 1;
        mutex.unlock(io);
        const body = try std.fmt.bufPrint(slot, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, json });
        try outbox.putOne(io, body);
    }

    fn h(_: *FakeHttpServer, req: *std.http.Server.Request, rec: fake.Recorded) !void {
        if (rec.method == .POST and std.mem.startsWith(u8, rec.target, "/messages")) {
            try req.respond("", .{ .status = .accepted });
            const m = rpcMethod(rec.body).?;
            if (std.mem.eql(u8, m, "initialize")) return push(idOf(rec.body),
                \\{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"old","version":"1"}}
            );
            if (!std.mem.startsWith(u8, m, "notifications/")) return push(idOf(rec.body), "{\"tools\":[]}");
            return;
        }
        // Streamable HTTP is refused: 405 for POSTs to the endpoint.
        if (rec.method == .POST) return req.respond("", .{ .status = .method_not_allowed });
        var buf: [512]u8 = undefined;
        var bw = try fake.startSse(req, &buf);
        try bw.writer.writeAll("event: endpoint\ndata: /messages?sid=1\n\n");
        try bw.writer.flush();
        try bw.flush();
        while (true) try fake.sseEvent(&bw, try outbox.getOne(io));
    }
};

test "era: http 405/404 twice => http+sse" {
    Sse.outbox = .init(&Sse.outbox_buf);
    var f: Fixture = undefined;
    try f.init(Sse.h);
    defer f.deinit();
    const c = try f.connect();
    try testing.expectEqual(protocol.revision.Era.legacy, c.serverInfo().era);
    try testing.expectEqual(protocol.Revision.v2024_11_05, c.serverInfo().revision);
    try testing.expectEqual(.http_sse, c.serverInfo().detection.transport);
    const r = try c.request(.tools_list, .{}, .{ .arena = f.arena.allocator() });
    try testing.expectEqual(@as(usize, 0), r.tools.len);
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, f.methodsOf(&buf), "POST:server/discover POST:initialize GET:-"));
}
