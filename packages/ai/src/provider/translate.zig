//! Prepares a transcript recorded with one provider for another: thinking
//! and opaque blocks are replayed only to the provider that produced them.
//! Tool ids are kept verbatim (both Anthropic `toolu_` and OpenAI `call_`
//! ids are opaque strings to every provider when they appear in history).

const std = @import("std");
const proto = @import("zg_ai_proto");

const Message = proto.Message;

/// Messages of `msgs` with foreign thinking/opaque blocks removed. Messages
/// that become empty are dropped and adjacent same-role messages merged, so
/// roles keep alternating. Returns `msgs` itself when nothing changes.
pub fn translateForProvider(arena: std.mem.Allocator, msgs: []const Message, target: proto.ProviderId) ![]const Message {
    var foreign = false;
    for (msgs) |m| for (m.content) |b| {
        if (isForeign(b, target)) foreign = true;
    };
    if (!foreign) return msgs;
    var out: std.ArrayList(Message) = .empty;
    for (msgs) |m| {
        var blocks: std.ArrayList(proto.ContentBlock) = .empty;
        for (m.content) |b| if (!isForeign(b, target)) try blocks.append(arena, b);
        if (blocks.items.len == 0) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1].role == m.role) {
            const prev = &out.items[out.items.len - 1];
            prev.content = try std.mem.concat(arena, proto.ContentBlock, &.{ prev.content, blocks.items });
            continue;
        }
        try out.append(arena, .{ .role = m.role, .content = blocks.items, .meta = m.meta });
    }
    return out.items;
}

fn isForeign(b: proto.ContentBlock, target: proto.ProviderId) bool {
    return switch (b) {
        .thinking => |t| t.origin != target,
        .provider_opaque => |o| o.origin != target,
        else => false,
    };
}

test "translate_drops_foreign_thinking" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const msgs = [_]Message{
        .{ .role = .user, .content = &.{.{ .text = .{ .text = "hi" } }} },
        .{ .role = .assistant, .content = &.{
            .{ .thinking = .{ .text = "t", .signature = "s", .origin = .anthropic } },
            .{ .text = .{ .text = "ok" } },
            .{ .tool_use = .{ .id = "toolu_1", .name = "x", .input_json = "{}" } },
        } },
        .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "toolu_1", .parts = &.{.{ .text = "r" }} } }} },
        .{ .role = .assistant, .content = &.{.{ .provider_opaque = .{ .origin = .anthropic, .kind = "server_tool_result", .raw_json = "{}" } }} },
        .{ .role = .assistant, .content = &.{.{ .text = .{ .text = "done" } }} },
    };
    const out = try translateForProvider(arena.allocator(), &msgs, .openai_chat);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqual(@as(usize, 2), out[1].content.len);
    try std.testing.expectEqualStrings("toolu_1", out[1].content[1].tool_use.id);
    try std.testing.expectEqualStrings("done", out[3].content[0].text.text);
    // Same provider: untouched.
    try std.testing.expectEqual(@as([*]const Message, &msgs), (try translateForProvider(arena.allocator(), &msgs, .anthropic)).ptr);
}
