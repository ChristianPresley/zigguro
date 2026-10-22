//! Anthropic Messages API request encoder (E10.F02.S01.T01). Writes the
//! JSON body straight to a writer in a fixed field order, so equal
//! requests produce identical bytes (prompt caching depends on it).

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("../request.zig");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Request = request.Request;
const Message = proto.Message;
const ContentBlock = proto.ContentBlock;
const writeRaw = proto.json.writeRaw;

/// Encoder options.
pub const EncodeOptions = struct {
    stream: bool = true,
    /// Emit `strict: true` on tools that ask for it.
    strict_tools: bool = false,
    /// Top-level automatic caching.
    auto_cache: ?request.CacheTtl = null,
    /// Body for `/v1/messages/count_tokens`: no stream, max_tokens or server tools.
    count_tokens: bool = false,
};

/// Encoding failures.
pub const EncodeError = error{ TooManyCacheBreakpoints, WriteFailed, OutOfMemory };

/// Maximum explicit cache breakpoints the API accepts.
pub const max_breakpoints = 4;

/// Counts the explicit breakpoints `req` asks for.
pub fn breakpointCount(req: *const Request) usize {
    var n: usize = req.cache.message_breaks.len;
    for (req.system) |s| n += @intFromBool(s.cache_break);
    for (req.tools) |t| n += @intFromBool(t.cache_break);
    return n;
}

/// Normalised view of the transcript: consecutive same-role messages merged
/// and, in user messages, tool_result blocks moved first. Allocates only
/// when something changes.
pub fn normalizeMessages(arena: Allocator, msgs: []const Message) Allocator.Error![]const Message {
    var change = false;
    for (msgs, 0..) |m, i| {
        if (i > 0 and msgs[i - 1].role == m.role) change = true;
        if (m.role == .user and !resultsFirst(m.content)) change = true;
    }
    if (!change) return msgs;
    var out: std.ArrayList(Message) = .empty;
    for (msgs) |m| {
        if (out.items.len > 0 and out.items[out.items.len - 1].role == m.role) {
            const prev = &out.items[out.items.len - 1];
            prev.content = try std.mem.concat(arena, ContentBlock, &.{ prev.content, m.content });
        } else try out.append(arena, m);
    }
    for (out.items) |*m| {
        if (m.role != .user or resultsFirst(m.content)) continue;
        const blocks = try arena.alloc(ContentBlock, m.content.len);
        var n: usize = 0;
        for (m.content) |b| if (b == .tool_result) {
            blocks[n] = b;
            n += 1;
        };
        for (m.content) |b| if (b != .tool_result) {
            blocks[n] = b;
            n += 1;
        };
        m.content = blocks;
    }
    return out.items;
}

fn resultsFirst(blocks: []const ContentBlock) bool {
    var seen_other = false;
    for (blocks) |b| {
        if (b == .tool_result) {
            if (seen_other) return false;
        } else seen_other = true;
    }
    return true;
}

/// Writes the request body. `req.messages` must already be normalised
/// (`normalizeMessages`) and translated for Anthropic.
pub fn writeBody(w: *std.Io.Writer, req: *const Request, opts: EncodeOptions) EncodeError!void {
    if (breakpointCount(req) > max_breakpoints) return error.TooManyCacheBreakpoints;
    var s: Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try field(&s, "model", req.model);
    if (!opts.count_tokens) try field(&s, "max_tokens", req.max_output_tokens);
    if (req.system.len > 0) {
        try s.objectField("system");
        try s.beginArray();
        for (req.system) |p| {
            try s.beginObject();
            try field(&s, "type", "text");
            try field(&s, "text", p.text);
            if (p.cache_break) try cacheControl(&s, req.cache.ttl);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.objectField("messages");
    try s.beginArray();
    for (req.messages, 0..) |m, i| try writeMessage(&s, m, isBreak(req, i), req.cache.ttl);
    try s.endArray();
    var wrote_tools = false;
    for (req.tools) |t| {
        if (opts.count_tokens and t.kind == .provider_native) continue;
        if (!wrote_tools) {
            try s.objectField("tools");
            try s.beginArray();
            wrote_tools = true;
        }
        if (t.kind == .provider_native) {
            try writeRaw(&s, t.raw_json orelse "{}");
            continue;
        }
        try s.beginObject();
        try field(&s, "name", t.name);
        try field(&s, "description", t.description);
        try s.objectField("input_schema");
        try writeRaw(&s, t.input_schema_json);
        if (opts.strict_tools and t.strict) try field(&s, "strict", true);
        if (t.cache_break) try cacheControl(&s, req.cache.ttl);
        try s.endObject();
    }
    if (wrote_tools) try s.endArray();
    if (req.tools.len > 0) try writeToolChoice(&s, req);
    switch (req.thinking) {
        .off => {},
        .budget => |n| {
            try s.objectField("thinking");
            try s.beginObject();
            try field(&s, "type", "enabled");
            try field(&s, "budget_tokens", @max(n, 1024));
            try s.endObject();
        },
        .adaptive => {
            try s.objectField("thinking");
            try s.beginObject();
            try field(&s, "type", "adaptive");
            try s.endObject();
        },
    }
    if (req.effort != null or req.output_schema_json != null) {
        try s.objectField("output_config");
        try s.beginObject();
        if (req.effort) |e| try field(&s, "effort", @tagName(e));
        if (req.output_schema_json) |sch| {
            try s.objectField("format");
            try s.beginObject();
            try field(&s, "type", "json_schema");
            try s.objectField("schema");
            try writeRaw(&s, sch);
            try s.endObject();
        }
        try s.endObject();
    }
    if (!opts.count_tokens) {
        if (req.stop_sequences.len > 0) try field(&s, "stop_sequences", req.stop_sequences);
        if (req.temperature) |t| if (req.thinking == .off) try field(&s, "temperature", t);
        if (req.metadata_user_id) |u| {
            try s.objectField("metadata");
            try s.beginObject();
            try field(&s, "user_id", u);
            try s.endObject();
        }
        if (opts.auto_cache) |ttl| try cacheControl(&s, ttl);
        if (opts.stream) try field(&s, "stream", true);
    }
    if (req.extra_body_json) |extra| try mergeExtra(&s, extra);
    try s.endObject();
}

fn isBreak(req: *const Request, i: usize) bool {
    for (req.cache.message_breaks) |b| if (b == i) return true;
    return false;
}

/// Thinking in budget mode allows only `auto` or `none`.
pub fn effectiveToolChoice(req: *const Request) request.ToolChoice {
    if (req.thinking != .off) switch (req.tool_choice) {
        .any, .tool => return .auto,
        else => {},
    };
    return req.tool_choice;
}

fn writeToolChoice(s: *Stringify, req: *const Request) !void {
    const tc = effectiveToolChoice(req);
    if (tc == .auto and req.parallel_tools) return; // the API default
    try s.objectField("tool_choice");
    try s.beginObject();
    try field(s, "type", @tagName(tc));
    if (tc == .tool) try field(s, "name", tc.tool);
    if (!req.parallel_tools and tc != .none) try field(s, "disable_parallel_tool_use", true);
    try s.endObject();
}

fn cacheControl(s: *Stringify, ttl: request.CacheTtl) !void {
    try s.objectField("cache_control");
    try s.beginObject();
    try field(s, "type", "ephemeral");
    if (ttl == .h1) try field(s, "ttl", "1h");
    try s.endObject();
}

fn writeMessage(s: *Stringify, m: Message, brk: bool, ttl: request.CacheTtl) !void {
    try s.beginObject();
    try field(s, "role", @tagName(m.role));
    try s.objectField("content");
    try s.beginArray();
    // The breakpoint goes on the last block that can carry cache_control.
    var last: ?usize = null;
    if (brk) {
        var i = m.content.len;
        while (i > 0) {
            i -= 1;
            if (m.content[i] != .thinking) {
                last = i;
                break;
            }
        }
    }
    for (m.content, 0..) |b, i| try writeBlock(s, b, last != null and last.? == i, ttl);
    try s.endArray();
    try s.endObject();
}

fn writeBlock(s: *Stringify, b: ContentBlock, brk: bool, ttl: request.CacheTtl) !void {
    switch (b) {
        .provider_opaque => |o| return writeRaw(s, o.raw_json),
        else => {},
    }
    try s.beginObject();
    switch (b) {
        .text => |t| {
            try field(s, "type", "text");
            try field(s, "text", t.text);
        },
        .image => |im| {
            try field(s, "type", "image");
            try source(s, im.media_type, im.data);
        },
        .document => |d| {
            try field(s, "type", "document");
            try source(s, d.media_type, d.data);
            if (d.title) |t| try field(s, "title", t);
        },
        .thinking => |t| if (t.redacted) {
            try field(s, "type", "redacted_thinking");
            try field(s, "data", t.signature);
        } else {
            try field(s, "type", "thinking");
            try field(s, "thinking", t.text);
            try field(s, "signature", t.signature);
        },
        .tool_use => |t| {
            try field(s, "type", if (t.server) "server_tool_use" else "tool_use");
            try field(s, "id", t.id);
            try field(s, "name", t.name);
            try s.objectField("input");
            try writeRaw(s, if (t.input_json.len == 0) "{}" else t.input_json);
        },
        .tool_result => |t| {
            try field(s, "type", "tool_result");
            try field(s, "tool_use_id", t.tool_use_id);
            try s.objectField("content");
            if (t.parts.len == 1 and t.parts[0] == .text) {
                try s.write(t.parts[0].text);
            } else {
                try s.beginArray();
                for (t.parts) |p| try writePart(s, p);
                try s.endArray();
            }
            if (t.is_error) try field(s, "is_error", true);
        },
        .provider_opaque => unreachable,
    }
    if (brk) try cacheControl(s, ttl);
    try s.endObject();
}

fn writePart(s: *Stringify, p: proto.ResultPart) !void {
    try s.beginObject();
    switch (p) {
        .text => |t| {
            try field(s, "type", "text");
            try field(s, "text", t);
        },
        .image => |im| {
            try field(s, "type", "image");
            try source(s, im.media_type, im.data);
        },
        .document => |d| {
            try field(s, "type", "document");
            try source(s, d.media_type, d.data);
            if (d.title) |t| try field(s, "title", t);
        },
        .resource_link => |r| {
            try field(s, "type", "text");
            try s.objectField("text");
            try s.print("\"{s} ({s})\"", .{ r.name, r.uri });
        },
    }
    try s.endObject();
}

fn source(s: *Stringify, media_type: []const u8, blob: proto.Blob) !void {
    try s.objectField("source");
    try s.beginObject();
    switch (blob) {
        .base64 => |d| {
            try field(s, "type", "base64");
            try field(s, "media_type", media_type);
            try field(s, "data", d);
        },
        .url => |u| {
            try field(s, "type", "url");
            try field(s, "url", u);
        },
        // Files are inlined by the loop before encoding; a leftover path is
        // sent as text so the request stays valid.
        .file => |p| {
            try field(s, "type", "text");
            try field(s, "media_type", "text/plain");
            try field(s, "data", p);
        },
    }
    try s.endObject();
}

fn mergeExtra(s: *Stringify, extra: []const u8) !void {
    // `extra` is a JSON object; copy its members (minus braces) verbatim.
    const t = std.mem.trim(u8, extra, " \t\r\n");
    if (t.len < 2 or t[0] != '{') return;
    const inner = std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n");
    if (inner.len == 0) return;
    try s.writer.writeByte(',');
    try s.writer.writeAll(inner);
}

fn field(s: *Stringify, name: []const u8, v: anytype) !void {
    try s.objectField(name);
    try s.write(v);
}

/// Request headers. `api_key` goes in `x-api-key` (zg_net sends it itself).
pub fn headers(arena: Allocator, api_version: []const u8, betas: []const []const u8, api_key: []const u8, req: *const Request) ![]const request.Header {
    var list: std.ArrayList(request.Header) = .empty;
    try list.append(arena, .{ .name = "content-type", .value = "application/json" });
    try list.append(arena, .{ .name = "accept", .value = "text/event-stream" });
    try list.append(arena, .{ .name = "anthropic-version", .value = api_version });
    if (api_key.len > 0) try list.append(arena, .{ .name = "x-api-key", .value = api_key });
    if (betas.len > 0) try list.append(arena, .{ .name = "anthropic-beta", .value = try std.mem.join(arena, ",", betas) });
    try list.appendSlice(arena, req.extra_headers);
    return list.items;
}

/// Encodes into a fresh slice in `arena`.
pub fn bodyAlloc(arena: Allocator, req: *const Request, opts: EncodeOptions) EncodeError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    writeBody(&out.writer, req, opts) catch |e| return switch (e) {
        error.WriteFailed => error.OutOfMemory,
        else => e,
    };
    return out.written();
}
