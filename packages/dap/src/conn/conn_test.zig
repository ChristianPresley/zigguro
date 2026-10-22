const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const DapConnection = @import("DapConnection.zig");
const protocol = @import("../gen/protocol.zig");
const ServerProcess = zg_lsp.client.ServerProcess;
const testing = std.testing;
const Io = std.Io;

const fake = test_exes.fake_dap_adapter;
const workspace = "/w";

/// The fake adapter playing `script`, and a connection to it.
const Harness = struct {
    rt: zg_core.Runtime,
    proc: *ServerProcess,
    conn: *DapConnection,
    path_buf: [std.fs.max_path_bytes]u8,
    log: Log,

    fn init(h: *Harness, script: []const u8, transport: ServerProcess.TransportKind, opts: DapConnection.Options) !void {
        h.rt.initTesting();
        errdefer _ = h.rt.deinit();
        h.log = .{ .io = h.rt.io };
        const path = try std.fmt.bufPrint(&h.path_buf, "{s}/testdata/scripts/{s}", .{ options.package_root, script });
        const argv: []const []const u8 = switch (transport) {
            .tcp_listen_child => &.{ fake, "--script", path, "--workspace", workspace, "--tcp", "{port}" },
            else => &.{ fake, "--script", path, "--workspace", workspace },
        };
        h.proc = try ServerProcess.start(&h.rt, .{ .argv = argv, .transport = transport, .name = "fake_dap_adapter" }, null, ServerProcess.default_stderr_cap);
        errdefer h.proc.deinit();
        h.conn = try DapConnection.init(&h.rt, h.proc.transport(), opts);
        try h.conn.onEvent(.{ .ctx = &h.log, .func = Log.onEvent });
    }

    fn deinit(h: *Harness) void {
        h.conn.deinit();
        h.proc.deinit();
        _ = h.rt.deinit();
    }

    fn exitStatus(h: *Harness) !std.process.Child.Term {
        h.proc.exitEvent().waitTimeout(h.rt.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } }) catch |err| {
            h.dumpStderr();
            return err;
        };
        return h.proc.exitStatus().?;
    }

    fn dumpStderr(h: *Harness) void {
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(testing.allocator);
        h.proc.stderrTail(&tail, 20) catch return;
        std.debug.print("fake adapter stderr:\n{s}\n", .{tail.items});
    }

    /// Sends `cmd` and waits for its result.
    fn call(h: *Harness, comptime cmd: protocol.Command, args: protocol.RequestInfo(cmd).Arguments) !DapConnection.Result(cmd) {
        var w: Wait(cmd) = .{ .io = h.rt.io, .log = &h.log };
        _ = try h.conn.request(cmd, args, .{ .ctx = &w, .func = Wait(cmd).done });
        return w.wait();
    }

    fn callRaw(h: *Harness, command: []const u8, args: ?[]const u8) !DapConnection.RawResult {
        var w: WaitRaw = .{ .io = h.rt.io };
        _ = try h.conn.requestRaw(command, args, .{ .ctx = &w, .func = WaitRaw.done });
        return w.wait();
    }
};

/// What the dispatcher delivered, in order: `event:<name>` and
/// `response:<command>`.
const Log = struct {
    mutex: Io.Mutex = .init,
    items: [64][32]u8 = undefined,
    lens: [64]usize = undefined,
    n: usize = 0,
    changed: Io.Event = .unset,
    io: Io,

    fn add(l: *Log, comptime prefix: []const u8, name: []const u8) void {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        if (l.n == l.items.len) return;
        const s = std.fmt.bufPrint(&l.items[l.n], prefix ++ "{s}", .{name}) catch return;
        l.lens[l.n] = s.len;
        l.n += 1;
        l.changed.set(l.io);
    }

    fn onEvent(ctx: ?*anyopaque, _: *DapConnection, event: []const u8, _: ?DapConnection.RawJson, _: u32) void {
        const l: *Log = @ptrCast(@alignCast(ctx.?));
        l.add("event:", event);
    }

    fn get(l: *Log, i: usize) []const u8 {
        return l.items[i][0..l.lens[i]];
    }

    /// Waits until `name` was logged.
    fn waitFor(l: *Log, name: []const u8) !void {
        while (true) {
            l.mutex.lockUncancelable(l.io);
            for (0..l.n) |i| if (std.mem.eql(u8, l.get(i), name)) {
                l.mutex.unlock(l.io);
                return;
            };
            l.changed.reset();
            l.mutex.unlock(l.io);
            try l.changed.waitTimeout(l.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
        }
    }

    fn expectSequence(l: *Log, want: []const []const u8) !void {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        try testing.expectEqual(want.len, l.n);
        for (want, 0..) |w, i| try testing.expectEqualStrings(w, l.get(i));
    }
};

fn Wait(comptime cmd: protocol.Command) type {
    return struct {
        event: Io.Event = .unset,
        result: ?DapConnection.Result(cmd) = null,
        io: Io,
        log: *Log,

        fn done(ctx: ?*anyopaque, r: DapConnection.Result(cmd)) void {
            const w: *@This() = @ptrCast(@alignCast(ctx.?));
            w.log.add("response:", @tagName(cmd));
            w.result = r;
            w.event.set(w.io);
        }

        fn wait(w: *@This()) !DapConnection.Result(cmd) {
            try w.event.waitTimeout(w.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
            return w.result.?;
        }
    };
}

const WaitRaw = struct {
    event: Io.Event = .unset,
    result: ?DapConnection.RawResult = null,
    io: Io,

    fn done(ctx: ?*anyopaque, r: DapConnection.RawResult) void {
        const w: *WaitRaw = @ptrCast(@alignCast(ctx.?));
        w.result = r;
        w.event.set(w.io);
    }

    fn wait(w: *WaitRaw) !DapConnection.RawResult {
        try w.event.waitTimeout(w.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
        return w.result.?;
    }
};

fn expectOk(r: anytype) !void {
    if (r != .ok) {
        std.debug.print("unexpected result: {t}\n", .{r});
        return error.TestUnexpectedResult;
    }
}

test "dap: request/response match by request_seq, in wire order with events" {
    var h: Harness = undefined;
    try h.init("launch_stop_continue.dapt", .stdio, .{});
    defer h.deinit();
    try h.conn.start();

    const caps = try h.call(.initialize, .{ .adapterID = "fake", .linesStartAt1 = true });
    defer caps.deinit();
    try expectOk(caps);
    try testing.expect(caps.ok.value.supportsConfigurationDoneRequest.?);
    try testing.expect(caps.ok.value.supportsCancelRequest.?);

    const launch = try h.callRaw("launch", "{\"program\":\"/w/zig-out/bin/app\"}");
    defer launch.deinit();
    try expectOk(launch);
    try h.log.waitFor("event:initialized");

    const bps = try h.call(.setBreakpoints, .{ .source = .{ .path = "/w/src/main.zig" }, .breakpoints = &.{.{ .line = 5 }} });
    defer bps.deinit();
    try expectOk(bps);
    try testing.expect(bps.ok.value.breakpoints[0].verified);
    const cd = try h.call(.configurationDone, .{});
    defer cd.deinit();
    try expectOk(cd);
    try h.log.waitFor("event:stopped");

    const threads = try h.call(.threads, {});
    defer threads.deinit();
    try testing.expectEqualStrings("main", threads.ok.value.threads[0].name);
    const st = try h.call(.stackTrace, .{ .threadId = 1 });
    defer st.deinit();
    try testing.expectEqual(@as(i64, 5), st.ok.value.stackFrames[0].line);
    const cont = try h.call(.@"continue", .{ .threadId = 1 });
    defer cont.deinit();
    try testing.expect(cont.ok.value.allThreadsContinued.?);
    try h.log.waitFor("event:terminated");
    const disc = try h.call(.disconnect, .{});
    defer disc.deinit();
    try expectOk(disc);

    try h.log.expectSequence(&.{
        "response:initialize",        "event:initialized",   "response:setBreakpoints",
        "response:configurationDone", "event:process",       "event:stopped",
        "response:threads",           "response:stackTrace", "response:continue",
        "event:continued",            "event:exited",        "event:terminated",
        "response:disconnect",
    });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

test "dap: events and responses delivered in wire order" {
    // `continue` answers and then sends `continued` and `exited` in the
    // same burst; the response must be handled first.
    var h: Harness = undefined;
    try h.init("launch_stop_continue.dapt", .stdio, .{});
    defer h.deinit();
    try h.conn.start();
    (try h.call(.initialize, .{ .adapterID = "fake", .linesStartAt1 = true })).deinit();
    (try h.callRaw("launch", "{\"program\":\"/w/zig-out/bin/app\"}")).deinit();
    (try h.call(.setBreakpoints, .{ .source = .{ .path = "/w/src/main.zig" }, .breakpoints = &.{.{ .line = 5 }} })).deinit();
    (try h.call(.configurationDone, .{})).deinit();
    try h.log.waitFor("event:stopped");
    (try h.call(.threads, {})).deinit();
    (try h.call(.stackTrace, .{ .threadId = 1 })).deinit();
    // Not waiting: the callback and the events race only if ordering is broken.
    var w: Wait(.@"continue") = .{ .io = h.rt.io, .log = &h.log };
    _ = try h.conn.request(.@"continue", .{ .threadId = 1 }, .{ .ctx = &w, .func = Wait(.@"continue").done });
    try h.log.waitFor("event:terminated");
    (try w.wait()).deinit();
    h.log.mutex.lockUncancelable(h.log.io);
    var at: ?usize = null;
    for (0..h.log.n) |i| if (std.mem.eql(u8, h.log.get(i), "response:continue")) {
        at = i;
    };
    try testing.expectEqualStrings("event:continued", h.log.get(at.? + 1));
    h.log.mutex.unlock(h.log.io);
    (try h.call(.disconnect, .{})).deinit();
}

test "dap: error response with format variables, unknown reverse request" {
    var h: Harness = undefined;
    try h.init("conn_errors.dapt", .stdio, .{});
    defer h.deinit();
    try h.conn.start();
    (try h.call(.initialize, .{ .adapterID = "fake" })).deinit();
    const launch = try h.call(.launch, .{});
    defer launch.deinit();
    try testing.expect(launch == .failed);
    try testing.expectEqualStrings("failed", launch.failed.response.message.?);
    try testing.expectEqual(@as(i64, 3), launch.failed.response.error_body.?.id);
    try testing.expectEqualStrings("cannot open /w/app: ENOENT", launch.failed.errorText());
    // The script checks our `not supported` answer to startDebugging
    // before it accepts `disconnect`.
    (try h.call(.disconnect, .{})).deinit();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

const Terminal = struct {
    fn runInTerminal(_: ?*anyopaque, c: *DapConnection, req: DapConnection.ReverseRequest, arena: std.mem.Allocator) void {
        const Args = struct { args: []const []const u8 };
        const a = req.arguments.?.parseLeaky(Args, arena, .{}) catch {
            c.respond(req.seq, req.command, false, null, "bad arguments") catch {};
            return;
        };
        std.debug.assert(std.mem.eql(u8, a.args[0], "/w/zig-out/bin/app"));
        c.respond(req.seq, req.command, true, "{\"processId\":4242}", null) catch {};
    }
};

test "dap: reverse runInTerminal handled and responded with our seq" {
    var h: Harness = undefined;
    try h.init("run_in_terminal.dapt", .stdio, .{});
    defer h.deinit();
    try h.conn.onReverseRequest("runInTerminal", .{ .ctx = null, .func = Terminal.runInTerminal });
    try h.conn.start();
    (try h.call(.initialize, .{ .adapterID = "fake", .supportsRunInTerminalRequest = true })).deinit();
    const launch = try h.callRaw("launch", "{\"console\":\"integratedTerminal\"}");
    defer launch.deinit();
    try expectOk(launch);
    try h.log.waitFor("event:initialized");
    (try h.call(.configurationDone, .{})).deinit();
    try h.log.waitFor("event:process");
    (try h.call(.disconnect, .{})).deinit();
    // The fake checks request_seq of our response and that our seq kept
    // increasing across requests and the response.
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

test "dap: cancel sends cancel and still resolves" {
    var h: Harness = undefined;
    try h.init("conn_cancel.dapt", .stdio, .{});
    defer h.deinit();
    try h.conn.start();
    const caps = try h.call(.initialize, .{ .adapterID = "fake" });
    h.conn.setSupportsCancel(caps.ok.value.supportsCancelRequest orelse false);
    caps.deinit();
    var w: Wait(.evaluate) = .{ .io = h.rt.io, .log = &h.log };
    const seq = try h.conn.request(.evaluate, .{ .expression = "slow()" }, .{ .ctx = &w, .func = Wait(.evaluate).done });
    try testing.expectEqual(@as(u32, 2), seq);
    h.conn.cancel(seq);
    const r = try w.wait();
    defer r.deinit();
    try testing.expectEqualStrings("cancelled", r.failed.response.message.?);
    (try h.call(.disconnect, .{})).deinit();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

test "dap: tcp transport against fake adapter --tcp" {
    var h: Harness = undefined;
    try h.init("attach.dapt", .tcp_listen_child, .{});
    defer h.deinit();
    try h.conn.start();
    (try h.call(.initialize, .{ .adapterID = "fake" })).deinit();
    const attach = try h.callRaw("attach", "{\"pid\":4242}");
    defer attach.deinit();
    try expectOk(attach);
    try h.log.waitFor("event:initialized");
    (try h.call(.configurationDone, .{})).deinit();
    try h.log.waitFor("event:thread");
    (try h.call(.disconnect, .{ .terminateDebuggee = false })).deinit();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

test "dap: close fails pending with .closed" {
    var h: Harness = undefined;
    try h.init("conn_hang.dapt", .stdio, .{});
    defer h.deinit();
    var closed = false;
    h.conn.onClose(.{ .ctx = &closed, .func = struct {
        fn f(ctx: ?*anyopaque, _: *DapConnection) void {
            const p: *bool = @ptrCast(@alignCast(ctx.?));
            p.* = true;
        }
    }.f });
    try h.conn.start();
    (try h.call(.initialize, .{ .adapterID = "fake" })).deinit();
    var w: Wait(.threads) = .{ .io = h.rt.io, .log = &h.log };
    _ = try h.conn.request(.threads, {}, .{ .ctx = &w, .func = Wait(.threads).done });
    try h.rt.io.sleep(.fromMilliseconds(50), .awake);
    h.conn.close();
    try testing.expect((try w.wait()) == .closed);
    try testing.expect(closed);
    try testing.expectError(error.ConnectionClosed, h.conn.request(.threads, {}, .{ .ctx = &w, .func = Wait(.threads).done }));
}

test "dap: timeout then late response dropped" {
    var h: Harness = undefined;
    try h.init("conn_timeout.dapt", .stdio, .{ .timeouts = .{ .default = .fromMilliseconds(100) } });
    defer h.deinit();
    try h.conn.start();
    (try h.call(.initialize, .{ .adapterID = "fake" })).deinit();
    try testing.expect((try h.call(.threads, {})) == .timeout);
    // The late `threads` response arrives first and is dropped.
    try h.rt.io.sleep(.fromMilliseconds(300), .awake);
    const disc = try h.call(.disconnect, .{});
    defer disc.deinit();
    try expectOk(disc);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

test "dap: adapter exit fails pending and closes" {
    var h: Harness = undefined;
    try h.init("crash.dapt", .stdio, .{});
    defer h.deinit();
    try h.conn.start();
    (try h.call(.initialize, .{ .adapterID = "fake" })).deinit();
    (try h.callRaw("launch", null)).deinit();
    (try h.call(.configurationDone, .{})).deinit();
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, try h.exitStatus());
    // After end of input every request fails at once or with .closed.
    for (0..500) |_| {
        if (h.conn.finished.load(.acquire)) break;
        try h.rt.io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expectError(error.ConnectionClosed, h.call(.threads, {}));
    try h.log.waitFor("event:output");
}
