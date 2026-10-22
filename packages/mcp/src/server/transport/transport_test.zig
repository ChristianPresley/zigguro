//! Server transports (E11.F05.S02.T01): stdio over in-memory streams, HTTP
//! over loopback with a raw socket client (for exact headers) and with the
//! zg_mcp client in both eras.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const protocol = @import("../../protocol/root.zig");
const Server = @import("../Server.zig");
const Client = @import("../../client/Client.zig");
const input = @import("../../client/input.zig");
const mrtr = @import("../../client/mrtr.zig");
const stdio = @import("stdio.zig");
const http = @import("http.zig");

const io = testing.io;
const gpa = testing.allocator;
const M = protocol.messages;

const info: M.Implementation = .{ .name = "zg-test", .version = "1.0" };

var spin_canceled: std.atomic.Value(bool) = .init(false);

fn text(cc: *Server.CallCtx, comptime fmt: []const u8, args: anytype) !M.CallToolResult {
    const blocks = try cc.arena.alloc(protocol.ContentBlock, 1);
    blocks[0] = .textBlock(try std.fmt.allocPrint(cc.arena, fmt, args));
    return .{ .content = blocks };
}

fn echo(_: ?*anyopaque, cc: *Server.CallCtx, args: Value) anyerror!M.CallToolResult {
    const t = if (args == .object) (if (args.object.get("text")) |x| x.string else "") else "";
    return text(cc, "echo: {s}", .{t});
}

fn spin(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
    var i: u32 = 0;
    while (!cc.isCanceled() and i < 2500) : (i += 1) try io.sleep(.fromMilliseconds(2), .awake);
    spin_canceled.store(cc.isCanceled(), .release);
    return text(cc, "late", .{});
}

fn ask(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
    const r = try cc.elicit("ok", .{ .message = "Proceed?" });
    return text(cc, "{t}", .{r.action});
}

fn newServer(a: Allocator) !*Server {
    const s = try Server.init(gpa, io, .{ .info = info });
    errdefer s.deinit();
    const parse = protocol.codec.parseValue;
    try s.addDynamicTool(.{ .def = .{
        .name = "echo",
        .input_schema = try parse(a, "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"},\"count\":{\"type\":\"integer\",\"x-mcp-header\":\"Count\"}}}"),
    }, .handler = .{ .ctx = null, .call = echo } });
    try s.addDynamicTool(.{ .def = .{ .name = "spin", .input_schema = try parse(a, "{\"type\":\"object\"}") }, .handler = .{ .ctx = null, .call = spin } });
    try s.addDynamicTool(.{ .def = .{ .name = "ask", .input_schema = try parse(a, "{\"type\":\"object\"}") }, .handler = .{ .ctx = null, .call = ask } });
    return s;
}

// ---------------------------------------------------------------- stdio

const Capture = struct {
    mutex: Io.Mutex = .init,
    aw: Io.Writer.Allocating,

    fn send(ctx: ?*anyopaque, body: []const u8) void {
        const c: *Capture = @ptrCast(@alignCast(ctx.?));
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.aw.writer.writeAll(body) catch {};
        c.aw.writer.writeByte('\n') catch {};
    }
};

test "stdio server: only MCP bytes on stdout; exits on stdin EOF" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = try newServer(arena.allocator());
    defer s.deinit();
    var in: Io.Reader = .fixed(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
        \\
    );
    var cap: Capture = .{ .aw = .init(gpa) };
    defer cap.aw.deinit();
    // Returns at EOF, after the running call finished.
    try stdio.serveStream(s, &in, .{ .ctx = &cap, .send = Capture.send }, .fromSeconds(2));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cap.aw.written(), "\n"), '\n');
    var ids: [3]bool = @splat(false);
    while (lines.next()) |line| {
        const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(), line, .{});
        try testing.expectEqualStrings("2.0", v.object.get("jsonrpc").?.string);
        const id = v.object.get("id").?.integer;
        ids[@intCast(id - 1)] = true;
    }
    try testing.expect(ids[0] and ids[1] and ids[2]);
    try testing.expect(std.mem.indexOf(u8, cap.aw.written(), "echo: hi") != null);
}

// ---------------------------------------------------------------- http (raw)

const Resp = struct {
    status: u16,
    head: []const u8,
    body: []const u8,

    fn header(r: Resp, name: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, r.head, "\r\n");
        _ = it.next();
        while (it.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }
};

/// A raw HTTP/1.1 client: exact headers, partial bodies, hang-ups.
const Raw = struct {
    stream: Io.net.Stream,
    rbuf: [64 * 1024]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    got: std.ArrayList(u8) = .empty,

    fn open(port: u16) !*Raw {
        const r = try gpa.create(Raw);
        errdefer gpa.destroy(r);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        r.* = .{ .stream = try addr.connect(io, .{ .mode = .stream }) };
        r.reader = r.stream.reader(io, &r.rbuf);
        return r;
    }

    fn close(r: *Raw) void {
        r.stream.close(io);
        r.got.deinit(gpa);
        gpa.destroy(r);
    }

    fn send(r: *Raw, bytes: []const u8) !void {
        var wbuf: [256]u8 = undefined;
        var w = r.stream.writer(io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
    }

    fn more(r: *Raw) !void {
        const in = &r.reader.interface;
        in.fillMore() catch |err| switch (err) {
            error.EndOfStream => return error.ConnectionClosed,
            else => return err,
        };
        try r.got.appendSlice(gpa, in.buffered());
        in.toss(in.buffered().len);
    }

    /// Reads until `needle` arrived.
    fn until(r: *Raw, needle: []const u8) ![]const u8 {
        while (std.mem.indexOf(u8, r.got.items, needle) == null) try r.more();
        return r.got.items;
    }

    /// Reads one response with a Content-Length body.
    fn response(r: *Raw, a: Allocator) !Resp {
        _ = try r.until("\r\n\r\n");
        const end = std.mem.indexOf(u8, r.got.items, "\r\n\r\n").? + 4;
        const head = try a.dupe(u8, r.got.items[0..end]);
        var resp: Resp = .{ .status = try std.fmt.parseInt(u16, head[9..12], 10), .head = head, .body = "" };
        const len = if (resp.header("content-length")) |l| try std.fmt.parseInt(usize, l, 10) else 0;
        while (r.got.items.len < end + len) try r.more();
        resp.body = try a.dupe(u8, r.got.items[end .. end + len]);
        const rest = r.got.items.len - (end + len);
        std.mem.copyForwards(u8, r.got.items[0..rest], r.got.items[end + len ..]);
        r.got.shrinkRetainingCapacity(rest);
        return resp;
    }
};

const pv_meta = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"elicitation\":{}}";

const HttpFx = struct {
    arena: std.heap.ArenaAllocator,
    s: *Server,
    l: *http.HttpListener,

    fn init(f: *HttpFx, opts: http.HttpServerOptions) !void {
        f.arena = .init(gpa);
        f.s = try newServer(f.arena.allocator());
        f.l = try http.listenHttp(f.s, opts);
    }

    fn deinit(f: *HttpFx) void {
        f.l.deinit();
        f.s.deinit();
        f.arena.deinit();
    }

    fn a(f: *HttpFx) Allocator {
        return f.arena.allocator();
    }

    /// A full request with Host and the given extra header lines.
    fn req(f: *HttpFx, method: []const u8, extra: []const u8, body: []const u8) ![]const u8 {
        return std.fmt.allocPrint(f.a(), "{s} /mcp HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: {d}\r\n{s}\r\n{s}", .{ method, f.l.port, body.len, extra, body });
    }

    /// Sends one request on a fresh connection and reads the response.
    fn roundTrip(f: *HttpFx, method: []const u8, extra: []const u8, body: []const u8) !Resp {
        const r = try Raw.open(f.l.port);
        defer r.close();
        try r.send(try f.req(method, extra, body));
        return r.response(f.a());
    }

    /// A modern tools/call with consistent headers plus `extra`.
    fn call(f: *HttpFx, id: u32, name_header: []const u8, args: []const u8, extra: []const u8) !Resp {
        const body = try std.fmt.allocPrint(f.a(), "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"echo\",\"arguments\":{s},{s}}}}}}}", .{ id, args, pv_meta });
        const hdrs = try std.fmt.allocPrint(f.a(), "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\nMcp-Name: {s}\r\n{s}", .{ name_header, extra });
        return f.roundTrip("POST", hdrs, body);
    }
};

test "http server: Host check" {
    var f: HttpFx = undefined;
    try f.init(.{});
    defer f.deinit();
    const r = try Raw.open(f.l.port);
    defer r.close();
    try r.send("POST /mcp HTTP/1.1\r\nHost: evil.example\r\nContent-Length: 2\r\n\r\n{}");
    const resp = try r.response(f.a());
    try testing.expectEqual(403, resp.status);
}

test "http server: Origin 403 with json error (body never read)" {
    var f: HttpFx = undefined;
    try f.init(.{ .allowed_origins = &.{"vscode-webview://ok"} });
    defer f.deinit();
    const r = try Raw.open(f.l.port);
    defer r.close();
    // Announces 100 MB but sends none of it: the answer comes anyway.
    try r.send(try std.fmt.allocPrint(f.a(), "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nOrigin: https://evil.example\r\nContent-Length: 104857600\r\n\r\n", .{f.l.port}));
    const resp = try r.response(f.a());
    try testing.expectEqual(403, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":null") != null);
    // An allowed origin passes.
    const ok = try f.call(1, "echo", "{}", "Origin: vscode-webview://ok\r\n");
    try testing.expectEqual(200, ok.status);
}

test "http server: bearer 401" {
    const tok: [32]u8 = @splat(0x5a);
    var f: HttpFx = undefined;
    try f.init(.{ .bearer_token = tok });
    defer f.deinit();
    const no = try f.call(1, "echo", "{}", "");
    try testing.expectEqual(401, no.status);
    try testing.expectEqualStrings("Bearer realm=\"zigguro\"", no.header("www-authenticate").?);
    const bad = try f.call(2, "echo", "{}", "Authorization: Bearer " ++ "00" ** 32 ++ "\r\n");
    try testing.expectEqual(401, bad.status);
    const good = try f.call(3, "echo", "{}", "Authorization: Bearer " ++ "5a" ** 32 ++ "\r\n");
    try testing.expectEqual(200, good.status);
}

test "http server: header mismatch -32020" {
    var f: HttpFx = undefined;
    try f.init(.{});
    defer f.deinit();
    const wrong_name = try f.call(1, "other", "{}", "");
    try testing.expectEqual(400, wrong_name.status);
    try testing.expect(std.mem.indexOf(u8, wrong_name.body, "-32020") != null);
    // Mcp-Method and the protocol version.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{" ++ pv_meta ++ "}}}";
    const wrong_method = try f.roundTrip("POST", "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\n", body);
    try testing.expect(std.mem.indexOf(u8, wrong_method.body, "-32020") != null);
    const wrong_pv = try f.roundTrip("POST", "MCP-Protocol-Version: 2025-11-25\r\nMcp-Method: tools/list\r\n", body);
    try testing.expect(std.mem.indexOf(u8, wrong_pv.body, "-32020") != null);
    const right = try f.roundTrip("POST", "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/list\r\n", body);
    try testing.expectEqual(200, right.status);
    // Mcp-Param: integers compare by value.
    const equal = try f.call(3, "echo", "{\"count\":42.0}", "Mcp-Param-Count: 42\r\n");
    try testing.expectEqual(200, equal.status);
    const differ = try f.call(4, "echo", "{\"count\":42}", "Mcp-Param-Count: 43\r\n");
    try testing.expect(std.mem.indexOf(u8, differ.body, "-32020") != null);
    const missing = try f.call(5, "echo", "{\"count\":42}", "");
    try testing.expect(std.mem.indexOf(u8, missing.body, "-32020") != null);
}

test "http server: base64 sentinel decode" {
    var f: HttpFx = undefined;
    try f.init(.{});
    defer f.deinit();
    // "echo" as a base64 sentinel.
    const r = try f.call(1, "=?base64?ZWNobw==?=", "{\"text\":\"b64\"}", "");
    try testing.expectEqual(200, r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "echo: b64") != null);
    try testing.expectEqualStrings("application/json", r.header("content-type").?);
}

test "http server: notification 202" {
    var f: HttpFx = undefined;
    try f.init(.{});
    defer f.deinit();
    const r = try f.roundTrip("POST", "", "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}");
    try testing.expectEqual(202, r.status);
}

test "http server: SSE when progressToken; disconnect cancels handler" {
    var f: HttpFx = undefined;
    try f.init(.{ .keepalive_interval = .fromMilliseconds(20) });
    defer f.deinit();
    spin_canceled.store(false, .release);
    const r = try Raw.open(f.l.port);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"spin\"," ++ pv_meta ++ ",\"progressToken\":\"p\"}}}";
    try r.send(try f.req("POST", "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/call\r\nMcp-Name: spin\r\n", body));
    const head = try r.until("\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, head, "text/event-stream") != null);
    try testing.expect(std.mem.indexOf(u8, head, "x-accel-buffering: no") != null);
    r.close();
    var i: u32 = 0;
    while (!spin_canceled.load(.acquire) and i < 2000) : (i += 1) try io.sleep(.fromMilliseconds(2), .awake);
    try testing.expect(spin_canceled.load(.acquire));
}

test "http server: modern GET/DELETE 405" {
    var f: HttpFx = undefined;
    try f.init(.{});
    defer f.deinit();
    try testing.expectEqual(405, (try f.roundTrip("GET", "", "")).status);
    try testing.expectEqual(405, (try f.roundTrip("DELETE", "", "")).status);
    try testing.expectEqual(405, (try f.roundTrip("PUT", "", "")).status);
}

fn legacyInit(f: *HttpFx) ![]const u8 {
    const r = try f.roundTrip("POST", "",
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
    );
    try testing.expectEqual(200, r.status);
    const sid = try f.a().dupe(u8, r.header("mcp-session-id").?);
    try testing.expectEqual(32, sid.len);
    for (sid) |c| try testing.expect(std.ascii.isPrint(c));
    const hdr = try std.fmt.allocPrint(f.a(), "Mcp-Session-Id: {s}\r\nMCP-Protocol-Version: 2025-11-25\r\n", .{sid});
    try testing.expectEqual(202, (try f.roundTrip("POST", hdr, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")).status);
    return hdr;
}

test "http server: legacy initialize mints session; 400 without; 404 after DELETE" {
    var f: HttpFx = undefined;
    try f.init(.{});
    defer f.deinit();
    const hdr = try legacyInit(&f);
    const list = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}";
    const ok = try f.roundTrip("POST", hdr, list);
    try testing.expectEqual(200, ok.status);
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"echo\"") != null);
    try testing.expectEqual(400, (try f.roundTrip("POST", "", list)).status);
    try testing.expectEqual(404, (try f.roundTrip("POST", "Mcp-Session-Id: x\r\n", list)).status);
    try testing.expectEqual(200, (try f.roundTrip("DELETE", hdr, "")).status);
    try testing.expectEqual(404, (try f.roundTrip("POST", hdr, list)).status);
}

test "http server: legacy GET stream gets list_changed; keepalive comments" {
    var f: HttpFx = undefined;
    try f.init(.{ .keepalive_interval = .fromMilliseconds(20) });
    defer f.deinit();
    const hdr = try legacyInit(&f);
    const r = try Raw.open(f.l.port);
    defer r.close();
    try r.send(try std.fmt.allocPrint(f.a(), "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept: text/event-stream\r\n{s}\r\n", .{ f.l.port, hdr }));
    _ = try r.until("text/event-stream");
    _ = try r.until(": keepalive");
    try f.s.addDynamicTool(.{ .def = .{ .name = "late", .input_schema = try protocol.codec.parseValue(f.a(), "{\"type\":\"object\"}") }, .handler = .{ .ctx = null, .call = echo } });
    _ = try r.until("notifications/tools/list_changed");
}

// ---------------------------------------------------------------- http (client)

const Broker = struct {
    calls: std.atomic.Value(u32) = .init(0),

    fn resolve(ctx: ?*anyopaque, _: input.InputContext, _: input.InputRequest, _: Allocator) anyerror!input.InputResponse {
        const b: *Broker = @ptrCast(@alignCast(ctx.?));
        _ = b.calls.fetchAdd(1, .monotonic);
        return .{ .elicitation = .{ .action = .accept } };
    }
};

fn clientRoundTrip(revisions: []const protocol.Revision, want_era: protocol.revision.Era) !void {
    var f: HttpFx = undefined;
    try f.init(.{});
    defer f.deinit();
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    const hc = try zg_net.http.Client.init(&rt, .{ .proxy = .none, .environ_map = &env });
    defer hc.deinit();
    var broker: Broker = .{};
    var si: input.ServerInput = undefined;
    si.init(gpa, io, .{ .ctx = &broker, .resolve = Broker.resolve }, .{ .server_id = "http", .min_prompt_interval = .zero });
    defer si.deinit();
    var ubuf: [64]u8 = undefined;
    const c = try Client.connect(&rt, gpa, .{ .http = .{ .client = hc, .opts = .{ .url = f.l.url(&ubuf) } } }, .{
        .client_info = .{ .name = "t", .version = "1" },
        .revisions = revisions,
        .on_server_request = si.serverRequestHandler(),
        .on_notification = si.notificationHandler(),
    });
    defer c.close();
    si.attach(c);
    try testing.expectEqual(want_era, c.serverInfo().era);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try mrtr.runWithInput(&si, .tools_call, .{ .name = "echo", .arguments = try protocol.codec.parseValue(arena.allocator(), "{\"text\":\"over http\"}") }, .{ .arena = arena.allocator() });
    try testing.expectEqualStrings("echo: over http", r.content[0].text.text);
    // Input: MRTR (modern) or a server request on the POST stream (legacy).
    const q = try mrtr.runWithInput(&si, .tools_call, .{ .name = "ask" }, .{ .arena = arena.allocator() });
    try testing.expectEqualStrings("accept", q.content[0].text.text);
    try testing.expectEqual(1, broker.calls.load(.monotonic));
}

test "http server: zg_mcp client, modern era" {
    try clientRoundTrip(&protocol.revision.supported_newest_first, .modern);
}

test "http server: zg_mcp client, legacy session" {
    try clientRoundTrip(&.{.v2025_11_25}, .legacy);
}
