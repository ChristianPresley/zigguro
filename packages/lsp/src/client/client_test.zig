const std = @import("std");
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const Client = @import("Client.zig");
const ServerProcess = @import("ServerProcess.zig");
const protocol = @import("../gen/protocol.zig");
const testing = std.testing;
const Io = std.Io;

const fake = test_exes.fake_lsp_server;
const workspace = "/w";

/// A fake server playing `script`, and a client for it.
pub const Harness = struct {
    rt: zg_core.Runtime,
    proc: *ServerProcess,
    client: *Client,
    path_buf: [std.fs.max_path_bytes]u8,

    pub fn init(h: *Harness, script: []const u8, ctx: Client.InitContext) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        try h.initPath(try std.fmt.bufPrint(&buf, "{s}/testdata/transcripts/{s}", .{ options.package_root, script }), ctx);
    }

    /// Like `init`, with the script's full path.
    pub fn initPath(h: *Harness, script_path: []const u8, ctx: Client.InitContext) !void {
        h.rt.initTesting();
        errdefer _ = h.rt.deinit();
        const path = h.path_buf[0..script_path.len];
        @memcpy(path, script_path);
        h.proc = try ServerProcess.start(&h.rt, .{
            .argv = &.{ fake, "--script", path, "--workspace", workspace },
            .name = "fake",
        }, null, ServerProcess.default_stderr_cap);
        errdefer h.proc.deinit();
        h.client = try Client.create(&h.rt, h.proc, ctx);
    }

    pub fn deinit(h: *Harness) void {
        h.client.deinit();
        h.proc.deinit();
        _ = h.rt.deinit();
    }

    /// Waits for the server to exit and returns its status.
    pub fn exitStatus(h: *Harness) !std.process.Child.Term {
        try h.proc.exitEvent().waitTimeout(h.rt.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
        return h.proc.exitStatus().?;
    }

    /// The fake server's stderr, for failure messages.
    pub fn dumpStderr(h: *Harness) void {
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(testing.allocator);
        h.proc.stderrTail(&tail, 20) catch return;
        std.debug.print("fake server stderr:\n{s}\n", .{tail.items});
    }
};

fn hoverParams(line: u32, character: u32) protocol.HoverParams {
    return .{ .textDocument = .{ .uri = "file:///w/main.zig" }, .position = .{ .line = line, .character = character } };
}

const zig_doc: @import("doc_selector.zig").DocMatch = .{ .language_id = "zig", .scheme = "file", .path = "/w/main.zig" };

/// Collects the async result of one request.
fn Collect(comptime M: protocol.Method) type {
    return struct {
        event: Io.Event = .unset,
        result: ?Client.Result(M) = null,
        io: Io,

        fn cb(c: *@This()) Client.ResultCb(M) {
            return .{ .ctx = c, .func = done };
        }

        fn done(ctx: ?*anyopaque, r: Client.Result(M)) void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.result = r;
            c.event.set(c.io);
        }

        fn wait(c: *@This()) !Client.Result(M) {
            try c.event.waitTimeout(c.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
            return c.result.?;
        }
    };
}

/// Records state changes.
const States = struct {
    mutex: Io.Mutex = .init,
    seen: [16]Client.ClientState = undefined,
    n: usize = 0,
    io: Io,

    fn listener(s: *States) Client.ClientListener {
        return .{ .ctx = s, .on_state = onState };
    }

    fn onState(ctx: ?*anyopaque, _: *Client, st: Client.ClientState) void {
        const s: *States = @ptrCast(@alignCast(ctx.?));
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.n < s.seen.len) s.seen[s.n] = st;
        s.n += 1;
    }

    fn items(s: *States) []const Client.ClientState {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.seen[0..s.n];
    }
};

test "client: handshake, queued request, unsupported, shutdown" {
    var h: Harness = undefined;
    try h.init("client_lifecycle.script", .{ .root_uri = "file:///w" });
    defer h.deinit();
    errdefer h.dumpStderr();
    var states: States = .{ .io = h.rt.io };
    try h.client.subscribe(states.listener());

    try h.client.start();
    try testing.expectEqual(Client.ClientState.initializing, h.client.state());
    // Queued: the server sleeps before answering `initialize`.
    var first: Collect(.@"textDocument/hover") = .{ .io = h.rt.io };
    _ = try h.client.request(.@"textDocument/hover", hoverParams(0, 6), .{ .doc = zig_doc }, first.cb());
    try h.client.waitInitialized(.fromSeconds(10));
    try testing.expectEqual(Client.ClientState.running, h.client.state());
    try testing.expectEqual(.utf8, h.client.encoding());
    try testing.expectEqualStrings("fake", h.client.serverInfo().?.name);
    try testing.expectEqualStrings("1.0", h.client.serverInfo().?.version.?);

    const r1 = try first.wait();
    defer r1.deinit();
    try testing.expectEqualStrings("hover text", r1.ok.value.?.contents.markup_content.value);

    // No definitionProvider: rejected without wire traffic (the script
    // would fail on an unexpected request).
    const def = try h.client.requestBlocking(.@"textDocument/definition", .{
        .textDocument = .{ .uri = "file:///w/main.zig" },
        .position = .{ .line = 0, .character = 0 },
    }, .{ .doc = zig_doc });
    try testing.expect(def == .unsupported);

    const r2 = try h.client.requestBlocking(.@"textDocument/hover", hoverParams(1, 0), .{ .doc = zig_doc });
    defer r2.deinit();
    try testing.expect(r2.ok.value == null);

    h.client.shutdown();
    try testing.expectEqual(Client.ClientState.stopped, h.client.state());
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
    try testing.expectEqualSlices(Client.ClientState, &.{ .initializing, .running, .shutting_down, .stopped }, states.items());

    // Requests after shutdown fail at once.
    const late = try h.client.requestBlocking(.@"textDocument/hover", hoverParams(0, 0), .{});
    try testing.expect(late == .server_gone);

    // The trace saw the handshake in order.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const snap = try h.client.traceRing().snapshot(arena.allocator());
    try testing.expectEqualStrings("initialize", snap[0].method);
    try testing.expectEqualStrings("initialize", snap[1].method);
    try testing.expectEqualStrings("initialized", snap[2].method);
    try testing.expectEqualStrings("exit", snap[snap.len - 1].method);
}

test "client: error mapping and timeout" {
    var h: Harness = undefined;
    try h.init("client_errors.script", .{});
    defer h.deinit();
    errdefer h.dumpStderr();
    try h.client.start();
    try h.client.waitInitialized(.fromSeconds(10));
    // clangd's legacy `offsetEncoding`.
    try testing.expectEqual(.utf8, h.client.encoding());

    const M = .@"textDocument/hover";
    const modified = try h.client.requestBlocking(M, hoverParams(0, 0), .{});
    try testing.expect(modified == .content_modified);
    const canceled = try h.client.requestBlocking(M, hoverParams(0, 0), .{});
    try testing.expect(canceled == .canceled);
    const failed = try h.client.requestBlocking(M, hoverParams(0, 0), .{});
    defer failed.deinit();
    try testing.expectEqual(@as(i32, -32603), failed.lsp_error.code);
    try testing.expectEqualStrings("boom", failed.lsp_error.message);
    const bad = try h.client.requestBlocking(M, hoverParams(0, 0), .{});
    defer bad.deinit();
    try testing.expectEqual(zg_jsonrpc.message.ErrorCode.parse_error.int(), bad.lsp_error.code);

    const slow = try h.client.requestBlocking(.@"textDocument/definition", .{
        .textDocument = .{ .uri = "file:///w/main.zig" },
        .position = .{ .line = 0, .character = 0 },
    }, .{ .timeout = .fromMilliseconds(100) });
    try testing.expect(slow == .timeout);

    h.client.shutdown();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

/// Counts `test/ready` notifications.
pub const Ready = struct {
    event: Io.Event = .unset,
    step: std.atomic.Value(u32) = .init(0),
    io: Io,

    pub fn onReady(ctx: ?*anyopaque, _: *zg_jsonrpc.Endpoint, _: zg_jsonrpc.message.Notification, _: std.mem.Allocator) void {
        const r: *Ready = @ptrCast(@alignCast(ctx.?));
        _ = r.step.fetchAdd(1, .acq_rel);
        r.event.set(r.io);
    }

    pub fn waitStep(r: *Ready, n: u32) !void {
        while (r.step.load(.acquire) < n) {
            try r.event.waitTimeout(r.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
            r.event.reset();
        }
    }
};

test "client: dynamic registration and configuration" {
    var ready: Ready = .{ .io = undefined };
    var h: Harness = undefined;
    try h.init("client_registration.script", .{
        .notification_handlers = &.{.{ .method = "test/ready", .handler = .{ .ctx = &ready, .func = Ready.onReady } }},
    });
    defer h.deinit();
    errdefer h.dumpStderr();
    ready.io = h.rt.io;
    try h.client.start();
    try h.client.waitInitialized(.fromSeconds(10));

    const fmt = protocol.DocumentFormattingParams{
        .textDocument = .{ .uri = "file:///w/a.zig" },
        .options = .{ .tabSize = 4, .insertSpaces = true },
    };
    const c_doc: @import("doc_selector.zig").DocMatch = .{ .language_id = "c", .scheme = "file", .path = "/w/a.c" };
    const M = .@"textDocument/formatting";
    try testing.expect((try h.client.requestBlocking(M, fmt, .{ .doc = zig_doc })) == .unsupported);
    // The script holds the registration until this arrives, so the check
    // above cannot race it.
    try h.client.notify(.@"$/setTrace", .{ .value = .Off });

    try ready.waitStep(1);
    try testing.expect((try h.client.requestBlocking(M, fmt, .{ .doc = c_doc })) == .unsupported);
    const ok = try h.client.requestBlocking(M, fmt, .{ .doc = zig_doc });
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 0), ok.ok.value.?.len);

    try ready.waitStep(2);
    try testing.expect((try h.client.requestBlocking(M, fmt, .{ .doc = zig_doc })) == .unsupported);

    h.client.shutdown();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

test "client: crash" {
    var h: Harness = undefined;
    try h.init("crash.script", .{});
    defer h.deinit();
    var states: States = .{ .io = h.rt.io };
    try h.client.subscribe(states.listener());
    try h.client.start();
    try h.client.waitInitialized(.fromSeconds(10));
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, try h.exitStatus());
    // The reader sees end of input shortly after the exit.
    for (0..500) |_| {
        if (h.client.state() == .crashed) break;
        try h.rt.io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expectEqual(Client.ClientState.crashed, h.client.state());
    const r = try h.client.requestBlocking(.@"textDocument/hover", hoverParams(0, 0), .{});
    try testing.expect(r == .server_gone);
    // Shutting down a crashed client only reaps the process.
    h.client.shutdown();
    try testing.expectEqual(Client.ClientState.crashed, h.client.state());
}

test "client: server gone during initialize" {
    var h: Harness = undefined;
    try h.init("crash.script", .{});
    defer h.deinit();
    // Kill the server before it answers.
    h.proc.terminate(.fromMilliseconds(0));
    h.client.start() catch {};
    try testing.expectError(error.ServerGone, h.client.waitInitialized(.fromSeconds(10)));
}

test "client: server exits before answering initialize" {
    // The fake server fails on the missing rootUri and exits; the failed
    // handshake must leave closing the endpoint to deinit.
    var h: Harness = undefined;
    try h.init("handshake.script", .{});
    defer h.deinit();
    try h.client.start();
    try testing.expectError(error.ServerGone, h.client.waitInitialized(.fromSeconds(10)));
    try testing.expectEqual(std.process.Child.Term{ .exited = 99 }, try h.exitStatus());
}

/// The client-visible results of the lifecycle session.
const LifecycleResults = struct {
    server: []const u8,
    first: []const u8,
    second_null: bool,
};

fn runLifecycle(h: *Harness, arena: std.mem.Allocator) !LifecycleResults {
    try h.client.start();
    try h.client.waitInitialized(.fromSeconds(10));
    const r1 = try h.client.requestBlocking(.@"textDocument/hover", hoverParams(0, 6), .{ .doc = zig_doc });
    defer r1.deinit();
    const r2 = try h.client.requestBlocking(.@"textDocument/hover", hoverParams(1, 0), .{ .doc = zig_doc });
    defer r2.deinit();
    const out: LifecycleResults = .{
        .server = try arena.dupe(u8, h.client.serverInfo().?.name),
        .first = try arena.dupe(u8, r1.ok.value.?.contents.markup_content.value),
        .second_null = r2.ok.value == null,
    };
    h.client.shutdown();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
    return out;
}

test "transcript: to-script round trip replays to identical client results" {
    const transcript = @import("transcript.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx: Client.InitContext = .{ .root_uri = "file:///w", .trace_bodies = true };

    // Record a session against the hand-written script.
    var dumped: Io.Writer.Allocating = .init(a);
    const want = blk: {
        var h: Harness = undefined;
        try h.init("client_lifecycle.script", ctx);
        defer h.deinit();
        errdefer h.dumpStderr();
        const r = try runLifecycle(&h, a);
        try h.client.traceRing().dump(a, &dumped.writer);
        break :blk r;
    };

    // Turn the trace into a script and replay it.
    var bad: usize = 0;
    const lines = try transcript.normalize(a, try transcript.parse(a, dumped.written(), &bad), null);
    var script: Io.Writer.Allocating = .init(a);
    try transcript.toScript(a, lines, &script.writer);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "replay.script", .data = script.written() });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    var h: Harness = undefined;
    try h.initPath(try std.fs.path.join(a, &.{ dir, "replay.script" }), ctx);
    defer h.deinit();
    errdefer {
        h.dumpStderr();
        std.debug.print("replayed script:\n{s}\n", .{script.written()});
    }
    const got = try runLifecycle(&h, a);
    try testing.expectEqualStrings(want.server, got.server);
    try testing.expectEqualStrings(want.first, got.first);
    try testing.expectEqual(want.second_null, got.second_null);
    try testing.expect(std.mem.indexOf(u8, script.written(), "> initialize {\"rootUri\":\"file://${workspace}\"}") != null);
}
