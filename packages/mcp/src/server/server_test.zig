//! Server core tests: raw JSON-RPC against a recording connection for the
//! wire details, and real `zg_mcp` clients over `InProcPair` for the era
//! flows.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Value = std.json.Value;
const zg_core = @import("zg_core");
const protocol = @import("../protocol/root.zig");
const Server = @import("Server.zig");
const typed = @import("typed.zig");
const Client = @import("../client/Client.zig");
const InProcPair = @import("../transport/in_process.zig");

const io = testing.io;
const messages = protocol.messages;
const gpa = testing.allocator;

const info: messages.Implementation = .{ .name = "zg-test", .version = "1.0" };

/// Records everything the server sends on one connection.
const Rec = struct {
    mutex: Io.Mutex = .init,
    msgs: std.ArrayList([]u8) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init() Rec {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(r: *Rec) void {
        for (r.msgs.items) |m| gpa.free(m);
        r.msgs.deinit(gpa);
        r.arena.deinit();
    }

    fn sink(r: *Rec) Server.Sink {
        return .{ .ctx = r, .send = send };
    }

    fn send(ctx: ?*anyopaque, body: []const u8) void {
        const r: *Rec = @ptrCast(@alignCast(ctx.?));
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.msgs.append(gpa, gpa.dupe(u8, body) catch @panic("oom")) catch @panic("oom");
    }

    fn count(r: *Rec) usize {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        return r.msgs.items.len;
    }

    /// Waits until `n` messages arrived, then returns message `i` parsed.
    fn at(r: *Rec, i: usize) !Value {
        var tries: usize = 0;
        while (r.count() <= i) : (tries += 1) {
            if (tries > 5000) return error.MessageNeverArrived;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        return std.json.parseFromSliceLeaky(Value, r.arena.allocator(), r.msgs.items[i], .{});
    }

    fn raw(r: *Rec, i: usize) []const u8 {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        return r.msgs.items[i];
    }
};

const modern_meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
;

/// Sends a modern request with `params` members (without braces).
fn modern(c: *Server.Conn, id: i64, method: []const u8, params: []const u8) void {
    var buf: [1024]u8 = undefined;
    const sep: []const u8 = if (params.len > 0) "," else "";
    const body = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{{s}{s}{s}}}}}", .{ id, method, params, sep, modern_meta }) catch unreachable;
    c.receive(body);
}

/// Sends a request with exactly `params` (legacy or malformed).
fn plain(c: *Server.Conn, id: i64, method: []const u8, params: []const u8) void {
    var buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params }) catch unreachable;
    c.receive(body);
}

fn legacyHandshake(c: *Server.Conn, rec: *Rec) !void {
    plain(c, 1, "initialize",
        \\{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"old","version":"1"}}
    );
    const r = try rec.at(rec.count() - 1);
    try testing.expectEqualStrings("2025-06-18", r.object.get("result").?.object.get("protocolVersion").?.string);
    c.receive("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
}

/// The value at dotted `path`; a key that itself contains dots
/// (`io.modelcontextprotocol/serverInfo`) matches the longest run of segments.
fn get(v: Value, path: []const u8) ?Value {
    if (path.len == 0) return v;
    switch (v) {
        .array => |arr| {
            const dot = std.mem.indexOfScalar(u8, path, '.') orelse path.len;
            const i = std.fmt.parseInt(usize, path[0..dot], 10) catch return null;
            if (i >= arr.items.len) return null;
            return get(arr.items[i], if (dot == path.len) "" else path[dot + 1 ..]);
        },
        .object => |obj| {
            var end = path.len;
            while (true) {
                if (obj.get(path[0..end])) |child| {
                    if (get(child, if (end == path.len) "" else path[end + 1 ..])) |found| return found;
                }
                end = std.mem.lastIndexOfScalar(u8, path[0..end], '.') orelse return null;
            }
        },
        else => return null,
    }
}

fn str(v: Value, path: []const u8) []const u8 {
    const x = get(v, path) orelse return "<missing>";
    return if (x == .string) x.string else "<not a string>";
}

fn int(v: Value, path: []const u8) i64 {
    const x = get(v, path) orelse return -1;
    return if (x == .integer) x.integer else -1;
}

// ---------------------------------------------------------------- tools

const Echo = struct {
    pub const name = "echo";
    pub const description = "Echoes its text";
    pub const annotations: typed.Annotations = .{ .read_only_hint = true };
    pub const Args = struct { text: []const u8, times: u8 = 1 };
    pub const Output = struct { text: []const u8, times: u8 };

    var calls: std.atomic.Value(u32) = .init(0);

    pub fn call(cc: *Server.CallCtx, args: Args) anyerror!typed.ToolReturn(Output) {
        _ = calls.fetchAdd(1, .monotonic);
        _ = cc;
        if (std.mem.eql(u8, args.text, "fail")) return .{ .tool_error = "asked to fail" };
        return .{ .ok = .{ .value = .{ .text = args.text, .times = args.times } } };
    }
};

fn dynTool(arena: std.mem.Allocator, name: []const u8) !Server.DynamicTool {
    return .{
        .def = .{ .name = name, .input_schema = try protocol.codec.parseValue(arena, "{\"type\":\"object\"}") },
        .handler = .{ .ctx = null, .call = struct {
            fn call(_: ?*anyopaque, cc: *Server.CallCtx, _: Value) anyerror!messages.CallToolResult {
                return Server.toolError(cc.arena, "unused", .{});
            }
        }.call },
    };
}

const Fixture = struct {
    s: *Server,
    rec: Rec,
    conn: *Server.Conn,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture, opts: Server.Options) !void {
        f.s = try Server.init(gpa, io, opts);
        f.rec = .init();
        f.arena = .init(gpa);
        f.conn = try f.s.connect(f.rec.sink(), "alice");
    }

    fn deinit(f: *Fixture) void {
        f.s.deinit();
        f.rec.deinit();
        f.arena.deinit();
    }
};

// ---------------------------------------------------------------- dispatch

test "dispatch: modern meta missing => -32602" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    // protocolVersion without clientCapabilities.
    plain(f.conn, 1, "tools/list",
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}
    );
    const r = try f.rec.at(0);
    try testing.expectEqual(@as(i64, -32602), int(r, "error.code"));
    try testing.expect(std.mem.indexOf(u8, str(r, "error.message"), "clientCapabilities") != null);
    // No meta and no initialize: refused, naming the versions.
    plain(f.conn, 2, "tools/list", "{}");
    const r2 = try f.rec.at(1);
    try testing.expectEqual(@as(i64, -32602), int(r2, "error.code"));
    try testing.expect(std.mem.indexOf(u8, str(r2, "error.message"), "2026-07-28, 2025-11-25") != null);
}

test "dispatch: unsupported version => -32022 with supported list" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info, .revisions = &.{ .v2026_07_28, .v2025_11_25 } });
    defer f.deinit();
    plain(f.conn, 1, "server/discover",
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01","io.modelcontextprotocol/clientCapabilities":{}}}
    );
    const r = try f.rec.at(0);
    try testing.expectEqual(@as(i64, -32022), int(r, "error.code"));
    try testing.expectEqualStrings("2099-01-01", str(r, "error.data.requested"));
    try testing.expectEqualStrings("2026-07-28", str(r, "error.data.supported.0"));
    try testing.expectEqualStrings("2025-11-25", str(r, "error.data.supported.1"));
    try testing.expectEqual(@as(usize, 2), get(r, "error.data.supported").?.array.items.len);
}

test "dispatch: initialize then legacy flow" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const s = try Server.init(gpa, io, .{ .info = info, .instructions = "hi" });
    defer s.deinit();
    try s.addTool(Echo);
    var pair: InProcPair = .init(gpa, io);
    defer pair.deinit();
    const conn = try s.serveInProcess(&pair);
    defer conn.close();
    const c = try Client.connect(&rt, gpa, .{ .in_process = &pair }, .{
        .client_info = .{ .name = "legacy-client", .version = "1" },
        .revisions = &.{ .v2025_06_18, .v2025_03_26 },
    });
    defer c.close();
    try testing.expectEqual(protocol.revision.Era.legacy, c.serverInfo().era);
    try testing.expectEqual(protocol.Revision.v2025_06_18, c.serverInfo().revision);
    try testing.expectEqualStrings("hi", c.serverInfo().instructions.?);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const l = try c.request(.tools_list, .{}, .{ .arena = arena.allocator() });
    try testing.expectEqual(@as(usize, 1), l.tools.len);
    try testing.expect(l.ttl_ms == null);
    const r = try c.request(.tools_call, .{ .name = "echo", .arguments = try protocol.codec.parseValue(arena.allocator(), "{\"text\":\"hey\"}") }, .{ .arena = arena.allocator() });
    try testing.expectEqualStrings("hey", r.structured_content.?.object.get("text").?.string);
    // The session negotiated by initialize stays legacy.
    conn.mutex.lockUncancelable(io);
    defer conn.mutex.unlock(io);
    try testing.expect(conn.state.legacy.?.initialized);
    try testing.expectEqualStrings("legacy-client", conn.state.legacy.?.client_info.name);
}

const EraLoop = struct {
    fn run(c: *Client, n: usize, failures: *std.atomic.Value(u32)) Io.Cancelable!void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        for (0..n) |i| {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            const text = std.fmt.allocPrint(a, "{{\"text\":\"m{d}\"}}", .{i}) catch return;
            const args = protocol.codec.parseValue(a, text) catch return;
            const r = c.request(.tools_call, .{ .name = "echo", .arguments = args }, .{ .arena = a }) catch {
                _ = failures.fetchAdd(1, .monotonic);
                continue;
            };
            const want = std.fmt.allocPrint(a, "m{d}", .{i}) catch return;
            if (!std.mem.eql(u8, r.structured_content.?.object.get("text").?.string, want)) _ = failures.fetchAdd(1, .monotonic);
        }
    }
};

test "dispatch: both eras concurrently on two connections" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const s = try Server.init(gpa, io, .{ .info = info });
    defer s.deinit();
    try s.addTool(Echo);
    var pairs: [2]InProcPair = .{ .init(gpa, io), .init(gpa, io) };
    defer for (&pairs) |*p| p.deinit();
    var conns: [2]*Server.Conn = undefined;
    for (&pairs, &conns) |*p, *c| c.* = try s.serveInProcess(p);
    defer for (conns) |c| c.close();
    const ci: messages.Implementation = .{ .name = "c", .version = "1" };
    const modern_c = try Client.connect(&rt, gpa, .{ .in_process = &pairs[0] }, .{ .client_info = ci });
    defer modern_c.close();
    const legacy_c = try Client.connect(&rt, gpa, .{ .in_process = &pairs[1] }, .{ .client_info = ci, .revisions = &.{.v2025_11_25} });
    defer legacy_c.close();
    try testing.expectEqual(protocol.revision.Era.modern, modern_c.serverInfo().era);
    try testing.expectEqual(protocol.revision.Era.legacy, legacy_c.serverInfo().era);
    var failures: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    try group.concurrent(io, EraLoop.run, .{ modern_c, 50, &failures });
    try group.concurrent(io, EraLoop.run, .{ legacy_c, 50, &failures });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
}

// ---------------------------------------------------------------- lists

test "tools/list: deterministic order" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    const names = [_][]const u8{ "zeta", "alpha", "mid", "beta", "omega" };
    for (names) |n| try f.s.addDynamicTool(try dynTool(f.arena.allocator(), n));
    modern(f.conn, 1, "tools/list", "");
    modern(f.conn, 2, "tools/list", "");
    for (0..2) |i| {
        const r = try f.rec.at(i);
        for (names, 0..) |n, j| {
            var path: [32]u8 = undefined;
            try testing.expectEqualStrings(n, str(r, try std.fmt.bufPrint(&path, "result.tools.{d}.name", .{j})));
        }
    }
    // The second answer is the cached page, byte for byte.
    try testing.expectEqualStrings(f.rec.raw(0)[std.mem.indexOf(u8, f.rec.raw(0), "\"result\"").?..], f.rec.raw(1)[std.mem.indexOf(u8, f.rec.raw(1), "\"result\"").?..]);
}

test "tools/list: cursor paging and stale cursor" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info, .page_size = 2 });
    defer f.deinit();
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |n| try f.s.addDynamicTool(try dynTool(f.arena.allocator(), n));
    modern(f.conn, 1, "tools/list", "");
    const p1 = try f.rec.at(0);
    try testing.expectEqual(@as(usize, 2), get(p1, "result.tools").?.array.items.len);
    const cursor = str(p1, "result.nextCursor");
    var buf: [64]u8 = undefined;
    modern(f.conn, 2, "tools/list", try std.fmt.bufPrint(&buf, "\"cursor\":\"{s}\"", .{cursor}));
    const p2 = try f.rec.at(1);
    try testing.expectEqualStrings("c", str(p2, "result.tools.0.name"));
    const cursor3 = str(p2, "result.nextCursor");
    modern(f.conn, 3, "tools/list", try std.fmt.bufPrint(&buf, "\"cursor\":\"{s}\"", .{cursor3}));
    const p3 = try f.rec.at(2);
    try testing.expectEqualStrings("e", str(p3, "result.tools.0.name"));
    try testing.expect(get(p3, "result.nextCursor") == null);
    // A change makes old cursors stale.
    try f.s.addDynamicTool(try dynTool(f.arena.allocator(), "f"));
    modern(f.conn, 4, "tools/list", try std.fmt.bufPrint(&buf, "\"cursor\":\"{s}\"", .{cursor}));
    const stale = try f.rec.at(3);
    try testing.expectEqual(@as(i64, -32602), int(stale, "error.code"));
    modern(f.conn, 5, "tools/list", "\"cursor\":\"garbage\"");
    try testing.expectEqual(@as(i64, -32602), int(try f.rec.at(4), "error.code"));
}

test "serverInfo in result _meta" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    modern(f.conn, 1, "server/discover", "");
    const d = try f.rec.at(0);
    try testing.expectEqualStrings("complete", str(d, "result.resultType"));
    try testing.expectEqualStrings("zg-test", str(d, "result._meta.io.modelcontextprotocol/serverInfo.name"));
    try testing.expectEqualStrings("2026-07-28", str(d, "result.supportedVersions.0"));
    modern(f.conn, 2, "prompts/list", "");
    try testing.expectEqualStrings("zg-test", str(try f.rec.at(1), "result._meta.io.modelcontextprotocol/serverInfo.name"));
}

test "ttlMs/cacheScope present on modern lists" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info, .list_ttl_ms = 5000, .principal_dependent = true });
    defer f.deinit();
    modern(f.conn, 1, "tools/list", "");
    const m = try f.rec.at(0);
    try testing.expectEqual(@as(i64, 5000), int(m, "result.ttlMs"));
    try testing.expectEqualStrings("private", str(m, "result.cacheScope"));
    modern(f.conn, 2, "resources/templates/list", "");
    try testing.expectEqual(@as(i64, 5000), int(try f.rec.at(1), "result.ttlMs"));
    try legacyHandshake(f.conn, &f.rec);
    plain(f.conn, 3, "tools/list", "{}");
    const l = try f.rec.at(3);
    try testing.expect(get(l, "result.ttlMs") == null);
    try testing.expect(get(l, "result.cacheScope") == null);
    try testing.expect(get(l, "result.resultType") == null);
    try testing.expect(get(l, "result._meta") == null);
}

// ---------------------------------------------------------------- tools/call

test "tools/call: invalid args => isError, handler not called" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    try f.s.addTool(Echo);
    const before = Echo.calls.load(.monotonic);
    modern(f.conn, 1, "tools/call", "\"name\":\"echo\",\"arguments\":{\"text\":5}");
    const r = try f.rec.at(0);
    try testing.expect(get(r, "result.isError").?.bool);
    try testing.expect(std.mem.startsWith(u8, str(r, "result.content.0.text"), "invalid arguments: /text"));
    modern(f.conn, 2, "tools/call", "\"name\":\"echo\",\"arguments\":{\"text\":\"x\",\"extra\":1}");
    try testing.expect(get(try f.rec.at(1), "result.isError").?.bool);
    try testing.expectEqual(before, Echo.calls.load(.monotonic));
    modern(f.conn, 3, "tools/call", "\"name\":\"nope\"");
    try testing.expectEqual(@as(i64, -32602), int(try f.rec.at(2), "error.code"));
}

test "tools/call: structured + text block" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    try f.s.addTool(Echo);
    modern(f.conn, 1, "tools/call", "\"name\":\"echo\",\"arguments\":{\"text\":\"hi\",\"times\":3}");
    const r = try f.rec.at(0);
    try testing.expectEqualStrings("complete", str(r, "result.resultType"));
    try testing.expectEqualStrings("hi", str(r, "result.structuredContent.text"));
    try testing.expectEqual(@as(i64, 3), int(r, "result.structuredContent.times"));
    try testing.expectEqualStrings("text", str(r, "result.content.0.type"));
    try testing.expectEqualStrings("{\"text\":\"hi\",\"times\":3}", str(r, "result.content.0.text"));
    try testing.expect(get(r, "result.isError") == null);
    modern(f.conn, 2, "tools/call", "\"name\":\"echo\",\"arguments\":{\"text\":\"fail\"}");
    const e = try f.rec.at(1);
    try testing.expect(get(e, "result.isError").?.bool);
    try testing.expectEqualStrings("asked to fail", str(e, "result.content.0.text"));
    // The tool definition carries both schemas and the annotations.
    modern(f.conn, 3, "tools/list", "");
    const l = try f.rec.at(2);
    try testing.expectEqualStrings("object", str(l, "result.tools.0.inputSchema.type"));
    try testing.expectEqualStrings("object", str(l, "result.tools.0.outputSchema.type"));
    try testing.expect(get(l, "result.tools.0.annotations.readOnlyHint").?.bool);
}

test "tools/call: authorizer deny" {
    const Deny = struct {
        fn decide(_: ?*anyopaque, principal: ?[]const u8, op: []const u8, target: []const u8) Server.Decision {
            std.debug.assert(std.mem.eql(u8, principal.?, "alice"));
            std.debug.assert(std.mem.eql(u8, op, "tools/call"));
            return if (std.mem.eql(u8, target, "echo")) .{ .deny = "no-echo" } else .allow;
        }
    };
    var f: Fixture = undefined;
    try f.init(.{ .info = info, .authorizer = .{ .ctx = null, .decide = Deny.decide } });
    defer f.deinit();
    try f.s.addTool(Echo);
    const before = Echo.calls.load(.monotonic);
    modern(f.conn, 1, "tools/call", "\"name\":\"echo\",\"arguments\":{\"text\":\"x\"}");
    const r = try f.rec.at(0);
    try testing.expect(get(r, "result.isError").?.bool);
    try testing.expectEqualStrings("denied by zigguro policy: no-echo", str(r, "result.content.0.text"));
    try testing.expectEqual(before, Echo.calls.load(.monotonic));
}

// ---------------------------------------------------------------- subscriptions

fn nopGet(_: ?*anyopaque, _: *Server.CallCtx, _: ?Value) anyerror!messages.GetPromptResult {
    return .{ .messages = &.{} };
}

test "listen: ack first, filtered, tagged" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    modern(f.conn, 9, "subscriptions/listen", "\"notifications\":{\"toolsListChanged\":true}");
    const ack = try f.rec.at(0);
    try testing.expectEqualStrings("notifications/subscriptions/acknowledged", str(ack, "method"));
    try testing.expectEqual(@as(i64, 9), int(ack, "params._meta.io.modelcontextprotocol/subscriptionId"));
    try testing.expect(get(ack, "params.notifications.toolsListChanged").?.bool);
    try f.s.addPrompt(.{ .name = "p" }, .{ .ctx = null, .get = nopGet });
    try f.s.addDynamicTool(try dynTool(f.arena.allocator(), "t"));
    const n = try f.rec.at(1);
    try testing.expectEqualStrings("notifications/tools/list_changed", str(n, "method"));
    try testing.expectEqual(@as(i64, 9), int(n, "params._meta.io.modelcontextprotocol/subscriptionId"));
    // The prompt change was filtered out, and the listen request is still open.
    try testing.expectEqual(@as(usize, 2), f.rec.count());
    // A request-scoped answer is not tagged.
    modern(f.conn, 10, "tools/list", "");
    try testing.expect(get(try f.rec.at(2), "result._meta.io.modelcontextprotocol/subscriptionId") == null);
    // Cancelling the listen ends it without a response.
    f.conn.receive("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":9}}");
    try f.s.addDynamicTool(try dynTool(f.arena.allocator(), "u"));
    try testing.expectEqual(@as(usize, 3), f.rec.count());
}

test "listen: graceful end" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    modern(f.conn, 4, "subscriptions/listen", "\"notifications\":{\"promptsListChanged\":true}");
    _ = try f.rec.at(0);
    f.s.endSubscriptions();
    const r = try f.rec.at(1);
    try testing.expectEqual(@as(i64, 4), int(r, "id"));
    try testing.expectEqualStrings("complete", str(r, "result.resultType"));
    try testing.expectEqual(@as(i64, 4), int(r, "result._meta.io.modelcontextprotocol/subscriptionId"));
    try testing.expectEqualStrings("zg-test", str(r, "result._meta.io.modelcontextprotocol/serverInfo.name"));
    // Nothing more is delivered on the ended stream.
    try f.s.addPrompt(.{ .name = "p" }, .{ .ctx = null, .get = nopGet });
    try testing.expectEqual(@as(usize, 2), f.rec.count());
}

fn readNothing(_: ?*anyopaque, _: *Server.CallCtx, _: []const u8) anyerror![]const protocol.content.ResourceContents {
    return &.{};
}

test "legacy subscribe: only subscribed URIs" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    try f.s.addResource(.{ .uri = "file:///a", .name = "a" }, .{ .ctx = null, .read = readNothing });
    try f.s.addResource(.{ .uri = "file:///b", .name = "b" }, .{ .ctx = null, .read = readNothing });
    var rec_b: Rec = .init();
    defer rec_b.deinit();
    const conn_b = try f.s.connect(rec_b.sink(), null);
    try legacyHandshake(f.conn, &f.rec);
    try legacyHandshake(conn_b, &rec_b);
    plain(f.conn, 2, "resources/subscribe", "{\"uri\":\"file:///a\"}");
    try testing.expect(get(try f.rec.at(1), "result") != null);
    f.s.resourceUpdated("file:///b");
    f.s.resourceUpdated("file:///a");
    const n = try f.rec.at(2);
    try testing.expectEqualStrings("notifications/resources/updated", str(n, "method"));
    try testing.expectEqualStrings("file:///a", str(n, "params.uri"));
    try testing.expectEqual(@as(usize, 3), f.rec.count());
    try testing.expectEqual(@as(usize, 1), rec_b.count());
    plain(f.conn, 3, "resources/unsubscribe", "{\"uri\":\"file:///a\"}");
    _ = try f.rec.at(3);
    f.s.resourceUpdated("file:///a");
    try testing.expectEqual(@as(usize, 4), f.rec.count());
    // Legacy sessions get list_changed for every list.
    try f.s.addResource(.{ .uri = "file:///c", .name = "c" }, .{ .ctx = null, .read = readNothing });
    try testing.expectEqualStrings("notifications/resources/list_changed", str(try f.rec.at(4), "method"));
    try testing.expectEqualStrings("notifications/resources/list_changed", str(try rec_b.at(1), "method"));
}

test "dispatch: method table per era" {
    var f: Fixture = undefined;
    try f.init(.{ .info = info });
    defer f.deinit();
    modern(f.conn, 1, "ping", "");
    try testing.expectEqual(@as(i64, -32601), int(try f.rec.at(0), "error.code"));
    modern(f.conn, 2, "tools/bogus", "");
    try testing.expectEqual(@as(i64, -32601), int(try f.rec.at(1), "error.code"));
    try legacyHandshake(f.conn, &f.rec);
    plain(f.conn, 3, "ping", "{}");
    try testing.expect(get(try f.rec.at(3), "result") != null);
    plain(f.conn, 4, "server/discover", "{}");
    try testing.expectEqual(@as(i64, -32601), int(try f.rec.at(4), "error.code"));
    plain(f.conn, 5, "resources/read", "{\"uri\":\"file:///missing\"}");
    try testing.expectEqual(@as(i64, -32002), int(try f.rec.at(5), "error.code"));
}
