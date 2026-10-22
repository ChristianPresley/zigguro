//! Server-side MRTR, progress, logs and cancellation (E11.F05.S01.T02).
//! Input flows run a real `zg_mcp` client with an InputBroker against the
//! server over `InProcPair`; wire details use a recording connection.
//!
//! MRTR "Server Requirements" by test: 1 (input_required only on
//! tools/call, resources/read, prompts/get) "mrtr modern: elicit ->
//! input_required -> retry -> complete" and the client's "input_required
//! on tools/list" row; 2 (declared capabilities only) "missing capability
//! => -32021"; 3 (opaque requestState) and 4 (integrity) "seal: tamper"
//! and "requestState tampered => -32602"; 5 (replay bounds, principal)
//! "seal: expired", "seal: other principal"; 6 (state per request) "seal:
//! AD mismatch"; 7 (round cap) "round cap 8"; 8 (at-most-once) "once".

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zg_core = @import("zg_core");
const protocol = @import("../protocol/root.zig");
const Server = @import("Server.zig");
const Client = @import("../client/Client.zig");
const request = @import("../client/request.zig");
const input = @import("../client/input.zig");
const mrtr = @import("../client/mrtr.zig");
const InProcPair = @import("../transport/in_process.zig");

const io = testing.io;
const gpa = testing.allocator;
const M = protocol.messages;

fn text(cc: *Server.CallCtx, comptime fmt: []const u8, args: anytype) !M.CallToolResult {
    const blocks = try cc.arena.alloc(protocol.ContentBlock, 1);
    blocks[0] = .textBlock(try std.fmt.allocPrint(cc.arena, fmt, args));
    return .{ .content = blocks };
}

const Tools = struct {
    var spins_canceled: std.atomic.Value(bool) = .init(false);

    /// Two rounds: `a`, then `b` with state from the first.
    fn confirm(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
        if (cc.state() == null) cc.setState("s1");
        const a = try cc.elicit("a", .{ .message = "First?" });
        const b = try cc.elicit("b", .{ .message = "Second?" });
        return text(cc, "a={t} b={t} state={s} round={d}", .{ a.action, b.action, cc.state() orelse "-", cc.round });
    }

    /// A new key every round, forever.
    fn endless(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
        var i: u32 = 0;
        while (true) : (i += 1) {
            var buf: [16]u8 = undefined;
            _ = try cc.elicit(try std.fmt.bufPrint(&buf, "k{d}", .{i}), .{ .message = "again?" });
        }
    }

    /// A URL elicitation completed out of band.
    fn login(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
        const id = cc.state() orelse blk: {
            const id = try cc.newElicitationId();
            cc.setState(id);
            break :blk id;
        };
        const r = try cc.elicit("login", .{ .mode = .url, .message = "Sign in", .url = "https://example.com/auth", .elicitation_id = id });
        if (r.action == .accept) cc.completeElicitation(id);
        return text(cc, "{t}", .{r.action});
    }

    fn roots(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
        const rs = try cc.roots("roots");
        return text(cc, "{s}", .{rs[0].uri});
    }

    fn prog(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
        cc.progress(1, 10, null);
        cc.progress(1, 10, null); // Not increasing.
        cc.progress(0.5, 10, null); // Going back.
        cc.progress(2, 10, null); // Within the rate limit.
        try io.sleep(.fromMilliseconds(80), .awake);
        cc.progress(3, 10, null);
        return text(cc, "ok", .{});
    }

    fn logs(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
        cc.log(.info, try protocol.codec.parseValue(cc.arena, "{\"msg\":\"hi\",\"password\":\"hunter2\"}"));
        cc.log(.debug, .{ .string = "too chatty" });
        return text(cc, "ok", .{});
    }

    fn spin(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!M.CallToolResult {
        var i: u32 = 0;
        while (!cc.isCanceled() and i < 2000) : (i += 1) try io.sleep(.fromMilliseconds(2), .awake);
        spins_canceled.store(cc.isCanceled(), .release);
        return text(cc, "late", .{});
    }

    fn once(_: ?*anyopaque, cc: *Server.CallCtx, args: Value) anyerror!M.CallToolResult {
        const nonce = args.object.get("nonce").?.string;
        return text(cc, "{}", .{cc.once(nonce)});
    }
};

fn addTools(s: *Server, a: Allocator) !void {
    const obj = try protocol.codec.parseValue(a, "{\"type\":\"object\"}");
    const list = [_]struct { []const u8, *const fn (?*anyopaque, *Server.CallCtx, Value) anyerror!M.CallToolResult }{
        .{ "confirm", Tools.confirm },
        .{ "endless", Tools.endless },
        .{ "login", Tools.login },
        .{ "roots", Tools.roots },
        .{ "prog", Tools.prog },
        .{ "logs", Tools.logs },
        .{ "spin", Tools.spin },
        .{ "once", Tools.once },
    };
    for (list) |t| try s.addDynamicTool(.{ .def = .{ .name = t[0], .input_schema = obj }, .handler = .{ .ctx = null, .call = t[1] } });
}

const Broker = struct {
    calls: std.atomic.Value(u32) = .init(0),
    mutex: Io.Mutex = .init,
    completed: ?[]u8 = null,
    last_id: ?[]u8 = null,

    fn broker(b: *Broker) input.InputBroker {
        return .{ .ctx = b, .resolve = resolve, .elicitationComplete = complete };
    }

    fn deinit(b: *Broker) void {
        if (b.completed) |c| gpa.free(c);
        if (b.last_id) |c| gpa.free(c);
    }

    fn resolve(ctx: ?*anyopaque, _: input.InputContext, req: input.InputRequest, _: Allocator) anyerror!input.InputResponse {
        const b: *Broker = @ptrCast(@alignCast(ctx.?));
        _ = b.calls.fetchAdd(1, .monotonic);
        return switch (req) {
            .elicitation => |e| blk: {
                if (e.elicitation_id) |id| {
                    b.mutex.lockUncancelable(io);
                    defer b.mutex.unlock(io);
                    if (b.last_id) |c| gpa.free(c);
                    b.last_id = try gpa.dupe(u8, id);
                }
                break :blk .{ .elicitation = .{ .action = .accept } };
            },
            .roots => .{ .roots = .{ .roots = &.{.{ .uri = "file:///work" }} } },
            else => .{ .failed = "no" },
        };
    }

    fn complete(ctx: ?*anyopaque, _: []const u8, id: []const u8) void {
        const b: *Broker = @ptrCast(@alignCast(ctx.?));
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        if (b.completed) |c| gpa.free(c);
        b.completed = gpa.dupe(u8, id) catch null;
    }
};

const Fixture = struct {
    rt: zg_core.Runtime,
    arena: std.heap.ArenaAllocator,
    s: *Server,
    pair: InProcPair,
    conn: *Server.Conn,
    broker: Broker,
    si: input.ServerInput,
    c: *Client,

    fn init(f: *Fixture, revisions: []const protocol.Revision, features: protocol.capabilities.ClientFeatures, sopts: Server.Options) !void {
        f.rt.initTesting();
        f.arena = .init(gpa);
        f.s = try Server.init(gpa, io, sopts);
        try addTools(f.s, f.arena.allocator());
        f.pair = .init(gpa, io);
        f.conn = try f.s.serveInProcess(&f.pair);
        f.broker = .{};
        f.si.init(gpa, io, f.broker.broker(), .{ .server_id = "fx", .min_prompt_interval = .zero });
        f.c = try Client.connect(&f.rt, gpa, .{ .in_process = &f.pair }, .{
            .client_info = .{ .name = "t", .version = "1" },
            .revisions = revisions,
            .features = features,
            .on_server_request = f.si.serverRequestHandler(),
            .on_notification = f.si.notificationHandler(),
        });
        f.si.attach(f.c);
    }

    fn deinit(f: *Fixture) void {
        f.c.close();
        f.conn.close();
        f.pair.deinit();
        f.s.deinit();
        f.si.deinit();
        f.broker.deinit();
        f.arena.deinit();
        _ = f.rt.deinit();
    }

    fn call(f: *Fixture, name: []const u8, o: request.CallOptions) request.RequestError!M.CallToolResult {
        return mrtr.runWithInput(&f.si, .tools_call, .{ .name = name }, o);
    }
};

const info: M.Implementation = .{ .name = "zg-test", .version = "1.0" };

test "mrtr modern: elicit -> input_required -> retry -> complete" {
    var f: Fixture = undefined;
    try f.init(&protocol.revision.supported_newest_first, .{}, .{ .info = info });
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try f.call("confirm", .{ .arena = arena.allocator() });
    // Round 0 asks a, round 1 asks b with the state sealed in round 0.
    try testing.expectEqualStrings("a=accept b=accept state=s1 round=2", r.content[0].text.text);
    try testing.expectEqual(2, f.broker.calls.load(.monotonic));
}

test "mrtr modern: missing capability => -32021" {
    var f: Fixture = undefined;
    try f.init(&protocol.revision.supported_newest_first, .{ .elicitation_form = false, .elicitation_url = false }, .{ .info = info });
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ei: request.ErrorInfo = .{};
    try testing.expectError(error.MissingRequiredClientCapability, f.call("confirm", .{ .arena = arena.allocator(), .error_info = &ei }));
    try testing.expect(ei.required_capabilities.?.has("elicitation.form"));
    try testing.expectEqual(0, f.broker.calls.load(.monotonic));
}

test "mrtr modern: round cap 8" {
    var f: Fixture = undefined;
    try f.init(&protocol.revision.supported_newest_first, .{}, .{ .info = info });
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ei: request.ErrorInfo = .{};
    try testing.expectError(error.ServerError, f.call("endless", .{ .arena = arena.allocator(), .error_info = &ei, .max_input_rounds = 20 }));
    try testing.expectEqual(-32602, ei.code.?);
    try testing.expectEqualStrings("too many input rounds", ei.message);
    try testing.expectEqual(8, f.broker.calls.load(.monotonic));
}

test "mrtr legacy stdio: elicitation/create sent mid-call, completes in one client request" {
    var f: Fixture = undefined;
    try f.init(&.{.v2025_11_25}, .{}, .{ .info = info });
    defer f.deinit();
    try testing.expectEqual(protocol.revision.Era.legacy, f.c.serverInfo().era);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try f.call("confirm", .{ .arena = arena.allocator() });
    // Two server requests, answered in-process: state stays in memory.
    try testing.expectEqualStrings("a=accept b=accept state=s1 round=2", r.content[0].text.text);
    try testing.expectEqual(2, f.broker.calls.load(.monotonic));
    const roots = try f.call("roots", .{ .arena = arena.allocator() });
    try testing.expectEqualStrings("file:///work", roots.content[0].text.text);
}

test "url elicitation legacy: complete notification sent" {
    var f: Fixture = undefined;
    try f.init(&.{.v2025_11_25}, .{}, .{ .info = info });
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try f.call("login", .{ .arena = arena.allocator() });
    try testing.expectEqualStrings("accept", r.content[0].text.text);
    var waited: u32 = 0;
    while (waited < 500) : (waited += 1) {
        f.broker.mutex.lockUncancelable(io);
        const done = f.broker.completed != null;
        f.broker.mutex.unlock(io);
        if (done) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    try testing.expectEqual(36, f.broker.completed.?.len);
    try testing.expectEqualStrings(f.broker.last_id.?, f.broker.completed.?);
}

// ---------------------------------------------------------------- wire

/// Records what the server sends.
const Rec = struct {
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    msgs: std.ArrayList([]const u8) = .empty,

    fn sink(r: *Rec) Server.Sink {
        return .{ .ctx = r, .send = send };
    }

    fn send(ctx: ?*anyopaque, body: []const u8) void {
        const r: *Rec = @ptrCast(@alignCast(ctx.?));
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        const copy = r.arena.allocator().dupe(u8, body) catch return;
        r.msgs.append(r.arena.allocator(), copy) catch return;
    }

    /// Messages containing `needle`.
    fn count(r: *Rec, needle: []const u8) usize {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        var n: usize = 0;
        for (r.msgs.items) |m| n += @intFromBool(std.mem.indexOf(u8, m, needle) != null);
        return n;
    }

    fn find(r: *Rec, needle: []const u8) ?[]const u8 {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        for (r.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return m;
        return null;
    }

    fn waitFor(r: *Rec, needle: []const u8) ![]const u8 {
        var i: u32 = 0;
        while (i < 2000) : (i += 1) {
            if (r.find(needle)) |m| return m;
            try io.sleep(.fromMilliseconds(2), .awake);
        }
        return error.MessageNeverArrived;
    }
};

const Wire = struct {
    s: *Server,
    rec: Rec,
    conn: *Server.Conn,

    fn init(w: *Wire) !void {
        w.s = try Server.init(gpa, io, .{ .info = info });
        w.rec = .{ .arena = .init(gpa) };
        w.conn = try w.s.connect(w.rec.sink(), "alice");
        try addTools(w.s, w.rec.arena.allocator());
    }

    fn deinit(w: *Wire) void {
        w.s.deinit();
        w.rec.arena.deinit();
    }

    fn call(w: *Wire, id: i64, name: []const u8, extra_meta: []const u8, extra: []const u8) void {
        var buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}"{s},"_meta":{{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{{"elicitation":{{}}}}{s}}}}}}}
        , .{ id, name, extra, extra_meta }) catch unreachable;
        w.conn.receive(body);
    }
};

test "mrtr modern: requestState tampered => -32602" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();
    w.call(1, "confirm", "", "");
    const first = try w.rec.waitFor("\"id\":1,");
    try testing.expect(std.mem.indexOf(u8, first, "\"resultType\":\"input_required\"") != null);
    w.call(2, "confirm", "", ",\"requestState\":\"AAAAbogus\",\"inputResponses\":{\"a\":{\"action\":\"accept\"}}");
    const second = try w.rec.waitFor("\"id\":2,");
    try testing.expect(std.mem.indexOf(u8, second, "-32602") != null);
    try testing.expect(std.mem.indexOf(u8, second, "invalid or expired requestState") != null);
    // The real token, replayed with other arguments, is refused too.
    const v = try std.json.parseFromSliceLeaky(Value, w.rec.arena.allocator(), first, .{});
    const token = v.object.get("result").?.object.get("requestState").?.string;
    var buf: [1024]u8 = undefined;
    w.call(3, "confirm", "", try std.fmt.bufPrint(&buf, ",\"arguments\":{{\"x\":1}},\"requestState\":\"{s}\"", .{token}));
    try testing.expect(std.mem.indexOf(u8, try w.rec.waitFor("\"id\":3,"), "invalid or expired requestState") != null);
    // ... and with the same arguments it opens.
    w.call(4, "confirm", "", try std.fmt.bufPrint(&buf, ",\"requestState\":\"{s}\",\"inputResponses\":{{\"a\":{{\"action\":\"accept\"}}}}", .{token}));
    try testing.expect(std.mem.indexOf(u8, try w.rec.waitFor("\"id\":4,"), "\"inputRequests\":{\"b\"") != null);
}

test "progress: only with token; monotonic; rate-limited" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();
    w.call(1, "prog", "", "");
    _ = try w.rec.waitFor("\"id\":1,");
    try testing.expectEqual(0, w.rec.count("notifications/progress"));
    w.call(2, "prog", ",\"progressToken\":\"p\"", "");
    _ = try w.rec.waitFor("\"id\":2,");
    try testing.expectEqual(2, w.rec.count("notifications/progress"));
    try testing.expectEqual(1, w.rec.count("\"progress\":1"));
    try testing.expectEqual(1, w.rec.count("\"progress\":3"));
}

test "log: only with logLevel (modern)" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();
    w.call(1, "logs", "", "");
    _ = try w.rec.waitFor("\"id\":1,");
    try testing.expectEqual(0, w.rec.count("notifications/message"));
    w.call(2, "logs", ",\"io.modelcontextprotocol/logLevel\":\"info\"", "");
    _ = try w.rec.waitFor("\"id\":2,");
    try testing.expectEqual(1, w.rec.count("notifications/message"));
    const m = w.rec.find("notifications/message").?;
    try testing.expect(std.mem.indexOf(u8, m, "[redacted]") != null);
    try testing.expect(std.mem.indexOf(u8, m, "hunter2") == null);
}

test "cancel: stdio notification cancels handler; http disconnect cancels handler" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();
    Tools.spins_canceled.store(false, .release);
    w.call(1, "spin", "", "");
    try io.sleep(.fromMilliseconds(20), .awake);
    w.conn.receive("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}");
    var i: u32 = 0;
    while (!Tools.spins_canceled.load(.acquire) and i < 1000) : (i += 1) try io.sleep(.fromMilliseconds(2), .awake);
    try testing.expect(Tools.spins_canceled.load(.acquire));
    try io.sleep(.fromMilliseconds(20), .awake);
    // Nothing is sent for a canceled request.
    try testing.expectEqual(0, w.rec.count("\"id\":1,"));

    // A transport going away (HTTP disconnect) closes the connection.
    Tools.spins_canceled.store(false, .release);
    w.call(2, "spin", "", "");
    try io.sleep(.fromMilliseconds(20), .awake);
    w.conn.close();
    i = 0;
    while (!Tools.spins_canceled.load(.acquire) and i < 1000) : (i += 1) try io.sleep(.fromMilliseconds(2), .awake);
    try testing.expect(Tools.spins_canceled.load(.acquire));
}

test "once: a nonce is consumed once" {
    var w: Wire = undefined;
    try w.init();
    defer w.deinit();
    w.call(1, "once", "", ",\"arguments\":{\"nonce\":\"n1\"}");
    try testing.expect(std.mem.indexOf(u8, try w.rec.waitFor("\"id\":1,"), "true") != null);
    w.call(2, "once", "", ",\"arguments\":{\"nonce\":\"n1\"}");
    try testing.expect(std.mem.indexOf(u8, try w.rec.waitFor("\"id\":2,"), "false") != null);
}
