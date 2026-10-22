//! OpenAI Responses API provider (E10.F03.S01.T01): stateless
//! (`store: false`) encoder, typed-SSE decoder and verbatim replay of
//! reasoning items (`provider_opaque` with origin `openai_responses`).

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
const Responses = @This();

/// Provider settings.
pub const Config = struct {
    base_url: []const u8 = "https://api.openai.com/v1",
    api_key: []const u8 = "",
    organization: ?[]const u8 = null,
    project: ?[]const u8 = null,
    caps: Capabilities = default_caps,
};

/// Capabilities of current OpenAI reasoning models.
pub const default_caps: Capabilities = .{
    .tools = true,
    .parallel_tools = true,
    .forced_tool_choice = true,
    .streaming = true,
    .thinking_adaptive = true,
    .cache_auto = true,
    .image_input = true,
    .pdf_input = true,
    .structured_output = true,
    .strict_tools = true,
};

gpa: Allocator,
transport: tp.Transport,
cfg: Config,

/// Creates a provider; free with `provider().deinit()`.
pub fn create(gpa: Allocator, t: tp.Transport, cfg: Config) !*Responses {
    const r = try gpa.create(Responses);
    r.* = .{ .gpa = gpa, .transport = t, .cfg = cfg };
    return r;
}

/// The `Provider` view.
pub fn provider(r: *Responses) Provider {
    return .{ .ptr = r, .vtable = &.{ .stream = stream, .deinit = deinitErased }, .id = .openai_responses, .caps = r.cfg.caps };
}

fn deinitErased(ptr: *anyopaque) void {
    const r: *Responses = @ptrCast(@alignCast(ptr));
    r.gpa.destroy(r);
}

/// Writes the request body (`req.messages` already translated).
pub fn writeBody(w: *std.Io.Writer, req: *const request.Request) Stringify.Error!void {
    var s: Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try field(&s, "model", req.model);
    if (req.system.len > 0) {
        try s.objectField("instructions");
        try s.beginWriteRaw();
        try s.writer.writeByte('"');
        for (req.system, 0..) |p, i| {
            if (i > 0) try s.writer.writeAll("\\n\\n");
            try Stringify.encodeJsonStringChars(p.text, .{}, s.writer);
        }
        try s.writer.writeByte('"');
        s.endWriteRaw();
    }
    try s.objectField("input");
    try s.beginArray();
    for (req.messages) |m| try writeItems(&s, m);
    try s.endArray();
    if (req.tools.len > 0) {
        try s.objectField("tools");
        try s.beginArray();
        for (req.tools) |t| {
            if (t.kind == .provider_native) {
                try wire.raw(&s, t.raw_json orelse "{}");
                continue;
            }
            try s.beginObject();
            try field(&s, "type", "function");
            try field(&s, "name", t.name);
            try field(&s, "description", t.description);
            try s.objectField("parameters");
            try wire.raw(&s, t.input_schema_json);
            if (t.strict) try field(&s, "strict", true);
            try s.endObject();
        }
        try s.endArray();
        try s.objectField("tool_choice");
        switch (req.tool_choice) {
            .auto => try s.write("auto"),
            .any => try s.write("required"),
            .none => try s.write("none"),
            .tool => |n| {
                try s.beginObject();
                try field(&s, "type", "function");
                try field(&s, "name", n);
                try s.endObject();
            },
        }
        try field(&s, "parallel_tool_calls", req.parallel_tools);
    }
    try field(&s, "max_output_tokens", req.max_output_tokens);
    if (req.effort) |e| {
        try s.objectField("reasoning");
        try s.beginObject();
        try field(&s, "effort", switch (e) {
            .max => "high",
            else => @tagName(e),
        });
        try s.endObject();
    }
    if (req.output_schema_json) |sch| {
        try s.objectField("text");
        try s.beginObject();
        try s.objectField("format");
        try s.beginObject();
        try field(&s, "type", "json_schema");
        try field(&s, "name", "output");
        try s.objectField("schema");
        try wire.raw(&s, sch);
        try field(&s, "strict", true);
        try s.endObject();
        try s.endObject();
    }
    if (req.temperature) |t| try field(&s, "temperature", t);
    try s.objectField("include");
    try s.beginArray();
    try s.write("reasoning.encrypted_content");
    try s.endArray();
    try field(&s, "store", false);
    try field(&s, "stream", true);
    try s.endObject();
}

fn writeItems(s: *Stringify, m: proto.Message) !void {
    var open = false;
    const close = struct {
        fn f(st: *Stringify, o: *bool) !void {
            if (!o.*) return;
            try st.endArray();
            try st.endObject();
            o.* = false;
        }
    }.f;
    for (m.content) |b| {
        switch (b) {
            .text, .image, .document => {
                if (!open) {
                    try s.beginObject();
                    try field(s, "type", "message");
                    try field(s, "role", @tagName(m.role));
                    try s.objectField("content");
                    try s.beginArray();
                    open = true;
                }
                try s.beginObject();
                switch (b) {
                    .text => |t| {
                        try field(s, "type", if (m.role == .user) "input_text" else "output_text");
                        try field(s, "text", t.text);
                    },
                    .image => |im| {
                        try field(s, "type", "input_image");
                        switch (im.data) {
                            .base64 => |d| {
                                try s.objectField("image_url");
                                try s.print("\"data:{s};base64,{s}\"", .{ im.media_type, d });
                            },
                            .url => |u| try field(s, "image_url", u),
                            .file => |p| try field(s, "image_url", p),
                        }
                    },
                    .document => |d| {
                        try field(s, "type", "input_file");
                        try field(s, "filename", d.title orelse "document.pdf");
                        switch (d.data) {
                            .base64 => |x| {
                                try s.objectField("file_data");
                                try s.print("\"data:{s};base64,{s}\"", .{ d.media_type, x });
                            },
                            .url => |u| try field(s, "file_url", u),
                            .file => |p| try field(s, "file_url", p),
                        }
                    },
                    else => unreachable,
                }
                try s.endObject();
            },
            .tool_use => |t| {
                try close(s, &open);
                try s.beginObject();
                try field(s, "type", "function_call");
                try field(s, "call_id", t.id);
                try field(s, "name", t.name);
                try field(s, "arguments", if (t.input_json.len == 0) "{}" else t.input_json);
                try s.endObject();
            },
            .tool_result => |t| {
                try close(s, &open);
                try s.beginObject();
                try field(s, "type", "function_call_output");
                try field(s, "call_id", t.tool_use_id);
                try s.objectField("output");
                if (t.parts.len == 1 and t.parts[0] == .text) {
                    try s.write(t.parts[0].text);
                } else {
                    try s.beginWriteRaw();
                    try s.writer.writeByte('"');
                    for (t.parts, 0..) |p, i| {
                        if (i > 0) try s.writer.writeAll("\\n");
                        switch (p) {
                            .text => |x| try Stringify.encodeJsonStringChars(x, .{}, s.writer),
                            .image => try s.writer.writeAll("[image omitted]"),
                            .document => try s.writer.writeAll("[document omitted]"),
                            .resource_link => |r| try Stringify.encodeJsonStringChars(r.uri, .{}, s.writer),
                        }
                    }
                    try s.writer.writeByte('"');
                    s.endWriteRaw();
                }
                try s.endObject();
            },
            .provider_opaque => |o| {
                try close(s, &open);
                try wire.raw(s, o.raw_json);
            },
            // Reasoning summaries are display-only; the opaque item replays.
            .thinking => {},
        }
    }
    try close(s, &open);
}

/// Typed-SSE decoder.
pub const Decoder = struct {
    arena: Allocator,
    e: wire.Emitter(.openai_responses),
    map: wire.IndexMap = .{},
    any_call: bool = false,
    done: bool = false,
    failure: ?Provider.StreamError = null,
    last_seq: ?u64 = null,

    /// A decoder emitting to `sink`.
    pub fn init(arena: Allocator, sink: events.EventSink) Decoder {
        return .{ .arena = arena, .e = .init(arena, sink) };
    }

    fn key(output_index: u32, part: u32) u64 {
        return (@as(u64, output_index) << 32) | part;
    }

    /// Reasoning summaries live at part 0xFFFF_FFFE of their output item.
    const summary_part = 0xFFFF_FFFE;
    const item_part = 0xFFFF_FFFF;

    /// Handles one SSE event.
    pub fn onSse(d: *Decoder, name: []const u8, data: []const u8) Provider.StreamError!void {
        _ = name;
        if (d.done) return;
        var scratch: std.heap.ArenaAllocator = .init(d.arena);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const v = json.parseValue(sa, data) catch return error.Protocol;
        const o = json.asObject(v) orelse return error.Protocol;
        const ty = json.str(o, "type") orelse return;
        if (json.int(u64, o, "sequence_number")) |seq| d.last_seq = seq;
        const oi = json.int(u32, o, "output_index") orelse 0;
        if (eql(ty, "response.output_text.delta") or eql(ty, "response.refusal.delta")) {
            const ci = json.int(u32, o, "content_index") orelse 0;
            const ix = d.map.get(d.arena, key(oi, ci)) catch return error.OutOfMemory;
            if (ix.new) try d.e.emit(.{ .block_start = .{ .index = ix.index, .kind = .text } });
            try d.e.emit(.{ .text_delta = .{ .index = ix.index, .text = json.str(o, "delta") orelse "" } });
        } else if (eql(ty, "response.function_call_arguments.delta")) {
            const ix = d.map.get(d.arena, key(oi, item_part)) catch return error.OutOfMemory;
            try d.e.emit(.{ .tool_input_delta = .{ .index = ix.index, .partial_json = json.str(o, "delta") orelse "" } });
        } else if (eql(ty, "response.reasoning_summary_text.delta")) {
            const ix = d.map.get(d.arena, key(oi, summary_part)) catch return error.OutOfMemory;
            if (ix.new) try d.e.emit(.{ .block_start = .{ .index = ix.index, .kind = .thinking, .origin = .openai_responses } });
            try d.e.emit(.{ .thinking_delta = .{ .index = ix.index, .text = json.str(o, "delta") orelse "" } });
        } else if (eql(ty, "response.created")) {
            const r = json.asObject(o.get("response") orelse .null) orelse return;
            try d.e.emit(.{ .message_start = .{ .id = json.str(r, "id") orelse "", .model = json.str(r, "model") orelse "" } });
        } else if (eql(ty, "response.output_item.added")) {
            const item = json.asObject(o.get("item") orelse .null) orelse return;
            const it = json.str(item, "type") orelse return;
            if (eql(it, "function_call")) {
                const ix = d.map.get(d.arena, key(oi, item_part)) catch return error.OutOfMemory;
                d.any_call = true;
                try d.e.emit(.{ .block_start = .{ .index = ix.index, .kind = .tool_use, .tool_id = json.str(item, "call_id") orelse "", .tool_name = json.str(item, "name") orelse "" } });
            }
        } else if (eql(ty, "response.output_item.done")) {
            const item_v = o.get("item") orelse return;
            const item = json.asObject(item_v) orelse return;
            const it = json.str(item, "type") orelse "";
            if (eql(it, "reasoning")) {
                if (d.map.find(key(oi, summary_part))) |si| try d.e.emit(.{ .block_stop = .{ .index = si } });
                const ix = d.map.get(d.arena, key(oi, item_part)) catch return error.OutOfMemory;
                try d.e.emit(.{ .block_start = .{ .index = ix.index, .kind = .opaque_block, .origin = .openai_responses, .opaque_kind = "reasoning", .raw_json = json.stringifyValue(sa, item_v) catch return error.OutOfMemory } });
                try d.e.emit(.{ .block_stop = .{ .index = ix.index } });
                return;
            }
            // Close every block of this output item.
            for (d.map.keys.items, 0..) |k, i| if (k >> 32 == oi) try d.e.emit(.{ .block_stop = .{ .index = @intCast(i) } });
        } else if (eql(ty, "response.completed") or eql(ty, "response.incomplete")) {
            const r = json.asObject(o.get("response") orelse .null) orelse return error.Protocol;
            if (r.get("usage")) |u| try d.e.emit(.{ .usage = usageFrom(u) });
            var stop: proto.StopReason = if (d.any_call) .tool_use else .end_turn;
            if (eql(ty, "response.incomplete")) {
                const reason = if (json.asObject(r.get("incomplete_details") orelse .null)) |det| json.str(det, "reason") orelse "" else "";
                stop = if (eql(reason, "max_output_tokens")) .max_tokens else if (eql(reason, "content_filter")) .refusal else .failed;
            }
            try d.e.emit(.{ .stop = stop });
            d.done = true;
        } else if (eql(ty, "response.failed") or eql(ty, "error")) {
            const r = json.asObject(o.get("response") orelse .null);
            const err_obj = if (r) |x| json.asObject(x.get("error") orelse .null) else json.asObject(o.get("error") orelse v);
            const code = if (err_obj) |e| json.str(e, "code") orelse json.str(e, "type") orelse "" else "";
            const msg = if (err_obj) |e| json.str(e, "message") orelse "" else "";
            try d.e.emit(.{ .provider_error = .{ .status = 200, .kind = code, .message = msg } });
            d.failure = Provider.classifyStatus(500, code, msg);
            d.done = true;
        }
    }

    /// The final response.
    pub fn finish(d: *Decoder) Provider.StreamError!request.Response {
        if (d.failure) |f| return f;
        if (!d.done) return error.StreamTruncated;
        return d.e.response();
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Maps a Responses usage object.
pub fn usageFrom(v: std.json.Value) proto.Usage {
    const o = json.asObject(v) orelse return .{};
    const input = json.int(u64, o, "input_tokens") orelse 0;
    const cached = if (json.asObject(o.get("input_tokens_details") orelse .null)) |x| json.int(u64, x, "cached_tokens") orelse 0 else 0;
    return .{
        .input = input -| cached,
        .cache_read = cached,
        .output = json.int(u64, o, "output_tokens") orelse 0,
        .reasoning = if (json.asObject(o.get("output_tokens_details") orelse .null)) |x| json.int(u64, x, "reasoning_tokens") orelse 0 else 0,
    };
}

fn stream(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request, sink: events.EventSink) Provider.StreamError!request.Response {
    const r: *Responses = @ptrCast(@alignCast(ptr));
    var q = req.*;
    q.messages = translate.translateForProvider(arena, req.messages, .openai_responses) catch return error.OutOfMemory;
    const body = wire.bodyAlloc(arena, &q, writeBody) catch return error.OutOfMemory;
    var hs: std.ArrayList(request.Header) = .empty;
    hs.append(arena, .{ .name = "content-type", .value = "application/json" }) catch return error.OutOfMemory;
    hs.append(arena, .{ .name = "accept", .value = "text/event-stream" }) catch return error.OutOfMemory;
    const key = req.api_key orelse r.cfg.api_key;
    if (key.len > 0) hs.append(arena, .{ .name = "authorization", .value = std.mem.concat(arena, u8, &.{ "Bearer ", key }) catch return error.OutOfMemory }) catch return error.OutOfMemory;
    if (r.cfg.organization) |x| hs.append(arena, .{ .name = "openai-organization", .value = x }) catch return error.OutOfMemory;
    if (r.cfg.project) |x| hs.append(arena, .{ .name = "openai-project", .value = x }) catch return error.OutOfMemory;
    hs.appendSlice(arena, req.extra_headers) catch return error.OutOfMemory;
    var dec: Decoder = .init(arena, sink);
    const out = try sse_stream.run(io, arena, r.transport, .{
        .url = std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, r.cfg.base_url, "/"), "/responses" }) catch return error.OutOfMemory,
        .headers = hs.items,
        .body = body,
    }, &dec);
    if (out.head.status / 100 != 2) return wire.httpFailure(arena, out, sink);
    var resp = try dec.finish();
    resp.request_id = out.head.request_id;
    return resp;
}
