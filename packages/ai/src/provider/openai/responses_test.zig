//! OpenAI Responses provider tests.

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("../request.zig");
const util = @import("../http_test_util.zig");
const fake = @import("../fake_server.zig");
const Responses = @import("Responses.zig");

const sse = util.sse;
const created = "{\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-5.5\"}}";
const usage = "\"usage\":{\"input_tokens\":120,\"input_tokens_details\":{\"cached_tokens\":100},\"output_tokens\":30,\"output_tokens_details\":{\"reasoning_tokens\":12}}";

const text_only = sse(&.{
    created,
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\"}}",
    "{\"type\":\"response.content_part.added\",\"output_index\":0,\"content_index\":0}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\" world\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\"}}",
    "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"," ++ usage ++ "}}",
});

const two_calls = sse(&.{
    created,
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"name\":\"read_file\",\"arguments\":\"\"}}",
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"path\\\":\"}",
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"\\\"a\\\"}\"}",
    "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\"}}",
    "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_b\",\"name\":\"grep\"}}",
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"q\\\":\\\"x\\\"}\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\"}}",
    "{\"type\":\"response.completed\",\"response\":{" ++ usage ++ "}}",
});

const reasoning_then_call = sse(&.{
    created,
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\"}}",
    "{\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"delta\":\"Need the file.\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"gAAAAB\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Need the file.\"}]}}",
    "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_a\",\"name\":\"read_file\"}}",
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{}\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\"}}",
    "{\"type\":\"response.completed\",\"response\":{" ++ usage ++ "}}",
});

const incomplete = sse(&.{
    created,
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"cut\"}",
    "{\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}," ++ usage ++ "}}",
});

const failed = sse(&.{
    created,
    "{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}",
});

const unknown_events = sse(&.{
    created,
    "{\"type\":\"response.in_progress\",\"sequence_number\":1}",
    "{\"type\":\"response.future_thing\",\"sequence_number\":5}",
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello world\"}",
    "{\"type\":\"response.output_text.done\",\"output_index\":0,\"content_index\":0,\"text\":\"Hello world\"}",
    "{\"type\":\"response.completed\",\"response\":{" ++ usage ++ "}}",
});

test "responses passes the conformance suite" {
    var f: util.Factory(Responses) = .{ .cfg = .{ .api_key = "sk-test" } };
    defer f.deinit();
    const u: proto.Usage = .{ .input = 20, .cache_read = 100, .output = 30, .reasoning = 12 };
    try util.expectConformance(f.factory(), &.{
        .{ .name = "text_only", .body = text_only, .expect = .{ .text = "Hello world", .usage = u }, .cancel = true },
        .{ .name = "parallel_tools", .body = two_calls, .expect = .{ .tool_names = &.{ "read_file", "grep" }, .stop = .tool_use } },
        .{ .name = "reasoning_then_call", .body = reasoning_then_call, .expect = .{ .tool_names = &.{"read_file"}, .stop = .tool_use, .thinking = true } },
        .{ .name = "max_tokens", .body = incomplete, .expect = .{ .text = "cut", .stop = .max_tokens } },
        .{ .name = "usage", .body = unknown_events, .expect = .{ .text = "Hello world", .usage = u } },
        .{ .name = "failed", .body = failed, .expect = .{ .err = error.ServerError } },
        .{ .name = "tool_error_round_trip", .status = 400, .body = "{\"error\":{\"message\":\"No tool output found for function call call_a.\",\"type\":\"invalid_request_error\"}}", .expect = .{ .err = error.InvalidRequest } },
        .{ .name = "truncated", .body = text_only[0 .. text_only.len / 2], .expect = .{ .err = error.StreamTruncated } },
    });
}

test "reasoning item kept verbatim as provider_opaque" {
    var f: fake.FakeTransport = try .init(std.testing.allocator, &.{.{ .body = reasoning_then_call }});
    defer f.deinit();
    const r = try Responses.create(std.testing.allocator, f.transport(), .{});
    const p = r.provider();
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const resp = try p.stream(std.testing.io, arena.allocator(), &.{ .model = "m", .messages = &.{} }, .discard);
    try std.testing.expectEqualStrings("Need the file.", resp.message.content[0].thinking.text);
    const o = resp.message.content[1].provider_opaque;
    try std.testing.expectEqualStrings("reasoning", o.kind);
    try std.testing.expect(std.mem.indexOf(u8, o.raw_json, "\"encrypted_content\":\"gAAAAB\"") != null);
}

fn golden(name: []const u8, req: request.Request) !void {
    try util.expectBodyGolden(@src(), "openai_responses", name, &req, Responses.writeBody);
}

const schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}";
const hi = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "Hello" } }} }};
const tools = [_]request.ToolDecl{.{ .name = "read_file", .description = "Read", .input_schema_json = schema, .strict = true }};

test "golden request encodings" {
    try golden("plain", .{ .model = "gpt-5.5", .messages = &hi, .system = &.{ .{ .text = "Be brief." }, .{ .text = "Line two" } } });
    try golden("tools_required", .{ .model = "m", .messages = &hi, .tools = &tools, .tool_choice = .any, .parallel_tools = false });
    try golden("tool_named", .{ .model = "m", .messages = &hi, .tools = &tools, .tool_choice = .{ .tool = "read_file" } });
    try golden("effort", .{ .model = "m", .messages = &hi, .effort = .high, .max_output_tokens = 2000 });
    try golden("image", .{ .model = "m", .messages = &.{.{ .role = .user, .content = &.{ .{ .text = .{ .text = "what" } }, .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = "AA==" } } } } }} });
    const replay = [_]proto.Message{
        hi[0],
        .{ .role = .assistant, .content = &.{
            .{ .thinking = .{ .text = "summary", .signature = "", .origin = .openai_responses } },
            .{ .provider_opaque = .{ .origin = .openai_responses, .kind = "reasoning", .raw_json = "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"gAAAAB\",\"summary\":[]}" } },
            .{ .text = .{ .text = "Reading." } },
            .{ .tool_use = .{ .id = "call_a", .name = "read_file", .input_json = "{\"path\":\"a\"}" } },
        } },
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "call_a", .parts = &.{.{ .text = "contents" }} } }} },
    };
    try golden("reasoning_replay_order", .{ .model = "m", .messages = &replay, .tools = &tools });
    const multi = [_]proto.Message{
        hi[0],
        .{ .role = .assistant, .content = &.{.{ .tool_use = .{ .id = "call_a", .name = "shot", .input_json = "" } }} },
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "call_a", .parts = &.{ .{ .text = "a" }, .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = "AA==" } } } } } }} },
    };
    try golden("result_flattened", .{ .model = "m", .messages = &multi });
    try golden("structured_output", .{ .model = "m", .messages = &hi, .output_schema_json = "{\"type\":\"object\"}", .temperature = 0.2 });
}
