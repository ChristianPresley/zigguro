//! The JSON-RPC 2.0 message model.
//!
//! `parse` is two-phase. Phase 1 (here) walks the top-level object with
//! `std.json.Scanner`, classifies the message and records `params`,
//! `result` and `error.data` as `RawJson` slices into the frame body: no
//! copy, so dispatch cost does not depend on payload size. Phase 2 is the
//! handler calling `RawJson.parse` for the type it expects.
//!
//! Ownership: every slice in a parsed message (method, string ids, raw
//! values) points into `body` or into `arena`, so it is valid only while
//! both live; a handler that keeps one must copy it.
//!
//! Writers use `std.json.Stringify` with `.minified` whitespace, which never
//! emits a raw newline, so their output is safe for NDJSON framing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;
const Stringify = std.json.Stringify;

/// A request id. Integer ids must fit in `i64`; `null` appears only in
/// responses to requests whose id could not be read.
pub const Id = union(enum) {
    int: i64,
    str: []const u8,
    null,

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .int => |x| b == .int and b.int == x,
            .str => |x| b == .str and std.mem.eql(u8, x, b.str),
            .null => b == .null,
        };
    }

    pub fn hash(id: Id) u64 {
        var h: std.hash.Wyhash = .init(@intFromEnum(id));
        switch (id) {
            .int => |x| h.update(std.mem.asBytes(&x)),
            .str => |s| h.update(s),
            .null => {},
        }
        return h.final();
    }

    pub fn jsonStringify(id: Id, w: *Stringify) !void {
        switch (id) {
            .int => |x| try w.write(x),
            .str => |s| try w.write(s),
            .null => try w.write(null),
        }
    }
};

/// JSON-RPC 2.0 and LSP 3.17 error codes. Non-exhaustive: peers may send
/// any `i32`.
pub const ErrorCode = enum(i32) {
    /// Invalid JSON was received.
    parse_error = -32700,
    /// The JSON is not a valid request object.
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    /// LSP: a request arrived before `initialize`.
    server_not_initialized = -32002,
    /// LSP: reserved generic code.
    unknown_error_code = -32001,
    /// LSP: the request was valid but failed.
    request_failed = -32803,
    /// LSP: the server cancelled the request.
    server_cancelled = -32802,
    /// LSP: the document changed while the request ran.
    content_modified = -32801,
    /// LSP: the client cancelled the request.
    request_cancelled = -32800,
    _,

    pub fn int(c: ErrorCode) i32 {
        return @intFromEnum(c);
    }
};

/// The `error` member of a response.
pub const ErrorObject = struct {
    code: i32,
    message: []const u8,
    data: ?RawJson = null,

    fn of(code: ErrorCode, message: []const u8) ErrorObject {
        return .{ .code = code.int(), .message = message };
    }
};

/// An unparsed JSON value: a slice of the frame body.
pub const RawJson = struct {
    bytes: []const u8,

    /// Parses into `T`, ignoring unknown fields unless `opts` says otherwise.
    pub fn parse(self: RawJson, comptime T: type, gpa: Allocator, opts: std.json.ParseOptions) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, gpa, self.bytes, withDefaults(opts));
    }

    /// Like `parse`, allocating everything in `arena` and returning the value.
    pub fn parseLeaky(self: RawJson, comptime T: type, arena: Allocator, opts: std.json.ParseOptions) !T {
        return std.json.parseFromSliceLeaky(T, arena, self.bytes, withDefaults(opts));
    }

    /// Writes the value verbatim, turning raw CR/LF (insignificant
    /// whitespace in valid JSON) into spaces so the output stays NDJSON-safe.
    pub fn jsonStringify(self: RawJson, w: *Stringify) !void {
        try w.beginWriteRaw();
        var rest = self.bytes;
        while (std.mem.indexOfAny(u8, rest, "\r\n")) |i| {
            try w.writer.writeAll(rest[0..i]);
            try w.writer.writeByte(' ');
            rest = rest[i + 1 ..];
        }
        try w.writer.writeAll(rest);
        w.endWriteRaw();
    }

    fn withDefaults(opts: std.json.ParseOptions) std.json.ParseOptions {
        var o = opts;
        o.ignore_unknown_fields = true;
        return o;
    }
};

pub const Request = struct { id: Id, method: []const u8, params: ?RawJson = null };
pub const Notification = struct { method: []const u8, params: ?RawJson = null };
/// Exactly one of `result` and `err` is set.
pub const Response = struct { id: Id, result: ?RawJson = null, err: ?ErrorObject = null };

pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
};

/// One element of a batch: a message, or an error to answer with id null.
pub const BatchEntry = union(enum) {
    message: Message,
    invalid: ErrorObject,
};

pub const Parsed = union(enum) {
    single: Message,
    batch: []BatchEntry,
    /// Reply with this error and id null.
    invalid: ErrorObject,
};

/// Classifies `body`. Never fails: malformed input yields `.invalid`.
/// `arena` holds the batch slice and any unescaped strings.
pub fn parse(arena: Allocator, body: []const u8) Parsed {
    var sfa = std.heap.stackFallback(512, arena);
    var sc: Scanner = .initCompleteInput(sfa.get(), body);
    defer sc.deinit();
    const first = sc.peekNextTokenType() catch return .{ .invalid = .of(.parse_error, "Parse error") };
    switch (first) {
        .object_begin => {
            sc.skipValue() catch return .{ .invalid = .of(.parse_error, "Parse error") };
            if (!atEnd(&sc)) return .{ .invalid = .of(.parse_error, "Parse error") };
            return switch (classify(arena, body)) {
                .message => |m| .{ .single = m },
                .invalid => |e| .{ .invalid = e },
            };
        },
        .array_begin => {
            var slices: std.ArrayList([]const u8) = .empty;
            _ = sc.next() catch return .{ .invalid = .of(.parse_error, "Parse error") };
            while (true) {
                const t = sc.peekNextTokenType() catch return .{ .invalid = .of(.parse_error, "Parse error") };
                if (t == .array_end) break;
                const v = rawValue(&sc, body) catch return .{ .invalid = .of(.parse_error, "Parse error") };
                slices.append(arena, v) catch return .{ .invalid = .of(.internal_error, "Out of memory") };
            }
            _ = sc.next() catch return .{ .invalid = .of(.parse_error, "Parse error") };
            if (!atEnd(&sc)) return .{ .invalid = .of(.parse_error, "Parse error") };
            if (slices.items.len == 0) return .{ .invalid = .of(.invalid_request, "Invalid Request") };
            const out = arena.alloc(BatchEntry, slices.items.len) catch return .{ .invalid = .of(.internal_error, "Out of memory") };
            for (slices.items, out) |s, *e| e.* = classify(arena, s);
            return .{ .batch = out };
        },
        else => {
            sc.skipValue() catch return .{ .invalid = .of(.parse_error, "Parse error") };
            if (!atEnd(&sc)) return .{ .invalid = .of(.parse_error, "Parse error") };
            return .{ .invalid = .of(.invalid_request, "Invalid Request") };
        },
    }
}

fn atEnd(sc: *Scanner) bool {
    const t = sc.next() catch return false;
    return t == .end_of_document;
}

/// The slice of the next value, with surrounding whitespace removed.
fn rawValue(sc: *Scanner, body: []const u8) ![]const u8 {
    _ = try sc.peekNextTokenType();
    const start = sc.cursor;
    try sc.skipValue();
    return std.mem.trimEnd(u8, body[start..sc.cursor], " \t\r\n");
}

fn invalidRequest() BatchEntry {
    return .{ .invalid = .of(.invalid_request, "Invalid Request") };
}

/// Classifies one syntactically valid JSON value.
fn classify(arena: Allocator, body: []const u8) BatchEntry {
    return classifyInner(arena, body) catch |err| switch (err) {
        error.OutOfMemory => .{ .invalid = .of(.internal_error, "Out of memory") },
        else => invalidRequest(),
    };
}

const ClassifyError = Scanner.AllocError || Scanner.PeekError || error{Invalid};

fn classifyInner(arena: Allocator, body: []const u8) ClassifyError!BatchEntry {
    var sfa = std.heap.stackFallback(512, arena);
    var sc: Scanner = .initCompleteInput(sfa.get(), body);
    defer sc.deinit();
    if (try sc.next() != .object_begin) return invalidRequest();

    var version_ok = false;
    var id: ?Id = null;
    var method: ?[]const u8 = null;
    var params: ?RawJson = null;
    var result: ?RawJson = null;
    var err_obj: ?ErrorObject = null;
    while (true) {
        const key = switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
            .object_end => break,
            .string => |s| s,
            .allocated_string => |s| s,
            else => return error.Invalid,
        };
        if (std.mem.eql(u8, key, "jsonrpc")) {
            version_ok = switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
                .string, .allocated_string => |s| std.mem.eql(u8, s, "2.0"),
                .object_begin, .array_begin => return error.Invalid,
                else => false,
            };
        } else if (std.mem.eql(u8, key, "id")) {
            id = switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
                .string, .allocated_string => |s| .{ .str = s },
                .number, .allocated_number => |n| .{ .int = std.fmt.parseInt(i64, n, 10) catch return error.Invalid },
                .null => .null,
                else => return error.Invalid,
            };
        } else if (std.mem.eql(u8, key, "method")) {
            method = switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
                .string, .allocated_string => |s| s,
                else => return error.Invalid,
            };
        } else if (std.mem.eql(u8, key, "params")) {
            const t = try sc.peekNextTokenType();
            if (t != .object_begin and t != .array_begin) return error.Invalid;
            params = .{ .bytes = try rawValue(&sc, body) };
        } else if (std.mem.eql(u8, key, "result")) {
            result = .{ .bytes = try rawValue(&sc, body) };
        } else if (std.mem.eql(u8, key, "error")) {
            err_obj = try parseErrorObject(arena, try rawValue(&sc, body));
        } else {
            try sc.skipValue();
        }
    }

    if (!version_ok) return invalidRequest();
    if (method) |m| {
        if (result != null or err_obj != null) return invalidRequest();
        const i = id orelse return .{ .message = .{ .notification = .{ .method = m, .params = params } } };
        if (i == .null) return invalidRequest();
        return .{ .message = .{ .request = .{ .id = i, .method = m, .params = params } } };
    }
    const i = id orelse return invalidRequest();
    if ((result == null) == (err_obj == null)) return invalidRequest();
    if (i == .null and err_obj == null) return invalidRequest();
    return .{ .message = .{ .response = .{ .id = i, .result = result, .err = err_obj } } };
}

fn parseErrorObject(arena: Allocator, bytes: []const u8) ClassifyError!ErrorObject {
    var sfa = std.heap.stackFallback(256, arena);
    var sc: Scanner = .initCompleteInput(sfa.get(), bytes);
    defer sc.deinit();
    if (try sc.next() != .object_begin) return error.Invalid;
    var code: ?i32 = null;
    var message: ?[]const u8 = null;
    var data: ?RawJson = null;
    while (true) {
        const key = switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
            .object_end => break,
            .string, .allocated_string => |s| s,
            else => return error.Invalid,
        };
        if (std.mem.eql(u8, key, "code")) {
            code = switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
                .number, .allocated_number => |n| std.fmt.parseInt(i32, n, 10) catch return error.Invalid,
                else => return error.Invalid,
            };
        } else if (std.mem.eql(u8, key, "message")) {
            message = switch (try sc.nextAlloc(arena, .alloc_if_needed)) {
                .string, .allocated_string => |s| s,
                else => return error.Invalid,
            };
        } else if (std.mem.eql(u8, key, "data")) {
            data = .{ .bytes = try rawValue(&sc, bytes) };
        } else {
            try sc.skipValue();
        }
    }
    return .{ .code = code orelse return error.Invalid, .message = message orelse return error.Invalid, .data = data };
}

fn begin(s: *Stringify) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
}

fn writeParams(s: *Stringify, params: anytype) !void {
    const P = @TypeOf(params);
    if (P == void or P == @TypeOf(null)) return;
    if (@typeInfo(P) == .optional) {
        if (params) |p| return writeParams(s, p);
        return;
    }
    try s.objectField("params");
    try s.write(params);
}

/// Writes `{"jsonrpc":"2.0","id":..,"method":..,"params":..}`. `params` of
/// type `void`, `null` or a null optional is omitted; a `RawJson` is copied
/// verbatim.
pub fn writeRequest(w: *std.Io.Writer, id: Id, method: []const u8, params: anytype) !void {
    var s: Stringify = .{ .writer = w };
    try begin(&s);
    try s.objectField("id");
    try s.write(id);
    try s.objectField("method");
    try s.write(method);
    try writeParams(&s, params);
    try s.endObject();
}

/// Writes a notification (a request without an id).
pub fn writeNotification(w: *std.Io.Writer, method: []const u8, params: anytype) !void {
    var s: Stringify = .{ .writer = w };
    try begin(&s);
    try s.objectField("method");
    try s.write(method);
    try writeParams(&s, params);
    try s.endObject();
}

/// Writes a success response; `void` results are written as `null`.
pub fn writeResult(w: *std.Io.Writer, id: Id, result: anytype) !void {
    var s: Stringify = .{ .writer = w };
    try begin(&s);
    try s.objectField("id");
    try s.write(id);
    try s.objectField("result");
    if (@TypeOf(result) == void) try s.write(null) else try s.write(result);
    try s.endObject();
}

/// Writes an error response; `data` of type `void` or `null` is omitted.
pub fn writeError(w: *std.Io.Writer, id: Id, code: i32, message: []const u8, data: anytype) !void {
    var s: Stringify = .{ .writer = w };
    try begin(&s);
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    const D = @TypeOf(data);
    if (D != void and D != @TypeOf(null)) {
        if (@typeInfo(D) != .optional or data != null) {
            try s.objectField("data");
            try s.write(data);
        }
    }
    try s.endObject();
    try s.endObject();
}

const testing = std.testing;

/// A compact description of a parse result for table tests.
fn describe(gpa: Allocator, p: Parsed) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (p) {
        .single => |m| try describeMessage(gpa, &out, m),
        .invalid => |e| try out.print(gpa, "invalid({d})", .{e.code}),
        .batch => |b| {
            try out.appendSlice(gpa, "batch[");
            for (b, 0..) |e, i| {
                if (i != 0) try out.append(gpa, ',');
                switch (e) {
                    .message => |m| try describeMessage(gpa, &out, m),
                    .invalid => |x| try out.print(gpa, "invalid({d})", .{x.code}),
                }
            }
            try out.append(gpa, ']');
        },
    }
    return out.toOwnedSlice(gpa);
}

fn describeId(gpa: Allocator, out: *std.ArrayList(u8), id: Id) !void {
    switch (id) {
        .int => |x| try out.print(gpa, "{d}", .{x}),
        .str => |s| try out.print(gpa, "\"{s}\"", .{s}),
        .null => try out.appendSlice(gpa, "null"),
    }
}

fn describeMessage(gpa: Allocator, out: *std.ArrayList(u8), m: Message) !void {
    switch (m) {
        .request => |r| {
            try out.appendSlice(gpa, "req(");
            try describeId(gpa, out, r.id);
            try out.print(gpa, ",{s},{s})", .{ r.method, if (r.params) |p| p.bytes else "-" });
        },
        .notification => |n| try out.print(gpa, "note({s},{s})", .{ n.method, if (n.params) |p| p.bytes else "-" }),
        .response => |r| {
            try out.appendSlice(gpa, "resp(");
            try describeId(gpa, out, r.id);
            if (r.result) |x| try out.print(gpa, ",ok:{s})", .{x.bytes});
            if (r.err) |e| try out.print(gpa, ",err:{d}:{s})", .{ e.code, e.message });
        },
    }
}

fn expectParse(body: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try describe(arena.allocator(), parse(arena.allocator(), body));
    try testing.expectEqualStrings(expected, d);
}

test "message: JSON-RPC 2.0 section 7 examples" {
    // Positional and named parameters.
    try expectParse(
        \\{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
    , "req(1,subtract,[42, 23])");
    try expectParse(
        \\{"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23, "minuend": 42}, "id": 3}
    , "req(3,subtract,{\"subtrahend\": 23, \"minuend\": 42})");
    try expectParse(
        \\{"jsonrpc": "2.0", "result": 19, "id": 1}
    , "resp(1,ok:19)");
    // Notifications.
    try expectParse(
        \\{"jsonrpc": "2.0", "method": "update", "params": [1,2,3,4,5]}
    , "note(update,[1,2,3,4,5])");
    try expectParse(
        \\{"jsonrpc": "2.0", "method": "foobar"}
    , "note(foobar,-)");
    // Error response for a non-existent method.
    try expectParse(
        \\{"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": "1"}
    , "resp(\"1\",err:-32601:Method not found)");
    // Invalid JSON.
    try expectParse(
        \\{"jsonrpc": "2.0", "method": "foobar, "params": "bar", "baz]
    , "invalid(-32700)");
    // Invalid Request object (method is not a string).
    try expectParse(
        \\{"jsonrpc": "2.0", "method": 1, "params": "bar"}
    , "invalid(-32600)");
    // Batch, invalid JSON.
    try expectParse(
        \\[
        \\  {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
        \\  {"jsonrpc": "2.0", "method"
        \\]
    , "invalid(-32700)");
    // Empty array.
    try expectParse("[]", "invalid(-32600)");
    // Invalid batch, not empty.
    try expectParse("[1]", "batch[invalid(-32600)]");
    try expectParse("[1,2,3]", "batch[invalid(-32600),invalid(-32600),invalid(-32600)]");
    // Mixed batch.
    try expectParse(
        \\[
        \\  {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"},
        \\  {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]},
        \\  {"jsonrpc": "2.0", "method": "subtract", "params": [42,23], "id": "2"},
        \\  {"foo": "boo"},
        \\  {"jsonrpc": "2.0", "method": "foo.get", "params": {"name": "myself"}, "id": "5"},
        \\  {"jsonrpc": "2.0", "method": "get_data", "id": "9"}
        \\]
    , "batch[req(\"1\",sum,[1,2,4]),note(notify_hello,[7]),req(\"2\",subtract,[42,23]),invalid(-32600),req(\"5\",foo.get,{\"name\": \"myself\"}),req(\"9\",get_data,-)]");
    // All-notification batch.
    try expectParse(
        \\[{"jsonrpc": "2.0", "method": "notify_sum", "params": [1,2,4]}, {"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}]
    , "batch[note(notify_sum,[1,2,4]),note(notify_hello,[7])]");
}

test "message: classification rules" {
    try expectParse("{\"method\":\"a\",\"id\":1}", "invalid(-32600)"); // no jsonrpc
    try expectParse("{\"jsonrpc\":\"1.0\",\"method\":\"a\",\"id\":1}", "invalid(-32600)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"method\":\"a\",\"id\":1.5}", "invalid(-32600)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"method\":\"a\",\"id\":99999999999999999999}", "invalid(-32600)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"method\":\"a\",\"id\":null}", "invalid(-32600)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"method\":\"a\",\"params\":3}", "invalid(-32600)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"id\":1}", "invalid(-32600)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":{\"code\":1,\"message\":\"x\"}}", "invalid(-32600)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}", "resp(null,err:-32700:Parse error)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":1}", "invalid(-32600)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"id\":-7,\"result\":null,\"extra\":[1,{}]}", "resp(-7,ok:null)");
    try expectParse("{\"jsonrpc\":\"2.0\",\"id\":\"a\\\"b\",\"method\":\"x\\u0041\"}", "req(\"a\"b\",xA,-)");
    try expectParse("\"str\"", "invalid(-32600)");
    try expectParse("{} {}", "invalid(-32700)");
    try expectParse("", "invalid(-32700)");
}

test "message: RawJson slices point into the body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":{\"a\":[1,2]}}";
    const req = parse(arena.allocator(), body).single.request;
    const p = req.params.?.bytes;
    try testing.expect(@intFromPtr(p.ptr) >= @intFromPtr(body.ptr));
    try testing.expect(@intFromPtr(p.ptr) + p.len <= @intFromPtr(body.ptr) + body.len);
    try testing.expectEqualStrings("{\"a\":[1,2]}", p);
    const P = struct { a: []const i64 };
    const v = try req.params.?.parse(P, testing.allocator, .{});
    defer v.deinit();
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, v.value.a);
}

test "message: id round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]Id{ .{ .int = -42 }, .{ .str = "abc" }, .null }) |id| {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try writeError(&aw.writer, id, -1, "m", null);
        const r = parse(arena.allocator(), aw.written()).single.response;
        try testing.expect(r.id.eql(id));
        try testing.expectEqual(id.hash(), r.id.hash());
    }
    try testing.expect(!(Id{ .int = 1 }).eql(.{ .str = "1" }));
}

test "message: writers" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try writeRequest(w, .{ .int = 1 }, "initialize", .{ .processId = @as(?i32, null) });
    try w.writeByte('|');
    try writeRequest(w, .{ .str = "x" }, "shutdown", {});
    try w.writeByte('|');
    try writeNotification(w, "n", RawJson{ .bytes = "{\n  \"a\": 1\r\n}" });
    try w.writeByte('|');
    try writeResult(w, .{ .int = 2 }, {});
    try w.writeByte('|');
    try writeResult(w, .{ .int = 3 }, .{ .ok = true });
    try w.writeByte('|');
    try writeError(w, .null, ErrorCode.parse_error.int(), "Parse error", .{ .line = 1 });
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null}}|{"jsonrpc":"2.0","id":"x","method":"shutdown"}|{"jsonrpc":"2.0","method":"n","params":{   "a": 1  }}|{"jsonrpc":"2.0","id":2,"result":null}|{"jsonrpc":"2.0","id":3,"result":{"ok":true}}|{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error","data":{"line":1}}}
    , aw.written());
}

test "fuzz: jsonrpc parse" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const body = buf[0..s.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            switch (parse(arena.allocator(), body)) {
                .single, .invalid => {},
                .batch => |b| try testing.expect(b.len > 0),
            }
            // Bounded: the arena never holds more than a small multiple of the input.
            try testing.expect(arena.queryCapacity() <= 64 * 1024 + 16 * body.len);
        }
    }.one, .{});
}
