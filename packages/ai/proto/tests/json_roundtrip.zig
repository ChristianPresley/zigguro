//! Golden round trips for every canonical type: encode → decode → encode
//! must reproduce `proto/testdata/golden/<case>.golden` byte for byte.

const std = @import("std");
const golden = @import("zg_core").testkit.golden;
const proto = @import("../root.zig");
const json = proto.json;

const golden_opts: golden.Options = .{ .dir = "proto/testdata/golden", .root = @import("zg_options").package_root, .normalize = .text };

fn roundTripMessage(comptime name: []const u8, m: proto.Message) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try json.messageAlloc(a, m);
    const back = try json.decodeMessageText(a, first);
    const second = try json.messageAlloc(a, back);
    try std.testing.expectEqualStrings(first, second);
    try golden.expectGoldenOpts(std.testing.io, @src(), name, second, golden_opts);
}

fn roundTripValue(comptime T: type, comptime name: []const u8, v: T) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try json.encodeValue(&out.writer, v);
    const first = out.written();
    const back = try json.decodeValue(T, a, try json.parseValue(a, first));
    var out2: std.Io.Writer.Allocating = .init(a);
    try json.encodeValue(&out2.writer, back);
    try std.testing.expectEqualStrings(first, out2.written());
    try golden.expectGoldenOpts(std.testing.io, @src(), name, first, golden_opts);
}

test "golden: text block" {
    try roundTripMessage("text", .{ .role = .user, .content = &.{
        .{ .text = .{ .text = "Hello \"world\"\n\u{1F600}" } },
        .{ .text = .{ .text = "cited", .citations_json = "[{\"type\":\"char_location\",\"start\":0}]" } },
    } });
}

test "golden: image block" {
    try roundTripMessage("image", .{ .role = .user, .content = &.{
        .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = "iVBORw0KGgo=" } } },
        .{ .image = .{ .media_type = "image/jpeg", .data = .{ .url = "https://example.com/a.jpg" } } },
        .{ .image = .{ .media_type = "image/gif", .data = .{ .file = "assets/x.gif" } } },
    } });
}

test "golden: document block" {
    try roundTripMessage("document", .{ .role = .user, .content = &.{
        .{ .document = .{ .media_type = "application/pdf", .data = .{ .file = "docs/spec.pdf" }, .title = "Spec" } },
    } });
}

test "golden: thinking block" {
    try roundTripMessage("thinking", .{ .role = .assistant, .content = &.{
        .{ .thinking = .{ .text = "Let me think.", .signature = "EqQBCkYIARgCIkB", .origin = .anthropic } },
        .{ .thinking = .{ .text = "", .signature = "opaque", .redacted = true, .origin = .anthropic } },
    } });
}

test "golden: tool_use block" {
    try roundTripMessage("tool_use", .{
        .role = .assistant,
        .content = &.{
            .{ .tool_use = .{ .id = "toolu_01", .name = "read_file", .input_json = "{\"path\":\"src/main.zig\",\"limit\":20}" } },
            .{ .tool_use = .{ .id = "srvtoolu_02", .name = "web_search", .input_json = "{\"query\":\"zig\"}", .server = true } },
        },
        .meta = .{ .id = "msg_1", .model = "claude-opus-5-5", .provider = .anthropic, .stop = .tool_use, .usage = .{ .input = 10, .output = 5 } },
    });
}

test "golden: tool_result block" {
    try roundTripMessage("tool_result", .{ .role = .user, .content = &.{
        .{ .tool_result = .{ .tool_use_id = "toolu_01", .parts = &.{
            .{ .text = "1\tconst std = @import(\"std\");" },
            .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = "AA==" } } },
            .{ .document = .{ .media_type = "text/plain", .data = .{ .base64 = "aGk=" }, .title = "hi" } },
            .{ .resource_link = .{ .uri = "file:///a.txt", .name = "a.txt", .mime = "text/plain" } },
        } } },
        .{ .tool_result = .{ .tool_use_id = "toolu_02", .parts = &.{.{ .text = "Invalid input" }}, .is_error = true } },
    } });
}

test "golden: provider_opaque block" {
    try roundTripMessage("provider_opaque", .{ .role = .assistant, .content = &.{
        .{ .provider_opaque = .{ .origin = .openai_responses, .kind = "reasoning", .raw_json = "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"gAAA\",\"summary\":[]}" } },
        .{ .provider_opaque = .{ .origin = .unknown, .kind = "web_search_tool_result", .raw_json = "{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srvtoolu_02\",\"content\":[]}" } },
    } });
}

test "golden: usage" {
    try roundTripValue(proto.Usage, "usage", .{ .input = 1200, .output = 340, .cache_read = 9000, .cache_write_5m = 100, .cache_write_1h = 50, .reasoning = 20, .server_tool_requests = 2 });
}

test "golden: context items (all ref kinds)" {
    const items = [_]proto.ContextItem{
        .{ .ref = .{ .file = "src/a.zig" }, .title = "a.zig", .mime = "text/x-zig", .text = "const a = 1;", .tokens = 5, .version_hash = 1 },
        .{ .ref = .{ .range = .{ .path = "src/a.zig", .lines = .{ 3, 9 } } }, .title = "a.zig:3-9", .mime = "text/x-zig", .text = "", .tokens = 0, .version_hash = 2 },
        .{ .ref = .{ .folder = "src" }, .title = "src/", .mime = "text/plain", .text = "a.zig\nb.zig", .tokens = 4, .version_hash = 3, .truncated = true, .omitted = &.{"c.zig"} },
        .{ .ref = .{ .note = .{ .target = "Daily/2026-10-22", .depth = 1 } }, .title = "note", .mime = "text/markdown", .text = "# hi", .tokens = 2, .version_hash = 4 },
        .{ .ref = .{ .symbol = "Agent.submit" }, .title = "sym", .mime = "text/x-zig", .text = "", .tokens = 0, .version_hash = 5 },
        .{ .ref = .{ .search = "TODO" }, .title = "search", .mime = "text/plain", .text = "", .tokens = 0, .version_hash = 6 },
        .{ .ref = .{ .tag = "#perf" }, .title = "tag", .mime = "text/plain", .text = "", .tokens = 0, .version_hash = 7 },
        .{ .ref = .{ .selection = .{ .doc = 42, .range = .{ 10, 20 } } }, .title = "sel", .mime = "text/plain", .text = "x", .tokens = 1, .version_hash = 8 },
        .{ .ref = .{ .terminal = .{ .terminal = 3, .block = 7 } }, .title = "term", .mime = "text/plain", .text = "$ ls", .tokens = 2, .version_hash = 9 },
        .{ .ref = .{ .url = "https://ziglang.org" }, .title = "url", .mime = "text/html", .text = "", .tokens = 0, .version_hash = 10 },
        .{ .ref = .{ .scm_diff = "HEAD~1..HEAD" }, .title = "diff", .mime = "text/x-diff", .text = "", .tokens = 0, .version_hash = 11 },
    };
    try roundTripValue([]const proto.ContextItem, "context_items", &items);
}

test "golden: assist request" {
    try roundTripValue(proto.AssistRequest, "assist_request", .{
        .kind = .explain_error,
        .prompt = "Why did this fail?",
        .context = &.{.{ .ref = .{ .terminal = .{ .terminal = 1 } }, .title = "t", .mime = "text/plain", .text = "error: x", .tokens = 3, .version_hash = 0 }},
        .output_schema_json = "{\"type\":\"object\"}",
        .origin = "terminal",
    });
}

test "fuzz: proto_decode" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const m = json.decodeMessageText(arena.allocator(), input) catch return;
            // Anything that decodes re-encodes and decodes again identically.
            const a = try json.messageAlloc(arena.allocator(), m);
            const b = try json.messageAlloc(arena.allocator(), try json.decodeMessageText(arena.allocator(), a));
            try std.testing.expectEqualStrings(a, b);
        }
    }.one, .{ .corpus = &.{
        "{\"role\":\"user\",\"content\":\"hi\"}",
        "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"b\",\"input\":{\"x\":[1,2]}}]}",
    } });
}
