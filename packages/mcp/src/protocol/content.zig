//! Content blocks (tool results, prompt messages, sampling) and resource
//! contents.

const std = @import("std");
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const codec = @import("codec.zig");
const messages = @import("messages.zig");

/// The sender or recipient of a message.
pub const Role = enum { user, assistant };

/// Hints for clients about how to use or display an object.
pub const Annotations = struct {
    audience: []const Role = &.{},
    priority: ?f64 = null,
    /// ISO 8601 timestamp, kept verbatim.
    last_modified: ?[]const u8 = null,
    extra: ?Value = null,
};

/// `{ type: "text" }`.
pub const Text = struct {
    text: []const u8,
    annotations: ?Annotations = null,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// `{ type: "image" }` and `{ type: "audio" }`: base64 `data` plus MIME type.
pub const Binary = struct {
    data: []const u8,
    mime_type: []const u8,
    annotations: ?Annotations = null,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// `{ type: "resource_link" }`: a `Resource` the client may read.
pub const ResourceLink = messages.Resource;

/// The contents of a resource: text or base64 `blob`.
pub const ResourceContents = struct {
    uri: []const u8,
    mime_type: ?[]const u8 = null,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// `{ type: "resource" }`: resource contents embedded in a message.
pub const EmbeddedResource = struct {
    resource: ResourceContents,
    annotations: ?Annotations = null,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// `{ type: "tool_use" }` in sampling messages (2025-11-25+).
pub const ToolUse = struct {
    id: []const u8,
    name: []const u8,
    input: Value,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// `{ type: "tool_result" }` in sampling messages (2025-11-25+).
pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const ContentBlock = &.{},
    structured_content: ?Value = null,
    is_error: ?bool = null,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// One content block, discriminated by `type`. Unknown types decode to
/// `.unknown` with the whole object, and re-encode verbatim.
pub const ContentBlock = union(enum) {
    text: Text,
    image: Binary,
    audio: Binary,
    resource_link: ResourceLink,
    resource: EmbeddedResource,
    tool_use: ToolUse,
    tool_result: ToolResult,
    unknown: Value,

    /// Codec hook: dispatches on `type`.
    pub fn jsonDecode(ctx: *codec.Ctx, v: Value) codec.DecodeError!ContentBlock {
        if (v != .object) return ctx.fail(error.TypeMismatch);
        const t = v.object.get("type") orelse return ctx.missing("type");
        if (t != .string) return ctx.fail(error.TypeMismatch);
        inline for (@typeInfo(ContentBlock).@"union".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "unknown")) continue;
            if (std.mem.eql(u8, t.string, f.name))
                return @unionInit(ContentBlock, f.name, try ctx.decodeSkipping(f.type, v, "type"));
        }
        return .{ .unknown = v };
    }

    /// Codec hook: writes `type` first.
    pub fn jsonEncode(c: ContentBlock, s: *Stringify) Stringify.Error!void {
        switch (c) {
            .unknown => |v| try s.write(v),
            inline else => |payload, tag| try codec.encodeTagged(s, payload, "type", @tagName(tag)),
        }
    }

    /// A text block.
    pub fn textBlock(text: []const u8) ContentBlock {
        return .{ .text = .{ .text = text } };
    }
};

/// Sampling `content`: one block or an array of blocks (SAMPLING "Result
/// Fields"), normalized to `items`; `single` remembers the wire shape.
pub const SamplingContent = struct {
    items: []const ContentBlock,
    single: bool = false,

    /// Codec hook.
    pub fn jsonDecode(ctx: *codec.Ctx, v: Value) codec.DecodeError!SamplingContent {
        if (v == .array) return .{ .items = try ctx.decode([]const ContentBlock, v) };
        const one = try ctx.arena.alloc(ContentBlock, 1);
        one[0] = try ctx.decode(ContentBlock, v);
        return .{ .items = one, .single = true };
    }

    /// Codec hook.
    pub fn jsonEncode(c: SamplingContent, s: *Stringify) Stringify.Error!void {
        if (c.single and c.items.len == 1) return codec.encodeValue(s, c.items[0]);
        return codec.encodeValue(s, c.items);
    }
};

const testing = std.testing;

test "protocol: sampling content single-vs-array normalized" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try codec.decodeBytes(SamplingContent, a, "{\"type\":\"text\",\"text\":\"hi\"}", .{});
    try testing.expectEqual(@as(usize, 1), one.items.len);
    try testing.expectEqualStrings("hi", one.items[0].text.text);
    const many = try codec.decodeBytes(SamplingContent, a,
        \\[{"type":"tool_use","id":"c1","name":"w","input":{"city":"Paris"}},{"type":"text","text":"x"}]
    , .{});
    try testing.expectEqual(@as(usize, 2), many.items.len);
    try testing.expectEqualStrings("c1", many.items[0].tool_use.id);
    try testing.expectEqualStrings("{\"type\":\"text\",\"text\":\"hi\"}", try codec.encodeAlloc(a, one));
}

test "protocol: unknown content type preserved" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\"type\":\"hologram\",\"data\":[1,2]}";
    const c = try codec.decodeBytes(ContentBlock, a, src, .{});
    try testing.expect(c == .unknown);
    try testing.expectEqualStrings(src, try codec.encodeAlloc(a, c));
}
