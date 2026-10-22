const std = @import("std");
const builtin = @import("builtin");
const script = @import("script.zig");
const zg_jsonrpc = @import("zg_jsonrpc");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const testing = std.testing;
const Value = std.json.Value;

test "script: parse all directives" {
    const text =
        "# comment\r\n" ++
        "strict\r\n" ++
        "\r\n" ++
        "> initialize {\"processId\": null}\r\n" ++
        "> initialized\n" ++
        "< {\"id\": $1, \"result\": {\"root\": \"${workspace}\"}}\n" ++
        "< event stopped {\"reason\": \"step\"}\n" ++
        "< event terminated\n" ++
        "~ 50ms\n" ++
        "! exit 3\n";
    var s = try script.Script.parse(testing.allocator, text, null);
    defer s.deinit();
    try testing.expect(s.strict);
    try testing.expectEqual(@as(usize, 7), s.steps.len);
    try testing.expectEqualStrings("initialize", s.steps[0].expect.method);
    try testing.expectEqual(@as(u32, 4), s.steps[0].expect.line);
    try testing.expect(s.steps[0].expect.params_subset.?.object.get("processId").? == .null);
    try testing.expect(s.steps[1].expect.params_subset == null);
    try testing.expect(std.mem.indexOf(u8, s.steps[2].reply.text, "$1") != null);
    try testing.expectEqualStrings("stopped", s.steps[3].event.name);
    try testing.expect(s.steps[3].event.body != null);
    try testing.expect(s.steps[4].event.body == null);
    try testing.expectEqual(@as(u32, 50), s.steps[5].delay_ms);
    try testing.expectEqual(@as(u8, 3), s.steps[6].exit);
}

test "script: line numbers in errors" {
    const cases = [_]struct { text: []const u8, line: u32 }{
        .{ .text = "> initialize\n> hover {bad json}\n", .line = 2 },
        .{ .text = "\n\n< {\"id\": $1,}\n", .line = 3 },
        .{ .text = "~ 5s\n", .line = 1 },
        .{ .text = "> a\n! quit\n", .line = 2 },
        .{ .text = "? what\n", .line = 1 },
        .{ .text = ">initialize\n", .line = 1 },
        .{ .text = "> a\n> b\n! exit 300\n", .line = 3 },
    };
    for (cases) |c| {
        var d: script.ParseDiag = .{};
        try testing.expectError(error.InvalidScript, script.Script.parse(testing.allocator, c.text, &d));
        try testing.expectEqual(c.line, d.line);
        try testing.expect(d.msg.len > 0);
    }
}

test "script: seed transcripts parse" {
    const io = testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "testdata/transcripts", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".script")) continue;
        const text = try dir.readFileAlloc(io, e.name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(text);
        var d: script.ParseDiag = .{};
        var s = script.Script.parse(testing.allocator, text, &d) catch |err| {
            std.debug.print("{s}:{d}: {s}\n", .{ e.name, d.line, d.msg });
            return err;
        };
        s.deinit();
        n += 1;
    }
    try testing.expect(n >= 6);
}

fn parseValue(arena: std.mem.Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "subsetMatch: nested objects/arrays/extra fields/type mismatch paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const actual = try parseValue(a,
        \\{"textDocument": {"uri": "file:///a.zig", "version": 3}, "position": {"line": 1, "character": 2.0},
        \\ "items": [{"label": "x", "kind": 1}, {"label": "y"}], "flag": true, "nothing": null}
    );
    const ok = [_][]const u8{
        "{}",
        \\{"textDocument": {"uri": "file:///a.zig"}}
        ,
        \\{"position": {"character": 2}}
        ,
        \\{"items": [{"label": "x"}, {}], "flag": true, "nothing": null}
        ,
    };
    for (ok) |e| try testing.expect(script.subsetMatch(try parseValue(a, e), actual) == null);

    const bad = [_]struct { e: []const u8, path: []const u8, missing: bool = false }{
        .{ .e = "{\"textDocument\": {\"version\": 4}}", .path = "$.textDocument.version" },
        .{ .e = "{\"textDocument\": {\"languageId\": \"zig\"}}", .path = "$.textDocument.languageId", .missing = true },
        .{ .e = "{\"items\": [{\"label\": \"x\"}]}", .path = "$.items" },
        .{ .e = "{\"items\": [{}, {\"label\": \"z\"}]}", .path = "$.items[1].label" },
        .{ .e = "{\"flag\": \"true\"}", .path = "$.flag" },
        .{ .e = "{\"position\": [1, 2]}", .path = "$.position" },
        .{ .e = "{\"nothing\": 0}", .path = "$.nothing" },
        .{ .e = "[]", .path = "$" },
    };
    for (bad) |c| {
        const m = script.subsetMatch(try parseValue(a, c.e), actual) orelse return error.TestExpectedMismatch;
        try testing.expectEqualStrings(c.path, m.path());
        try testing.expectEqual(c.missing, m.actual == null);
    }
}

test "script: substitute ids and workspace" {
    const out = try script.substitute(testing.allocator, "{\"id\": $1, \"uri\": \"file://${workspace}/x\"}", "\"abc\"", "C:\\w \"q\"");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"id\": \"abc\", \"uri\": \"file://C:\\\\w \\\"q\\\"/x\"}", out);
}

/// Content-Length frames of `msgs`.
fn frames(gpa: std.mem.Allocator, msgs: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (msgs) |m| try out.writer.print("Content-Length: {d}\r\n\r\n{s}", .{ m.len, m });
    return out.toOwnedSlice();
}

/// Bodies of the Content-Length frames in `bytes`.
fn bodies(arena: std.mem.Allocator, bytes: []const u8) ![]Value {
    var r: std.Io.Reader = .fixed(bytes);
    var fr = zg_jsonrpc.framing.ContentLengthReader.init(&r, .{});
    defer fr.deinit(arena);
    var list: std.ArrayList(Value) = .empty;
    while (true) {
        const b = fr.next(arena) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try list.append(arena, try std.json.parseFromSliceLeaky(Value, arena, try arena.dupe(u8, b), .{}));
    }
    return list.items;
}

const Run = struct { status: u8, out: []Value, diag: []const u8 };

fn runInProcess(arena: std.mem.Allocator, text: []const u8, msgs: []const []const u8, framing: script.Framing) !Run {
    var s = try script.Script.parse(testing.allocator, text, null);
    defer s.deinit();
    const input = try frames(arena, msgs);
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(arena);
    var diag: std.Io.Writer.Allocating = .init(arena);
    const status = try script.runPeer(testing.io, testing.allocator, &s, &in, &out.writer, .{
        .framing = framing,
        .workspace = "/ws",
        .diag = &diag.writer,
    });
    return .{ .status = status, .out = try bodies(arena, out.written()), .diag = diag.written() };
}

test "runPeer: lsp handshake, skipped notifications, epilogue" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try runInProcess(arena.allocator(),
        \\> initialize {"rootUri": "file://${workspace}"}
        \\< {"id": $1, "result": {"capabilities": {}, "root": "${workspace}"}}
        \\> initialized
        \\< event window/logMessage {"type": 3, "message": "ready"}
    , &.{
        \\{"jsonrpc":"2.0","id":"a1","method":"initialize","params":{"processId":null,"rootUri":"file:///ws"}}
        ,
        \\{"jsonrpc":"2.0","method":"$/setTrace","params":{"value":"off"}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    }, .lsp);
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 4), r.out.len);
    const init_reply = r.out[0].object;
    try testing.expectEqualStrings("2.0", init_reply.get("jsonrpc").?.string);
    try testing.expectEqualStrings("a1", init_reply.get("id").?.string);
    try testing.expectEqualStrings("/ws", init_reply.get("result").?.object.get("root").?.string);
    try testing.expectEqualStrings("window/logMessage", r.out[1].object.get("method").?.string);
    try testing.expect(r.out[2].object.get("result").? == .null);
    try testing.expectEqual(@as(i64, -32601), r.out[3].object.get("error").?.object.get("code").?.integer);
}

test "runPeer: mismatch reports the path and exits 99" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try runInProcess(arena.allocator(),
        \\> initialize
        \\< {"id": $1, "result": {"capabilities": {}}}
        \\> textDocument/hover {"position": {"line": 4}}
    , &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"position":{"line":5,"character":0}}}
        ,
    }, .lsp);
    try testing.expectEqual(script.mismatch_status, r.status);
    try testing.expect(std.mem.indexOf(u8, r.diag, "line 3") != null);
    try testing.expect(std.mem.indexOf(u8, r.diag, "$.position.line") != null);
    try testing.expect(std.mem.indexOf(u8, r.diag, "expected: 4") != null);
    try testing.expect(std.mem.indexOf(u8, r.diag, "actual: 5") != null);
}

test "runPeer: strict rejects unscripted notifications" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try runInProcess(arena.allocator(), "strict\n> initialized\n", &.{
        \\{"jsonrpc":"2.0","method":"$/setTrace","params":{"value":"off"}}
        ,
    }, .lsp);
    try testing.expectEqual(script.mismatch_status, r.status);
    try testing.expect(std.mem.indexOf(u8, r.diag, "$/setTrace") != null);
}

test "runPeer: end of input while expecting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try runInProcess(arena.allocator(), "> initialize\n", &.{}, .lsp);
    try testing.expectEqual(script.mismatch_status, r.status);
    try testing.expect(std.mem.indexOf(u8, r.diag, "end of input") != null);
}

test "runPeer: response expectation and exit directive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try runInProcess(arena.allocator(),
        \\< {"id": 100, "method": "workspace/configuration", "params": {"items": [{"section": "zls"}]}}
        \\> response {"id": 100, "result": [{"enable_snippets": true}]}
        \\! exit 7
    , &.{
        \\{"jsonrpc":"2.0","id":100,"result":[{"enable_snippets":true,"other":1}]}
        ,
    }, .lsp);
    try testing.expectEqual(@as(u8, 7), r.status);
    try testing.expectEqualStrings("workspace/configuration", r.out[0].object.get("method").?.string);
}

test "runPeer: dap framing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try runInProcess(arena.allocator(),
        \\> initialize {"adapterID": "fake"}
        \\< {"type": "response", "request_seq": $1, "success": true, "command": "initialize", "body": {"supportsConfigurationDoneRequest": true}}
        \\< event initialized
        \\> launch {"program": "${workspace}/a.out"}
        \\< {"type": "response", "request_seq": $1, "success": true, "command": "launch"}
        \\< event stopped {"reason": "entry", "threadId": 1}
    , &.{
        \\{"seq":1,"type":"request","command":"initialize","arguments":{"adapterID":"fake","linesStartAt1":true}}
        ,
        \\{"seq":2,"type":"request","command":"launch","arguments":{"program":"/ws/a.out"}}
        ,
        \\{"seq":3,"type":"request","command":"threads"}
        ,
        \\{"seq":4,"type":"request","command":"disconnect","arguments":{}}
        ,
    }, .dap);
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqual(@as(usize, 6), r.out.len);
    for (r.out, 1..) |m, seq| try testing.expectEqual(@as(i64, @intCast(seq)), m.object.get("seq").?.integer);
    try testing.expectEqual(@as(i64, 1), r.out[0].object.get("request_seq").?.integer);
    try testing.expectEqualStrings("initialized", r.out[1].object.get("event").?.string);
    try testing.expectEqual(@as(i64, 2), r.out[2].object.get("request_seq").?.integer);
    try testing.expectEqualStrings("entry", r.out[3].object.get("body").?.object.get("reason").?.string);
    try testing.expect(!r.out[4].object.get("success").?.bool);
    try testing.expect(r.out[5].object.get("success").?.bool);
}

test "runPeer: dap response shortcut and reverse request" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try runInProcess(arena.allocator(),
        \\> launch
        \\< {"body": {}}
        \\< reverse runInTerminal {"kind": "integrated", "args": ["/bin/true"]}
        \\> response runInTerminal {"success": true, "body": {"processId": 42}}
        \\< event process {"systemProcessId": 42}
    , &.{
        \\{"seq":1,"type":"request","command":"launch","arguments":{}}
        ,
        \\{"seq":2,"type":"response","request_seq":2,"command":"runInTerminal","success":true,"body":{"processId":42}}
        ,
    }, .dap);
    try testing.expectEqual(@as(u8, 0), r.status);
    const launch = r.out[0].object;
    try testing.expectEqualStrings("response", launch.get("type").?.string);
    try testing.expectEqualStrings("launch", launch.get("command").?.string);
    try testing.expectEqual(@as(i64, 1), launch.get("request_seq").?.integer);
    try testing.expect(launch.get("success").?.bool);
    const rev = r.out[1].object;
    try testing.expectEqualStrings("request", rev.get("type").?.string);
    try testing.expectEqualStrings("runInTerminal", rev.get("command").?.string);
    try testing.expectEqual(@as(i64, 2), rev.get("seq").?.integer);
    try testing.expectEqualStrings("process", r.out[2].object.get("event").?.string);
}

test "runPeer: dap reverse response must answer the reverse request" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try runInProcess(arena.allocator(),
        \\< reverse startDebugging {"request": "launch", "configuration": {}}
        \\> response startDebugging
    , &.{
        \\{"seq":1,"type":"response","request_seq":7,"command":"startDebugging","success":true}
        ,
    }, .dap);
    try testing.expectEqual(script.mismatch_status, r.status);
    try testing.expect(std.mem.indexOf(u8, r.diag, "request_seq 7") != null);
}

test "runPeer: dap client seq regression" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const msgs: []const []const u8 = &.{
        \\{"seq":2,"type":"request","command":"initialize","arguments":{}}
        ,
        \\{"seq":2,"type":"request","command":"launch","arguments":{}}
        ,
    };
    const bad = try runInProcess(arena.allocator(), "> initialize\n< {}\n> launch\n", msgs, .dap);
    try testing.expectEqual(script.mismatch_status, bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.diag, "seq regression") != null);
    const off = try runInProcess(arena.allocator(), "seq-check off\n> initialize\n< {}\n> launch\n", msgs, .dap);
    try testing.expectEqual(@as(u8, 0), off.status);
}

// --- the fake server as a real child process ---

const Child = struct {
    child: std.process.Child,
    in_w: std.Io.File.Writer,
    out_r: std.Io.File.Reader,
    frames: zg_jsonrpc.framing.ContentLengthReader,
    in_buf: [4096]u8 = undefined,
    out_buf: [4096]u8 = undefined,

    fn start(c: *Child, extra: []const []const u8) !void {
        const io = testing.io;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.append(testing.allocator, test_exes.fake_lsp_server);
        try argv.appendSlice(testing.allocator, extra);
        c.child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        c.in_w = c.child.stdin.?.writerStreaming(io, &c.in_buf);
        c.out_r = c.child.stdout.?.readerStreaming(io, &c.out_buf);
        c.frames = .init(&c.out_r.interface, .{});
    }

    fn send(c: *Child, json: []const u8) !void {
        try zg_jsonrpc.framing.writeContentLength(&c.in_w.interface, json);
    }

    fn recv(c: *Child, arena: std.mem.Allocator) !Value {
        const b = try c.frames.next(testing.allocator);
        return std.json.parseFromSliceLeaky(Value, arena, try arena.dupe(u8, b), .{});
    }

    /// Reads stderr to the end, then reaps the child.
    fn finish(c: *Child, arena: std.mem.Allocator) !struct { term: std.process.Child.Term, stderr: []const u8 } {
        const io = testing.io;
        c.frames.deinit(testing.allocator);
        var buf: [1024]u8 = undefined;
        var er = c.child.stderr.?.readerStreaming(io, &buf);
        const err_text = try er.interface.allocRemaining(arena, .limited(1 << 20));
        const term = try c.child.wait(io);
        return .{ .term = term, .stderr = err_text };
    }
};

fn transcriptPath(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ options.package_root, "testdata", "transcripts", name });
}

test "fake_server: handshake + hover via real child process" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Child = .{ .child = undefined, .in_w = undefined, .out_r = undefined, .frames = undefined };
    try c.start(&.{ "--script", try transcriptPath(a, "hover.script"), "--workspace", "/ws" });
    try c.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"capabilities":{}}}
    );
    const r1 = try c.recv(a);
    try testing.expect(r1.object.get("result").?.object.get("capabilities").?.object.get("hoverProvider").?.bool);
    try c.send(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try c.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///ws/main.zig","languageId":"zig","version":1,"text":"const std = @import(\"std\");"}}}
    );
    try c.send(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///ws/main.zig"},"position":{"line":0,"character":6}}}
    );
    const r2 = try c.recv(a);
    try testing.expectEqual(@as(i64, 2), r2.object.get("id").?.integer);
    try testing.expectEqualStrings("markdown", r2.object.get("result").?.object.get("contents").?.object.get("kind").?.string);
    try c.send(
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
    );
    _ = try c.recv(a);
    try c.send(
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    const done = try c.finish(a);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, done.term);
}

test "fake_server: mismatch exits 99 with diff" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Child = .{ .child = undefined, .in_w = undefined, .out_r = undefined, .frames = undefined };
    try c.start(&.{ "--script", try transcriptPath(a, "handshake.script"), "--workspace", "/ws" });
    try c.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///elsewhere"}}
    );
    const done = try c.finish(a);
    try testing.expectEqual(std.process.Child.Term{ .exited = script.mismatch_status }, done.term);
    try testing.expect(std.mem.indexOf(u8, done.stderr, "$.rootUri") != null);
    try testing.expect(std.mem.indexOf(u8, done.stderr, "file:///ws") != null);
    try testing.expect(std.mem.indexOf(u8, done.stderr, "file:///elsewhere") != null);
}

test "fake_server: exit directive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Child = .{ .child = undefined, .in_w = undefined, .out_r = undefined, .frames = undefined };
    try c.start(&.{ "--script", try transcriptPath(a, "crash.script") });
    try c.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    _ = try c.recv(a);
    try c.send(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    const done = try c.finish(a);
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, done.term);
}
