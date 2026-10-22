//! Tests for print.zig, repl.zig and runner.zig (E10.F10.S01.T01).

const std = @import("std");
const proto = @import("zg_ai_proto");
const store_mod = @import("../session/store.zig");
const deps = @import("../loop/deps.zig");
const request = @import("../provider/request.zig");
const signals = @import("signals.zig");
const repl = @import("repl.zig");
const permission = @import("permission.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const io = ts.io;
const Harness = ts.Harness;
const script = ts.script;
const Step = ts.Step;

test "print text mode" {
    var h: Harness = undefined;
    try h.init(&.{script.text("Hello there.")});
    defer h.deinit();
    try testing.expectEqual(.ok, try h.run(try h.options(&.{ "-p", "hi" }), ""));
    try testing.expectEqualStrings("Hello there.\n", h.stdout());
    try testing.expectEqualStrings("", h.stderr());
    try testing.expectEqualStrings("hi", h.lastUserText(0));
}

test "json output is one result object" {
    var h: Harness = undefined;
    try h.init(&.{script.text("Four.")});
    defer h.deinit();
    try testing.expectEqual(.ok, try h.run(try h.options(&.{ "-p", "2+2?", "--output-format", "json" }), ""));
    try testing.expectEqualStrings(
        \\{"type":"result","subtype":"success","result":"Four.","session_id":"01J80000000000000000000001","num_turns":1,"duration_ms":0,"usage":{"input":10,"output":5,"cache_read":0,"cache_write_5m":0,"cache_write_1h":0,"reasoning":0,"server_tool_requests":0},"total_cost_usd":0.000035,"is_error":false,"permission_denials":[]}
        \\
    , h.stdout());
}

test "stdin attached as context" {
    var h: Harness = undefined;
    try h.init(&.{ script.text("Two lines."), script.text("Just stdin.") });
    defer h.deinit();
    var o = try h.options(&.{ "-p", "Summarize this." });
    o.env.stdin_piped = true;
    try testing.expectEqual(.ok, try h.run(o, "line one\nline two\n"));
    try testing.expectEqualStrings("Summarize this.\n\n<stdin>\nline one\nline two\n</stdin>", h.lastUserText(0));
    // Without -p the input is the prompt.
    var o2 = try h.options(&.{});
    o2.env.stdin_piped = true;
    try testing.expectEqual(.ok, try h.run(o2, "no newline"));
    try testing.expectEqualStrings("<stdin>\nno newline\n</stdin>", h.lastUserText(1));
    // Neither: a usage error.
    try testing.expectEqual(.usage, try h.run(try h.options(&.{}), ""));
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "no prompt") != null);
}

test "stdin over cap spills" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var h: Harness = undefined;
    try h.init(&.{script.text("Read it.")});
    defer h.deinit();
    var dir_buf: [64]u8 = undefined;
    var o = try h.options(&.{ "-p", "Look at the log." });
    o.env.stdin_piped = true;
    o.env.stdin_cap = 16;
    o.env.spill_dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const big = "0123456789" ** 5;
    try testing.expectEqual(.ok, try h.run(o, big));
    const text = h.lastUserText(0);
    try testing.expect(std.mem.indexOf(u8, text, "bytes=\"50\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, big) == null);
    var buf: [128]u8 = undefined;
    const saved = try tmp.dir.readFile(io, "zg-stdin-01J80000000000000000000001.txt", &buf);
    try testing.expectEqualStrings(big, saved);
}

const tool_then_text = [_][]const Step{ script.tools(&.{.{ "t1", "run", "{\"command\":\"make\"}" }}), script.text("Done.") };

test "budget exit 3" {
    var h: Harness = undefined;
    try h.init(&tool_then_text);
    defer h.deinit();
    try testing.expectEqual(.budget, try h.run(try h.options(&.{ "-p", "build it", "--max-turns", "1", "--allowed-tools", "run", "--output-format", "json" }), ""));
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "\"subtype\":\"error_max_turns\"") != null);
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "\"is_error\":true") != null);
}

test "permission denied exit 4" {
    var h: Harness = undefined;
    try h.init(&tool_then_text);
    defer h.deinit();
    try testing.expectEqual(.permission_required, try h.run(try h.options(&.{ "-p", "build it" }), ""));
    try testing.expectEqual(@as(u32, 0), h.tool.calls.load(.acquire));
    try testing.expectEqualStrings("Done.\n", h.stdout());
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "run needs approval") != null);
    // The model saw the denial as the tool result.
    const results = h.sp.requests()[1].messages[2];
    try testing.expect(results.content[0].tool_result.is_error);
}

test "allowed tool runs; a deny rule beats it" {
    var h: Harness = undefined;
    try h.init(&(tool_then_text ++ tool_then_text));
    defer h.deinit();
    try testing.expectEqual(.ok, try h.run(try h.options(&.{ "-p", "build it", "--allowed-tools", "run(make*)" }), ""));
    try testing.expectEqual(@as(u32, 1), h.tool.calls.load(.acquire));
    // A rule-based deny is not a missing approval: exit 0.
    try testing.expectEqual(.ok, try h.run(try h.options(&.{ "-p", "again", "--allowed-tools", "run", "--disallowed-tools", "run(make:*)" }), ""));
    try testing.expectEqual(@as(u32, 1), h.tool.calls.load(.acquire));
}

test "sigint flushes and exits 130" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var store: store_mod.SessionStore = try .init(testing.allocator, path_buf[0..n], "/work");
    defer store.deinit();

    const slow = [_][]const Step{&.{ .{ .delay_ms = 10_000 }, .{ .event = .{ .message_start = .{ .id = "m1", .model = "m" } } } }};
    var h: Harness = undefined;
    try h.init(&slow);
    defer h.deinit();
    var sig: signals.Signals = .{ .exit_on_second = false };
    var o = try h.options(&.{ "-p", "take your time" });
    o.env.signals = &sig;
    o.env.store = &store;
    const Raiser = struct {
        fn run(s: *signals.Signals) void {
            io.sleep(.fromMilliseconds(50), .awake) catch return;
            s.raise(.interrupt);
        }
    };
    var f = try io.concurrent(Raiser.run, .{&sig});
    defer f.cancel(io);
    const t0 = std.Io.Timestamp.now(io, .awake);
    try testing.expectEqual(.interrupted, try h.run(o, ""));
    try testing.expect(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 5_000);
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "interrupted") != null);

    // The session log has the prompt.
    const l = try store.open(io, ts.session_id, .{ .mode = .full });
    defer l.deinit();
    var found = false;
    for (l.tail) |x| if (x.record == .user) {
        found = std.mem.eql(u8, x.record.user.content[0].text.text, "take your time");
    };
    try testing.expect(found);
}

test "bare skips memory and hooks" {
    const Ctx = struct {
        fn build(_: *anyopaque, _: std.Io, arena: std.mem.Allocator, v: *const deps.ContextView) anyerror!request.Request {
            var r = try deps.ContextBuilder.basic.build(deps.ContextBuilder.basic.ctx, io, arena, v);
            const sys = try arena.alloc(request.SystemPart, 1);
            sys[0] = .{ .text = "MEMORY: project rules" };
            r.system = sys;
            return r;
        }
        var hooked: u32 = 0;
        fn submit(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) anyerror!deps.PromptDecision {
            hooked += 1;
            return .allow;
        }
    };
    var h: Harness = undefined;
    try h.init(&.{ script.text("a"), script.text("b") });
    defer h.deinit();
    var dummy: u8 = 0;
    h.manager.deps.context = .{ .ctx = &dummy, .build = Ctx.build };
    h.manager.deps.hooks = .{ .ctx = &dummy, .prompt_submit = Ctx.submit };
    try testing.expectEqual(.ok, try h.run(try h.options(&.{ "-p", "x" }), ""));
    try testing.expectEqualStrings("MEMORY: project rules", h.sp.requests()[0].system[0].text);
    try testing.expectEqual(@as(u32, 1), Ctx.hooked);
    try testing.expectEqual(.ok, try h.run(try h.options(&.{ "-p", "x", "--bare" }), ""));
    try testing.expectEqual(@as(usize, 0), h.sp.requests()[1].system.len);
    try testing.expectEqual(@as(u32, 1), Ctx.hooked);
}

test "json schema final answer validated" {
    var h: Harness = undefined;
    try h.init(&.{ script.text("Sure! It is 4."), script.text("```json\n{\"answer\": 4}\n```"), script.text("still prose"), script.text("more prose") });
    defer h.deinit();
    const schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"integer\"}}}";
    try testing.expectEqual(.ok, try h.run(try h.options(&.{ "-p", "2+2", "--json-schema", schema, "--output-format", "json" }), ""));
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "\"structured_output\":{\"answer\":4}") != null);
    try testing.expect(std.mem.indexOf(u8, h.sp.requests()[0].system[0].text, schema) != null);
    try testing.expect(std.mem.indexOf(u8, h.lastUserText(1), "does not match the required JSON Schema") != null);
    // Still wrong after the repair turn: exit 1.
    try testing.expectEqual(.failed, try h.run(try h.options(&.{ "-p", "2+2", "--json-schema", schema }), ""));
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "does not match --json-schema") != null);
    // A bad schema is a usage error.
    try testing.expectEqual(.usage, try h.run(try h.options(&.{ "-p", "2+2", "--json-schema", "missing-file.json" }), ""));
}

test "unknown model is a usage error" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try testing.expectEqual(.usage, try h.run(try h.options(&.{ "-p", "x", "--model", "gpt-nope" }), ""));
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "unknown model gpt-nope") != null);
}

test "provider failure exits 1" {
    var h: Harness = undefined;
    try h.init(&.{&.{.{ .fail = error.InvalidRequest }}});
    defer h.deinit();
    try testing.expectEqual(.failed, try h.run(try h.options(&.{ "-p", "x" }), ""));
}

test "repl runs lines until ctrl-d" {
    var h: Harness = undefined;
    try h.init(&.{ script.text("One."), script.text("Two.") });
    defer h.deinit();
    var in: std.Io.Reader = .fixed("first\n\n/help\nsecond\n");
    const code = try repl.runRepl(io, testing.allocator, h.manager, try h.options(&.{}), &h.out.writer, &in);
    try testing.expectEqual(.ok, code);
    try testing.expectEqualStrings("> One.\n> > > Two.\n> \n", h.stdout());
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "unknown command /help") != null);
    try testing.expectEqualStrings("second", h.lastUserText(1));
}

test "repl exit command" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    var in: std.Io.Reader = .fixed("/exit\nnever\n");
    try testing.expectEqual(.ok, try repl.runRepl(io, testing.allocator, h.manager, try h.options(&.{}), &h.out.writer, &in));
    try testing.expectEqual(@as(usize, 0), h.sp.requests().len);
}

test "streamed approval times out" {
    var clock: @import("../provider/ratelimit.zig").FakeClock = .init(0);
    const Sink = struct {
        lines: u32 = 0,
        fn emit(ctx: *anyopaque, line: @import("stream_json.zig").OutLine) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (line == .permission_request) s.lines += 1;
        }
    };
    var sink: Sink = .{};
    var b: permission.Broker = .init(testing.allocator, io, &sink, Sink.emit);
    defer b.deinit();
    b.clock = clock.clock();
    b.timeout_ms = 1000;
    const a = try b.ask("run", "{}", "run needs approval");
    try testing.expect(!a.allow);
    try testing.expectEqualStrings("the approval timed out", a.message.?);
    try testing.expectEqual(@as(u32, 1), sink.lines);
    try testing.expectEqual(@as(u64, 1000), clock.slept_ms.load(.acquire));
    // An answer that arrives first is used.
    try b.answer("perm_2", .{ .allow = true });
    try testing.expect((try b.ask("run", "{}", "again")).allow);
}
