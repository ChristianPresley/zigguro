//! Lossless JSON codecs for the canonical model, used by sessions, the
//! stream-json protocol and golden tests.
//!
//! Field names are snake_case and mirror Anthropic's where they exist
//! (`tool_use_id`, `is_error`); the union discriminator is `"type"`. Keys are
//! written in declaration order so encoded prefixes stay byte-stable for
//! prompt caching. Blocks with an unknown `type` decode to `provider_opaque`
//! (origin `unknown`) and re-encode verbatim.

const std = @import("std");
const message = @import("message.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const Message = message.Message;
const ContentBlock = message.ContentBlock;
const ResultPart = message.ResultPart;
const Blob = message.Blob;

/// Decoding failures.
pub const DecodeError = error{ InvalidMessage, OutOfMemory };

/// Options shared by every decoder: numbers stay as their source text.
pub const parse_options: std.json.ParseOptions = .{ .parse_numbers = false, .ignore_unknown_fields = true, .allocate = .alloc_always };

const stringify_options: Stringify.Options = .{ .emit_null_optional_fields = false };

/// Parses JSON text into a `Value` with `parse_options`, allocating in `arena`.
pub fn parseValue(arena: Allocator, text: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, parse_options) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidMessage,
    };
}

/// Re-stringifies `v` compactly, preserving key order; caller owns via `arena`.
pub fn stringifyValue(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    return Stringify.valueAlloc(arena, v, .{});
}

/// Canonical form of JSON text (compact, key order kept, numbers verbatim).
pub fn canonicalize(arena: Allocator, text: []const u8) DecodeError![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "{}";
    return stringifyValue(arena, try parseValue(arena, trimmed));
}

/// Writes `m` as one compact JSON object.
pub fn encodeMessage(w: *std.Io.Writer, m: Message) std.Io.Writer.Error!void {
    var s: Stringify = .{ .writer = w, .options = stringify_options };
    try writeMessage(&s, m);
}

/// Writes `m` with an existing `Stringify` (for embedding in larger objects).
pub fn writeMessage(s: *Stringify, m: Message) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("role");
    try s.write(@tagName(m.role));
    try s.objectField("content");
    try s.beginArray();
    for (m.content) |b| try writeBlock(s, b);
    try s.endArray();
    if (!std.meta.eql(m.meta, message.Meta{})) {
        try s.objectField("meta");
        try s.write(m.meta);
    }
    try s.endObject();
}

/// Writes one content block.
pub fn writeBlock(s: *Stringify, b: ContentBlock) std.Io.Writer.Error!void {
    if (b == .provider_opaque and b.provider_opaque.origin == .unknown) return writeRaw(s, b.provider_opaque.raw_json);
    try s.beginObject();
    try s.objectField("type");
    try s.write(@tagName(b));
    switch (b) {
        .text => |t| {
            try field(s, "text", t.text);
            if (t.citations_json) |c| {
                try s.objectField("citations");
                try writeRaw(s, c);
            }
        },
        .image => |im| {
            try field(s, "media_type", im.media_type);
            try writeBlob(s, im.data);
        },
        .document => |d| {
            try field(s, "media_type", d.media_type);
            try writeBlob(s, d.data);
            if (d.title) |t| try field(s, "title", t);
        },
        .thinking => |t| {
            try field(s, "text", t.text);
            try field(s, "signature", t.signature);
            if (t.redacted) try field(s, "redacted", true);
            try field(s, "origin", @tagName(t.origin));
        },
        .tool_use => |t| {
            try field(s, "id", t.id);
            try field(s, "name", t.name);
            try s.objectField("input");
            try writeRaw(s, if (t.input_json.len == 0) "{}" else t.input_json);
            if (t.server) try field(s, "server", true);
        },
        .tool_result => |t| {
            try field(s, "tool_use_id", t.tool_use_id);
            try s.objectField("content");
            try s.beginArray();
            for (t.parts) |p| try writePart(s, p);
            try s.endArray();
            if (t.is_error) try field(s, "is_error", true);
        },
        .provider_opaque => |o| {
            try field(s, "origin", @tagName(o.origin));
            try field(s, "kind", o.kind);
            try s.objectField("raw");
            try writeRaw(s, o.raw_json);
        },
    }
    try s.endObject();
}

/// Writes one tool-result part.
pub fn writePart(s: *Stringify, p: ResultPart) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("type");
    try s.write(@tagName(p));
    switch (p) {
        .text => |t| try field(s, "text", t),
        .image => |im| {
            try field(s, "media_type", im.media_type);
            try writeBlob(s, im.data);
        },
        .document => |d| {
            try field(s, "media_type", d.media_type);
            try writeBlob(s, d.data);
            if (d.title) |t| try field(s, "title", t);
        },
        .resource_link => |r| {
            try field(s, "uri", r.uri);
            try field(s, "name", r.name);
            if (r.mime) |m| try field(s, "mime", m);
        },
    }
    try s.endObject();
}

fn writeBlob(s: *Stringify, b: Blob) std.Io.Writer.Error!void {
    try s.objectField("source");
    try s.beginObject();
    try field(s, "type", @tagName(b));
    switch (b) {
        .base64 => |d| try field(s, "data", d),
        .url => |u| try field(s, "url", u),
        .file => |p| try field(s, "path", p),
    }
    try s.endObject();
}

fn field(s: *Stringify, name: []const u8, v: anytype) std.Io.Writer.Error!void {
    try s.objectField(name);
    try s.write(v);
}

/// Writes pre-encoded JSON text as a value.
pub fn writeRaw(s: *Stringify, raw: []const u8) std.Io.Writer.Error!void {
    try s.beginWriteRaw();
    try s.writer.writeAll(raw);
    s.endWriteRaw();
}

/// Writes any value with the default rules (struct field order, enums as
/// strings, null optionals omitted). Use for `Usage`, `ContextItem`,
/// `AssistRequest` and similar plain types.
pub fn encodeValue(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
    try Stringify.value(v, stringify_options, w);
}

/// Decodes a plain value written by `encodeValue`.
pub fn decodeValue(comptime T: type, arena: Allocator, v: Value) DecodeError!T {
    return std.json.parseFromValueLeaky(T, arena, v, parse_options) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidMessage,
    };
}

/// Decodes a message object; strings point into `v` or `arena`.
pub fn decodeMessage(arena: Allocator, v: Value) DecodeError!Message {
    const obj = asObject(v) orelse return error.InvalidMessage;
    const role = std.meta.stringToEnum(message.Role, str(obj, "role") orelse return error.InvalidMessage) orelse return error.InvalidMessage;
    const content_v = obj.get("content") orelse return error.InvalidMessage;
    const blocks: []ContentBlock = switch (content_v) {
        // A bare string is shorthand for one text block.
        .string => |t| blk: {
            const one = try arena.alloc(ContentBlock, 1);
            one[0] = .{ .text = .{ .text = t } };
            break :blk one;
        },
        .array => |a| blk: {
            const out = try arena.alloc(ContentBlock, a.items.len);
            for (a.items, out) |item, *b| b.* = try decodeBlock(arena, item);
            break :blk out;
        },
        else => return error.InvalidMessage,
    };
    var meta: message.Meta = .{};
    if (obj.get("meta")) |mv| meta = try decodeValue(message.Meta, arena, mv);
    return .{ .role = role, .content = blocks, .meta = meta };
}

/// Decodes a message from JSON text.
pub fn decodeMessageText(arena: Allocator, text: []const u8) DecodeError!Message {
    return decodeMessage(arena, try parseValue(arena, text));
}

/// Decodes one content block.
pub fn decodeBlock(arena: Allocator, v: Value) DecodeError!ContentBlock {
    const obj = asObject(v) orelse return error.InvalidMessage;
    const ty = str(obj, "type") orelse return error.InvalidMessage;
    const Tag = std.meta.Tag(ContentBlock);
    const tag = std.meta.stringToEnum(Tag, ty) orelse
        return .{ .provider_opaque = .{ .origin = .unknown, .kind = ty, .raw_json = try stringifyValue(arena, v) } };
    return switch (tag) {
        .text => .{ .text = .{
            .text = str(obj, "text") orelse return error.InvalidMessage,
            .citations_json = if (obj.get("citations")) |c| try stringifyValue(arena, c) else null,
        } },
        .image => .{ .image = .{ .media_type = try reqStr(obj, "media_type"), .data = try decodeBlob(obj) } },
        .document => .{ .document = .{ .media_type = try reqStr(obj, "media_type"), .data = try decodeBlob(obj), .title = str(obj, "title") } },
        .thinking => .{ .thinking = .{
            .text = try reqStr(obj, "text"),
            .signature = str(obj, "signature") orelse "",
            .redacted = boolean(obj, "redacted"),
            .origin = std.meta.stringToEnum(message.ProviderId, str(obj, "origin") orelse "unknown") orelse .unknown,
        } },
        .tool_use => .{ .tool_use = .{
            .id = try reqStr(obj, "id"),
            .name = try reqStr(obj, "name"),
            .input_json = if (obj.get("input")) |i| try stringifyValue(arena, i) else "{}",
            .server = boolean(obj, "server"),
        } },
        .tool_result => blk: {
            const parts: []ResultPart = if (obj.get("content")) |c| switch (c) {
                .string => |t| p: {
                    const one = try arena.alloc(ResultPart, 1);
                    one[0] = .{ .text = t };
                    break :p one;
                },
                .array => |a| p: {
                    const out = try arena.alloc(ResultPart, a.items.len);
                    for (a.items, out) |item, *part| part.* = try decodePart(item);
                    break :p out;
                },
                else => return error.InvalidMessage,
            } else &.{};
            break :blk .{ .tool_result = .{ .tool_use_id = try reqStr(obj, "tool_use_id"), .parts = parts, .is_error = boolean(obj, "is_error") } };
        },
        .provider_opaque => .{ .provider_opaque = .{
            .origin = std.meta.stringToEnum(message.ProviderId, str(obj, "origin") orelse "unknown") orelse .unknown,
            .kind = try reqStr(obj, "kind"),
            .raw_json = try stringifyValue(arena, obj.get("raw") orelse return error.InvalidMessage),
        } },
    };
}

/// Decodes one tool-result part.
pub fn decodePart(v: Value) DecodeError!ResultPart {
    const obj = asObject(v) orelse return error.InvalidMessage;
    const ty = str(obj, "type") orelse return error.InvalidMessage;
    const tag = std.meta.stringToEnum(std.meta.Tag(ResultPart), ty) orelse return error.InvalidMessage;
    return switch (tag) {
        .text => .{ .text = try reqStr(obj, "text") },
        .image => .{ .image = .{ .media_type = try reqStr(obj, "media_type"), .data = try decodeBlob(obj) } },
        .document => .{ .document = .{ .media_type = try reqStr(obj, "media_type"), .data = try decodeBlob(obj), .title = str(obj, "title") } },
        .resource_link => .{ .resource_link = .{ .uri = try reqStr(obj, "uri"), .name = try reqStr(obj, "name"), .mime = str(obj, "mime") } },
    };
}

fn decodeBlob(obj: std.json.ObjectMap) DecodeError!Blob {
    const src = asObject(obj.get("source") orelse return error.InvalidMessage) orelse return error.InvalidMessage;
    const ty = str(src, "type") orelse return error.InvalidMessage;
    if (std.mem.eql(u8, ty, "base64")) return .{ .base64 = try reqStr(src, "data") };
    if (std.mem.eql(u8, ty, "url")) return .{ .url = try reqStr(src, "url") };
    if (std.mem.eql(u8, ty, "file")) return .{ .file = try reqStr(src, "path") };
    return error.InvalidMessage;
}

/// The object payload of `v`, if it is one.
pub fn asObject(v: Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

/// String member `key` of `obj`, if present and a string.
pub fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn reqStr(obj: std.json.ObjectMap, key: []const u8) DecodeError![]const u8 {
    return str(obj, key) orelse error.InvalidMessage;
}

/// Bool member `key`, false when absent.
pub fn boolean(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

/// Integer member `key` (number text or integer), if present.
pub fn int(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| std.math.cast(T, i),
        .number_string => |s| std.fmt.parseInt(T, s, 10) catch null,
        .float => |f| if (f >= 0 and f < 1e18) std.math.cast(T, @as(i64, @intFromFloat(f))) else null,
        else => null,
    };
}

/// Encodes `m` into a fresh slice owned by `gpa`.
pub fn messageAlloc(gpa: Allocator, m: Message) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    encodeMessage(&out.writer, m) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Deep-copies `m` into `arena` (all slices duplicated).
pub fn cloneMessage(arena: Allocator, m: Message) Allocator.Error!Message {
    const text = try messageAlloc(arena, m);
    return decodeMessageText(arena, text) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidMessage => unreachable,
    };
}

test "unknown_block_preserved" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\"role\":\"assistant\",\"content\":[{\"type\":\"server_tool_use\",\"id\":\"x\",\"name\":\"web_search\",\"input\":{}}]}";
    const m = try decodeMessageText(a, src);
    try std.testing.expect(m.content[0] == .provider_opaque);
    try std.testing.expectEqualStrings("server_tool_use", m.content[0].provider_opaque.kind);
    try std.testing.expectEqualStrings(src, try messageAlloc(a, m));
}

test "numbers keep their source text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("{\"a\":1.50,\"b\":[1e3]}", try canonicalize(arena.allocator(), " {\"a\": 1.50, \"b\": [1e3]} "));
    try std.testing.expectEqualStrings("{}", try canonicalize(arena.allocator(), ""));
}
