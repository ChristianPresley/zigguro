//! Gemini provider (E10.F03.S02.T02): `streamGenerateContent?alt=sse` with
//! function calling. Thought parts and thought signatures are preserved as
//! `provider_opaque` blocks and replayed exactly, as the stateless
//! function-calling guide requires. P2: enabled behind
//! `ai.providers.gemini.enabled`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("../Provider.zig");
const request = @import("../request.zig");
const events = @import("../events.zig");
const tp = @import("../transport.zig");
const translate = @import("../translate.zig");
const sse_stream = @import("../sse_stream.zig");
const wire = @import("../wire.zig");
const Capabilities = @import("../capabilities.zig").Capabilities;

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const json = proto.json;
const field = wire.field;
const Gemini = @This();

/// Provider settings.
pub const Config = struct {
    base_url: []const u8 = "https://generativelanguage.googleapis.com/v1beta",
    api_key: []const u8 = "",
    caps: Capabilities = default_caps,
};

/// Capabilities of current Gemini models.
pub const default_caps: Capabilities = .{ .tools = true, .parallel_tools = true, .forced_tool_choice = true, .streaming = true, .thinking_budget = true, .image_input = true, .pdf_input = true, .structured_output = true, .cache_auto = true };

gpa: Allocator,
transport: tp.Transport,
cfg: Config,

/// Creates a provider; free with `provider().deinit()`.
pub fn create(gpa: Allocator, t: tp.Transport, cfg: Config) !*Gemini {
    const g = try gpa.create(Gemini);
    g.* = .{ .gpa = gpa, .transport = t, .cfg = cfg };
    return g;
}

/// The `Provider` view.
pub fn provider(g: *Gemini) Provider {
    return .{ .ptr = g, .vtable = &.{ .stream = stream, .deinit = deinitErased }, .id = .gemini, .caps = g.cfg.caps };
}

fn deinitErased(ptr: *anyopaque) void {
    const g: *Gemini = @ptrCast(@alignCast(ptr));
    g.gpa.destroy(g);
}

/// Opaque kind for a thought part replayed verbatim.
pub const thought_kind = "thought_part";
/// Opaque kind carrying `{"id":..,"thoughtSignature":..}` for a function call.
pub const signature_kind = "thought_signature";

/// Writes the request body (`req.messages` already translated).
pub fn writeBody(w: *std.Io.Writer, req: *const request.Request) Stringify.Error!void {
    var s: Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    if (req.system.len > 0) {
        try s.objectField("systemInstruction");
        try s.beginObject();
        try s.objectField("parts");
        try s.beginArray();
        for (req.system) |p| {
            try s.beginObject();
            try field(&s, "text", p.text);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.objectField("contents");
    try s.beginArray();
    for (req.messages) |m| {
        try s.beginObject();
        try field(&s, "role", if (m.role == .user) "user" else "model");
        try s.objectField("parts");
        try s.beginArray();
        for (m.content, 0..) |b, i| switch (b) {
            .text => |t| {
                try s.beginObject();
                try field(&s, "text", t.text);
                try s.endObject();
            },
            .image => |im| try inline_data(&s, im.media_type, im.data),
            .document => |d| try inline_data(&s, d.media_type, d.data),
            .tool_use => |t| {
                try s.beginObject();
                try s.objectField("functionCall");
                try s.beginObject();
                if (!std.mem.startsWith(u8, t.id, "gem_")) try field(&s, "id", t.id);
                try field(&s, "name", t.name);
                try s.objectField("args");
                try wire.raw(&s, if (t.input_json.len == 0) "{}" else t.input_json);
                try s.endObject();
                if (signatureFor(m.content[i + 1 ..], t.id)) |sig| try field(&s, "thoughtSignature", sig);
                try s.endObject();
            },
            .tool_result => |t| {
                try s.beginObject();
                try s.objectField("functionResponse");
                try s.beginObject();
                if (!std.mem.startsWith(u8, t.tool_use_id, "gem_")) try field(&s, "id", t.tool_use_id);
                try field(&s, "name", nameFor(req.messages, t.tool_use_id));
                try s.objectField("response");
                try s.beginObject();
                try s.objectField(if (t.is_error) "error" else "output");
                var buf: [8192]u8 = undefined;
                var fba: std.heap.FixedBufferAllocator = .init(&buf);
                try s.write(wire.flattenParts(fba.allocator(), t.parts) catch "[output too large]");
                try s.endObject();
                try s.endObject();
                try s.endObject();
            },
            .provider_opaque => |o| if (std.mem.eql(u8, o.kind, thought_kind)) try wire.raw(&s, o.raw_json),
            .thinking => {},
        };
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    var any_tool = false;
    for (req.tools) |t| any_tool = any_tool or t.kind == .function;
    if (any_tool) {
        try s.objectField("tools");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("functionDeclarations");
        try s.beginArray();
        for (req.tools) |t| if (t.kind == .function) {
            try s.beginObject();
            try field(&s, "name", t.name);
            try field(&s, "description", t.description);
            try s.objectField("parameters");
            try wire.raw(&s, t.input_schema_json);
            try s.endObject();
        };
        try s.endArray();
        try s.endObject();
        try s.endArray();
        try s.objectField("toolConfig");
        try s.beginObject();
        try s.objectField("functionCallingConfig");
        try s.beginObject();
        switch (req.tool_choice) {
            .auto => try field(&s, "mode", "AUTO"),
            .none => try field(&s, "mode", "NONE"),
            .any => try field(&s, "mode", "ANY"),
            .tool => |n| {
                try field(&s, "mode", "ANY");
                try field(&s, "allowedFunctionNames", &[_][]const u8{n});
            },
        }
        try s.endObject();
        try s.endObject();
    }
    try s.objectField("generationConfig");
    try s.beginObject();
    try field(&s, "maxOutputTokens", req.max_output_tokens);
    if (req.temperature) |t| try field(&s, "temperature", t);
    if (req.stop_sequences.len > 0) try field(&s, "stopSequences", req.stop_sequences);
    switch (req.thinking) {
        .off => {},
        .budget => |n| {
            try s.objectField("thinkingConfig");
            try s.beginObject();
            try field(&s, "thinkingBudget", n);
            try field(&s, "includeThoughts", true);
            try s.endObject();
        },
        .adaptive => {
            try s.objectField("thinkingConfig");
            try s.beginObject();
            try field(&s, "thinkingBudget", -1);
            try field(&s, "includeThoughts", true);
            try s.endObject();
        },
    }
    if (req.output_schema_json) |sch| {
        try field(&s, "responseMimeType", "application/json");
        try s.objectField("responseJsonSchema");
        try wire.raw(&s, sch);
    }
    try s.endObject();
    try s.endObject();
}

fn inline_data(s: *Stringify, media_type: []const u8, blob: proto.Blob) !void {
    try s.beginObject();
    switch (blob) {
        .base64 => |d| {
            try s.objectField("inlineData");
            try s.beginObject();
            try field(s, "mimeType", media_type);
            try field(s, "data", d);
            try s.endObject();
        },
        .url => |u| {
            try s.objectField("fileData");
            try s.beginObject();
            try field(s, "mimeType", media_type);
            try field(s, "fileUri", u);
            try s.endObject();
        },
        .file => |p| try field(s, "text", p),
    }
    try s.endObject();
}

fn signatureFor(rest: []const proto.ContentBlock, id: []const u8) ?[]const u8 {
    // The decoder writes {"id":"<id>","thoughtSignature":"<sig>"}.
    const p1 = "{\"id\":\"";
    const p2 = "\",\"thoughtSignature\":\"";
    for (rest) |b| {
        if (b != .provider_opaque or !std.mem.eql(u8, b.provider_opaque.kind, signature_kind)) continue;
        const raw = b.provider_opaque.raw_json;
        if (!std.mem.startsWith(u8, raw, p1)) continue;
        const r1 = raw[p1.len..];
        if (!std.mem.startsWith(u8, r1, id) or !std.mem.startsWith(u8, r1[id.len..], p2) or !std.mem.endsWith(u8, raw, "\"}")) continue;
        return raw[p1.len + id.len + p2.len .. raw.len - 2];
    }
    return null;
}

fn nameFor(msgs: []const proto.Message, id: []const u8) []const u8 {
    for (msgs) |m| for (m.content) |b| {
        if (b == .tool_use and std.mem.eql(u8, b.tool_use.id, id)) return b.tool_use.name;
    };
    return "unknown";
}

/// SSE decoder: each event is a full GenerateContentResponse chunk.
pub const Decoder = struct {
    arena: Allocator,
    e: wire.Emitter(.gemini),
    next_index: u32 = 0,
    text_index: ?u32 = null,
    calls: u32 = 0,
    started: bool = false,
    finished: bool = false,

    /// A decoder emitting to `sink`.
    pub fn init(arena: Allocator, sink: events.EventSink) Decoder {
        return .{ .arena = arena, .e = .init(arena, sink) };
    }

    fn closeText(d: *Decoder) !void {
        if (d.text_index) |i| try d.e.emit(.{ .block_stop = .{ .index = i } });
        d.text_index = null;
    }

    fn opaqueBlock(d: *Decoder, kind: []const u8, raw: []const u8) !void {
        const i = d.next_index;
        d.next_index += 1;
        try d.e.emit(.{ .block_start = .{ .index = i, .kind = .opaque_block, .origin = .gemini, .opaque_kind = kind, .raw_json = raw } });
        try d.e.emit(.{ .block_stop = .{ .index = i } });
    }

    /// Handles one SSE event.
    pub fn onSse(d: *Decoder, name: []const u8, data: []const u8) Provider.StreamError!void {
        _ = name;
        var scratch: std.heap.ArenaAllocator = .init(d.arena);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const v = json.parseValue(sa, data) catch return error.Protocol;
        const o = json.asObject(v) orelse return error.Protocol;
        if (json.asObject(o.get("error") orelse .null)) |e| {
            const status = json.str(e, "status") orelse "";
            const msg = json.str(e, "message") orelse "";
            try d.e.emit(.{ .provider_error = .{ .status = 200, .kind = status, .message = msg } });
            return if (std.mem.eql(u8, status, "RESOURCE_EXHAUSTED")) error.RateLimited else Provider.classifyStatus(500, status, msg);
        }
        if (!d.started) {
            d.started = true;
            try d.e.emit(.{ .message_start = .{ .id = json.str(o, "responseId") orelse "", .model = json.str(o, "modelVersion") orelse "" } });
        }
        if (o.get("usageMetadata")) |u| try d.e.emit(.{ .usage = usageFrom(u) });
        const cands = o.get("candidates") orelse return;
        if (cands != .array or cands.array.items.len == 0) return;
        const c = json.asObject(cands.array.items[0]) orelse return;
        if (json.asObject(c.get("content") orelse .null)) |content| if (content.get("parts")) |parts| if (parts == .array) {
            for (parts.array.items) |pv| {
                const p = json.asObject(pv) orelse continue;
                if (json.boolean(p, "thought")) {
                    try d.closeText();
                    try d.opaqueBlock(thought_kind, json.stringifyValue(sa, pv) catch return error.OutOfMemory);
                } else if (json.asObject(p.get("functionCall") orelse .null)) |fc| {
                    try d.closeText();
                    const i = d.next_index;
                    d.next_index += 1;
                    d.calls += 1;
                    const id = json.str(fc, "id") orelse std.fmt.allocPrint(sa, "gem_{d}", .{d.calls}) catch return error.OutOfMemory;
                    try d.e.emit(.{ .block_start = .{ .index = i, .kind = .tool_use, .tool_id = id, .tool_name = json.str(fc, "name") orelse "" } });
                    try d.e.emit(.{ .tool_input_delta = .{ .index = i, .partial_json = if (fc.get("args")) |a| json.stringifyValue(sa, a) catch return error.OutOfMemory else "{}" } });
                    try d.e.emit(.{ .block_stop = .{ .index = i } });
                    if (json.str(p, "thoughtSignature")) |sig| {
                        var w: std.Io.Writer.Allocating = .init(sa);
                        Stringify.value(.{ .id = id, .thoughtSignature = sig }, .{}, &w.writer) catch return error.OutOfMemory;
                        try d.opaqueBlock(signature_kind, w.written());
                    }
                } else if (json.str(p, "text")) |t| {
                    if (d.text_index == null) {
                        d.text_index = d.next_index;
                        d.next_index += 1;
                        try d.e.emit(.{ .block_start = .{ .index = d.text_index.?, .kind = .text } });
                    }
                    try d.e.emit(.{ .text_delta = .{ .index = d.text_index.?, .text = t } });
                }
            }
        };
        if (json.str(c, "finishReason")) |fr| {
            try d.closeText();
            d.finished = true;
            try d.e.emit(.{ .stop = mapFinish(fr, d.calls > 0) });
        }
    }

    /// The final response; truncated without a finish reason.
    pub fn finish(d: *Decoder) Provider.StreamError!request.Response {
        if (!d.finished) return error.StreamTruncated;
        return d.e.response();
    }
};

/// Maps `finishReason`.
pub fn mapFinish(fr: []const u8, any_call: bool) proto.StopReason {
    if (std.mem.eql(u8, fr, "STOP")) return if (any_call) .tool_use else .end_turn;
    if (std.mem.eql(u8, fr, "MAX_TOKENS")) return .max_tokens;
    const refusals = [_][]const u8{ "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII" };
    for (refusals) |r| if (std.mem.eql(u8, fr, r)) return .refusal;
    return .failed;
}

/// Maps `usageMetadata`.
pub fn usageFrom(v: std.json.Value) proto.Usage {
    const o = json.asObject(v) orelse return .{};
    const prompt = json.int(u64, o, "promptTokenCount") orelse 0;
    const cached = json.int(u64, o, "cachedContentTokenCount") orelse 0;
    return .{
        .input = prompt -| cached,
        .cache_read = cached,
        .output = json.int(u64, o, "candidatesTokenCount") orelse 0,
        .reasoning = json.int(u64, o, "thoughtsTokenCount") orelse 0,
    };
}

fn stream(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request, sink: events.EventSink) Provider.StreamError!request.Response {
    const g: *Gemini = @ptrCast(@alignCast(ptr));
    var q = req.*;
    q.messages = translate.translateForProvider(arena, req.messages, .gemini) catch return error.OutOfMemory;
    const body = wire.bodyAlloc(arena, &q, writeBody) catch return error.OutOfMemory;
    var hs: std.ArrayList(request.Header) = .empty;
    hs.append(arena, .{ .name = "content-type", .value = "application/json" }) catch return error.OutOfMemory;
    const key = req.api_key orelse g.cfg.api_key;
    // The documented header form keeps the key out of URLs and logs.
    if (key.len > 0) hs.append(arena, .{ .name = "x-goog-api-key", .value = key }) catch return error.OutOfMemory;
    hs.appendSlice(arena, req.extra_headers) catch return error.OutOfMemory;
    var dec: Decoder = .init(arena, sink);
    const out = try sse_stream.run(io, arena, g.transport, .{
        .url = std.fmt.allocPrint(arena, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ std.mem.trimEnd(u8, g.cfg.base_url, "/"), req.model }) catch return error.OutOfMemory,
        .headers = hs.items,
        .body = body,
    }, &dec);
    if (out.head.status / 100 != 2) return wire.httpFailure(arena, out, sink);
    var resp = try dec.finish();
    resp.request_id = out.head.request_id;
    return resp;
}
