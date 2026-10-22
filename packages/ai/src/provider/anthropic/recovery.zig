//! Stop-reason recovery (E10.F02.S02.T02): what the loop does after
//! max_tokens, pause_turn, refusal, context overflow or an interrupted
//! stream. Every strategy is capped at 2 attempts to avoid loops.

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("../request.zig");
const Provider = @import("../Provider.zig");

const Allocator = std.mem.Allocator;
const Message = proto.Message;

/// How to continue an interrupted text answer. Comes from the registry
/// (`continue_strategy`), never parsed from a model id.
pub const ContinueStrategy = enum {
    /// Claude ≤ 4.5: replay the partial text as an assistant prefill.
    prefill_assistant,
    /// Claude ≥ 4.6 and every OpenAI-compatible provider.
    user_continue_message,
};

/// The model facts recovery needs (from the registry).
pub const ModelFacts = struct {
    max_output: u32 = 32_000,
    continue_strategy: ContinueStrategy = .user_continue_message,
    /// Configured `ai.refusalFallbackModel`.
    refusal_fallback: ?[]const u8 = null,
    /// `ai.autoContinueOnMaxTokens`.
    auto_continue: bool = true,
};

/// The recovery decision.
pub const Recovery = union(enum) {
    none,
    resend_assistant_as_is,
    retry_with_max_tokens: u32,
    continue_text: ContinueStrategy,
    fallback_model: []const u8,
    compact_then_retry,
    surface_to_user: []const u8,
};

/// Maximum attempts of any strategy.
pub const max_attempts = 2;

/// Decides what to do after a response (or a failure with a partial).
pub fn decide(resp: ?*const request.Response, err: ?Provider.StreamError, partial: ?*const Message, model: ModelFacts, current_max: u32, attempt: u8) Recovery {
    if (attempt >= max_attempts) return if (err != null) .{ .surface_to_user = "giving up after repeated recovery attempts" } else .none;
    if (err) |e| switch (e) {
        error.StreamTruncated, error.StreamStalled => {
            const p = partial orelse return .none;
            for (p.content) |b| if (b == .text and b.text.text.len > 0) return .{ .continue_text = model.continue_strategy };
            return .none; // nothing recoverable: the retry policy re-sends
        },
        error.ContextOverflow => return .compact_then_retry,
        else => return .none,
    };
    const r = resp orelse return .none;
    return switch (r.stop) {
        .max_tokens => if (r.truncated_tool_use) blk: {
            const next = @min(current_max *| 2, model.max_output);
            break :blk if (next > current_max) .{ .retry_with_max_tokens = next } else .{ .surface_to_user = "the tool call does not fit in the model's output limit" };
        } else if (model.auto_continue and endsWithText(r.message)) .{ .continue_text = model.continue_strategy } else .none,
        .pause_turn => .resend_assistant_as_is,
        .refusal => if (model.refusal_fallback) |f| .{ .fallback_model = f } else .{ .surface_to_user = "the model declined to continue" },
        .context_window_exceeded => .compact_then_retry,
        else => .none,
    };
}

fn endsWithText(m: Message) bool {
    if (m.content.len == 0) return false;
    return m.content[m.content.len - 1] == .text;
}

/// The text prefix of the user continuation message.
pub const continue_prefix = "Your previous response was interrupted and ended with [";
/// The text suffix of the user continuation message.
pub const continue_suffix = "]. Continue from where you left off.";

/// History to resend after an interrupted answer `partial`.
pub fn buildContinuation(arena: Allocator, history: []const Message, partial: Message, s: ContinueStrategy) ![]const Message {
    var text: std.ArrayList(u8) = .empty;
    for (partial.content) |b| if (b == .text) try text.appendSlice(arena, b.text.text);
    const out = try arena.alloc(Message, history.len + 1);
    @memcpy(out[0..history.len], history);
    out[history.len] = switch (s) {
        .prefill_assistant => .{ .role = .assistant, .content = try one(arena, std.mem.trimEnd(u8, text.items, " \t\r\n")), .meta = .{ .synthetic = true } },
        .user_continue_message => .{ .role = .user, .content = try one(arena, try std.mem.concat(arena, u8, &.{ continue_prefix, text.items, continue_suffix })), .meta = .{ .synthetic = true } },
    };
    return out;
}

fn one(arena: Allocator, t: []const u8) ![]const proto.ContentBlock {
    const b = try arena.alloc(proto.ContentBlock, 1);
    b[0] = .{ .text = .{ .text = t } };
    return b;
}

const testing = std.testing;

test "decide_matrix" {
    const text_msg: Message = .{ .role = .assistant, .content = &.{.{ .text = .{ .text = "abc" } }} };
    const tool_msg: Message = .{ .role = .assistant, .content = &.{.{ .tool_use = .{ .id = "t", .name = "x", .input_json = "{}" } }} };
    const empty: Message = .{ .role = .assistant, .content = &.{} };
    const old: ModelFacts = .{ .max_output = 64_000, .continue_strategy = .prefill_assistant };
    const new: ModelFacts = .{ .max_output = 64_000, .continue_strategy = .user_continue_message, .refusal_fallback = "claude-fallback" };
    const R = request.Response;
    const mk = struct {
        fn f(m: Message, stop: proto.StopReason, trunc: bool) R {
            return .{ .message = m, .stop = stop, .usage = .{}, .truncated_tool_use = trunc };
        }
    }.f;
    const Row = struct { resp: ?R, err: ?Provider.StreamError, partial: ?Message, model: ModelFacts, max: u32, attempt: u8, want: std.meta.Tag(Recovery) };
    const rows = [_]Row{
        .{ .resp = mk(empty, .max_tokens, true), .err = null, .partial = null, .model = old, .max = 4096, .attempt = 0, .want = .retry_with_max_tokens },
        .{ .resp = mk(empty, .max_tokens, true), .err = null, .partial = null, .model = .{ .max_output = 4096 }, .max = 4096, .attempt = 0, .want = .surface_to_user },
        .{ .resp = mk(text_msg, .max_tokens, false), .err = null, .partial = null, .model = old, .max = 4096, .attempt = 0, .want = .continue_text },
        .{ .resp = mk(text_msg, .max_tokens, false), .err = null, .partial = null, .model = .{ .auto_continue = false }, .max = 4096, .attempt = 0, .want = .none },
        .{ .resp = mk(tool_msg, .max_tokens, false), .err = null, .partial = null, .model = new, .max = 4096, .attempt = 0, .want = .none },
        .{ .resp = mk(text_msg, .pause_turn, false), .err = null, .partial = null, .model = new, .max = 4096, .attempt = 0, .want = .resend_assistant_as_is },
        .{ .resp = mk(text_msg, .refusal, false), .err = null, .partial = null, .model = old, .max = 4096, .attempt = 0, .want = .surface_to_user },
        .{ .resp = mk(text_msg, .refusal, false), .err = null, .partial = null, .model = new, .max = 4096, .attempt = 0, .want = .fallback_model },
        .{ .resp = mk(text_msg, .context_window_exceeded, false), .err = null, .partial = null, .model = new, .max = 4096, .attempt = 0, .want = .compact_then_retry },
        .{ .resp = null, .err = error.StreamTruncated, .partial = text_msg, .model = old, .max = 4096, .attempt = 0, .want = .continue_text },
        .{ .resp = null, .err = error.StreamStalled, .partial = empty, .model = new, .max = 4096, .attempt = 1, .want = .none },
        .{ .resp = null, .err = error.ContextOverflow, .partial = null, .model = new, .max = 4096, .attempt = 0, .want = .compact_then_retry },
        .{ .resp = null, .err = error.StreamTruncated, .partial = text_msg, .model = new, .max = 4096, .attempt = 2, .want = .surface_to_user },
        .{ .resp = mk(text_msg, .end_turn, false), .err = null, .partial = null, .model = new, .max = 4096, .attempt = 0, .want = .none },
    };
    for (rows, 0..) |row, i| {
        const got = decide(if (row.resp) |*r| r else null, row.err, if (row.partial) |*p| p else null, row.model, row.max, row.attempt);
        testing.expectEqual(row.want, std.meta.activeTag(got)) catch |e| {
            std.debug.print("row {d}: got {s}\n", .{ i, @tagName(got) });
            return e;
        };
    }
    const r0 = decide(&mk(empty, .max_tokens, true), null, null, old, 4096, 0);
    try testing.expectEqual(@as(u32, 8192), r0.retry_with_max_tokens);
}

test "continuation goldens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hist = [_]Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "Write a haiku" } }} }};
    const partial: Message = .{ .role = .assistant, .content = &.{.{ .text = .{ .text = "Old pond, frog " } }} };
    const pre = try buildContinuation(a, &hist, partial, .prefill_assistant);
    try testing.expectEqualStrings(
        \\{"role":"assistant","content":[{"type":"text","text":"Old pond, frog"}],"meta":{"synthetic":true}}
    , try proto.json.messageAlloc(a, pre[1]));
    const usr = try buildContinuation(a, &hist, partial, .user_continue_message);
    try testing.expectEqualStrings(
        \\{"role":"user","content":[{"type":"text","text":"Your previous response was interrupted and ended with [Old pond, frog ]. Continue from where you left off."}],"meta":{"synthetic":true}}
    , try proto.json.messageAlloc(a, usr[1]));
}
