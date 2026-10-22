//! Canonical conversation model shared by every provider, the agent loop,
//! sessions, the UI and the CLI (E10.F01). All slices are borrowed; see the
//! ownership note in `root.zig`.

const std = @import("std");

/// Which provider (or test double) produced a provider-specific artefact.
/// `unknown` marks blocks decoded from JSON whose producer is not recorded;
/// they are never replayed to any provider.
pub const ProviderId = enum { anthropic, openai_responses, openai_chat, gemini, scripted, cassette, unknown };

/// Conversation role. System text travels in `Request.system`, not here.
pub const Role = enum { user, assistant };

/// Binary payload of an image or document.
pub const Blob = union(enum) {
    /// Base64 data (no `data:` prefix).
    base64: []const u8,
    /// Remote URL the provider fetches.
    url: []const u8,
    /// Workspace-relative path, loaded lazily when the request is encoded.
    file: []const u8,
};

/// One part of a tool result. Mirrors Anthropic tool_result content blocks
/// and the MCP content types.
pub const ResultPart = union(enum) {
    text: []const u8,
    image: struct { media_type: []const u8, data: Blob },
    document: struct { media_type: []const u8, data: Blob, title: ?[]const u8 = null },
    resource_link: struct { uri: []const u8, name: []const u8, mime: ?[]const u8 = null },
};

/// One block of message content.
pub const ContentBlock = union(enum) {
    text: struct { text: []const u8, citations_json: ?[]const u8 = null },
    image: struct { media_type: []const u8, data: Blob },
    document: struct { media_type: []const u8, data: Blob, title: ?[]const u8 = null },
    /// Model reasoning. `signature` must be replayed verbatim, and only to `origin`.
    thinking: struct { text: []const u8, signature: []const u8, redacted: bool = false, origin: ProviderId },
    /// `input_json` is canonical JSON text of the tool input object.
    tool_use: struct { id: []const u8, name: []const u8, input_json: []const u8, server: bool = false },
    tool_result: struct { tool_use_id: []const u8, parts: []const ResultPart, is_error: bool = false },
    /// Anything provider-specific that must survive a round trip, e.g. an
    /// OpenAI reasoning item or an Anthropic server tool result.
    provider_opaque: struct { origin: ProviderId, kind: []const u8, raw_json: []const u8 },

    /// The tag name, which is also the JSON `"type"` discriminator.
    pub fn kind(b: ContentBlock) []const u8 {
        return @tagName(b);
    }
};

/// Why a model stopped producing output.
pub const StopReason = enum { end_turn, max_tokens, stop_sequence, tool_use, pause_turn, refusal, context_window_exceeded, canceled, failed };

/// Token usage of one request (or a sum of several).
pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write_5m: u64 = 0,
    cache_write_1h: u64 = 0,
    reasoning: u64 = 0,
    server_tool_requests: u32 = 0,

    /// Adds `b` into `a` field by field.
    pub fn add(a: *Usage, b: Usage) void {
        inline for (std.meta.fields(Usage)) |f| @field(a, f.name) += @field(b, f.name);
    }

    /// All input-side tokens: uncached input plus cache reads and writes.
    pub fn totalInput(u: Usage) u64 {
        return u.input + u.cache_read + u.cache_write_5m + u.cache_write_1h;
    }
};

/// Per-message metadata. Never sent to providers.
pub const Meta = struct {
    /// Provider message id (assistant) or a local id.
    id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?ProviderId = null,
    stop: ?StopReason = null,
    usage: ?Usage = null,
    /// Unix milliseconds when the message was completed.
    time_ms: ?i64 = null,
    /// Inserted by the harness (reminders, compaction summaries), not typed by the user.
    synthetic: bool = false,
    /// A partial message committed after a cancel or error.
    interrupted: bool = false,
};

/// One conversation message.
pub const Message = struct {
    role: Role,
    content: []const ContentBlock,
    meta: Meta = .{},

    /// Concatenated text of all text blocks; caller owns the result.
    pub fn text(m: Message, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (m.content) |b| switch (b) {
            .text => |t| try out.appendSlice(gpa, t.text),
            else => {},
        };
        return out.toOwnedSlice(gpa);
    }

    /// Number of `tool_use` blocks.
    pub fn toolUseCount(m: Message) usize {
        var n: usize = 0;
        for (m.content) |b| {
            if (b == .tool_use) n += 1;
        }
        return n;
    }
};

test "usage add and totals" {
    var a: Usage = .{ .input = 1, .output = 2, .cache_read = 3 };
    a.add(.{ .input = 10, .cache_write_5m = 4, .server_tool_requests = 1 });
    try std.testing.expectEqual(@as(u64, 11), a.input);
    try std.testing.expectEqual(@as(u64, 18), a.totalInput());
    try std.testing.expectEqual(@as(u32, 1), a.server_tool_requests);
}

test "message text and tool count" {
    const m: Message = .{ .role = .assistant, .content = &.{
        .{ .text = .{ .text = "a" } },
        .{ .tool_use = .{ .id = "t", .name = "x", .input_json = "{}" } },
        .{ .text = .{ .text = "b" } },
    } };
    const t = try m.text(std.testing.allocator);
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("ab", t);
    try std.testing.expectEqual(@as(usize, 1), m.toolUseCount());
}
