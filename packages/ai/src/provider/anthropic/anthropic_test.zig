//! Anthropic provider tests: request goldens, stream fixtures, the shared
//! conformance suite, HTTP error mapping, rate-limit headers, count_tokens
//! and list_models against the fake transport.

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const request = @import("../request.zig");
const events = @import("../events.zig");
const Provider = @import("../Provider.zig");
const fake = @import("../fake_server.zig");
const conformance = @import("../conformance.zig");
const encode = @import("encode.zig");
const decode = @import("decode.zig");
const Anthropic = @import("Anthropic.zig");

const testing = std.testing;
const Request = request.Request;
const Message = proto.Message;
const root = @import("zg_options").package_root;

fn goldenReq(comptime name: []const u8, req: Request, opts: encode.EncodeOptions) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = req;
    r.messages = try encode.normalizeMessages(a, r.messages);
    const body = try encode.bodyAlloc(a, &r, opts);
    // Valid JSON, and byte-stable.
    _ = try proto.json.parseValue(a, body);
    try testing.expectEqualStrings(body, try encode.bodyAlloc(a, &r, opts));
    try golden.expectGoldenOpts(testing.io, @src(), name, body, .{ .root = root, .dir = "testdata/golden/anthropic_requests" });
}

const user_hi = [_]Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "Hello" } }} }};
const schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}";
const read_tool = [_]request.ToolDecl{.{ .name = "read_file", .description = "Read a file", .input_schema_json = schema }};

test "golden: plain text" {
    try goldenReq("plain_text", .{ .model = "claude-opus-5-5", .messages = &user_hi, .max_output_tokens = 1024 }, .{});
}

test "golden: system with 2 breakpoints" {
    try goldenReq("system_breakpoints", .{ .model = "m", .messages = &user_hi, .system = &.{
        .{ .text = "You are zigguro.", .cache_break = true },
        .{ .text = "Project rules...", .cache_break = true },
        .{ .text = "env: linux", .stable = false },
    }, .cache = .{ .message_breaks = &.{0} } }, .{});
}

test "golden: tools and forced tool choice" {
    try goldenReq("tool_choice_tool", .{ .model = "m", .messages = &user_hi, .tools = &read_tool, .tool_choice = .{ .tool = "read_file" } }, .{});
}

test "golden: parallel results with text after" {
    const msgs = [_]Message{
        user_hi[0],
        .{ .role = .assistant, .content = &.{
            .{ .tool_use = .{ .id = "toolu_1", .name = "read_file", .input_json = "{\"path\":\"a\"}" } },
            .{ .tool_use = .{ .id = "toolu_2", .name = "read_file", .input_json = "{\"path\":\"b\"}" } },
        } },
        .{ .role = .user, .content = &.{
            .{ .text = .{ .text = "also check c" } },
            .{ .tool_result = .{ .tool_use_id = "toolu_1", .parts = &.{.{ .text = "A" }} } },
            .{ .tool_result = .{ .tool_use_id = "toolu_2", .parts = &.{ .{ .text = "B" }, .{ .text = "more" } }, .is_error = true } },
        } },
    };
    try goldenReq("parallel_results", .{ .model = "m", .messages = &msgs, .tools = &read_tool, .parallel_tools = false }, .{});
}

test "golden: images" {
    const msgs = [_]Message{.{ .role = .user, .content = &.{
        .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = "iVBORw0KGgo=" } } },
        .{ .image = .{ .media_type = "image/jpeg", .data = .{ .url = "https://example.com/a.jpg" } } },
        .{ .text = .{ .text = "What is this?" } },
    } }};
    try goldenReq("images", .{ .model = "m", .messages = &msgs }, .{});
}

test "golden: thinking budget" {
    try goldenReq("thinking_budget", .{ .model = "m", .messages = &user_hi, .thinking = .{ .budget = 4096 }, .max_output_tokens = 16000, .temperature = 0.5 }, .{});
}

test "golden: adaptive thinking with effort" {
    try goldenReq("thinking_adaptive_effort", .{ .model = "m", .messages = &user_hi, .thinking = .adaptive, .effort = .high }, .{});
}

test "golden: redacted thinking replay" {
    const msgs = [_]Message{
        user_hi[0],
        .{ .role = .assistant, .content = &.{
            .{ .thinking = .{ .text = "hmm", .signature = "sig1", .origin = .anthropic } },
            .{ .thinking = .{ .text = "", .signature = "EmwKAhgB", .redacted = true, .origin = .anthropic } },
            .{ .text = .{ .text = "Hi!" } },
        } },
        .{ .role = .user, .content = &.{.{ .text = .{ .text = "again" } }} },
    };
    try goldenReq("redacted_thinking", .{ .model = "m", .messages = &msgs, .thinking = .adaptive }, .{});
}

test "golden: consecutive user messages merged" {
    const msgs = [_]Message{ user_hi[0], .{ .role = .user, .content = &.{.{ .text = .{ .text = "and more" } }} } };
    try goldenReq("consecutive_user_merge", .{ .model = "m", .messages = &msgs }, .{});
}

test "golden: strict tools" {
    const tools = [_]request.ToolDecl{.{ .name = "read_file", .description = "Read", .input_schema_json = schema, .strict = true }};
    try goldenReq("strict_tools", .{ .model = "m", .messages = &user_hi, .tools = &tools }, .{ .strict_tools = true });
}

test "golden: auto cache" {
    try goldenReq("auto_cache", .{ .model = "m", .messages = &user_hi }, .{ .auto_cache = .h1 });
}

test "golden: 1h ttl breakpoints" {
    const tools = [_]request.ToolDecl{.{ .name = "read_file", .description = "Read", .input_schema_json = schema, .cache_break = true }};
    try goldenReq("ttl_1h", .{ .model = "m", .messages = &user_hi, .tools = &tools, .cache = .{ .ttl = .h1, .message_breaks = &.{0} } }, .{});
}

test "golden: forced choice downgraded with thinking" {
    try goldenReq("forced_choice_thinking", .{ .model = "m", .messages = &user_hi, .tools = &read_tool, .tool_choice = .any, .thinking = .{ .budget = 2048 } }, .{});
}

test "golden: server web_search passthrough" {
    const tools = [_]request.ToolDecl{ read_tool[0], .{ .name = "web_search", .description = "", .input_schema_json = "{}", .kind = .provider_native, .raw_json = "{\"type\":\"web_search_20250305\",\"name\":\"web_search\",\"max_uses\":5}" } };
    try goldenReq("server_web_search", .{ .model = "m", .messages = &user_hi, .tools = &tools }, .{});
}

test "golden: empty tool input" {
    const msgs = [_]Message{
        user_hi[0],
        .{ .role = .assistant, .content = &.{.{ .tool_use = .{ .id = "toolu_1", .name = "list", .input_json = "" } }} },
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "toolu_1", .parts = &.{.{ .text = "ok" }} } }} },
    };
    try goldenReq("empty_tool_input", .{ .model = "m", .messages = &msgs }, .{});
}

test "breakpoint_limit_assert" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sys = [_]request.SystemPart{ .{ .text = "a", .cache_break = true }, .{ .text = "b", .cache_break = true }, .{ .text = "c", .cache_break = true } };
    const req: Request = .{ .model = "m", .messages = &user_hi, .system = &sys, .cache = .{ .message_breaks = &.{ 0, 0 } } };
    try testing.expectError(error.TooManyCacheBreakpoints, encode.bodyAlloc(arena.allocator(), &req, .{}));
}

// Stream fixtures: decode each and compare the event log with a golden.

const fixtures = .{
    "text_only",         "parallel_tools_3",        "thinking_signature",   "redacted_thinking",
    "server_web_search", "ping_interleaved",        "error_overloaded_mid", "unknown_event_and_delta",
    "truncated_no_stop", "max_tokens_cut_tool_use", "refusal",
};

const Log = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    fn emit(ctx: *anyopaque, ev: events.StreamEvent) void {
        const l: *Log = @ptrCast(@alignCast(ctx));
        var w: std.Io.Writer.Allocating = .init(l.arena);
        std.json.Stringify.value(ev, .{ .emit_null_optional_fields = false }, &w.writer) catch return;
        l.out.appendSlice(l.arena, w.written()) catch {};
        l.out.append(l.arena, '\n') catch {};
    }
};

fn decodeFixture(a: std.mem.Allocator, body: []const u8, log: *Log) !request.Response {
    const zg_net = @import("zg_net");
    var d: decode.Decoder = .init(a, .{ .ctx = log, .emit = Log.emit });
    var p: zg_net.sse.Parser = .init(a, .{});
    try p.feed(body, &d);
    p.finish();
    return d.finish();
}

test "stream fixtures decode to golden event logs" {
    inline for (fixtures) |name| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var log: Log = .{ .arena = a };
        const result = decodeFixture(a, @embedFile("testdata/" ++ name ++ ".sse"), &log);
        if (result) |resp| {
            try log.out.appendSlice(a, "=> ");
            try log.out.appendSlice(a, try proto.json.messageAlloc(a, resp.message));
            if (resp.truncated_tool_use) try log.out.appendSlice(a, " (truncated tool_use)");
        } else |e| {
            try log.out.appendSlice(a, "=> error.");
            try log.out.appendSlice(a, @errorName(e));
        }
        try golden.expectGoldenOpts(testing.io, @src(), name, log.out.items, .{ .root = root, .dir = "testdata/golden/anthropic_streams" });
    }
}

const Factory = struct {
    fake: ?fake.FakeTransport = null,
    fn make(ctx: *anyopaque, gpa: std.mem.Allocator, fx: *const conformance.Fixture, opts: conformance.MakeOptions) anyerror!Provider {
        const self: *Factory = @ptrCast(@alignCast(ctx));
        if (self.fake) |*f| f.deinit();
        const routes = try gpa.alloc(fake.Route, 1);
        routes[0] = .{ .status = fx.status, .headers = fx.headers, .body = fx.body, .chunk_size = opts.chunk_size, .chunk_delay_ms = opts.chunk_delay_ms };
        self.fake = try .init(gpa, routes);
        // The route lives in the fake's arena.
        const owned = try self.fake.?.arena.allocator().dupe(fake.Route, routes);
        gpa.free(routes);
        self.fake.?.routes = owned;
        const p = try Anthropic.create(gpa, self.fake.?.transport(), .{ .api_key = "sk-test" });
        return p.provider();
    }
};

test "anthropic passes the provider conformance suite" {
    var f: Factory = .{};
    defer if (f.fake) |*x| x.deinit();
    const fx = [_]conformance.Fixture{
        .{ .name = "text_only", .body = @embedFile("testdata/text_only.sse"), .expect = .{ .text = "Hello world", .usage = .{ .input = 25, .cache_read = 100, .output = 12 } }, .cancel = true },
        .{ .name = "parallel_tools", .body = @embedFile("testdata/parallel_tools_3.sse"), .expect = .{ .text = "Reading.", .tool_names = &.{ "read_file", "read_file", "grep" }, .stop = .tool_use } },
        .{ .name = "usage", .body = @embedFile("testdata/ping_interleaved.sse"), .expect = .{ .usage = .{ .input = 25, .cache_read = 100, .output = 12 } } },
        .{ .name = "max_tokens", .body = @embedFile("testdata/max_tokens_cut_tool_use.sse"), .expect = .{ .stop = .max_tokens } },
        .{ .name = "thinking", .body = @embedFile("testdata/thinking_signature.sse"), .expect = .{ .text = "42", .thinking = true } },
        .{ .name = "refusal", .body = @embedFile("testdata/refusal.sse"), .expect = .{ .stop = .refusal } },
        .{ .name = "overloaded_mid_stream", .body = @embedFile("testdata/error_overloaded_mid.sse"), .expect = .{ .err = error.Overloaded } },
        .{ .name = "truncated", .body = @embedFile("testdata/truncated_no_stop.sse"), .expect = .{ .err = error.StreamTruncated } },
        .{ .name = "tool_error_round_trip", .status = 400, .body = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"tool_use ids must be unique\"}}", .expect = .{ .err = error.InvalidRequest } },
    };
    var report = try conformance.runConformance(testing.io, testing.allocator, .{ .ctx = &f, .make = Factory.make }, .{ .fixtures = &fx, .request = .{ .model = "claude-opus-5-5", .messages = &user_hi } });
    defer report.deinit(testing.allocator);
    for (report.failures.items) |x| std.debug.print("{s}\n", .{x});
    try testing.expectEqual(@as(u32, 0), report.failed);
}

test "http_error_body_mapping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Row = struct { status: u16, kind: []const u8, msg: []const u8, retry_after: bool, want: Provider.StreamError };
    const rows = [_]Row{
        .{ .status = 400, .kind = "invalid_request_error", .msg = "bad", .retry_after = false, .want = error.InvalidRequest },
        .{ .status = 400, .kind = "invalid_request_error", .msg = "prompt is too long: 201000 tokens > 200000 maximum", .retry_after = false, .want = error.ContextOverflow },
        .{ .status = 401, .kind = "authentication_error", .msg = "", .retry_after = false, .want = error.Auth },
        .{ .status = 403, .kind = "permission_error", .msg = "", .retry_after = false, .want = error.Auth },
        .{ .status = 404, .kind = "not_found_error", .msg = "", .retry_after = false, .want = error.InvalidRequest },
        .{ .status = 413, .kind = "request_too_large", .msg = "", .retry_after = false, .want = error.ContextOverflow },
        .{ .status = 429, .kind = "rate_limit_error", .msg = "", .retry_after = true, .want = error.RateLimited },
        .{ .status = 429, .kind = "rate_limit_error", .msg = "spend limit", .retry_after = false, .want = error.InvalidRequest },
        .{ .status = 529, .kind = "overloaded_error", .msg = "", .retry_after = false, .want = error.Overloaded },
    };
    for (rows) |r| {
        const body = try std.fmt.allocPrint(a, "{{\"type\":\"error\",\"error\":{{\"type\":\"{s}\",\"message\":\"{s}\"}},\"request_id\":\"req_1\"}}", .{ r.kind, r.msg });
        const e = decode.parseHttpError(a, body);
        try testing.expectEqualStrings("req_1", e.request_id.?);
        try testing.expectEqual(r.want, decode.classifyHttp(r.status, e, r.retry_after));
    }
}

test "ratelimit_headers_parsed" {
    const hs = [_]request.Header{
        .{ .name = "anthropic-ratelimit-requests-limit", .value = "50" },
        .{ .name = "anthropic-ratelimit-requests-remaining", .value = "49" },
        .{ .name = "Anthropic-RateLimit-Tokens-Remaining", .value = "79000" },
        .{ .name = "anthropic-ratelimit-input-tokens-remaining", .value = "40000" },
        .{ .name = "anthropic-ratelimit-output-tokens-remaining", .value = "8000" },
        .{ .name = "retry-after", .value = "3" },
        .{ .name = "content-type", .value = "text/event-stream" },
    };
    const r = decode.rateLimitFrom(&hs).?;
    try testing.expectEqual(@as(?u64, 50), r.requests_limit);
    try testing.expectEqual(@as(?u64, 49), r.requests_remaining);
    try testing.expectEqual(@as(?u64, 79000), r.tokens_remaining);
    try testing.expectEqual(@as(?u64, 8000), r.output_tokens_remaining);
    try testing.expectEqual(@as(?u64, 3000), r.retry_after_ms);
    try testing.expect(decode.rateLimitFrom(hs[6..]) == null);
}

test "count_tokens and list_models over the fake transport" {
    const routes = [_]fake.Route{
        .{ .url_contains = "/v1/messages/count_tokens", .body = "{\"input_tokens\":14}" },
        .{ .url_contains = "after_id=m2", .body = "{\"data\":[{\"id\":\"m3\",\"display_name\":\"Three\",\"max_input_tokens\":1000000,\"max_tokens\":128000}],\"has_more\":false,\"last_id\":\"m3\"}" },
        .{ .url_contains = "after_id=m1", .body = "{\"data\":[{\"id\":\"m2\"}],\"has_more\":true,\"last_id\":\"m2\"}" },
        .{ .url_contains = "/v1/models", .body = "{\"data\":[{\"id\":\"m1\",\"max_input_tokens\":200000}],\"has_more\":true,\"last_id\":\"m1\"}" },
    };
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    const a_ = try Anthropic.create(testing.allocator, f.transport(), .{ .api_key = "sk-test", .base_url = "https://api.test/" });
    const p = a_.provider();
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tools = [_]request.ToolDecl{ read_tool[0], .{ .name = "web_search", .description = "", .input_schema_json = "{}", .kind = .provider_native, .raw_json = "{\"type\":\"web_search_20250305\",\"name\":\"web_search\"}" } };
    try testing.expectEqual(@as(u64, 14), try p.countTokens(testing.io, arena.allocator(), &.{ .model = "m", .messages = &user_hi, .tools = &tools }));
    const sent = f.requests()[0];
    try testing.expectEqualStrings("https://api.test/v1/messages/count_tokens", sent.url);
    try testing.expect(std.mem.indexOf(u8, sent.body, "web_search") == null);
    try testing.expect(std.mem.indexOf(u8, sent.body, "\"stream\"") == null);
    const models = try p.listModels(testing.io, arena.allocator());
    try testing.expectEqual(@as(usize, 3), models.len);
    try testing.expectEqualStrings("m3", models[2].id);
    try testing.expectEqual(@as(?u32, 128000), models[2].max_output);
    try testing.expectEqual(@as(?u32, 200000), models[0].context_window);
}

test "stream sends key, version and beta headers" {
    const routes = [_]fake.Route{.{ .body = @embedFile("testdata/text_only.sse"), .headers = &.{.{ .name = "request-id", .value = "req_9" }} }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    const a_ = try Anthropic.create(testing.allocator, f.transport(), .{ .betas = &.{ "a-1", "b-2" } });
    const p = a_.provider();
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const resp = try p.stream(testing.io, arena.allocator(), &.{ .model = "m", .messages = &user_hi, .api_key = "sk-req" }, .discard);
    try testing.expectEqualStrings("req_9", resp.request_id.?);
    const hs = f.requests()[0].headers;
    var seen: u8 = 0;
    for (hs) |h| {
        if (std.mem.eql(u8, h.name, "x-api-key") and std.mem.eql(u8, h.value, "sk-req")) seen += 1;
        if (std.mem.eql(u8, h.name, "anthropic-version") and std.mem.eql(u8, h.value, "2023-06-01")) seen += 1;
        if (std.mem.eql(u8, h.name, "anthropic-beta") and std.mem.eql(u8, h.value, "a-1,b-2")) seen += 1;
    }
    try testing.expectEqual(@as(u8, 3), seen);
}
