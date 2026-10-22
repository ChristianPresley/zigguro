//! Chat Completions provider for OpenAI-compatible servers (Ollama,
//! llama.cpp, LM Studio, gateways) with a dialect table and local-server
//! discovery (E10.F03.S02.T01).

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("../Provider.zig");
const request = @import("../request.zig");
const events = @import("../events.zig");
const tp = @import("../transport.zig");
const translate = @import("../translate.zig");
const sse_stream = @import("../sse_stream.zig");
const wire = @import("../wire.zig");
const dialects = @import("dialects.zig");
const Capabilities = @import("../capabilities.zig").Capabilities;

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const json = proto.json;
const field = wire.field;
const Chat = @This();

/// Provider settings.
pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8 = "",
    /// Dialect name, or "auto" (generic).
    dialect: []const u8 = "auto",
    /// Display label, e.g. "Ollama (local)".
    label: []const u8 = "",
    caps: Capabilities = default_caps,
};

/// Conservative capabilities for local servers.
pub const default_caps: Capabilities = .{ .tools = true, .parallel_tools = true, .forced_tool_choice = true, .streaming = true, .image_input = true };

gpa: Allocator,
transport: tp.Transport,
cfg: Config,
dialect: dialects.Dialect,

/// Creates a provider; free with `provider().deinit()`.
pub fn create(gpa: Allocator, t: tp.Transport, cfg: Config) !*Chat {
    const c = try gpa.create(Chat);
    c.* = .{ .gpa = gpa, .transport = t, .cfg = cfg, .dialect = dialects.byName(cfg.dialect) };
    if (!c.dialect.tool_choice) c.cfg.caps.forced_tool_choice = false;
    return c;
}

/// The `Provider` view.
pub fn provider(c: *Chat) Provider {
    return .{ .ptr = c, .vtable = &.{ .stream = stream, .list_models = listModelsErased, .deinit = deinitErased }, .id = .openai_chat, .caps = c.cfg.caps };
}

fn deinitErased(ptr: *anyopaque) void {
    const c: *Chat = @ptrCast(@alignCast(ptr));
    c.gpa.destroy(c);
}

/// Body encoder context.
pub const Body = struct { req: *const request.Request, dialect: dialects.Dialect };

/// Writes the request body (`req.messages` already translated).
pub fn writeBody(w: *std.Io.Writer, b: Body) Stringify.Error!void {
    const req = b.req;
    var s: Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try field(&s, "model", req.model);
    try s.objectField("messages");
    try s.beginArray();
    if (req.system.len > 0) {
        try s.beginObject();
        try field(&s, "role", "system");
        try s.objectField("content");
        try s.beginWriteRaw();
        try s.writer.writeByte('"');
        for (req.system, 0..) |p, i| {
            if (i > 0) try s.writer.writeAll("\\n\\n");
            try Stringify.encodeJsonStringChars(p.text, .{}, s.writer);
        }
        try s.writer.writeByte('"');
        s.endWriteRaw();
        try s.endObject();
    }
    for (req.messages) |m| try writeMessage(&s, m, b.dialect);
    try s.endArray();
    if (req.tools.len > 0) {
        try s.objectField("tools");
        try s.beginArray();
        for (req.tools) |t| {
            if (t.kind == .provider_native) continue;
            try s.beginObject();
            try field(&s, "type", "function");
            try s.objectField("function");
            try s.beginObject();
            try field(&s, "name", t.name);
            try field(&s, "description", t.description);
            try s.objectField("parameters");
            try wire.raw(&s, t.input_schema_json);
            if (t.strict) try field(&s, "strict", true);
            try s.endObject();
            try s.endObject();
        }
        try s.endArray();
        if (b.dialect.tool_choice) {
            try s.objectField("tool_choice");
            switch (req.tool_choice) {
                .auto => try s.write("auto"),
                .any => try s.write("required"),
                .none => try s.write("none"),
                .tool => |n| {
                    try s.beginObject();
                    try field(&s, "type", "function");
                    try s.objectField("function");
                    try s.beginObject();
                    try field(&s, "name", n);
                    try s.endObject();
                    try s.endObject();
                },
            }
            if (!req.parallel_tools) try field(&s, "parallel_tool_calls", false);
        }
    }
    try field(&s, "max_tokens", req.max_output_tokens);
    if (req.temperature) |t| try field(&s, "temperature", t);
    if (req.stop_sequences.len > 0) try field(&s, "stop", req.stop_sequences);
    try field(&s, "stream", true);
    if (b.dialect.include_usage) {
        try s.objectField("stream_options");
        try s.beginObject();
        try field(&s, "include_usage", true);
        try s.endObject();
    }
    try s.endObject();
}

fn writeMessage(s: *Stringify, m: proto.Message, d: dialects.Dialect) !void {
    // Tool results become separate `tool` messages, written first.
    for (m.content) |b| if (b == .tool_result) {
        try s.beginObject();
        try field(s, "role", "tool");
        try field(s, "tool_call_id", b.tool_result.tool_use_id);
        try s.objectField("content");
        var buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const text = wire.flattenParts(fba.allocator(), b.tool_result.parts) catch b.tool_result.parts[0].text;
        try s.write(text);
        try s.endObject();
    };
    var n_text: usize = 0;
    var n_media: usize = 0;
    var n_calls: usize = 0;
    for (m.content) |b| switch (b) {
        .text => n_text += 1,
        .image => n_media += 1,
        .tool_use => n_calls += 1,
        else => {},
    };
    if (n_text + n_media + n_calls == 0) return;
    try s.beginObject();
    try field(s, "role", @tagName(m.role));
    try s.objectField("content");
    if (n_media == 0) {
        if (n_text == 0) try s.write(null) else {
            try s.beginWriteRaw();
            try s.writer.writeByte('"');
            var first = true;
            for (m.content) |b| if (b == .text) {
                if (!first) try s.writer.writeAll("\\n");
                first = false;
                try Stringify.encodeJsonStringChars(b.text.text, .{}, s.writer);
            };
            try s.writer.writeByte('"');
            s.endWriteRaw();
        }
    } else {
        try s.beginArray();
        for (m.content) |b| switch (b) {
            .text => |t| {
                try s.beginObject();
                try field(s, "type", "text");
                try field(s, "text", t.text);
                try s.endObject();
            },
            .image => |im| {
                const skip = im.data == .file or (d.data_urls_only and im.data == .url);
                try s.beginObject();
                if (skip) {
                    try field(s, "type", "text");
                    try field(s, "text", "[image omitted]");
                } else {
                    try field(s, "type", "image_url");
                    try s.objectField("image_url");
                    try s.beginObject();
                    try s.objectField("url");
                    switch (im.data) {
                        .base64 => |x| try s.print("\"data:{s};base64,{s}\"", .{ im.media_type, x }),
                        .url => |u| try s.write(u),
                        .file => unreachable,
                    }
                    try s.endObject();
                }
                try s.endObject();
            },
            else => {},
        };
        try s.endArray();
    }
    if (n_calls > 0) {
        try s.objectField("tool_calls");
        try s.beginArray();
        for (m.content) |b| if (b == .tool_use) {
            try s.beginObject();
            try field(s, "id", b.tool_use.id);
            try field(s, "type", "function");
            try s.objectField("function");
            try s.beginObject();
            try field(s, "name", b.tool_use.name);
            try field(s, "arguments", if (b.tool_use.input_json.len == 0) "{}" else b.tool_use.input_json);
            try s.endObject();
            try s.endObject();
        };
        try s.endArray();
    }
    try s.endObject();
}

/// Chunk decoder.
pub const Decoder = struct {
    arena: Allocator,
    e: wire.Emitter(.openai_chat),
    dialect: dialects.Dialect,
    map: wire.IndexMap = .{},
    started: bool = false,
    finished: bool = false,
    done: bool = false,
    any_call: bool = false,

    const text_key = 0xFFFF_0000;
    const think_key = 0xFFFF_0001;

    /// A decoder emitting to `sink`.
    pub fn init(arena: Allocator, sink: events.EventSink, d: dialects.Dialect) Decoder {
        return .{ .arena = arena, .e = .init(arena, sink), .dialect = d };
    }

    /// Handles one SSE event.
    pub fn onSse(d: *Decoder, name: []const u8, data: []const u8) Provider.StreamError!void {
        _ = name;
        if (d.done) return;
        if (std.mem.eql(u8, std.mem.trim(u8, data, " "), "[DONE]")) {
            try d.closeAll();
            d.done = true;
            return;
        }
        var scratch: std.heap.ArenaAllocator = .init(d.arena);
        defer scratch.deinit();
        const v = json.parseValue(scratch.allocator(), data) catch return error.Protocol;
        const o = json.asObject(v) orelse return error.Protocol;
        if (o.get("error")) |ev| {
            const eo = json.asObject(ev);
            const msg = if (eo) |x| json.str(x, "message") orelse "" else "";
            const kind = if (eo) |x| json.str(x, "type") orelse "" else "";
            try d.e.emit(.{ .provider_error = .{ .status = 200, .kind = kind, .message = msg } });
            return Provider.classifyStatus(500, kind, msg);
        }
        if (!d.started) {
            d.started = true;
            try d.e.emit(.{ .message_start = .{ .id = json.str(o, "id") orelse "", .model = json.str(o, "model") orelse "" } });
        }
        if (o.get("usage")) |u| if (u == .object) try d.e.emit(.{ .usage = usageFrom(u) });
        const choices = o.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const c = json.asObject(choices.array.items[0]) orelse return;
        if (json.asObject(c.get("delta") orelse .null)) |delta| {
            if (d.dialect.reasoning_field) |rf| if (json.str(delta, rf)) |t| if (t.len > 0) {
                const ix = d.map.get(d.arena, think_key) catch return error.OutOfMemory;
                if (ix.new) try d.e.emit(.{ .block_start = .{ .index = ix.index, .kind = .thinking, .origin = .openai_chat } });
                try d.e.emit(.{ .thinking_delta = .{ .index = ix.index, .text = t } });
            };
            if (json.str(delta, "content")) |t| if (t.len > 0) {
                const ix = d.map.get(d.arena, text_key) catch return error.OutOfMemory;
                if (ix.new) try d.e.emit(.{ .block_start = .{ .index = ix.index, .kind = .text } });
                try d.e.emit(.{ .text_delta = .{ .index = ix.index, .text = t } });
            };
            if (delta.get("tool_calls")) |tcs| if (tcs == .array) for (tcs.array.items, 0..) |tc_v, pos| {
                const tc = json.asObject(tc_v) orelse continue;
                const ti = json.int(u32, tc, "index") orelse @as(u32, @intCast(pos));
                const ix = d.map.get(d.arena, ti) catch return error.OutOfMemory;
                const func = json.asObject(tc.get("function") orelse .null);
                if (ix.new) {
                    d.any_call = true;
                    try d.e.emit(.{ .block_start = .{
                        .index = ix.index,
                        .kind = .tool_use,
                        .tool_id = json.str(tc, "id") orelse try std.fmt.allocPrint(scratch.allocator(), "call_{d}", .{ti}),
                        .tool_name = if (func) |f| json.str(f, "name") orelse "" else "",
                    } });
                }
                if (func) |f| if (f.get("arguments")) |args| switch (args) {
                    .string => |a| if (a.len > 0) try d.e.emit(.{ .tool_input_delta = .{ .index = ix.index, .partial_json = a } }),
                    .object => try d.e.emit(.{ .tool_input_delta = .{ .index = ix.index, .partial_json = json.stringifyValue(scratch.allocator(), args) catch return error.OutOfMemory } }),
                    else => {},
                };
            };
        }
        if (json.str(c, "finish_reason")) |fr| {
            d.finished = true;
            try d.e.emit(.{ .stop = mapFinish(fr, d.any_call) });
        }
    }

    fn closeAll(d: *Decoder) !void {
        for (d.map.keys.items, 0..) |_, i| try d.e.emit(.{ .block_stop = .{ .index = @intCast(i) } });
    }

    /// The final response. Without `[DONE]`, a stream that reported a
    /// finish reason still completes; otherwise it was truncated.
    pub fn finish(d: *Decoder) Provider.StreamError!request.Response {
        if (!d.done) {
            if (!d.finished) return error.StreamTruncated;
            try d.closeAll();
            d.done = true;
        }
        return d.e.response();
    }
};

/// Maps `finish_reason`.
pub fn mapFinish(fr: []const u8, any_call: bool) proto.StopReason {
    if (std.mem.eql(u8, fr, "stop")) return if (any_call) .tool_use else .end_turn;
    if (std.mem.eql(u8, fr, "tool_calls") or std.mem.eql(u8, fr, "function_call")) return .tool_use;
    if (std.mem.eql(u8, fr, "length")) return .max_tokens;
    if (std.mem.eql(u8, fr, "content_filter")) return .refusal;
    return .end_turn;
}

/// Maps a Chat Completions usage object.
pub fn usageFrom(v: std.json.Value) proto.Usage {
    const o = json.asObject(v) orelse return .{};
    const input = json.int(u64, o, "prompt_tokens") orelse 0;
    const cached = if (json.asObject(o.get("prompt_tokens_details") orelse .null)) |x| json.int(u64, x, "cached_tokens") orelse 0 else 0;
    return .{
        .input = input -| cached,
        .cache_read = cached,
        .output = json.int(u64, o, "completion_tokens") orelse 0,
        .reasoning = if (json.asObject(o.get("completion_tokens_details") orelse .null)) |x| json.int(u64, x, "reasoning_tokens") orelse 0 else 0,
    };
}

fn headers(c: *const Chat, arena: Allocator, req: *const request.Request, accept: []const u8) ![]const request.Header {
    var hs: std.ArrayList(request.Header) = .empty;
    try hs.append(arena, .{ .name = "content-type", .value = "application/json" });
    try hs.append(arena, .{ .name = "accept", .value = accept });
    const key = req.api_key orelse c.cfg.api_key;
    if (key.len > 0) try hs.append(arena, .{ .name = "authorization", .value = try std.mem.concat(arena, u8, &.{ "Bearer ", key }) });
    try hs.appendSlice(arena, req.extra_headers);
    return hs.items;
}

fn stream(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request, sink: events.EventSink) Provider.StreamError!request.Response {
    const c: *Chat = @ptrCast(@alignCast(ptr));
    var q = req.*;
    q.messages = translate.translateForProvider(arena, req.messages, .openai_chat) catch return error.OutOfMemory;
    const body = wire.bodyAlloc(arena, Body{ .req = &q, .dialect = c.dialect }, writeBody) catch return error.OutOfMemory;
    var dec: Decoder = .init(arena, sink, c.dialect);
    const out = try sse_stream.run(io, arena, c.transport, .{
        .url = std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, c.cfg.base_url, "/"), "/chat/completions" }) catch return error.OutOfMemory,
        .headers = headers(c, arena, req, "text/event-stream") catch return error.OutOfMemory,
        .body = body,
    }, &dec);
    if (out.head.status / 100 != 2) return wire.httpFailure(arena, out, sink);
    var resp = try dec.finish();
    resp.request_id = out.head.request_id;
    return resp;
}

fn listModelsErased(ptr: *anyopaque, io: std.Io, arena: Allocator) Provider.StreamError![]Provider.ModelInfo {
    const c: *Chat = @ptrCast(@alignCast(ptr));
    const empty: request.Request = .{ .model = "", .messages = &.{} };
    const res = c.transport.sendCollect(io, arena, .{
        .method = .GET,
        .url = std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, c.cfg.base_url, "/"), "/models" }) catch return error.OutOfMemory,
        .headers = (headers(c, arena, &empty, "application/json") catch return error.OutOfMemory)[1..],
    }) catch |e| return sse_stream.mapTransport(e);
    if (res.head.status / 100 != 2) return wire.httpFailure(arena, .{ .head = res.head, .prefix = res.body }, .discard);
    return parseModels(arena, res.body) catch error.Protocol;
}

/// Parses an OpenAI-style `/models` list.
pub fn parseModels(arena: Allocator, body: []const u8) ![]Provider.ModelInfo {
    const v = try json.parseValue(arena, body);
    const o = json.asObject(v) orelse return error.InvalidMessage;
    const data = o.get("data") orelse o.get("models") orelse return error.InvalidMessage;
    if (data != .array) return error.InvalidMessage;
    var out: std.ArrayList(Provider.ModelInfo) = .empty;
    for (data.array.items) |item| {
        const m = json.asObject(item) orelse continue;
        try out.append(arena, .{ .id = json.str(m, "id") orelse json.str(m, "name") orelse continue, .created = json.int(i64, m, "created") });
    }
    return out.items;
}

/// A server found by `discover`.
pub const Discovered = struct { base_url: []const u8, dialect: dialects.Dialect, models: []const Provider.ModelInfo };

/// Probes the default local servers plus `extra` base URLs in parallel
/// (`GET /models` with 300 ms connect and idle timeouts, enforced by the
/// transport) and returns those that answered.
pub fn discover(io: std.Io, arena: Allocator, t: tp.Transport, extra: []const []const u8) ![]Discovered {
    var urls: std.ArrayList([]const u8) = .empty;
    for (dialects.builtin_dialects) |d| if (d.default_url) |u| try urls.append(arena, u);
    try urls.appendSlice(arena, extra);
    const slots = try arena.alloc(?Discovered, urls.items.len);
    @memset(slots, null);
    const Probe = struct {
        fn run(ii: std.Io, a: Allocator, tt: tp.Transport, base: []const u8, slot: *?Discovered) void {
            probe(ii, a, tt, base, slot) catch {};
        }
        fn probe(ii: std.Io, a: Allocator, tt: tp.Transport, base: []const u8, slot: *?Discovered) !void {
            const res = try tt.sendCollect(ii, a, .{ .method = .GET, .url = try std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, base, "/"), "/models" }), .timeout_connect_ms = 300, .idle_timeout_ms = 300 });
            if (res.head.status != 200) return;
            const models = parseModels(a, res.body) catch return;
            slot.* = .{ .base_url = base, .dialect = dialects.identify(base, res.body, res.head.get("server")), .models = models };
        }
    };
    // Each probe allocates from its own arena; results are copied after.
    const arenas = try arena.alloc(std.heap.ArenaAllocator, urls.items.len);
    for (arenas) |*a| a.* = .init(std.heap.page_allocator);
    defer for (arenas) |*a| a.deinit();
    var group: std.Io.Group = .init;
    for (urls.items, slots, arenas) |u, *slot, *a| group.async(io, Probe.run, .{ io, a.allocator(), t, u, slot });
    try group.await(io);
    var out: std.ArrayList(Discovered) = .empty;
    for (slots) |s| if (s) |d| {
        const models = try arena.alloc(Provider.ModelInfo, d.models.len);
        for (d.models, models) |m, *o| o.* = .{ .id = try arena.dupe(u8, m.id), .created = m.created };
        try out.append(arena, .{ .base_url = d.base_url, .dialect = d.dialect, .models = models });
    };
    return out.items;
}
