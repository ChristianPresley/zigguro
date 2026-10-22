//! Provider-neutral stream events. Providers emit them synchronously, in
//! arrival order, through an `EventSink`; slices are valid only during the
//! `emit` call.

const proto = @import("zg_ai_proto");

/// Kind of a content block being streamed.
pub const BlockKind = enum { text, thinking, redacted_thinking, tool_use, server_tool_use, opaque_block };

/// Rate-limit headroom reported by a provider (from response headers).
pub const RateLimitSnapshot = struct {
    requests_remaining: ?u64 = null,
    requests_limit: ?u64 = null,
    tokens_remaining: ?u64 = null,
    tokens_limit: ?u64 = null,
    input_tokens_remaining: ?u64 = null,
    output_tokens_remaining: ?u64 = null,
    /// Milliseconds until the tightest window resets.
    reset_ms: ?u64 = null,
    /// Server-requested wait (Retry-After), in milliseconds.
    retry_after_ms: ?u64 = null,
};

/// Classified provider failure, emitted just before `stream` returns an error.
pub const ErrorInfo = struct {
    status: u16 = 0,
    /// Provider error type, e.g. "overloaded_error", "rate_limit_error".
    kind: []const u8 = "",
    message: []const u8 = "",
    retry_after_ms: ?u64 = null,
    request_id: ?[]const u8 = null,
};

/// One streaming event.
pub const StreamEvent = union(enum) {
    message_start: struct { id: []const u8, model: []const u8 },
    block_start: struct {
        index: u32,
        kind: BlockKind,
        tool_id: ?[]const u8 = null,
        tool_name: ?[]const u8 = null,
        /// Complete JSON of an opaque or redacted block (e.g. a server tool
        /// result, an OpenAI reasoning item, redacted thinking data).
        raw_json: ?[]const u8 = null,
        /// Which provider the block belongs to (thinking and opaque blocks).
        origin: proto.ProviderId = .unknown,
        /// Opaque block kind (its JSON `type`).
        opaque_kind: ?[]const u8 = null,
    },
    text_delta: struct { index: u32, text: []const u8 },
    thinking_delta: struct { index: u32, text: []const u8 },
    signature: struct { index: u32, value: []const u8 },
    tool_input_delta: struct { index: u32, partial_json: []const u8 },
    /// Citation JSON appended to a text block.
    citation: struct { index: u32, json: []const u8 },
    block_stop: struct { index: u32 },
    usage: proto.Usage,
    stop: proto.StopReason,
    rate_limit: RateLimitSnapshot,
    ping,
    warning: []const u8,
    provider_error: ErrorInfo,
};

/// Receives stream events. Must be cheap: copy what you keep.
pub const EventSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, ev: StreamEvent) void,

    /// Forwards one event.
    pub inline fn send(s: EventSink, ev: StreamEvent) void {
        s.emit(s.ctx, ev);
    }

    /// A sink that drops everything.
    pub const discard: EventSink = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .emit = struct {
        fn f(_: *anyopaque, _: StreamEvent) void {}
    }.f };
};
