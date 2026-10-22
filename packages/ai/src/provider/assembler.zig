//! Folds `StreamEvent`s into a canonical `Message`.
//!
//! Rules: block `index` values map to content positions in first-seen
//! order; tool input deltas are concatenated and parsed once at `finish`
//! (empty input means `{}`); `signature` attaches to the thinking block at
//! `index`; opaque blocks carry their raw JSON. Usage events are cumulative,
//! so each field keeps its maximum. Text deltas append to arena-backed
//! buffers: no allocation per delta beyond amortised growth.

const std = @import("std");
const proto = @import("zg_ai_proto");
const events = @import("events.zig");

const Allocator = std.mem.Allocator;
const StreamEvent = events.StreamEvent;
const BlockKind = events.BlockKind;

/// Assembly failures.
pub const AssembleError = error{ OutOfMemory, InvalidToolInput, UnknownBlock };

const Slot = struct {
    index: u32,
    kind: BlockKind,
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    citations: std.ArrayList(u8) = .empty,
    tool_id: []const u8 = "",
    tool_name: []const u8 = "",
    raw_json: ?[]const u8 = null,
    origin: proto.ProviderId = .unknown,
    opaque_kind: []const u8 = "",
    complete: bool = false,
};

/// Incremental message builder; everything lives in `arena`.
pub const MessageAssembler = struct {
    arena: Allocator,
    slots: std.ArrayList(Slot) = .empty,
    last: usize = 0,
    id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    usage: proto.Usage = .{},
    stop: ?proto.StopReason = null,
    rate_limit: ?events.RateLimitSnapshot = null,
    error_info: ?events.ErrorInfo = null,
    origin: proto.ProviderId = .unknown,

    /// A fresh assembler allocating from `arena`.
    pub fn init(arena: Allocator) MessageAssembler {
        return .{ .arena = arena };
    }

    fn slot(a: *MessageAssembler, index: u32) ?*Slot {
        if (a.last < a.slots.items.len and a.slots.items[a.last].index == index) return &a.slots.items[a.last];
        for (a.slots.items, 0..) |*s, i| if (s.index == index) {
            a.last = i;
            return s;
        };
        return null;
    }

    /// Folds one event.
    pub fn feed(a: *MessageAssembler, ev: StreamEvent) AssembleError!void {
        switch (ev) {
            .message_start => |m| {
                a.id = try a.arena.dupe(u8, m.id);
                a.model = try a.arena.dupe(u8, m.model);
            },
            .block_start => |b| {
                if (a.slot(b.index)) |_| return; // duplicate start: ignore
                var s: Slot = .{ .index = b.index, .kind = b.kind, .origin = if (b.origin == .unknown) a.origin else b.origin };
                if (b.tool_id) |t| s.tool_id = try a.arena.dupe(u8, t);
                if (b.tool_name) |t| s.tool_name = try a.arena.dupe(u8, t);
                if (b.raw_json) |r| s.raw_json = try a.arena.dupe(u8, r);
                if (b.opaque_kind) |k| s.opaque_kind = try a.arena.dupe(u8, k);
                try a.slots.append(a.arena, s);
                a.last = a.slots.items.len - 1;
            },
            .text_delta => |d| try (try a.need(d.index, .text)).text.appendSlice(a.arena, d.text),
            .thinking_delta => |d| try (try a.need(d.index, .thinking)).text.appendSlice(a.arena, d.text),
            .signature => |d| try (try a.need(d.index, .thinking)).signature.appendSlice(a.arena, d.value),
            .tool_input_delta => |d| try (try a.need(d.index, .tool_use)).text.appendSlice(a.arena, d.partial_json),
            .citation => |c| {
                const s = try a.need(c.index, .text);
                try s.citations.append(a.arena, if (s.citations.items.len == 0) '[' else ',');
                try s.citations.appendSlice(a.arena, c.json);
            },
            .block_stop => |b| if (a.slot(b.index)) |s| {
                s.complete = true;
            },
            .usage => |u| inline for (std.meta.fields(proto.Usage)) |f| {
                @field(a.usage, f.name) = @max(@field(a.usage, f.name), @field(u, f.name));
            },
            .stop => |r| a.stop = r,
            .rate_limit => |r| a.rate_limit = r,
            .provider_error => |e| a.error_info = .{
                .status = e.status,
                .kind = try a.arena.dupe(u8, e.kind),
                .message = try a.arena.dupe(u8, e.message),
                .retry_after_ms = e.retry_after_ms,
                .request_id = if (e.request_id) |r| try a.arena.dupe(u8, r) else null,
            },
            .ping, .warning, .retrying => {},
        }
    }

    /// Slot at `index`, created on the fly if a delta arrives without a start.
    fn need(a: *MessageAssembler, index: u32, kind: BlockKind) AssembleError!*Slot {
        if (a.slot(index)) |s| return s;
        try a.slots.append(a.arena, .{ .index = index, .kind = kind, .origin = a.origin });
        a.last = a.slots.items.len - 1;
        return &a.slots.items[a.last];
    }

    fn toBlock(a: *MessageAssembler, s: *const Slot) AssembleError!proto.ContentBlock {
        return switch (s.kind) {
            .text => .{ .text = .{ .text = s.text.items, .citations_json = if (s.citations.items.len > 0) try std.mem.concat(a.arena, u8, &.{ s.citations.items, "]" }) else null } },
            .thinking => .{ .thinking = .{ .text = s.text.items, .signature = s.signature.items, .origin = s.origin } },
            .redacted_thinking => .{ .thinking = .{ .text = "", .signature = s.raw_json orelse s.signature.items, .redacted = true, .origin = s.origin } },
            .tool_use, .server_tool_use => .{ .tool_use = .{
                .id = s.tool_id,
                .name = s.tool_name,
                .input_json = proto.json.canonicalize(a.arena, s.text.items) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidMessage => return error.InvalidToolInput,
                },
                .server = s.kind == .server_tool_use,
            } },
            .opaque_block => .{ .provider_opaque = .{ .origin = s.origin, .kind = s.opaque_kind, .raw_json = s.raw_json orelse "{}" } },
        };
    }

    fn meta(a: *const MessageAssembler) proto.Meta {
        return .{ .id = a.id, .model = a.model, .stop = a.stop, .usage = a.usage, .provider = if (a.origin == .unknown) null else a.origin };
    }

    /// The final message: every block, with tool inputs parsed.
    pub fn finish(a: *MessageAssembler) AssembleError!proto.Message {
        const blocks = try a.arena.alloc(proto.ContentBlock, a.slots.items.len);
        for (a.slots.items, blocks) |*s, *b| b.* = try a.toBlock(s);
        return .{ .role = .assistant, .content = blocks, .meta = a.meta() };
    }

    /// `finish`, except that a tool call cut by `max_tokens` is dropped
    /// (reported through `truncated_tool_use`) instead of failing.
    pub fn finishLenient(a: *MessageAssembler) AssembleError!struct { message: proto.Message, truncated_tool_use: bool } {
        const m = a.finish() catch |e| switch (e) {
            error.InvalidToolInput => if (a.stop == .max_tokens) {
                var p = try a.partial();
                p.meta.stop = .max_tokens;
                return .{ .message = p, .truncated_tool_use = true };
            } else return e,
            else => return e,
        };
        return .{ .message = m, .truncated_tool_use = false };
    }

    /// What can be kept after an interruption: completed blocks plus text
    /// so far. Incomplete tool_use and thinking blocks are dropped (they
    /// cannot be partially recovered).
    pub fn partial(a: *MessageAssembler) AssembleError!proto.Message {
        var out: std.ArrayList(proto.ContentBlock) = .empty;
        for (a.slots.items) |*s| {
            const keep = s.complete or s.kind == .text;
            if (!keep) continue;
            if (s.kind == .text and s.text.items.len == 0) continue;
            try out.append(a.arena, a.toBlock(s) catch |e| switch (e) {
                error.InvalidToolInput => continue,
                else => return e,
            });
        }
        var m = a.meta();
        m.stop = .canceled;
        return .{ .role = .assistant, .content = out.items, .meta = m };
    }
};

const testing = std.testing;

test "assembler folds parallel tool calls in stream order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var a: MessageAssembler = .init(arena.allocator());
    const evs = [_]StreamEvent{
        .{ .message_start = .{ .id = "msg_1", .model = "m" } },
        .{ .block_start = .{ .index = 0, .kind = .text } },
        .{ .text_delta = .{ .index = 0, .text = "Reading " } },
        .{ .text_delta = .{ .index = 0, .text = "files." } },
        .{ .block_stop = .{ .index = 0 } },
        .{ .block_start = .{ .index = 1, .kind = .tool_use, .tool_id = "a", .tool_name = "read" } },
        .{ .block_start = .{ .index = 2, .kind = .tool_use, .tool_id = "b", .tool_name = "read" } },
        .{ .tool_input_delta = .{ .index = 1, .partial_json = "{\"path\": " } },
        .{ .tool_input_delta = .{ .index = 2, .partial_json = "" } },
        .{ .tool_input_delta = .{ .index = 1, .partial_json = "\"x\"}" } },
        .{ .block_stop = .{ .index = 1 } },
        .{ .block_stop = .{ .index = 2 } },
        .{ .block_start = .{ .index = 3, .kind = .tool_use, .tool_id = "c", .tool_name = "grep" } },
        .{ .tool_input_delta = .{ .index = 3, .partial_json = "{\"q\":[1, 2]}" } },
        .{ .block_stop = .{ .index = 3 } },
        .{ .usage = .{ .input = 10 } },
        .{ .usage = .{ .input = 10, .output = 7 } },
        .{ .stop = .tool_use },
    };
    for (evs) |e| try a.feed(e);
    const m = try a.finish();
    try testing.expectEqual(@as(usize, 4), m.content.len);
    try testing.expectEqualStrings("Reading files.", m.content[0].text.text);
    try testing.expectEqualStrings("{\"path\":\"x\"}", m.content[1].tool_use.input_json);
    try testing.expectEqualStrings("{}", m.content[2].tool_use.input_json);
    try testing.expectEqualStrings("{\"q\":[1,2]}", m.content[3].tool_use.input_json);
    try testing.expectEqual(@as(u64, 7), m.meta.usage.?.output);
    try testing.expectEqual(proto.StopReason.tool_use, m.meta.stop.?);
}

test "assembler_partial_drops_incomplete_tool" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var a: MessageAssembler = .init(arena.allocator());
    try a.feed(.{ .block_start = .{ .index = 0, .kind = .thinking, .origin = .anthropic } });
    try a.feed(.{ .thinking_delta = .{ .index = 0, .text = "hmm" } });
    try a.feed(.{ .block_start = .{ .index = 1, .kind = .text } });
    try a.feed(.{ .text_delta = .{ .index = 1, .text = "Partial ans" } });
    try a.feed(.{ .block_start = .{ .index = 2, .kind = .tool_use, .tool_id = "t", .tool_name = "x" } });
    try a.feed(.{ .tool_input_delta = .{ .index = 2, .partial_json = "{\"a\":" } });
    const m = try a.partial();
    try testing.expectEqual(@as(usize, 1), m.content.len);
    try testing.expectEqualStrings("Partial ans", m.content[0].text.text);
    try testing.expectEqual(proto.StopReason.canceled, m.meta.stop.?);
    try testing.expectError(error.InvalidToolInput, a.finish());
}

test "signature, citations and opaque blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var a: MessageAssembler = .init(arena.allocator());
    try a.feed(.{ .block_start = .{ .index = 0, .kind = .thinking, .origin = .anthropic } });
    try a.feed(.{ .thinking_delta = .{ .index = 0, .text = "x" } });
    try a.feed(.{ .signature = .{ .index = 0, .value = "sig" } });
    try a.feed(.{ .block_start = .{ .index = 1, .kind = .text } });
    try a.feed(.{ .citation = .{ .index = 1, .json = "{\"n\":1}" } });
    try a.feed(.{ .citation = .{ .index = 1, .json = "{\"n\":2}" } });
    try a.feed(.{ .block_start = .{ .index = 2, .kind = .opaque_block, .raw_json = "{\"type\":\"r\"}", .opaque_kind = "r", .origin = .openai_responses } });
    const m = try a.finish();
    try testing.expectEqualStrings("sig", m.content[0].thinking.signature);
    try testing.expectEqualStrings("[{\"n\":1},{\"n\":2}]", m.content[1].text.citations_json.?);
    try testing.expectEqualStrings("r", m.content[2].provider_opaque.kind);
}
