//! stdio transport tests against `fixtures/echo_server.zig`.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const zg_core = @import("zg_core");
const zg_mcp = @import("zg_mcp");
const fixtures = @import("mcp_fixtures");
const Transport = zg_mcp.transport.Transport;
const StdioTransport = zg_mcp.transport.StdioTransport;

const io = testing.io;
const wait_limit: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

/// Collects one request's outcome.
const Waiter = struct {
    mutex: Io.Mutex = .init,
    done: Io.Event = .unset,
    result: [256]u8 = undefined,
    result_len: usize = 0,
    failure: ?std.meta.Tag(Transport.TransportError) = null,
    exit: ?Transport.ExitInfo = null,
    tail_has_boom: bool = false,
    sink: Transport.RequestSink = undefined,

    fn init(w: *Waiter) void {
        w.* = .{};
        w.sink = .{ .ctx = w, .onNotification = onNote, .onServerRequest = onReq, .onResponse = onResp, .onError = onErr };
    }

    fn from(ctx: ?*anyopaque) *Waiter {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onNote(_: ?*anyopaque, _: zg_mcp.protocol.Notification, _: Raw.Notification) void {}
    fn onReq(_: ?*anyopaque, _: Raw.Request) void {}

    fn onResp(ctx: ?*anyopaque, r: Raw.Response) void {
        const w = from(ctx);
        if (r.result) |res| {
            const n = @min(res.bytes.len, w.result.len);
            @memcpy(w.result[0..n], res.bytes[0..n]);
            w.result_len = n;
        }
        w.done.set(io);
    }

    fn onErr(ctx: ?*anyopaque, e: Transport.TransportError) void {
        const w = from(ctx);
        w.failure = e;
        if (e == .process_exited) {
            w.exit = e.process_exited;
            w.tail_has_boom = std.mem.indexOf(u8, e.process_exited.stderr_tail, "boom") != null;
            w.exit.?.stderr_tail = "";
        }
        w.done.set(io);
    }

    fn resultStr(w: *const Waiter) []const u8 {
        return w.result[0..w.result_len];
    }
};

const Raw = struct {
    const Notification = @typeInfo(@typeInfo(@FieldType(Transport.RequestSink, "onNotification")).pointer.child).@"fn".params[2].type.?;
    const Request = @typeInfo(@typeInfo(@FieldType(Transport.RequestSink, "onServerRequest")).pointer.child).@"fn".params[1].type.?;
    const Response = @typeInfo(@typeInfo(@FieldType(Transport.RequestSink, "onResponse")).pointer.child).@"fn".params[1].type.?;
};

const Fixture = struct {
    rt: zg_core.Runtime,
    t: ?*StdioTransport = null,

    fn init(f: *Fixture, args: []const []const u8, opts: zg_mcp.transport.StdioOptions) !void {
        f.* = .{ .rt = undefined };
        f.rt.initTesting();
        var o = opts;
        o.command = fixtures.echo_server;
        o.args = args;
        f.t = try StdioTransport.start(&f.rt, testing.allocator, o);
    }

    fn close(f: *Fixture) void {
        if (f.t) |t| t.deinit();
        f.t = null;
    }

    fn deinit(f: *Fixture) void {
        f.close();
        _ = f.rt.deinit();
    }

    fn send(f: *Fixture, w: *Waiter, id: i64, method: []const u8, params: []const u8) !void {
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
        , .{ id, method, params });
        try f.t.?.transport().request(.{ .id = .{ .int = id }, .method = .ping, .method_str = method, .body = body, .revision = .v2025_11_25 }, &w.sink);
    }
};

const no_opts: zg_mcp.transport.StdioOptions = .{ .command = "" };

test "stdio: request/response round-trip" {
    var f: Fixture = undefined;
    try f.init(&.{}, no_opts);
    defer f.deinit();
    var w: Waiter = undefined;
    w.init();
    try f.send(&w, 1, "echo", "{\"x\":1}");
    try w.done.waitTimeout(io, wait_limit);
    try testing.expectEqualStrings("{\"echo\":{\"x\":1}}", w.resultStr());
    try testing.expect(f.t.?.pid() != null);
    try testing.expectEqual(Transport.Kind.stdio, f.t.?.transport().kind());
}

test "stdio: 1000 concurrent requests" {
    var f: Fixture = undefined;
    try f.init(&.{}, no_opts);
    defer f.deinit();
    const ws = try testing.allocator.alloc(Waiter, 1000);
    defer testing.allocator.free(ws);
    for (ws, 0..) |*w, i| {
        w.init();
        var p: [32]u8 = undefined;
        try f.send(w, @intCast(i + 1), "echo", try std.fmt.bufPrint(&p, "{d}", .{i}));
    }
    for (ws, 0..) |*w, i| {
        try w.done.waitTimeout(io, wait_limit);
        var want: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{{\"echo\":{d}}}", .{i}), w.resultStr());
    }
}

const Lines = struct {
    mutex: Io.Mutex = .init,
    saw_cancel: Io.Event = .unset,
    count: usize = 0,

    fn on(ctx: ?*anyopaque, line: []const u8) void {
        const l: *Lines = @ptrCast(@alignCast(ctx.?));
        l.mutex.lockUncancelable(io);
        defer l.mutex.unlock(io);
        l.count += 1;
        if (std.mem.eql(u8, line, "cancelled 7")) l.saw_cancel.set(io);
    }
};

test "stdio: cancel sends notifications/cancelled" {
    var f: Fixture = undefined;
    try f.init(&.{}, no_opts);
    defer f.deinit();
    var lines: Lines = .{};
    f.t.?.onStderrLine(.{ .ctx = &lines, .func = Lines.on });
    var w: Waiter = undefined;
    w.init();
    try f.send(&w, 7, "slow", "{}");
    f.t.?.transport().cancel(.{ .int = 7 }, "user");
    try testing.expect(w.failure == .canceled);
    try lines.saw_cancel.waitTimeout(io, wait_limit);
}

test "stdio: stderr ring keeps last 64KiB" {
    var f: Fixture = undefined;
    try f.init(&.{}, no_opts);
    defer f.deinit();
    var w: Waiter = undefined;
    w.init();
    try f.send(&w, 1, "stderr", "{\"bytes\":200000}");
    try w.done.waitTimeout(io, wait_limit);
    // stderr and stdout are separate pipes: wait for the ring to fill.
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const snap = try f.t.?.stderrSnapshot(testing.allocator);
        defer testing.allocator.free(snap);
        if (snap.len == 64 * 1024) {
            try testing.expect(std.mem.endsWith(u8, snap, "x\n"));
            try testing.expect(std.mem.indexOfNone(u8, snap, "x\n") == null);
            break;
        }
        if (tries > 500) return error.RingNeverFilled;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "stdio: crash during startup => process_exited with tail" {
    var f: Fixture = undefined;
    try f.init(&.{"--crash-on-start"}, no_opts);
    defer f.deinit();
    var w: Waiter = undefined;
    w.init();
    // The request may race the exit: either it is refused or it fails.
    f.send(&w, 1, "echo", "{}") catch |err| {
        try testing.expectEqual(error.Closed, err);
        try f.t.?.exited.waitTimeout(io, wait_limit);
        try testing.expectEqual(@as(?u32, 2), f.t.?.exitInfo().?.code);
        return;
    };
    try w.done.waitTimeout(io, wait_limit);
    try testing.expect(w.failure == .process_exited);
    try testing.expectEqual(@as(?u32, 2), w.exit.?.code);
    try testing.expect(w.exit.?.during_startup);
    try testing.expect(w.tail_has_boom);
}

fn alive(pid: std.posix.pid_t) bool {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return false;
    var stat: [512]u8 = undefined;
    const data = Io.Dir.cwd().readFile(io, path, &stat) catch return false;
    // A zombie ("Z") is dead for our purposes.
    const close_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return false;
    return !(data.len > close_paren + 2 and data[close_paren + 2] == 'Z');
}

test "stdio: close escalates to SIGTERM then SIGKILL; grandchild reaped" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(&.{"--ignore-term"}, .{
        .command = "",
        .grace_stdin_close = .fromMilliseconds(50),
        .grace_term = .fromMilliseconds(50),
    });
    defer f.deinit();
    var w: Waiter = undefined;
    w.init();
    try f.send(&w, 1, "spawn", "{}");
    try w.done.waitTimeout(io, wait_limit);
    const res = w.resultStr();
    const grandchild = try std.fmt.parseInt(std.posix.pid_t, res[std.mem.indexOf(u8, res, ":").? + 1 .. res.len - 1], 10);
    const server: std.posix.pid_t = f.t.?.pid().?;
    try testing.expect(alive(server));
    try testing.expect(alive(grandchild));
    // With --ignore-term the server outlives stdin EOF and SIGTERM, so only
    // the SIGKILL to its process group ends it and the grandchild.
    f.close();
    var tries: usize = 0;
    while (alive(server) or alive(grandchild)) : (tries += 1) {
        if (tries > 400) return error.ProcessesSurvived;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "stdio: oversized line => protocol error" {
    var f: Fixture = undefined;
    try f.init(&.{}, .{ .command = "", .max_line_bytes = 1024 });
    defer f.deinit();
    var w: Waiter = undefined;
    w.init();
    try f.send(&w, 1, "big", "{\"bytes\":5000}");
    try w.done.waitTimeout(io, wait_limit);
    try testing.expect(w.failure == .protocol);
}

test "stdio: unknown command => CommandNotFound" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try testing.expectError(error.CommandNotFound, StdioTransport.start(&rt, testing.allocator, .{ .command = "/nonexistent/zg-mcp-server" }));
}

test "era: stdio legacy -32601 => initialize (real pipe)" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const Client = zg_mcp.client.Client;
    const c = try Client.connect(&rt, testing.allocator, .{ .stdio = .{ .command = fixtures.echo_server } }, .{
        .client_info = .{ .name = "zigguro-test", .version = "0.0.1" },
    });
    defer c.close();
    try testing.expectEqual(zg_mcp.protocol.revision.Era.legacy, c.serverInfo().era);
    try testing.expectEqual(zg_mcp.protocol.Revision.v2025_06_18, c.serverInfo().revision);
    try testing.expectEqual(Transport.Kind.stdio, c.serverInfo().detection.transport);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try c.request(.ping, .{}, .{ .arena = arena.allocator() });
}
