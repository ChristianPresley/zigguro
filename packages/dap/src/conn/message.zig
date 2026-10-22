//! The DAP base protocol message envelope: decoding without a full parse
//! (`seq`, `type`, `command`/`event`, `request_seq`, `success`, `message`,
//! with `arguments`/`body` kept as raw JSON for lazy typed decoding), the
//! writers for requests and responses, and error message formatting.

const std = @import("std");
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../gen/protocol.zig");
const Allocator = std.mem.Allocator;

pub const RawJson = zg_jsonrpc.message.RawJson;

pub const Kind = enum { request, response, event };

/// One decoded message. Strings and `body` point into the decode arena
/// or the input.
pub const Envelope = struct {
    seq: u32,
    kind: Kind,
    /// Requests and responses: the command. Events: the event name.
    name: []const u8,
    /// Responses only.
    request_seq: u32 = 0,
    success: bool = false,
    message: ?[]const u8 = null,
    /// `arguments` of a request, `body` of a response or event.
    body: ?RawJson = null,
};

pub const DecodeError = error{ InvalidMessage, OutOfMemory };

/// Decodes the envelope of `bytes`. Unknown keys are skipped.
pub fn decode(arena: Allocator, bytes: []const u8) DecodeError!Envelope {
    var sc: std.json.Scanner = .initCompleteInput(arena, bytes);
    defer sc.deinit();
    return decodeScanner(arena, &sc, bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidMessage,
    };
}

fn decodeScanner(arena: Allocator, sc: *std.json.Scanner, bytes: []const u8) !Envelope {
    if (try sc.next() != .object_begin) return error.InvalidMessage;
    var seq: ?u32 = null;
    var kind: ?Kind = null;
    var command: ?[]const u8 = null;
    var event: ?[]const u8 = null;
    var env: Envelope = .{ .seq = 0, .kind = .event, .name = "" };
    while (true) {
        const key = switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
            .object_end => break,
            .string, .allocated_string => |s| s,
            else => return error.InvalidMessage,
        };
        if (eql(key, "seq")) {
            seq = try readInt(arena, sc);
        } else if (eql(key, "request_seq")) {
            env.request_seq = try readInt(arena, sc);
        } else if (eql(key, "type")) {
            const t = try readString(arena, sc);
            kind = std.meta.stringToEnum(Kind, t) orelse return error.InvalidMessage;
        } else if (eql(key, "command")) {
            command = try readString(arena, sc);
        } else if (eql(key, "event")) {
            event = try readString(arena, sc);
        } else if (eql(key, "success")) {
            env.success = switch (try sc.next()) {
                .true => true,
                .false => false,
                else => return error.InvalidMessage,
            };
        } else if (eql(key, "message")) {
            env.message = switch (try sc.peekNextTokenType()) {
                .null => blk: {
                    _ = try sc.next();
                    break :blk null;
                },
                else => try readString(arena, sc),
            };
        } else if (eql(key, "arguments") or eql(key, "body")) {
            const start = sc.cursor;
            try sc.skipValue();
            const raw = trimValue(bytes[start..sc.cursor]);
            env.body = if (std.mem.eql(u8, raw, "null")) null else .{ .bytes = raw };
        } else {
            try sc.skipValue();
        }
    }
    if (try sc.next() != .end_of_document) return error.InvalidMessage;
    env.seq = seq orelse return error.InvalidMessage;
    env.kind = kind orelse return error.InvalidMessage;
    env.name = switch (env.kind) {
        .request, .response => command orelse return error.InvalidMessage,
        .event => event orelse return error.InvalidMessage,
    };
    return env;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The text of a value the scanner just skipped: drops the `:` and the
/// whitespace before it.
fn trimValue(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len > 0 and t[0] == ':') t = std.mem.trimStart(u8, t[1..], " \t\r\n");
    return t;
}

fn readString(arena: Allocator, sc: *std.json.Scanner) ![]const u8 {
    return switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
        .string, .allocated_string => |s| s,
        else => error.InvalidMessage,
    };
}

fn readInt(arena: Allocator, sc: *std.json.Scanner) !u32 {
    const tok = try sc.nextAlloc(arena, .alloc_if_needed);
    const s = switch (tok) {
        .number, .allocated_number => |n| n,
        else => return error.InvalidMessage,
    };
    return std.fmt.parseInt(u32, s, 10) catch error.InvalidMessage;
}

/// Writes a request. `args_json` is JSON text or null.
pub fn writeRequest(w: *std.Io.Writer, seq: u32, command: []const u8, args_json: ?[]const u8) std.Io.Writer.Error!void {
    try w.print("{{\"seq\":{d},\"type\":\"request\",\"command\":", .{seq});
    try std.json.Stringify.encodeJsonString(command, .{}, w);
    if (args_json) |a| {
        try w.writeAll(",\"arguments\":");
        try w.writeAll(a);
    }
    try w.writeByte('}');
}

/// Writes a response to a reverse request.
pub fn writeResponse(w: *std.Io.Writer, seq: u32, request_seq: u32, command: []const u8, success: bool, body_json: ?[]const u8, msg: ?[]const u8) std.Io.Writer.Error!void {
    try w.print("{{\"seq\":{d},\"type\":\"response\",\"request_seq\":{d},\"success\":{},\"command\":", .{ seq, request_seq, success });
    try std.json.Stringify.encodeJsonString(command, .{}, w);
    if (msg) |m| {
        try w.writeAll(",\"message\":");
        try std.json.Stringify.encodeJsonString(m, .{}, w);
    }
    if (body_json) |b| {
        try w.writeAll(",\"body\":");
        try w.writeAll(b);
    }
    try w.writeByte('}');
}

/// The `body.error` of a failed response, if present and well formed.
pub fn errorBody(arena: Allocator, body: ?RawJson) ?protocol.Message {
    const b = body orelse return null;
    const E = struct { @"error": ?protocol.Message = null };
    const e = b.parseLeaky(E, arena, .{}) catch return null;
    return e.@"error";
}

/// Substitutes `{name}` placeholders from `variables` (unknown names stay
/// as written), for display.
pub fn formatMessage(arena: Allocator, m: protocol.Message) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var i: usize = 0;
    const f = m.format;
    while (i < f.len) {
        if (f[i] == '{') if (std.mem.indexOfScalarPos(u8, f, i + 1, '}')) |end| {
            const name = f[i + 1 .. end];
            if (m.variables) |vars| if (vars.map.get(name)) |v| {
                w.writeAll(v) catch return error.OutOfMemory;
                i = end + 1;
                continue;
            };
        };
        w.writeByte(f[i]) catch return error.OutOfMemory;
        i += 1;
    }
    return out.toOwnedSlice();
}

test "message: decode request, response and event" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;

    const req = try decode(a, "{\"seq\":3,\"type\":\"request\",\"command\":\"runInTerminal\",\"arguments\": {\"args\":[\"a\"]}}");
    try t.expectEqual(Kind.request, req.kind);
    try t.expectEqual(@as(u32, 3), req.seq);
    try t.expectEqualStrings("runInTerminal", req.name);
    try t.expectEqualStrings("{\"args\":[\"a\"]}", req.body.?.bytes);

    const resp = try decode(a, "{\"type\":\"response\",\"seq\":9,\"request_seq\":4,\"success\":false,\"command\":\"evaluate\",\"message\":\"not \\\"stopped\\\"\",\"body\":null,\"extra\":[1,{}]}");
    try t.expectEqual(Kind.response, resp.kind);
    try t.expectEqual(@as(u32, 4), resp.request_seq);
    try t.expect(!resp.success);
    try t.expectEqualStrings("not \"stopped\"", resp.message.?);
    try t.expect(resp.body == null);

    const ev = try decode(a, "{\"seq\":1,\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"reason\":\"step\"}}");
    try t.expectEqual(Kind.event, ev.kind);
    try t.expectEqualStrings("stopped", ev.name);
    try t.expectEqualStrings("{\"reason\":\"step\"}", ev.body.?.bytes);

    for ([_][]const u8{ "[]", "{}", "{\"seq\":1}", "{\"seq\":1,\"type\":\"request\"}", "{\"seq\":-1,\"type\":\"event\",\"event\":\"x\"}", "{\"seq\":1,\"type\":\"bogus\",\"event\":\"x\"}", "{\"seq\":1,\"type\":\"event\",\"event\":\"x\"} 1" }) |bad|
        try t.expectError(error.InvalidMessage, decode(a, bad));
}

test "message: writers round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeRequest(&aw.writer, 7, "setBreakpoints", "{\"lines\":[1]}");
    const req = try decode(a, aw.written());
    try std.testing.expectEqualStrings("setBreakpoints", req.name);
    try std.testing.expectEqualStrings("{\"lines\":[1]}", req.body.?.bytes);

    var aw2: std.Io.Writer.Allocating = .init(a);
    try writeResponse(&aw2.writer, 8, 2, "runInTerminal", false, null, "not supported");
    const resp = try decode(a, aw2.written());
    try std.testing.expectEqual(@as(u32, 2), resp.request_seq);
    try std.testing.expectEqualStrings("not supported", resp.message.?);
}

test "message: error body with format variables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try decode(a,
        \\{"seq":2,"type":"response","request_seq":1,"success":false,"command":"launch","message":"failed",
        \\ "body":{"error":{"id":3,"format":"cannot open {path}: {_err} {missing}","variables":{"path":"/w/app","_err":"ENOENT"},"showUser":true}}}
    );
    const m = errorBody(a, env.body).?;
    try std.testing.expectEqual(@as(i64, 3), m.id);
    try std.testing.expectEqualStrings("cannot open /w/app: ENOENT {missing}", try formatMessage(a, m));
}

test "fuzz: dap message decode" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const env = decode(a, input) catch return;
            _ = errorBody(a, env.body);
            if (errorBody(a, env.body)) |m| _ = try formatMessage(a, m);
        }
    }.one, .{});
}
