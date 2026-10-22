//! Tests of `fake_dap_adapter` with a raw DAP client (no DapConnection),
//! so the fake can be trusted by the connection and session tests.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_jsonrpc = @import("zg_jsonrpc");
const zg_lsp = @import("zg_lsp");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const ServerProcess = zg_lsp.client.ServerProcess;
const Value = std.json.Value;
const testing = std.testing;

const fake = test_exes.fake_dap_adapter;
const workspace = "/w";

fn scriptPath(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/testdata/scripts/{s}", .{ options.package_root, name }) catch unreachable;
}

/// A minimal DAP client over a transport: numbered requests, raw frames.
const Raw = struct {
    gpa: std.mem.Allocator,
    t: *zg_lsp.transport.Transport,
    frames: zg_jsonrpc.framing.ContentLengthReader,
    arena: std.heap.ArenaAllocator,
    seq: i64 = 1,

    fn init(r: *Raw, t: *zg_lsp.transport.Transport) void {
        r.* = .{ .gpa = testing.allocator, .t = t, .frames = .init(t.reader, .{}), .arena = .init(testing.allocator) };
    }

    fn deinit(r: *Raw) void {
        r.frames.deinit(r.gpa);
        r.arena.deinit();
    }

    fn write(r: *Raw, body: []const u8) !void {
        try zg_jsonrpc.framing.writeContentLength(r.t.writer, body);
        try r.t.writer.flush();
    }

    /// Sends request `command` with `args` (JSON text or "") and returns its seq.
    fn request(r: *Raw, command: []const u8, args: []const u8) !i64 {
        const seq = r.seq;
        r.seq += 1;
        var buf: [4096]u8 = undefined;
        const body = if (args.len > 0)
            try std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{s}}}", .{ seq, command, args })
        else
            try std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\"}}", .{ seq, command });
        try r.write(body);
        return seq;
    }

    /// Answers reverse request `request_seq`.
    fn respond(r: *Raw, request_seq: i64, command: []const u8, body_json: []const u8) !void {
        const seq = r.seq;
        r.seq += 1;
        var buf: [4096]u8 = undefined;
        try r.write(try std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"type\":\"response\",\"request_seq\":{d},\"command\":\"{s}\",\"success\":true,\"body\":{s}}}", .{ seq, request_seq, command, body_json }));
    }

    /// The next message; null at end of input.
    fn next(r: *Raw) !?std.json.ObjectMap {
        const body = r.frames.next(r.gpa) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        const v = try std.json.parseFromSliceLeaky(Value, r.arena.allocator(), body, .{});
        return v.object;
    }

    fn expectResponse(r: *Raw, request_seq: i64, command: []const u8) !std.json.ObjectMap {
        const m = (try r.next()) orelse return error.EndOfStream;
        try testing.expectEqualStrings("response", m.get("type").?.string);
        try testing.expectEqualStrings(command, m.get("command").?.string);
        try testing.expectEqual(request_seq, m.get("request_seq").?.integer);
        try testing.expect(m.get("success").?.bool);
        return m;
    }

    fn expectEvent(r: *Raw, event: []const u8) !std.json.ObjectMap {
        const m = (try r.next()) orelse return error.EndOfStream;
        try testing.expectEqualStrings("event", m.get("type").?.string);
        try testing.expectEqualStrings(event, m.get("event").?.string);
        return m;
    }
};

fn startFake(rt: *zg_core.Runtime, script: []const u8, buf: []u8) !*ServerProcess {
    return ServerProcess.start(rt, .{
        .argv = &.{ fake, "--script", scriptPath(buf, script), "--workspace", workspace },
        .name = "fake_dap_adapter",
    }, null, ServerProcess.default_stderr_cap);
}

fn waitExit(rt: *zg_core.Runtime, p: *ServerProcess) !std.process.Child.Term {
    try p.exitEvent().waitTimeout(rt.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    return p.exitStatus().?;
}

test "fake_adapter: launch, initialized, setBreakpoints, configurationDone, stopped" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try startFake(&rt, "launch_stop_continue.dapt", &buf);
    defer p.deinit();
    var r: Raw = undefined;
    r.init(p.transport());
    defer r.deinit();

    const init_seq = try r.request("initialize", "{\"adapterID\":\"fake\",\"linesStartAt1\":true}");
    const caps = try r.expectResponse(init_seq, "initialize");
    try testing.expect(caps.get("body").?.object.get("supportsConfigurationDoneRequest").?.bool);
    const launch = try r.request("launch", "{\"program\":\"/w/zig-out/bin/app\"}");
    _ = try r.expectResponse(launch, "launch");
    _ = try r.expectEvent("initialized");
    const bp = try r.request("setBreakpoints", "{\"source\":{\"path\":\"/w/src/main.zig\"},\"breakpoints\":[{\"line\":5}]}");
    const bps = try r.expectResponse(bp, "setBreakpoints");
    try testing.expect(bps.get("body").?.object.get("breakpoints").?.array.items[0].object.get("verified").?.bool);
    _ = try r.expectResponse(try r.request("configurationDone", ""), "configurationDone");
    _ = try r.expectEvent("process");
    const stopped = try r.expectEvent("stopped");
    try testing.expectEqualStrings("breakpoint", stopped.get("body").?.object.get("reason").?.string);
    _ = try r.expectResponse(try r.request("threads", ""), "threads");
    const st = try r.expectResponse(try r.request("stackTrace", "{\"threadId\":1}"), "stackTrace");
    const frame = st.get("body").?.object.get("stackFrames").?.array.items[0].object;
    try testing.expectEqualStrings("/w/src/main.zig", frame.get("source").?.object.get("path").?.string);
    _ = try r.expectResponse(try r.request("continue", "{\"threadId\":1}"), "continue");
    _ = try r.expectEvent("continued");
    try testing.expectEqual(@as(i64, 0), (try r.expectEvent("exited")).get("body").?.object.get("exitCode").?.integer);
    _ = try r.expectEvent("terminated");
    _ = try r.expectResponse(try r.request("disconnect", ""), "disconnect");
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try waitExit(&rt, p));
}

test "fake_adapter: reverse request runInTerminal round trip" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try startFake(&rt, "run_in_terminal.dapt", &buf);
    defer p.deinit();
    var r: Raw = undefined;
    r.init(p.transport());
    defer r.deinit();

    _ = try r.expectResponse(try r.request("initialize", "{\"adapterID\":\"fake\",\"supportsRunInTerminalRequest\":true}"), "initialize");
    const launch = try r.request("launch", "{\"console\":\"integratedTerminal\"}");
    const rev = (try r.next()).?;
    try testing.expectEqualStrings("request", rev.get("type").?.string);
    try testing.expectEqualStrings("runInTerminal", rev.get("command").?.string);
    const args = rev.get("arguments").?.object;
    try testing.expectEqualStrings("/w/zig-out/bin/app", args.get("args").?.array.items[0].string);
    try r.respond(rev.get("seq").?.integer, "runInTerminal", "{\"processId\":4242}");
    _ = try r.expectResponse(launch, "launch");
    _ = try r.expectEvent("initialized");
    _ = try r.expectResponse(try r.request("configurationDone", ""), "configurationDone");
    try testing.expectEqual(@as(i64, 4242), (try r.expectEvent("process")).get("body").?.object.get("systemProcessId").?.integer);
    _ = try r.expectResponse(try r.request("disconnect", ""), "disconnect");
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try waitExit(&rt, p));
}

test "fake_adapter: tcp mode readiness line and connect" {
    const io = testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var child = try std.process.spawn(io, .{
        .argv = &.{ fake, "--script", scriptPath(&buf, "attach.dapt"), "--tcp", "0" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);
    var line_buf: [128]u8 = undefined;
    var out = child.stdout.?.readerStreaming(io, &line_buf);
    const line = try out.interface.takeDelimiterExclusive('\n');
    try testing.expect(std.mem.startsWith(u8, line, "listening "));
    const port = try std.fmt.parseInt(u16, line["listening ".len..], 10);
    try testing.expect(port != 0);

    const t = try zg_lsp.transport.tcp.TcpTransport.connect(testing.allocator, io, "127.0.0.1", port, .{});
    defer t.transport.deinit();
    var r: Raw = undefined;
    r.init(&t.transport);
    defer r.deinit();
    _ = try r.expectResponse(try r.request("initialize", "{\"adapterID\":\"fake\"}"), "initialize");
    _ = try r.expectResponse(try r.request("attach", "{\"pid\":4242}"), "attach");
    _ = try r.expectEvent("initialized");
    _ = try r.expectResponse(try r.request("configurationDone", ""), "configurationDone");
    _ = try r.expectEvent("process");
    _ = try r.expectEvent("thread");
    _ = try r.expectResponse(try r.request("disconnect", "{\"terminateDebuggee\":false}"), "disconnect");
    reaped = true;
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "fake_adapter: client seq regression detected" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try startFake(&rt, "attach.dapt", &buf);
    defer p.deinit();
    var r: Raw = undefined;
    r.init(p.transport());
    defer r.deinit();
    _ = try r.expectResponse(try r.request("initialize", "{\"adapterID\":\"fake\"}"), "initialize");
    r.seq = 1; // a client bug: seq goes back
    _ = try r.request("attach", "{\"pid\":4242}");
    try testing.expectEqual(std.process.Child.Term{ .exited = 99 }, try waitExit(&rt, p));
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(testing.allocator);
    for (0..500) |_| {
        tail.clearRetainingCapacity();
        try p.stderrTail(&tail, 10);
        if (std.mem.indexOf(u8, tail.items, "seq regression") != null) break;
        try rt.io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(std.mem.indexOf(u8, tail.items, "seq regression") != null);
}

test "fake_adapter: crash exit observed" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try startFake(&rt, "crash.dapt", &buf);
    defer p.deinit();
    var r: Raw = undefined;
    r.init(p.transport());
    defer r.deinit();
    _ = try r.expectResponse(try r.request("initialize", "{\"adapterID\":\"fake\"}"), "initialize");
    _ = try r.expectResponse(try r.request("launch", ""), "launch");
    _ = try r.expectEvent("initialized");
    _ = try r.expectResponse(try r.request("configurationDone", ""), "configurationDone");
    _ = try r.expectEvent("output");
    try testing.expect((try r.next()) == null);
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, try waitExit(&rt, p));
}

test "fake_adapter: every seed script parses" {
    const names = [_][]const u8{
        "launch_stop_continue.dapt", "attach.dapt",    "breakpoints_verified_later.dapt", "run_in_terminal.dapt",
        "start_debugging.dapt",      "terminate.dapt", "variables_paging.dapt",           "crash.dapt",
    };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (names) |n| {
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, scriptPath(&buf, n), testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(text);
        var d: zg_lsp.testing.script.ParseDiag = .{};
        var s = zg_lsp.testing.script.Script.parse(testing.allocator, text, &d) catch |err| {
            std.debug.print("{s}:{d}: {s}\n", .{ n, d.line, d.msg });
            return err;
        };
        s.deinit();
    }
}
