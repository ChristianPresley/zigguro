//! Chat Completions provider tests.

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("../request.zig");
const util = @import("../http_test_util.zig");
const fake = @import("../fake_server.zig");
const Chat = @import("Chat.zig");
const dialects = @import("dialects.zig");

const sse = util.sse;
fn chunk(comptime delta: []const u8, comptime finish: []const u8) []const u8 {
    return "{\"id\":\"c1\",\"model\":\"qwen3\",\"choices\":[{\"index\":0,\"delta\":" ++ delta ++ ",\"finish_reason\":" ++ finish ++ "}]}";
}
const usage_chunk = "{\"id\":\"c1\",\"choices\":[],\"usage\":{\"prompt_tokens\":50,\"completion_tokens\":7,\"total_tokens\":57}}";

const text = sse(&.{ chunk("{\"role\":\"assistant\",\"content\":\"\"}", "null"), chunk("{\"content\":\"Hello\"}", "null"), chunk("{\"content\":\" world\"}", "null"), chunk("{}", "\"stop\""), usage_chunk, "[DONE]" });
const tool_calls_3 = sse(&.{
    chunk("{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"call_0\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]}", "null"),
    chunk("{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\"}}]}", "null"),
    chunk("{\"tool_calls\":[{\"index\":1,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"b\\\"}\"}}]}", "null"),
    chunk("{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"a\\\"}\"}}]}", "null"),
    chunk("{\"tool_calls\":[{\"index\":2,\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"grep\",\"arguments\":\"{}\"}}]}", "null"),
    chunk("{}", "\"tool_calls\""),
    usage_chunk,
    "[DONE]",
});
// Some servers repeat the id on every delta; dedupe by index.
const repeated_ids = sse(&.{
    chunk("{\"tool_calls\":[{\"index\":0,\"id\":\"call_0\",\"function\":{\"name\":\"grep\",\"arguments\":\"{\\\"q\\\"\"}}]}", "null"),
    chunk("{\"tool_calls\":[{\"index\":0,\"id\":\"call_0\",\"function\":{\"arguments\":\":1}\"}}]}", "null"),
    chunk("{}", "\"tool_calls\""),
    "[DONE]",
});
const reasoning = sse(&.{ chunk("{\"reasoning_content\":\"Think.\"}", "null"), chunk("{\"content\":\"42\"}", "null"), chunk("{}", "\"stop\""), "[DONE]" });
const length = sse(&.{ chunk("{\"content\":\"cut\"}", "null"), chunk("{}", "\"length\""), "[DONE]" });
const no_done = sse(&.{chunk("{\"content\":\"Half\"}", "null")});
const finish_no_done = sse(&.{chunk("{\"content\":\"Hello world\"}", "\"stop\"")});

test "chat passes the conformance suite (llamacpp dialect)" {
    var f: util.Factory(Chat) = .{ .cfg = .{ .base_url = "http://127.0.0.1:8080/v1", .dialect = "llamacpp" } };
    defer f.deinit();
    try util.expectConformance(f.factory(), &.{
        .{ .name = "text_only", .body = text, .expect = .{ .text = "Hello world", .usage = .{ .input = 50, .output = 7 } }, .cancel = true },
        .{ .name = "parallel_tools", .body = tool_calls_3, .expect = .{ .tool_names = &.{ "read_file", "read_file", "grep" }, .stop = .tool_use } },
        .{ .name = "repeated_ids", .body = repeated_ids, .expect = .{ .tool_names = &.{"grep"}, .stop = .tool_use } },
        .{ .name = "reasoning_content", .body = reasoning, .expect = .{ .text = "42", .thinking = true } },
        .{ .name = "max_tokens", .body = length, .expect = .{ .text = "cut", .stop = .max_tokens } },
        .{ .name = "usage", .body = text, .expect = .{ .usage = .{ .input = 50, .output = 7 } } },
        .{ .name = "no_usage", .body = finish_no_done, .expect = .{ .text = "Hello world", .usage = .{} } },
        .{ .name = "done_sentinel_missing", .body = no_done, .expect = .{ .err = error.StreamTruncated } },
        .{ .name = "tool_error_round_trip", .status = 400, .body = "{\"error\":{\"message\":\"bad tool_call_id\",\"type\":\"invalid_request_error\"}}", .expect = .{ .err = error.InvalidRequest } },
    });
}

test "golden encodings per dialect" {
    const schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}";
    const tools = [_]request.ToolDecl{.{ .name = "read_file", .description = "Read", .input_schema_json = schema }};
    const hi = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "Hello" } }} }};
    const convo = [_]proto.Message{
        hi[0],
        .{ .role = .assistant, .content = &.{ .{ .text = .{ .text = "Reading." } }, .{ .tool_use = .{ .id = "call_0", .name = "read_file", .input_json = "{\"path\":\"a\"}" } } } },
        .{ .role = .user, .content = &.{ .{ .tool_result = .{ .tool_use_id = "call_0", .parts = &.{.{ .text = "A" }} } }, .{ .text = .{ .text = "thanks" } } } },
    };
    const image = [_]proto.Message{.{ .role = .user, .content = &.{ .{ .text = .{ .text = "what" } }, .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = "AA==" } } }, .{ .image = .{ .media_type = "image/png", .data = .{ .url = "https://x/y.png" } } } } }};
    const cases = .{
        .{ "plain", request.Request{ .model = "m", .messages = &hi, .system = &.{.{ .text = "Be brief." }} } },
        .{ "tools_forced", request.Request{ .model = "m", .messages = &hi, .tools = &tools, .tool_choice = .{ .tool = "read_file" }, .parallel_tools = false } },
        .{ "conversation", request.Request{ .model = "m", .messages = &convo, .tools = &tools } },
        .{ "images", request.Request{ .model = "m", .messages = &image, .stop_sequences = &.{"END"} } },
    };
    inline for (.{ "ollama", "llamacpp", "lmstudio", "generic" }) |dn| {
        inline for (cases) |c| {
            const req = c[1];
            try util.expectBodyGolden(@src(), "openai_chat", dn ++ "_" ++ c[0], Chat.Body{ .req = &req, .dialect = dialects.byName(dn) }, Chat.writeBody);
        }
    }
}

test "discover_fake_servers" {
    const routes = [_]fake.Route{
        .{ .url_contains = "127.0.0.1:11434", .body = "{\"object\":\"list\",\"data\":[{\"id\":\"qwen3:8b\",\"object\":\"model\",\"owned_by\":\"library\"}]}" },
        .{ .url_contains = "127.0.0.1:1234", .body = "{\"data\":[{\"id\":\"llama-3.2\"}]}" },
        .{ .url_contains = "my-box:9000", .body = "{\"data\":[{\"id\":\"custom\"}]}", .headers = &.{.{ .name = "Server", .value = "llama.cpp" }} },
        // 127.0.0.1:8080 has no route: the fake fails it like a dead port.
    };
    var f: fake.FakeTransport = try .init(std.testing.allocator, &routes);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    const t0 = std.Io.Timestamp.now(io, .awake);
    const found = try Chat.discover(io, arena.allocator(), f.transport(), &.{"http://my-box:9000/v1"});
    try std.testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 400);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    var names: [3][]const u8 = undefined;
    for (found, 0..) |d, i| names[i] = d.dialect.name;
    try std.testing.expectEqualStrings("ollama", names[0]);
    try std.testing.expectEqualStrings("lmstudio", names[1]);
    try std.testing.expectEqualStrings("llamacpp", names[2]);
    try std.testing.expectEqualStrings("qwen3:8b", found[0].models[0].id);
}
