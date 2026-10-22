//! Anthropic Messages streaming decoder (E10.F02.S01.T02): SSE events in,
//! canonical `StreamEvent`s out, plus the assembled `Response`. Unknown
//! events and deltas are ignored; unknown block types become opaque blocks
//! with their JSON retained.

const std = @import("std");
const proto = @import("zg_ai_proto");
const events = @import("../events.zig");
const request = @import("../request.zig");
const Provider = @import("../Provider.zig");
const MessageAssembler = @import("../assembler.zig").MessageAssembler;

const Allocator = std.mem.Allocator;
const json = proto.json;

/// Decoding failures.
pub const DecodeError = Provider.StreamError;

/// Incremental decoder; one per response.
pub const Decoder = struct {
    arena: Allocator,
    sink: events.EventSink,
    asm_: MessageAssembler,
    done: bool = false,
    failure: ?Provider.StreamError = null,
    unknown_stops: u32 = 0,

    /// A decoder emitting to `sink`.
    pub fn init(arena: Allocator, sink: events.EventSink) Decoder {
        var d: Decoder = .{ .arena = arena, .sink = sink, .asm_ = .init(arena) };
        d.asm_.origin = .anthropic;
        return d;
    }

    fn emit(d: *Decoder, ev: events.StreamEvent) DecodeError!void {
        d.asm_.feed(ev) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Protocol,
        };
        d.sink.send(ev);
    }

    /// Handles one SSE event (`event:` name and `data:` payload).
    pub fn onSse(d: *Decoder, name: []const u8, data: []const u8) DecodeError!void {
        if (d.done) return;
        var scratch: std.heap.ArenaAllocator = .init(d.arena);
        defer scratch.deinit();
        const v = json.parseValue(scratch.allocator(), data) catch return error.Protocol;
        const obj = json.asObject(v) orelse return error.Protocol;
        const ty = json.str(obj, "type") orelse name;
        if (std.mem.eql(u8, ty, "content_block_delta")) {
            const index = json.int(u32, obj, "index") orelse return error.Protocol;
            const delta = json.asObject(obj.get("delta") orelse return error.Protocol) orelse return error.Protocol;
            const dt = json.str(delta, "type") orelse return;
            if (std.mem.eql(u8, dt, "text_delta")) {
                try d.emit(.{ .text_delta = .{ .index = index, .text = json.str(delta, "text") orelse "" } });
            } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                try d.emit(.{ .tool_input_delta = .{ .index = index, .partial_json = json.str(delta, "partial_json") orelse "" } });
            } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                try d.emit(.{ .thinking_delta = .{ .index = index, .text = json.str(delta, "thinking") orelse "" } });
            } else if (std.mem.eql(u8, dt, "signature_delta")) {
                try d.emit(.{ .signature = .{ .index = index, .value = json.str(delta, "signature") orelse "" } });
            } else if (std.mem.eql(u8, dt, "citations_delta")) {
                if (delta.get("citation")) |c| try d.emit(.{ .citation = .{ .index = index, .json = try json.stringifyValue(scratch.allocator(), c) } });
            }
            return;
        }
        if (std.mem.eql(u8, ty, "message_start")) {
            const msg = json.asObject(obj.get("message") orelse return error.Protocol) orelse return error.Protocol;
            try d.emit(.{ .message_start = .{ .id = json.str(msg, "id") orelse "", .model = json.str(msg, "model") orelse "" } });
            if (msg.get("usage")) |u| try d.emit(.{ .usage = usageFrom(u) });
        } else if (std.mem.eql(u8, ty, "content_block_start")) {
            const index = json.int(u32, obj, "index") orelse return error.Protocol;
            const cb_v = obj.get("content_block") orelse return error.Protocol;
            const cb = json.asObject(cb_v) orelse return error.Protocol;
            const kind = json.str(cb, "type") orelse return error.Protocol;
            if (std.mem.eql(u8, kind, "text")) {
                try d.emit(.{ .block_start = .{ .index = index, .kind = .text } });
                if (json.str(cb, "text")) |t| if (t.len > 0) try d.emit(.{ .text_delta = .{ .index = index, .text = t } });
            } else if (std.mem.eql(u8, kind, "thinking")) {
                try d.emit(.{ .block_start = .{ .index = index, .kind = .thinking, .origin = .anthropic } });
                if (json.str(cb, "thinking")) |t| if (t.len > 0) try d.emit(.{ .thinking_delta = .{ .index = index, .text = t } });
            } else if (std.mem.eql(u8, kind, "redacted_thinking")) {
                try d.emit(.{ .block_start = .{ .index = index, .kind = .redacted_thinking, .origin = .anthropic, .raw_json = json.str(cb, "data") orelse "" } });
            } else if (std.mem.eql(u8, kind, "tool_use") or std.mem.eql(u8, kind, "server_tool_use")) {
                try d.emit(.{ .block_start = .{
                    .index = index,
                    .kind = if (kind[0] == 's') .server_tool_use else .tool_use,
                    .tool_id = json.str(cb, "id") orelse "",
                    .tool_name = json.str(cb, "name") orelse "",
                } });
                // Some events carry a complete input up front.
                if (cb.get("input")) |inp| if (inp == .object and inp.object.count() > 0)
                    try d.emit(.{ .tool_input_delta = .{ .index = index, .partial_json = try json.stringifyValue(scratch.allocator(), inp) } });
            } else {
                try d.emit(.{ .block_start = .{ .index = index, .kind = .opaque_block, .origin = .anthropic, .opaque_kind = kind, .raw_json = try json.stringifyValue(scratch.allocator(), cb_v) } });
            }
        } else if (std.mem.eql(u8, ty, "content_block_stop")) {
            try d.emit(.{ .block_stop = .{ .index = json.int(u32, obj, "index") orelse return error.Protocol } });
        } else if (std.mem.eql(u8, ty, "message_delta")) {
            if (obj.get("usage")) |u| try d.emit(.{ .usage = usageFrom(u) });
            if (json.asObject(obj.get("delta") orelse .null)) |delta| if (json.str(delta, "stop_reason")) |sr| {
                const stop = mapStop(sr);
                if (stop == .failed) {
                    d.unknown_stops += 1;
                    d.sink.send(.{ .warning = "unknown stop_reason mapped to failed" });
                }
                try d.emit(.{ .stop = stop });
            };
        } else if (std.mem.eql(u8, ty, "message_stop")) {
            d.done = true;
        } else if (std.mem.eql(u8, ty, "ping")) {
            d.sink.send(.ping);
        } else if (std.mem.eql(u8, ty, "error")) {
            const err = json.asObject(obj.get("error") orelse .null);
            const kind = if (err) |e| json.str(e, "type") orelse "" else "";
            const message = if (err) |e| json.str(e, "message") orelse "" else "";
            try d.emit(.{ .provider_error = .{ .status = 200, .kind = kind, .message = message } });
            d.failure = Provider.classifyStatus(500, kind, message);
            d.done = true;
        }
        // Anything else: ignored.
    }

    /// The final response; `error.StreamTruncated` without `message_stop`.
    pub fn finish(d: *Decoder) DecodeError!request.Response {
        if (d.failure) |f| return f;
        if (!d.done) return error.StreamTruncated;
        const fin = d.asm_.finishLenient() catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Protocol,
        };
        const msg = fin.message;
        const truncated = fin.truncated_tool_use;
        return .{ .message = msg, .stop = d.asm_.stop orelse .end_turn, .usage = d.asm_.usage, .request_id = null, .rate_limit = d.asm_.rate_limit, .truncated_tool_use = truncated };
    }

    /// The SSE parser sink interface (`onEvent`).
    pub fn onEvent(d: *Decoder, ev: anytype) !void {
        try d.onSse(ev.type, ev.data);
    }
};

/// Maps an Anthropic `stop_reason`.
pub fn mapStop(s: []const u8) proto.StopReason {
    const table = .{
        .{ "end_turn", .end_turn },                                     .{ "max_tokens", .max_tokens }, .{ "stop_sequence", .stop_sequence },
        .{ "tool_use", .tool_use },                                     .{ "pause_turn", .pause_turn }, .{ "refusal", .refusal },
        .{ "model_context_window_exceeded", .context_window_exceeded },
    };
    inline for (table) |row| if (std.mem.eql(u8, s, row[0])) return row[1];
    return .failed;
}

/// Maps an Anthropic usage object (cumulative).
pub fn usageFrom(v: std.json.Value) proto.Usage {
    const o = json.asObject(v) orelse return .{};
    var u: proto.Usage = .{
        .input = json.int(u64, o, "input_tokens") orelse 0,
        .output = json.int(u64, o, "output_tokens") orelse 0,
        .cache_read = json.int(u64, o, "cache_read_input_tokens") orelse 0,
    };
    if (json.asObject(o.get("cache_creation") orelse .null)) |cc| {
        u.cache_write_5m = json.int(u64, cc, "ephemeral_5m_input_tokens") orelse 0;
        u.cache_write_1h = json.int(u64, cc, "ephemeral_1h_input_tokens") orelse 0;
    } else u.cache_write_5m = json.int(u64, o, "cache_creation_input_tokens") orelse 0;
    if (json.asObject(o.get("server_tool_use") orelse .null)) |st| {
        u.server_tool_requests = (json.int(u32, st, "web_search_requests") orelse 0) + (json.int(u32, st, "web_fetch_requests") orelse 0);
    }
    return u;
}

/// Parses `anthropic-ratelimit-*` and `retry-after` headers.
pub fn rateLimitFrom(headers: []const request.Header) ?events.RateLimitSnapshot {
    var r: events.RateLimitSnapshot = .{};
    var any = false;
    for (headers) |h| {
        const n = std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " "), 10) catch null;
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            if (n) |x| r.retry_after_ms = x * 1000;
            any = true;
            continue;
        }
        const prefix = "anthropic-ratelimit-";
        if (h.name.len <= prefix.len or !std.ascii.startsWithIgnoreCase(h.name, prefix)) continue;
        const rest = h.name[prefix.len..];
        any = true;
        if (eq(rest, "requests-limit")) r.requests_limit = n;
        if (eq(rest, "requests-remaining")) r.requests_remaining = n;
        if (eq(rest, "tokens-limit")) r.tokens_limit = n;
        if (eq(rest, "tokens-remaining")) r.tokens_remaining = n;
        if (eq(rest, "input-tokens-remaining")) r.input_tokens_remaining = n;
        if (eq(rest, "output-tokens-remaining")) r.output_tokens_remaining = n;
    }
    return if (any) r else null;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Parsed HTTP error body `{type:"error", error:{type, message}, request_id}`.
pub const HttpError = struct { kind: []const u8, message: []const u8, request_id: ?[]const u8 };

/// Parses an error body; tolerant of non-JSON bodies.
pub fn parseHttpError(arena: Allocator, body: []const u8) HttpError {
    const v = json.parseValue(arena, body) catch return .{ .kind = "", .message = body[0..@min(body.len, 512)], .request_id = null };
    const o = json.asObject(v) orelse return .{ .kind = "", .message = "", .request_id = null };
    const e = json.asObject(o.get("error") orelse .null);
    return .{
        .kind = if (e) |x| json.str(x, "type") orelse "" else "",
        .message = if (e) |x| json.str(x, "message") orelse "" else "",
        .request_id = json.str(o, "request_id"),
    };
}

/// Classifies a non-2xx response. A 429 without `retry-after` is a spend
/// cap and is reported as `InvalidRequest` (not retryable).
pub fn classifyHttp(status: u16, err: HttpError, has_retry_after: bool) Provider.StreamError {
    if (status == 429 and !has_retry_after) return error.InvalidRequest;
    return Provider.classifyStatus(status, err.kind, err.message);
}
