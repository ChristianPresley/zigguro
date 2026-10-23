//! Binds E12's completion `ChatPort` to an E10 `zg_ai.Provider`: the chat
//! fallback for ghost-text completions when no FIM server is configured.
//! The call runs on the completion engine's task and streams text deltas
//! only. Whitespace-only stop sequences are left out (Anthropic rejects
//! them); post-processing cuts single-line completions at the newline.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_review = @import("zg_review");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = zg_ai.proto;
const complete = zg_review.assist.complete;
const ChatRequest = complete.provider_chat.ChatRequest;

pub const ChatCompletionPort = struct {
    provider: zg_ai.Provider,

    pub fn port(p: *ChatCompletionPort) complete.ChatPort {
        return .{ .ctx = p, .stream = stream };
    }

    fn stream(ctx: *anyopaque, io: Io, arena: Allocator, r: *const ChatRequest, sink: complete.providers.Sink) anyerror!void {
        const p: *ChatCompletionPort = @ptrCast(@alignCast(ctx));
        const req = try request(arena, r);
        var relay: Relay = .{ .sink = sink };
        _ = try p.provider.stream(io, arena, &req, .{ .ctx = &relay, .emit = Relay.emit });
        if (relay.err) |e| return e;
    }

    const Relay = struct {
        sink: complete.providers.Sink,
        err: ?anyerror = null,

        fn emit(ctx: ?*anyopaque, ev: zg_ai.StreamEvent) void {
            const relay: *Relay = @ptrCast(@alignCast(ctx.?));
            if (relay.err != null) return;
            switch (ev) {
                .text_delta => |d| relay.sink.text(relay.sink.ctx, d.text) catch |e| {
                    relay.err = e;
                },
                else => {},
            }
        }
    };
};

/// The provider request for `r` (in `arena`).
pub fn request(arena: Allocator, r: *const ChatRequest) !zg_ai.Request {
    const system = try arena.alloc(zg_ai.request.SystemPart, 1);
    system[0] = .{ .text = r.system, .cache_break = true };
    const content = try arena.alloc(proto.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = r.user } };
    const messages = try arena.alloc(proto.Message, 1);
    messages[0] = .{ .role = .user, .content = content };
    var stops: std.ArrayList([]const u8) = .empty;
    for (r.stop) |s| if (std.mem.trim(u8, s, " \t\r\n").len > 0) try stops.append(arena, s);
    return .{
        .model = r.model,
        .system = system,
        .messages = messages,
        .max_output_tokens = r.max_tokens,
        .stop_sequences = stops.items,
        .temperature = r.temperature,
    };
}

const testing = std.testing;

test "chat completion port: request fields and streamed text" {
    const scripted = zg_ai.scripted;
    const sp = try scripted.ScriptedProvider.init(testing.allocator, &.{&.{
        .{ .event = .{ .message_start = .{ .id = "msg", .model = "m" } } },
        .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } },
        .{ .event = .{ .text_delta = .{ .index = 0, .text = "```zig\nret" } } },
        .{ .event = .{ .text_delta = .{ .index = 0, .text = "urn 1;\n```" } } },
        .{ .event = .{ .block_stop = .{ .index = 0 } } },
        .{ .event = .{ .stop = .end_turn } },
    }}, .{});
    defer sp.destroy();
    var cp: ChatCompletionPort = .{ .provider = sp.provider() };
    var fim: complete.ChatFim = .{ .opts = .{ .port = cp.port(), .model = "haiku" } };

    const Collect = struct {
        buf: std.ArrayList(u8) = .empty,
        fn f(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            try c.buf.appendSlice(testing.allocator, bytes);
        }
    };
    var got: Collect = .{};
    defer got.buf.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: complete.CompletionRequest = .{ .path = "a.zig", .language = "zig", .prefix = "    re", .suffix = "\n}", .multiline = false, .max_tokens = 32, .stop = &.{"\n"} };
    try fim.provider().complete(testing.io, arena.allocator(), &req, .{ .ctx = &got, .text = Collect.f });
    try testing.expectEqualStrings("return 1;", got.buf.items);

    const sent = sp.requests()[0];
    try testing.expectEqualStrings("haiku", sent.model);
    try testing.expect(sent.system[0].cache_break);
    try testing.expectEqual(@as(usize, 0), sent.stop_sequences.len);
    try testing.expectEqual(@as(?f32, 0), sent.temperature);
    try testing.expect(std.mem.indexOf(u8, sent.messages[0].content[0].text.text, "    re<CURSOR>\n}") != null);
}
