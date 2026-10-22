//! Client core tests over the in-process transport and `MockServer`. The
//! stdio and in-process transports share one detection path
//! (`detectStream`), so the `era: stdio ...` rows run here; the real-pipe
//! row is in `test/stdio_test.zig` and the HTTP rows in
//! `client_http_test.zig`.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const zg_core = @import("zg_core");
const protocol = @import("../protocol/root.zig");
const Client = @import("Client.zig");
const request = @import("request.zig");
const mock = @import("../testing/mock_server.zig");

const io = testing.io;
const meta_keys = protocol.meta_keys;

const Fixture = struct {
    rt: zg_core.Runtime,
    srv: mock.MockServer,
    client: ?*Client = null,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture, mode: mock.Mode) void {
        f.* = .{ .rt = undefined, .srv = undefined, .arena = .init(testing.allocator) };
        f.rt.initTesting();
        f.srv.init(testing.allocator, io, mode);
    }

    fn connect(f: *Fixture, opts: Client.Options) Client.ConnectError!*Client {
        var o = opts;
        o.client_info = .{ .name = "zigguro-test", .version = "0.0.1" };
        f.client = try Client.connect(&f.rt, testing.allocator, .{ .in_process = &f.srv.pair }, o);
        return f.client.?;
    }

    fn deinit(f: *Fixture) void {
        if (f.client) |c| c.close();
        f.srv.deinit();
        f.arena.deinit();
        _ = f.rt.deinit();
    }

    fn callOpts(f: *Fixture) request.CallOptions {
        return .{ .arena = f.arena.allocator() };
    }
};

const base: Client.Options = .{ .client_info = .{ .name = "", .version = "" } };

test "era: stdio modern discover" {
    var f: Fixture = undefined;
    f.init(.modern);
    defer f.deinit();
    const c = try f.connect(base);
    const info = c.serverInfo();
    try testing.expectEqual(protocol.revision.Era.modern, info.era);
    try testing.expectEqual(protocol.Revision.v2026_07_28, info.revision);
    try testing.expect(info.capabilities.has("tools.listChanged"));
    try testing.expectEqualStrings("mock", info.server_info.?.name);
    try testing.expectEqualStrings("be nice", info.instructions.?);
    try testing.expectEqual(@as(usize, 0), f.srv.count("initialize"));
    try testing.expectEqual(@import("../transport/Transport.zig").Kind.in_process, info.detection.transport);
}

test "era: stdio legacy -32601 => initialize" {
    var f: Fixture = undefined;
    f.init(.legacy);
    defer f.deinit();
    const c = try f.connect(base);
    try testing.expectEqual(protocol.revision.Era.legacy, c.serverInfo().era);
    try testing.expectEqual(protocol.Revision.v2025_11_25, c.serverInfo().revision);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("server/discover initialize notifications/initialized", f.srv.methods(&buf));
    // Legacy capability shape for 2025-11-25.
    const init_body = f.srv.find("initialize", 0).?.body;
    try testing.expect(std.mem.indexOf(u8, init_body, "\"roots\":{\"listChanged\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, init_body, "\"elicitation\":{\"form\":{},\"url\":{}}") != null);
    try testing.expect(std.mem.indexOf(u8, init_body, "\"tasks\":{\"requests\":{\"sampling\":{\"createMessage\":{}},\"elicitation\":{\"create\":{}}}}") != null);
    try testing.expect(std.mem.indexOf(u8, init_body, meta_keys.protocol_version) == null);
    // Requests after initialize carry no modern _meta.
    _ = try c.request(.tools_list, .{}, f.callOpts());
    const list_body = f.srv.find("tools/list", 0).?.body;
    try testing.expect(std.mem.indexOf(u8, list_body, meta_keys.client_capabilities) == null);
    try testing.expectEqual(@as(u32, 0), f.srv.violations);
}

test "era: stdio silent => timeout => initialize" {
    var f: Fixture = undefined;
    f.init(.silent_discover);
    defer f.deinit();
    var o = base;
    o.discover_timeout = .fromMilliseconds(100);
    const c = try f.connect(o);
    try testing.expectEqual(protocol.revision.Era.legacy, c.serverInfo().era);
    try testing.expectEqualStrings("server/discover went unanswered", c.serverInfo().detection.reason);
    // The unanswered probe was cancelled.
    try testing.expectEqual(@as(usize, 1), f.srv.count("notifications/cancelled"));
    try testing.expectEqual(@as(u32, 0), f.srv.violations);
}

test "era: stdio -32022 supported=[2025-11-25] => legacy initialize 2025-11-25" {
    var f: Fixture = undefined;
    f.init(.version_error);
    defer f.deinit();
    const c = try f.connect(base);
    try testing.expectEqual(protocol.Revision.v2025_11_25, c.serverInfo().revision);
    try testing.expect(std.mem.indexOf(u8, f.srv.find("initialize", 0).?.body, "\"protocolVersion\":\"2025-11-25\"") != null);
}

test "era: legacy server answering an older revision" {
    var f: Fixture = undefined;
    f.init(.legacy);
    defer f.deinit();
    f.srv.legacy_version = "2025-03-26";
    const c = try f.connect(base);
    try testing.expectEqual(protocol.Revision.v2025_03_26, c.serverInfo().revision);
    // A revision we do not implement: disconnect (L1125).
    var g: Fixture = undefined;
    g.init(.legacy);
    defer g.deinit();
    g.srv.legacy_version = "1999-01-01";
    try testing.expectError(error.UnsupportedRevision, g.connect(base));
}

test "era: cached hint skips probe" {
    var f: Fixture = undefined;
    f.init(.legacy);
    defer f.deinit();
    var o = base;
    o.era_hint = .{ .era = .legacy, .revision = .v2025_11_25, .transport = .stdio, .reason = "" };
    const c = try f.connect(o);
    try testing.expectEqual(protocol.revision.Era.legacy, c.serverInfo().era);
    try testing.expectEqual(@as(usize, 0), f.srv.count("server/discover"));

    // A wrong hint falls back to detection.
    var g: Fixture = undefined;
    g.init(.modern);
    defer g.deinit();
    const d = try g.connect(o);
    try testing.expectEqual(protocol.revision.Era.modern, d.serverInfo().era);
}

test "meta: required keys on every modern request" {
    var f: Fixture = undefined;
    f.init(.modern);
    defer f.deinit();
    const c = try f.connect(base);
    _ = try c.request(.tools_list, .{}, f.callOpts());
    _ = try c.request(.tools_call, .{ .name = "echo" }, f.callOpts());
    for ([_][]const u8{ "server/discover", "tools/list", "tools/call" }) |m| {
        const body = f.srv.find(m, 0).?.body;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(), body, .{});
        const meta = v.object.get("params").?.object.get("_meta").?.object;
        try testing.expectEqualStrings("2026-07-28", meta.get(meta_keys.protocol_version).?.string);
        try testing.expect(meta.get(meta_keys.client_capabilities).?.object.get("elicitation") != null);
        try testing.expectEqualStrings("zigguro-test", meta.get(meta_keys.client_info).?.object.get("name").?.string);
    }
}

test "meta: caller _meta preserved" {
    var f: Fixture = undefined;
    f.init(.modern);
    defer f.deinit();
    var o = base;
    o.send_client_info = false;
    const c = try f.connect(o);
    const caller = try protocol.codec.decodeBytes(protocol.RequestMeta, f.arena.allocator(), "{\"com.example/trace\":\"t1\"}", .{});
    _ = try c.request(.tools_list, .{ .meta = caller }, f.callOpts());
    const body = f.srv.find("tools/list", 0).?.body;
    try testing.expect(std.mem.indexOf(u8, body, "\"com.example/trace\":\"t1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, meta_keys.protocol_version) != null);
    try testing.expect(std.mem.indexOf(u8, body, meta_keys.client_info) == null); // Privacy setting.
    const reserved = try protocol.codec.decodeBytes(protocol.RequestMeta, f.arena.allocator(), "{\"io.modelcontextprotocol/x\":1}", .{});
    try testing.expectError(error.ReservedMetaKey, c.request(.tools_list, .{ .meta = reserved }, f.callOpts()));
}

test "timeout: progress resets, max cap enforced" {
    var f: Fixture = undefined;
    f.init(.modern);
    defer f.deinit();
    const c = try f.connect(base);
    const Counter = struct {
        n: std.atomic.Value(u32) = .init(0),
        fn on(ctx: ?*anyopaque, _: protocol.messages.Progress) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = s.n.fetchAdd(1, .monotonic);
        }
    };
    var counter: Counter = .{};
    var o = f.callOpts();
    o.timeout = .fromMilliseconds(80);
    o.max_timeout = .fromMilliseconds(300);
    o.on_progress = .{ .ctx = &counter, .func = Counter.on };
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    try testing.expectError(error.Timeout, c.request(.tools_call, .{ .name = "progress" }, o));
    const ms = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
    // Progress every 20 ms kept the 80 ms timeout alive until the 300 ms cap.
    try testing.expect(ms >= 300 and ms < 3000);
    try testing.expect(counter.n.load(.monotonic) >= 5);
    try testing.expectEqual(@as(usize, 1), f.srv.count("notifications/cancelled"));

    // Without progress the soft timeout applies.
    o.on_progress = null;
    o.timeout = .fromMilliseconds(50);
    const t1 = Io.Clock.Timestamp.now(io, .awake);
    try testing.expectError(error.Timeout, c.request(.tools_call, .{ .name = "hang" }, o));
    try testing.expect(t1.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds() < 300);
}

test "cancel: stdio sends notifications/cancelled" {
    var f: Fixture = undefined;
    f.init(.legacy);
    defer f.deinit();
    const c = try f.connect(base);
    var tok: request.CancelToken = .init(io);
    const Canceler = struct {
        fn run(t: *request.CancelToken) Io.Cancelable!void {
            try io.sleep(.fromMilliseconds(30), .awake);
            t.cancel("user pressed stop");
        }
    };
    var fut = try io.concurrent(Canceler.run, .{&tok});
    defer fut.cancel(io) catch {};
    var o = f.callOpts();
    o.cancel = &tok;
    try testing.expectError(error.Canceled, c.request(.tools_call, .{ .name = "hang" }, o));
    const n = f.srv.find("notifications/cancelled", 0).?.body;
    const call_id = f.srv.find("tools/call", 0).?.id.?;
    var want: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, n, try std.fmt.bufPrint(&want, "\"requestId\":{d}", .{call_id})) != null);
    try testing.expect(std.mem.indexOf(u8, n, "user pressed stop") != null);
    // A canceled token fails later requests at once.
    try testing.expectError(error.Canceled, c.request(.tools_call, .{ .name = "echo" }, o));
}

test "legacy: ping auto-answered" {
    var f: Fixture = undefined;
    f.init(.legacy);
    defer f.deinit();
    f.srv.ping_first = true;
    const c = try f.connect(base);
    const r = try c.request(.tools_list, .{}, f.callOpts());
    try testing.expectEqual(@as(usize, 0), r.tools.len);
    try testing.expect(f.srv.ping_answered);
    try testing.expect(std.mem.indexOf(u8, f.srv.find("(response)", 0).?.body, "\"id\":\"srv-ping\",\"result\":{}") != null);
}

test "legacy: session_expired => reinitialize" {
    var f: Fixture = undefined;
    f.init(.legacy);
    defer f.deinit();
    const Resets = struct {
        n: u32 = 0,
        fn on(ctx: ?*anyopaque, _: *Client) void {
            const s: *@This() = @ptrCast(@alignCast(ctx.?));
            s.n += 1;
        }
    };
    var resets: Resets = .{};
    var o = base;
    o.on_session_reset = .{ .ctx = &resets, .func = Resets.on };
    const c = try f.connect(o);
    f.srv.fail_next = .{ .method = "tools/list", .err = .session_expired };
    _ = try c.request(.tools_list, .{}, f.callOpts());
    try testing.expectEqual(@as(usize, 2), f.srv.count("initialize"));
    try testing.expectEqual(@as(usize, 2), f.srv.count("tools/list"));
    try testing.expectEqual(@as(u32, 1), resets.n);
    // A tool call is never replayed.
    f.srv.fail_next = .{ .method = "tools/call", .err = .session_expired };
    try testing.expectError(error.SessionExpired, c.request(.tools_call, .{ .name = "echo" }, f.callOpts()));
    try testing.expectEqual(@as(usize, 3), f.srv.count("initialize"));
    try testing.expectEqual(@as(usize, 1), f.srv.count("tools/call"));
    try testing.expectEqual(@as(u32, 0), f.srv.violations);
}

test "broken stream: list re-issued with new id; tools/call not re-issued" {
    var f: Fixture = undefined;
    f.init(.modern);
    defer f.deinit();
    const c = try f.connect(base);
    f.srv.fail_next = .{ .method = "tools/list", .err = .stream_broken };
    _ = try c.request(.tools_list, .{}, f.callOpts());
    try testing.expectEqual(@as(usize, 2), f.srv.count("tools/list"));
    try testing.expect(f.srv.find("tools/list", 0).?.id.? != f.srv.find("tools/list", 1).?.id.?);
    f.srv.fail_next = .{ .method = "tools/call", .err = .stream_broken };
    try testing.expectError(error.ConnectionClosed, c.request(.tools_call, .{ .name = "echo" }, f.callOpts()));
    try testing.expectEqual(@as(usize, 1), f.srv.count("tools/call"));
}

test "client: -32021 carries the required capabilities" {
    var f: Fixture = undefined;
    f.init(.modern);
    defer f.deinit();
    const c = try f.connect(base);
    var info: request.ErrorInfo = .{};
    var o = f.callOpts();
    o.error_info = &info;
    try testing.expectError(error.MissingRequiredClientCapability, c.request(.tools_call, .{ .name = "needcap" }, o));
    try testing.expect(info.required_capabilities.?.has("elicitation.form"));
    try testing.expectError(error.ServerError, c.request(.tools_call, .{ .name = "nope" }, o));
    try testing.expectEqual(@as(?i64, -32602), info.code);
}

test "client: MRTR input rounds" {
    var f: Fixture = undefined;
    f.init(.modern);
    defer f.deinit();
    const c = try f.connect(base);
    try testing.expectError(error.InputDeclined, c.request(.tools_call, .{ .name = "ask" }, f.callOpts()));
    const Roots = struct {
        fn answer(_: ?*anyopaque, arena: std.mem.Allocator, reqs: protocol.messages.InputRequests) anyerror!?protocol.messages.InputResponses {
            try testing.expect(reqs.get("r1").? == .roots);
            return try protocol.codec.decodeBytes(protocol.messages.InputResponses, arena, "{\"r1\":{\"roots\":[]}}", .{});
        }
    };
    var o = f.callOpts();
    o.input = .{ .ctx = null, .func = Roots.answer };
    const r = try c.request(.tools_call, .{ .name = "ask" }, o);
    try testing.expectEqualStrings("thanks", r.content[0].text.text);
    const retry = f.srv.find("tools/call", 2).?.body;
    try testing.expect(std.mem.indexOf(u8, retry, "\"requestState\":\"s1\"") != null);
    try testing.expect(std.mem.indexOf(u8, retry, "\"inputResponses\":{\"r1\":{\"roots\":[]}}") != null);
}

test "client: methods outside the negotiated revision are refused" {
    var f: Fixture = undefined;
    f.init(.modern);
    defer f.deinit();
    const c = try f.connect(base);
    // ping and logging/setLevel do not exist in 2026-07-28.
    try testing.expectError(error.MethodNotAllowed, c.request(.ping, .{}, f.callOpts()));
    try testing.expectError(error.MethodNotAllowed, c.request(.logging_set_level, .{ .level = .info }, f.callOpts()));
}
