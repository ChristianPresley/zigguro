const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const ServerProcess = @import("ServerProcess.zig");
const tcp = @import("../transport/tcp.zig");
const testing = std.testing;

const fake = test_exes.fake_lsp_server;

fn transcript(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/testdata/transcripts/{s}", .{ options.package_root, name }) catch unreachable;
}

fn endpoint(rt: *zg_core.Runtime, p: *ServerProcess) !*zg_jsonrpc.Endpoint {
    const t = p.transport();
    const ep = try zg_jsonrpc.Endpoint.init(rt, .{ .framing = .content_length, .dialect = .lsp }, t.reader, t.writer);
    errdefer ep.deinit();
    try ep.start();
    return ep;
}

test "server_process: echo server with 1 MB of stderr" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const p = try ServerProcess.start(&rt, .{ .argv = &.{ fake, "--echo", "--stderr-noise", "1048576" }, .name = "fake" }, null, 64 << 10);
    defer p.deinit();
    const ep = try endpoint(&rt, p);
    defer ep.deinit();

    for (0..20) |i| {
        const r = try ep.request("test/echo", .{ .n = i }, .{ .timeout = .fromSeconds(10) });
        defer r.deinit();
        var want: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{{\"n\":{d}}}", .{i}), r.response.result.?.bytes);
    }
    try ep.notify("exit", {});
    try p.exitEvent().waitTimeout(rt.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, p.exitStatus().?);

    // The drain loop may still be copying the last bytes after exit.
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(testing.allocator);
    for (0..500) |_| {
        tail.clearRetainingCapacity();
        try p.stderrTail(&tail, 3);
        if (std.mem.endsWith(u8, tail.items, "noise done\n")) break;
        try rt.io.sleep(.fromMilliseconds(10), .awake);
    }
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tail.items, "\n"), '\n');
    var count: usize = 0;
    var last: []const u8 = "";
    while (lines.next()) |l| : (count += 1) last = l;
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("noise done", last);
    try testing.expect(std.mem.startsWith(u8, tail.items, "stderr noise line "));
}

test "server_process: exit detection" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try ServerProcess.start(&rt, .{ .argv = &.{ fake, "--script", transcript(&buf, "crash.script") } }, null, ServerProcess.default_stderr_cap);
    defer p.deinit();
    try testing.expect(p.pid() != null);
    try testing.expect(p.exitStatus() == null);
    const ep = try endpoint(&rt, p);
    defer ep.deinit();
    const r = try ep.request("initialize", .{ .capabilities = .{} }, .{ .timeout = .fromSeconds(10) });
    r.deinit();
    try ep.notify("initialized", .{});
    try p.exitEvent().waitTimeout(rt.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, p.exitStatus().?);
}

fn processAlive(pid: std.posix.pid_t) bool {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&path, "/proc/{d}/stat", .{pid}) catch unreachable;
    const io = testing.io;
    var stat_buf: [512]u8 = undefined;
    const stat = std.Io.Dir.cwd().readFile(io, p, &stat_buf) catch return false;
    // A zombie (state Z) is dead but not yet reaped by its parent.
    const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return true;
    return !(close_paren + 2 < stat.len and stat[close_paren + 2] == 'Z');
}

test "server_process: terminate kills tree" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // Windows needs the E01 Job Object helper.
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const p = try ServerProcess.start(&rt, .{ .argv = &.{ fake, "--echo", "--spawn-grandchild" } }, null, ServerProcess.default_stderr_cap);
    defer p.deinit();

    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(testing.allocator);
    const grandchild: std.posix.pid_t = for (0..500) |_| {
        tail.clearRetainingCapacity();
        try p.stderrTail(&tail, 10);
        if (std.mem.indexOf(u8, tail.items, "grandchild ")) |i| {
            const rest = tail.items[i + "grandchild ".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse continue;
            break try std.fmt.parseInt(std.posix.pid_t, rest[0..end], 10);
        }
        try rt.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.NoGrandchild;
    const child = p.pid().?;
    try testing.expect(processAlive(child));
    try testing.expect(processAlive(grandchild));

    // The server exits on end of input; the grandchild dies only through
    // the process group.
    p.terminate(.fromMilliseconds(500));
    try testing.expect(p.exitStatus() != null);
    try testing.expect(!processAlive(child));
    // The grandchild is reparented to init, which reaps it shortly after.
    for (0..200) |_| {
        if (!processAlive(grandchild)) break;
        try rt.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.GrandchildAlive;
}

test "server_process: terminate kills a server that ignores end of input" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const p = try ServerProcess.start(&rt, .{ .argv = &.{ fake, "--sleep" } }, null, ServerProcess.default_stderr_cap);
    defer p.deinit();
    const t0 = std.Io.Timestamp.now(rt.io, .awake);
    p.terminate(.fromMilliseconds(50));
    const elapsed = t0.durationTo(std.Io.Timestamp.now(rt.io, .awake));
    try testing.expect(p.exitStatus() != null);
    try testing.expect(p.exitStatus().? != .exited);
    try testing.expect(elapsed.toMilliseconds() < 5000);
}

test "server_process: tcp_listen_child" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try ServerProcess.start(&rt, .{
        .argv = &.{ fake, "--script", transcript(&buf, "handshake.script"), "--workspace", "/ws", "--port", "{port}" },
        .transport = .tcp_listen_child,
    }, null, ServerProcess.default_stderr_cap);
    defer p.deinit();
    const ep = try endpoint(&rt, p);
    defer ep.deinit();
    const r = try ep.request("initialize", .{ .rootUri = "file:///ws" }, .{ .timeout = .fromSeconds(10) });
    defer r.deinit();
    try testing.expect(std.mem.indexOf(u8, r.response.result.?.bytes, "\"serverInfo\"") != null);
    try ep.notify("initialized", .{});
    const s = try ep.request("shutdown", {}, .{ .timeout = .fromSeconds(10) });
    s.deinit();
    try ep.notify("exit", {});
    try p.exitEvent().waitTimeout(rt.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, p.exitStatus().?);
}

test "server_process: tcp_connect without a process" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const io = rt.io;
    const any: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    var accept = try io.concurrent(std.Io.net.Server.accept, .{ &server, io });
    const p = try ServerProcess.start(&rt, .{ .transport = .{ .tcp_connect = .{ .host = "localhost", .port = port } } }, null, 4096);
    defer p.deinit();
    const stream = try accept.await(io);
    defer stream.close(io);
    try testing.expect(p.pid() == null);
    try testing.expect(p.exitEvent().isSet());
    try p.transport().writer.writeAll("ping");
    try p.transport().writer.flush();
    var rbuf: [16]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    try testing.expectEqualStrings("ping", try r.interface.take(4));
}

test "server_process: remote hosts need allow_remote" {
    try testing.expectError(error.RemoteNotAllowed, tcp.resolveAddress("10.1.2.3", 80, false));
    _ = try tcp.resolveAddress("10.1.2.3", 80, true);
    _ = try tcp.resolveAddress("::1", 80, false);
    _ = try tcp.resolveAddress("127.0.0.2", 80, false);
    try testing.expectError(error.InvalidHost, tcp.resolveAddress("example.com", 80, true));
}

const DenyAll = struct {
    fn decide(_: ?*anyopaque, _: []const []const u8, _: ?[]const u8) ServerProcess.SpawnPolicy.Decision {
        return .{ .deny = "workspace is untrusted" };
    }
};

test "server_process: spawn denied by policy" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const policy: ServerProcess.SpawnPolicy = .{ .decideFn = DenyAll.decide };
    var diag: ServerProcess.StartDiag = .{};
    try testing.expectError(error.SpawnDenied, ServerProcess.startDiag(&rt, .{ .argv = &.{ "./evil", "--stdio" } }, &policy, 4096, &diag));
    try testing.expectEqualStrings("workspace is untrusted", diag.deny_reason.?);
}

const Wrap = struct {
    wrapper: []const []const u8,
    fn decide(ctx: ?*anyopaque, _: []const []const u8, _: ?[]const u8) ServerProcess.SpawnPolicy.Decision {
        const self: *const Wrap = @ptrCast(@alignCast(ctx.?));
        return .{ .allow = .{ .wrapper_argv = self.wrapper, .env_allow = &.{"PATH"}, .env_set = &.{.{ "ZG_SANDBOX", "1" }} } };
    }
};

test "server_process: policy wrapper argv and environment" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env = try std.testing.environ.createMap(testing.allocator);
    defer env.deinit();
    // The wrapper is the fake server playing crash.script; the wrapped argv
    // (`--echo`) follows it, and the script takes precedence.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var w: Wrap = .{ .wrapper = &.{ fake, "--script", transcript(&buf, "crash.script") } };
    const policy: ServerProcess.SpawnPolicy = .{ .ctx = &w, .decideFn = Wrap.decide };
    try testing.expectError(error.MissingBaseEnv, ServerProcess.start(&rt, .{ .argv = &.{"--echo"} }, &policy, 4096));
    const p = try ServerProcess.start(&rt, .{ .argv = &.{"--echo"}, .base_env = &env, .env_add = &.{.{ "ZG_EXTRA", "x" }} }, &policy, 4096);
    defer p.deinit();
    const ep = try endpoint(&rt, p);
    defer ep.deinit();
    const r = try ep.request("initialize", .{}, .{ .timeout = .fromSeconds(10) });
    r.deinit();
    try ep.notify("initialized", .{});
    try p.exitEvent().waitTimeout(rt.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, p.exitStatus().?);
}

test "server_process: empty argv" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try testing.expectError(error.EmptyArgv, ServerProcess.start(&rt, .{}, null, 4096));
}

test "server_process: missing executable" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try testing.expectError(error.FileNotFound, ServerProcess.start(&rt, .{ .argv = &.{"/nonexistent/zigguro-no-such-server"} }, null, 4096));
}

test "server_process: start/terminate cycles leave no processes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const cycles: usize = if (options.slow_tests) 1000 else 20;
    for (0..cycles) |_| {
        const p = try ServerProcess.start(&rt, .{ .argv = &.{ fake, "--echo" } }, null, 4096);
        const pid = p.pid().?;
        p.terminate(.fromSeconds(5));
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, p.exitStatus().?);
        p.deinit();
        try testing.expect(!processAlive(pid));
    }
}
