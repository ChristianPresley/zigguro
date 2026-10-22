//! Small JSON-writing and HTTP-error helpers shared by the OpenAI,
//! Chat Completions and Gemini providers.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("Provider.zig");
const events = @import("events.zig");
const sse_stream = @import("sse_stream.zig");

const Stringify = std.json.Stringify;

/// Writes `"name": v`.
pub fn field(s: *Stringify, name: []const u8, v: anytype) Stringify.Error!void {
    try s.objectField(name);
    try s.write(v);
}

/// Writes pre-encoded JSON as a value.
pub const raw = proto.json.writeRaw;

/// A `data:` URL for a base64 blob (`null` for URL or file blobs).
pub fn dataUrl(a: std.mem.Allocator, media_type: []const u8, blob: proto.Blob) !?[]const u8 {
    return switch (blob) {
        .base64 => |d| try std.mem.concat(a, u8, &.{ "data:", media_type, ";base64,", d }),
        .url => |u| u,
        .file => null,
    };
}

/// Flattens tool-result parts to text (non-text parts become markers).
pub fn flattenParts(a: std.mem.Allocator, parts: []const proto.ResultPart) ![]const u8 {
    if (parts.len == 1 and parts[0] == .text) return parts[0].text;
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i > 0) try out.append(a, '\n');
        switch (p) {
            .text => |t| try out.appendSlice(a, t),
            .image => try out.appendSlice(a, "[image omitted]"),
            .document => try out.appendSlice(a, "[document omitted]"),
            .resource_link => |r| try out.print(a, "{s} ({s})", .{ r.name, r.uri }),
        }
    }
    return out.items;
}

/// Writes the body to a fresh slice.
pub fn bodyAlloc(a: std.mem.Allocator, ctx: anytype, comptime writeBody: anytype) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    writeBody(&out.writer, ctx) catch return error.OutOfMemory;
    return out.written();
}

/// Classifies a non-2xx body shaped `{"error":{"message","type"|"status","code"}}`,
/// emits a `provider_error` and returns the error.
pub fn httpFailure(arena: std.mem.Allocator, out: sse_stream.Outcome, sink: events.EventSink) Provider.StreamError {
    var kind: []const u8 = "";
    var message: []const u8 = out.prefix[0..@min(out.prefix.len, 512)];
    if (proto.json.parseValue(arena, out.prefix)) |v| {
        if (proto.json.asObject(v)) |o| {
            const ev = o.get("error") orelse std.json.Value.null;
            if (proto.json.asObject(ev)) |e| {
                kind = proto.json.str(e, "type") orelse proto.json.str(e, "status") orelse proto.json.str(e, "code") orelse "";
                message = proto.json.str(e, "message") orelse "";
            } else if (ev == .string) message = ev.string;
        }
    } else |_| {}
    const ra = out.head.get("retry-after");
    const ra_ms: ?u64 = if (ra) |x| (std.fmt.parseInt(u64, std.mem.trim(u8, x, " "), 10) catch 0) * 1000 else null;
    sink.send(.{ .provider_error = .{ .status = out.head.status, .kind = kind, .message = message, .retry_after_ms = ra_ms, .request_id = out.head.request_id } });
    if (std.mem.indexOf(u8, kind, "insufficient_quota") != null) return error.InvalidRequest;
    if (std.mem.eql(u8, kind, "RESOURCE_EXHAUSTED")) return error.RateLimited;
    return Provider.classifyStatus(out.head.status, kind, message);
}

/// Wraps a provider decoder so its events also fold into an assembler.
pub fn Emitter(comptime origin: proto.ProviderId) type {
    return struct {
        sink: events.EventSink,
        asm_: @import("assembler.zig").MessageAssembler,

        /// An emitter folding into `arena`.
        pub fn init(arena: std.mem.Allocator, sink: events.EventSink) @This() {
            var e: @This() = .{ .sink = sink, .asm_ = .init(arena) };
            e.asm_.origin = origin;
            return e;
        }

        /// Folds and forwards `ev`.
        pub fn emit(e: *@This(), ev: events.StreamEvent) Provider.StreamError!void {
            e.asm_.feed(ev) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Protocol,
            };
            e.sink.send(ev);
        }

        /// The final response.
        pub fn response(e: *@This()) Provider.StreamError!@import("request.zig").Response {
            const fin = e.asm_.finishLenient() catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Protocol,
            };
            return .{ .message = fin.message, .stop = e.asm_.stop orelse .end_turn, .usage = e.asm_.usage, .rate_limit = e.asm_.rate_limit, .truncated_tool_use = fin.truncated_tool_use };
        }
    };
}

/// Maps dense canonical block indices to provider keys (output index, part).
pub const IndexMap = struct {
    keys: std.ArrayList(u64) = .empty,

    /// The canonical index for `key`, and whether it is new.
    pub fn get(m: *IndexMap, a: std.mem.Allocator, key: u64) !struct { index: u32, new: bool } {
        for (m.keys.items, 0..) |k, i| if (k == key) return .{ .index = @intCast(i), .new = false };
        try m.keys.append(a, key);
        return .{ .index = @intCast(m.keys.items.len - 1), .new = true };
    }

    /// The canonical index for `key`, if seen.
    pub fn find(m: *const IndexMap, key: u64) ?u32 {
        for (m.keys.items, 0..) |k, i| if (k == key) return @intCast(i);
        return null;
    }
};
