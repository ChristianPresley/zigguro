//! Gemini provider tests.

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("../request.zig");
const util = @import("../http_test_util.zig");
const fake = @import("../fake_server.zig");
const Gemini = @import("Gemini.zig");

const sse = util.sse;
const usage = "\"usageMetadata\":{\"promptTokenCount\":40,\"cachedContentTokenCount\":10,\"candidatesTokenCount\":8,\"thoughtsTokenCount\":3}";

const text = sse(&.{
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello\"}]}}],\"responseId\":\"r1\",\"modelVersion\":\"gemini-3-pro\"}",
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\" world\"}]},\"finishReason\":\"STOP\"}]," ++ usage ++ "}",
});
const calls_2 = sse(&.{
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"thought\":true,\"text\":\"plan\",\"thoughtSignature\":\"c2ln\"},{\"functionCall\":{\"id\":\"fc_1\",\"name\":\"read_file\",\"args\":{\"path\":\"a\"}},\"thoughtSignature\":\"c2lnMg==\"},{\"functionCall\":{\"name\":\"grep\",\"args\":{\"q\":\"x\"}}}]},\"finishReason\":\"STOP\"}]," ++ usage ++ "}",
});
const max_tokens = sse(&.{"{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"cut\"}]},\"finishReason\":\"MAX_TOKENS\"}]}"});
const truncated = sse(&.{"{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"half\"}]}}]}"});

test "gemini passes the conformance suite" {
    var f: util.Factory(Gemini) = .{ .cfg = .{ .api_key = "k" } };
    defer f.deinit();
    try util.expectConformance(f.factory(), &.{
        .{ .name = "text_only", .body = text, .expect = .{ .text = "Hello world", .usage = .{ .input = 30, .cache_read = 10, .output = 8, .reasoning = 3 } }, .cancel = true },
        .{ .name = "parallel_tools", .body = calls_2, .expect = .{ .tool_names = &.{ "read_file", "grep" }, .stop = .tool_use } },
        .{ .name = "usage", .body = text, .expect = .{ .usage = .{ .input = 30, .cache_read = 10, .output = 8, .reasoning = 3 } } },
        .{ .name = "max_tokens", .body = max_tokens, .expect = .{ .text = "cut", .stop = .max_tokens } },
        .{ .name = "truncated", .body = truncated, .expect = .{ .err = error.StreamTruncated } },
        .{ .name = "error_429", .status = 429, .body = "{\"error\":{\"code\":429,\"message\":\"Quota\",\"status\":\"RESOURCE_EXHAUSTED\"}}", .expect = .{ .err = error.RateLimited } },
        .{ .name = "tool_error_round_trip", .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"bad\",\"status\":\"INVALID_ARGUMENT\"}}", .expect = .{ .err = error.InvalidRequest } },
    });
}

test "function_result_roundtrip request golden" {
    var f: fake.FakeTransport = try .init(std.testing.allocator, &.{.{ .body = calls_2 }});
    defer f.deinit();
    const g = try Gemini.create(std.testing.allocator, f.transport(), .{ .api_key = "k" });
    const p = g.provider();
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hi = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "Hello" } }} }};
    const resp = try p.stream(std.testing.io, a, &.{ .model = "gemini-3-pro", .messages = &hi }, .discard);
    try std.testing.expectEqualStrings("gem_2", resp.message.content[3].tool_use.id);
    try std.testing.expectEqualStrings("x-goog-api-key", f.requests()[0].headers[1].name);
    try std.testing.expect(std.mem.endsWith(u8, f.requests()[0].url, "/models/gemini-3-pro:streamGenerateContent?alt=sse"));
    // Next turn: history with the thought part, signature and both results.
    const msgs = [_]proto.Message{
        hi[0],
        resp.message,
        .{ .role = .user, .content = &.{
            .{ .tool_result = .{ .tool_use_id = "fc_1", .parts = &.{.{ .text = "A" }} } },
            .{ .tool_result = .{ .tool_use_id = "gem_2", .parts = &.{.{ .text = "no match" }}, .is_error = true } },
        } },
    };
    const tools = [_]request.ToolDecl{ .{ .name = "read_file", .description = "Read", .input_schema_json = "{\"type\":\"object\"}" }, .{ .name = "grep", .description = "Search", .input_schema_json = "{\"type\":\"object\"}" } };
    const req: request.Request = .{ .model = "gemini-3-pro", .messages = &msgs, .tools = &tools, .system = &.{.{ .text = "Be brief." }}, .thinking = .{ .budget = 1024 } };
    try util.expectBodyGolden(@src(), "gemini", "function_result_roundtrip", &req, Gemini.writeBody);
}
