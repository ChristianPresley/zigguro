//! Tests for stream_json.zig and stream-json runs (E10.F10.S01.T02).

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const sj = @import("stream_json.zig");
const fake = @import("../provider/fake_server.zig");
const cassette = @import("../testing/cassette.zig");
const Anthropic = @import("../provider/anthropic/Anthropic.zig");
const ts = @import("test_support.zig");

const testing = std.testing;
const io = ts.io;
const Harness = ts.Harness;
const script = ts.script;
const Step = ts.Step;

const stream_args = [_][:0]const u8{ "--input-format", "stream-json", "--output-format", "stream-json" };
const prompt_args = stream_args ++ [_][:0]const u8{ "--permission-prompts", "stream" };

inline fn userLine(comptime text: []const u8) []const u8 {
    return comptime "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"" ++ text ++ "\"}]}}\n";
}

/// The `type` of each output line, space-separated.
fn types(buf: []u8, out: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    var first = true;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    while (it.next()) |line| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{});
        if (!first) try w.writeByte(' ');
        first = false;
        try w.writeAll(v.object.get("type").?.string);
    }
    return w.buffered();
}

test "roundtrip all line types" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const msg: proto.Message = .{ .role = .assistant, .content = &.{.{ .text = .{ .text = "hi" } }} };
    const lines = [_]sj.OutLine{
        .{ .system = .{ .subtype = .init, .session_id = "S", .model = "m", .cwd = "/w", .tools = &.{"run"}, .permission_mode = "default" } },
        .{ .assistant = .{ .message = msg, .session_id = "S" } },
        .{ .user = .{ .message = .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "t1", .parts = &.{.{ .text = "ok" }} } }} }, .session_id = "S" } },
        .{ .stream_event = .{ .event = .{ .text_delta = .{ .index = 0, .text = "h" } }, .session_id = "S" } },
        .{ .stream_event = .{ .event = .{ .block_start = .{ .index = 1, .kind = .tool_use, .tool_id = "t1", .tool_name = "run" } }, .session_id = "S" } },
        .{ .permission_request = .{ .request_id = "perm_1", .tool = "run", .input_json = "{\"command\":\"make\"}", .reason = "run needs approval" } },
        .{ .system = .{ .subtype = .api_retry, .session_id = "S", .model = "m", .cwd = "/w", .permission_mode = "plan", .attempt = 2, .retry_delay_ms = 500 } },
        .{ .result = .{ .subtype = .success, .result = "hi", .structured_output = "{\"a\":1}", .session_id = "S", .num_turns = 1, .duration_ms = 3, .usage = .{ .input = 1 }, .total_cost_usd = 0.5, .is_error = false, .permission_denials = &.{.{ .tool_name = "run", .tool_input = "{}", .reason = "no" }} } },
    };
    for (lines) |l| try sj.writeLine(&w, l);
    try testing.expectEqualStrings(
        \\{"type":"system","subtype":"init","session_id":"S","model":"m","cwd":"/w","tools":["run"],"mcp_servers":[],"permission_mode":"default","protocol":"zg.stream/1"}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]},"session_id":"S","parent_tool_use_id":null}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"ok"}]}]},"session_id":"S"}
        \\{"type":"stream_event","event":{"type":"text_delta","index":0,"text":"h"},"session_id":"S"}
        \\{"type":"stream_event","event":{"type":"block_start","index":1,"kind":"tool_use","tool_id":"t1","tool_name":"run","origin":"unknown"},"session_id":"S"}
        \\{"type":"permission_request","request_id":"perm_1","tool":"run","input":{"command":"make"},"reason":"run needs approval"}
        \\{"type":"system","subtype":"api_retry","session_id":"S","model":"m","cwd":"/w","tools":[],"mcp_servers":[],"permission_mode":"plan","protocol":"zg.stream/1","attempt":2,"retry_delay_ms":500}
        \\{"type":"result","subtype":"success","result":"hi","structured_output":{"a":1},"session_id":"S","num_turns":1,"duration_ms":3,"usage":{"input":1,"output":0,"cache_read":0,"cache_write_5m":0,"cache_write_1h":0,"reasoning":0,"server_tool_requests":0},"total_cost_usd":0.5,"is_error":false,"permission_denials":[{"tool_name":"run","tool_input":"{}","reason":"no"}]}
        \\
    , w.buffered());

    // Every output line is one JSON object, and input lines parse back.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in: std.Io.Reader = .fixed(userLine("hello") ++ "\n  \n" ++
        \\{"type":"permission_response","request_id":"perm_1","behavior":"deny","message":"not now","extra":1}
        \\{"type":"interrupt"}
        \\{"type":"control_request","x":1}
        \\{"type":"user","message":{"role":"user","content":"short form"}}
    );
    try testing.expectEqualStrings("hello", (try sj.readLine(a, &in)).?.user.message.content[0].text.text);
    const pr = (try sj.readLine(a, &in)).?.permission_response;
    try testing.expectEqualStrings("perm_1", pr.request_id);
    try testing.expectEqual(sj.Behavior.deny, pr.behavior);
    try testing.expectEqualStrings("not now", pr.message.?);
    try testing.expect((try sj.readLine(a, &in)).? == .interrupt);
    try testing.expectEqualStrings("control_request", (try sj.readLine(a, &in)).?.unknown);
    try testing.expectEqualStrings("short form", (try sj.readLine(a, &in)).?.user.message.content[0].text.text);
    try testing.expectEqual(@as(?sj.InLine, null), try sj.readLine(a, &in));
    var bad: std.Io.Reader = .fixed("{\"type\":\"user\"}\nnot json\n");
    try testing.expectError(error.InvalidLine, sj.readLine(a, &bad));
    try testing.expectError(error.InvalidLine, sj.readLine(a, &bad));
}

test "input stream queues turns" {
    var h: Harness = undefined;
    try h.init(&.{ script.text("First."), script.text("Second.") });
    defer h.deinit();
    try testing.expectEqual(.ok, try h.run(try h.options(&stream_args), userLine("one") ++ userLine("two")));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("system assistant assistant result", try types(&buf, h.stdout()));
    try testing.expectEqualStrings("two", h.lastUserText(1));
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "\"result\":\"Second.\"") != null);
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "\"num_turns\":2") != null);
}

test "permission request response allow" {
    const turns = [_][]const Step{ script.tools(&.{.{ "t1", "run", "{\"command\":\"make\"}" }}), script.text("Built.") };
    var h: Harness = undefined;
    try h.init(&turns);
    defer h.deinit();
    const input = userLine("build") ++ "{\"type\":\"permission_response\",\"request_id\":\"perm_1\",\"behavior\":\"allow\"}\n";
    try testing.expectEqual(.ok, try h.run(try h.options(&prompt_args), input));
    try testing.expectEqual(@as(u32, 1), h.tool.calls.load(.acquire));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("system assistant permission_request user assistant result", try types(&buf, h.stdout()));
}

test "permission denied over the stream" {
    const turns = [_][]const Step{ script.tools(&.{.{ "t1", "run", "{\"command\":\"rm -rf /\"}" }}), script.text("Okay.") };
    var h: Harness = undefined;
    try h.init(&turns);
    defer h.deinit();
    const input = userLine("clean") ++ "{\"type\":\"permission_response\",\"request_id\":\"perm_1\",\"behavior\":\"deny\",\"message\":\"too dangerous\"}\n";
    try testing.expectEqual(.permission_required, try h.run(try h.options(&prompt_args), input));
    try testing.expectEqual(@as(u32, 0), h.tool.calls.load(.acquire));
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "Permission denied: too dangerous") != null);
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "\"subtype\":\"error_permission\"") != null);
}

test "interrupt line cancels" {
    const turns = [_][]const Step{&.{ .{ .delay_ms = 10_000 }, .{ .event = .{ .message_start = .{ .id = "x", .model = "m" } } } }};
    var h: Harness = undefined;
    try h.init(&turns);
    defer h.deinit();
    const t0 = std.Io.Timestamp.now(io, .awake);
    const code = try h.run(try h.options(&stream_args), userLine("wait") ++ "{\"type\":\"interrupt\"}\n");
    try testing.expect(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() < 5_000);
    try testing.expectEqual(.interrupted, code);
    try testing.expect(std.mem.indexOf(u8, h.stdout(), "\"subtype\":\"error_interrupted\"") != null);
}

test "unknown type skipped" {
    var h: Harness = undefined;
    try h.init(&.{script.text("Fine.")});
    defer h.deinit();
    const input = "{\"type\":\"telemetry\",\"x\":1}\nnot json at all\n" ++ userLine("hi");
    try testing.expectEqual(.ok, try h.run(try h.options(&stream_args), input));
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "unknown type telemetry") != null);
    try testing.expect(std.mem.indexOf(u8, h.stderr(), "not a valid zg.stream/1 message") != null);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("system assistant result", try types(&buf, h.stdout()));
}

test "result always last even on error" {
    var h: Harness = undefined;
    try h.init(&.{&.{.{ .fail = error.InvalidRequest }}});
    defer h.deinit();
    try testing.expectEqual(.failed, try h.run(try h.options(&stream_args), userLine("hi")));
    const out = std.mem.trimEnd(u8, h.stdout(), "\n");
    const last = out[std.mem.lastIndexOfScalar(u8, out, '\n').? + 1 ..];
    try testing.expect(std.mem.startsWith(u8, last, "{\"type\":\"result\",\"subtype\":\"error_during_execution\""));
    try testing.expect(std.mem.indexOf(u8, last, "\"is_error\":true") != null);
    try testing.expect(std.mem.startsWith(u8, out, "{\"type\":\"system\",\"subtype\":\"init\""));
    // Empty input still yields init and one result.
    var h2: Harness = undefined;
    try h2.init(&.{});
    defer h2.deinit();
    try testing.expectEqual(.ok, try h2.run(try h2.options(&stream_args), ""));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("system result", try types(&buf, h2.stdout()));
}

const tool_sse =
    \\event: message_start
    \\data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"m","content":[],"stop_reason":null,"usage":{"input_tokens":30,"output_tokens":1}}}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"run","input":{}}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"make\"}"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":0}
    \\
    \\event: message_delta
    \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":9}}
    \\
    \\event: message_stop
    \\data: {"type":"message_stop"}
    \\
    \\
;

test "golden stream from cassette" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/stream.jsonl", .{&tmp.sub_path});
    const routes = [_]fake.Route{
        .{ .body = tool_sse, .chunk_size = 50, .once = true },
        .{ .body = @embedFile("../provider/anthropic/testdata/text_only.sse"), .chunk_size = 50 },
    };
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    const input = userLine("build it") ++ "{\"type\":\"permission_response\",\"request_id\":\"perm_1\",\"behavior\":\"allow\"}\n";
    var outs: [2][]u8 = undefined;
    inline for (.{ cassette.Mode.record, cassette.Mode.replay }, 0..) |mode, i| {
        var h: Harness = undefined;
        try h.init(&.{});
        defer h.deinit();
        const c = try cassette.Cassette.open(io, testing.allocator, path, mode, .{});
        defer c.deinit();
        const an = try Anthropic.create(testing.allocator, c.transport(if (mode == .record) f.transport() else null), .{ .api_key = "sk-test" });
        const p = an.provider();
        defer p.deinit();
        h.useProvider(&p);
        try testing.expectEqual(.ok, try h.run(try h.options(&(prompt_args ++ [_][:0]const u8{"--include-partial"})), input));
        try c.finish();
        outs[i] = try testing.allocator.dupe(u8, h.stdout());
    }
    defer for (outs) |o| testing.allocator.free(o);
    try testing.expectEqual(@as(usize, 2), f.requests().len);
    try testing.expectEqualStrings(outs[0], outs[1]);
    try golden.expectGoldenOpts(io, @src(), "two_turns_with_approval", outs[1], .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/headless" });
}
