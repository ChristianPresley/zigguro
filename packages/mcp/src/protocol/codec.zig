//! The comptime-driven codec between protocol types and JSON.
//!
//! Mapping rules, applied to every struct without hand-written per-field code:
//! - a field's JSON name is its snake_case name converted to camelCase,
//!   except `meta`, which is `_meta`; a type may override names with
//!   `pub const json_names = .{ .field = "jsonName" }`, checked at comptime so
//!   a misspelled field fails compilation;
//! - a field named `extra` (type `?std.json.Value`) receives every unknown
//!   member on decode and is merged back on encode, so proxies and the
//!   conformance harness round-trip messages they do not understand;
//! - optional fields and fields with a default may be absent; any other
//!   missing member is `error.MissingField`, with its JSON Pointer recorded in
//!   `Diagnostic`;
//! - enums use their tag names unless the type declares
//!   `pub const json_values = .{ .tag = "wire" }`;
//! - a type with `pub fn jsonDecode(ctx: *Ctx, v: Value) DecodeError!T` or
//!   `pub fn jsonEncode(self: T, s: *Stringify) Stringify.Error!void` takes
//!   over its own mapping (tagged unions, maps and number-or-string values).
//!
//! On encode, null optionals and empty defaulted slices are omitted.
//!
//! Ownership: every decode allocates from the caller's arena and returns
//! values that borrow from it (and from nothing else), so a `RawJson` body may
//! be freed as soon as the decode returns.

const std = @import("std");
const zg_jsonrpc = @import("zg_jsonrpc");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const RawJson = zg_jsonrpc.message.RawJson;

/// Errors from decoding protocol values.
pub const DecodeError = error{
    OutOfMemory,
    /// The bytes are not one well-formed JSON value.
    SyntaxError,
    /// A required member is absent (see `Diagnostic.pointer`).
    MissingField,
    /// A member has the wrong JSON type, or a number does not fit.
    TypeMismatch,
    /// A string is not one of the enum's wire values.
    InvalidEnum,
    /// `resultType` is not a value this client recognizes (BASIC: MUST be invalid).
    InvalidResultType,
};

/// Where a decode failed. Pass one in `DecodeOptions` to learn the JSON
/// Pointer (RFC 6901) of the offending member.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    set: bool = false,

    /// The JSON Pointer of the first failure, e.g. `/tools/3/inputSchema`.
    pub fn pointer(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }
};

/// Options for the decode entry points.
pub const DecodeOptions = struct {
    /// Accept `resultType: "task"` (only after sending a task-capable request).
    allow_task: bool = false,
    diag: ?*Diagnostic = null,
};

const max_depth = 64;

/// Decoding state handed to custom `jsonDecode` functions.
pub const Ctx = struct {
    arena: Allocator,
    diag: ?*Diagnostic = null,
    path: [max_depth]Segment = undefined,
    depth: usize = 0,

    const Segment = union(enum) { key: []const u8, index: usize };

    /// Decodes `v` as `T` (recursing into custom decoders).
    pub fn decode(ctx: *Ctx, comptime T: type, v: Value) DecodeError!T {
        return decodeValue(T, ctx, v);
    }

    /// Decodes member `key` of object `obj`, or returns null when absent.
    pub fn member(ctx: *Ctx, comptime T: type, obj: std.json.ObjectMap, key: []const u8) DecodeError!?T {
        const v = obj.get(key) orelse return null;
        ctx.push(.{ .key = key });
        defer ctx.pop();
        return try decodeValue(T, ctx, v);
    }

    /// Decodes struct `T` from object `v`, ignoring member `key` (a
    /// discriminator such as `type`) instead of keeping it in `extra`.
    /// Types with their own `jsonDecode` handle the member themselves.
    pub fn decodeSkipping(ctx: *Ctx, comptime T: type, v: Value, key: []const u8) DecodeError!T {
        if (@hasDecl(T, "jsonDecode")) return T.jsonDecode(ctx, v);
        return decodeStruct(T, ctx, v, key);
    }

    /// Records the current path in the diagnostic and returns `err`.
    pub fn fail(ctx: *Ctx, err: DecodeError) DecodeError {
        if (ctx.diag) |d| if (!d.set) {
            d.set = true;
            var w: std.Io.Writer = .fixed(&d.buf);
            for (ctx.path[0..@min(ctx.depth, max_depth)]) |seg| switch (seg) {
                .key => |k| {
                    w.writeByte('/') catch break;
                    for (k) |c| switch (c) {
                        '~' => w.writeAll("~0") catch break,
                        '/' => w.writeAll("~1") catch break,
                        else => w.writeByte(c) catch break,
                    };
                },
                .index => |i| w.print("/{d}", .{i}) catch break,
            };
            d.len = w.end;
        };
        return err;
    }

    /// Like `fail`, naming a missing member below the current path.
    pub fn missing(ctx: *Ctx, key: []const u8) DecodeError {
        ctx.push(.{ .key = key });
        defer ctx.pop();
        return ctx.fail(error.MissingField);
    }

    fn push(ctx: *Ctx, s: Segment) void {
        if (ctx.depth < max_depth) ctx.path[ctx.depth] = s;
        ctx.depth += 1;
    }

    fn pop(ctx: *Ctx) void {
        ctx.depth -= 1;
    }
};

/// Parses `bytes` into a `std.json.Value` in `arena` (strings copied, numbers
/// that do not fit `i64`/`f64` kept as `number_string`).
pub fn parseValue(arena: Allocator, bytes: []const u8) DecodeError!Value {
    return std.json.parseFromSliceLeaky(Value, arena, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SyntaxError,
    };
}

/// Decodes a parsed value as `T`. Result memory belongs to `arena`.
pub fn decodeFromValue(comptime T: type, arena: Allocator, v: Value, opts: DecodeOptions) DecodeError!T {
    var ctx: Ctx = .{ .arena = arena, .diag = opts.diag };
    return decodeValue(T, &ctx, v);
}

/// Decodes JSON bytes as `T`. Result memory belongs to `arena`; `bytes` may
/// be freed afterwards.
pub fn decodeBytes(comptime T: type, arena: Allocator, bytes: []const u8, opts: DecodeOptions) DecodeError!T {
    return decodeFromValue(T, arena, try parseValue(arena, bytes), opts);
}

/// Decodes request or notification params. Absent params decode as `{}`, so
/// types whose members are all optional accept them. Memory belongs to `arena`.
pub fn decodeParams(comptime T: type, arena: Allocator, raw: ?RawJson, opts: DecodeOptions) DecodeError!T {
    const v: Value = if (raw) |r| try parseValue(arena, r.bytes) else .{ .object = .empty };
    return decodeFromValue(T, arena, v, opts);
}

/// The outcome of a request, dispatched on `resultType`.
pub fn Decoded(comptime T: type) type {
    return union(ResultKind) {
        /// `resultType` absent (pre-2026 servers) or `"complete"`.
        complete: T,
        /// `resultType: "input_required"` (MRTR).
        input_required: @import("messages.zig").InputRequiredResult,
        /// `resultType: "task"`, accepted only with `DecodeOptions.allow_task`.
        task: @import("messages.zig").CreateTaskResult,
    };
}

/// Decodes a result, dispatching on `resultType` (BASIC "Result types"):
/// absent or `"complete"` gives `.complete`, `"input_required"` gives
/// `.input_required`, `"task"` gives `.task` when `opts.allow_task`, anything
/// else is `error.InvalidResultType`. With `allow_task`, a 2025-11-25
/// `{ task: {...} }` without `resultType` is also `.task`. Memory belongs to `arena`.
pub fn decodeResult(comptime T: type, arena: Allocator, raw: RawJson, opts: DecodeOptions) DecodeError!Decoded(T) {
    return decodeResultValue(T, arena, try parseValue(arena, raw.bytes), opts);
}

/// `decodeResult` on an already parsed value.
pub fn decodeResultValue(comptime T: type, arena: Allocator, v: Value, opts: DecodeOptions) DecodeError!Decoded(T) {
    var ctx: Ctx = .{ .arena = arena, .diag = opts.diag };
    if (v != .object) return ctx.fail(error.TypeMismatch);
    const obj = v.object;
    const kind: ResultKind = if (obj.get("resultType")) |rt| blk: {
        if (rt != .string) return ctx.fail(error.InvalidResultType);
        break :blk resultKind(rt.string) orelse return ctx.fail(error.InvalidResultType);
    } else if (opts.allow_task and !@hasField(T, "task") and isObject(obj.get("task")))
        // 2025-11-25 task-augmented requests answer `{ task: {...} }` without `resultType`.
        .task
    else
        .complete;
    // `resultType` is consumed here (never kept in `extra`);
    // `withResultType` writes it back.
    const M = @import("messages.zig");
    return switch (kind) {
        .complete => .{ .complete = try ctx.decodeSkipping(T, v, "resultType") },
        .input_required => .{ .input_required = try ctx.decodeSkipping(M.InputRequiredResult, v, "resultType") },
        .task => if (opts.allow_task)
            .{ .task = try ctx.decodeSkipping(M.CreateTaskResult, v, "resultType") }
        else
            ctx.fail(error.InvalidResultType),
    };
}

fn isObject(v: ?Value) bool {
    return v != null and v.? == .object;
}

/// The wire values of `resultType`.
pub const ResultKind = enum {
    complete,
    input_required,
    task,
};

/// Maps a `resultType` string; null for unrecognized values.
pub fn resultKind(s: []const u8) ?ResultKind {
    return std.meta.stringToEnum(ResultKind, s);
}

/// Wraps `value` so that `std.json.Stringify.write` (and so
/// `zg_jsonrpc.message.writeRequest` and friends) encode it with this codec.
pub fn json(value: anytype) Json(@TypeOf(value)) {
    return .{ .value = value };
}

/// See `json`.
pub fn Json(comptime T: type) type {
    return struct {
        value: T,
        /// Called by `std.json.Stringify.write`.
        pub fn jsonStringify(self: @This(), s: *Stringify) Stringify.Error!void {
            return encodeValue(s, self.value);
        }
    };
}

/// A result wrapped with its `resultType` for modern (2026-07-28) peers.
pub fn ResultWith(comptime T: type) type {
    return struct {
        kind: ResultKind,
        value: T,
        /// Called by `std.json.Stringify.write`.
        pub fn jsonStringify(self: @This(), s: *Stringify) Stringify.Error!void {
            return encodeStruct(s, self.value, .{ "resultType", @tagName(self.kind) });
        }
    };
}

/// Wraps result `value` so that it encodes with `resultType: kind` (modern
/// peers require it; omit the wrapper for legacy peers).
pub fn withResultType(kind: ResultKind, value: anytype) ResultWith(@TypeOf(value)) {
    return .{ .kind = kind, .value = value };
}

/// Encodes `value` as minified JSON (camelCase, nulls omitted, `extra`
/// members preserved).
pub fn encode(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    var s: Stringify = .{ .writer = w };
    try encodeValue(&s, value);
}

/// Encodes `value` into a new slice owned by `gpa`.
pub fn encodeAlloc(gpa: Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    encode(&aw.writer, value) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Encodes `value` into an `std.json.Value` allocated in `arena`.
pub fn toValue(arena: Allocator, value: anytype) DecodeError!Value {
    const bytes = try encodeAlloc(arena, value);
    return parseValue(arena, bytes);
}

/// Encodes one value through an existing `Stringify` (for custom `jsonEncode`).
pub fn encodeValue(s: *Stringify, value: anytype) Stringify.Error!void {
    const T = @TypeOf(value);
    if (T == Value) return s.write(value);
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => {
            if (@hasDecl(T, "jsonEncode")) return value.jsonEncode(s);
            if (@hasDecl(T, "jsonStringify")) return s.write(value);
        },
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .null => return s.write(value),
        .float, .comptime_float => return writeFloat(s, value),
        .optional => return if (value) |v| encodeValue(s, v) else s.write(null),
        .pointer => |p| {
            if (p.size == .one) return encodeValue(s, value.*);
            if (p.child == u8) return s.write(value);
            try s.beginArray();
            for (value) |item| try encodeValue(s, item);
            return s.endArray();
        },
        .array => return encodeValue(s, &value),
        .@"enum" => return s.write(enumWire(T, value)),
        .@"struct" => return encodeStruct(s, value, null),
        // Tagged unions without hooks (`Decoded`) encode their payload.
        .@"union" => switch (value) {
            inline else => |payload| return encodeValue(s, payload),
        },
        else => @compileError("codec cannot encode " ++ @typeName(T)),
    }
}

/// Encodes struct `value` as an object whose first member is
/// `lead[0]: lead[1]` (a `type` or `resultType` discriminator).
pub fn encodeTagged(s: *Stringify, value: anytype, key: []const u8, tag: []const u8) Stringify.Error!void {
    return encodeStruct(s, value, .{ key, tag });
}

fn encodeStruct(s: *Stringify, value: anytype, lead: ?[2][]const u8) Stringify.Error!void {
    const T = @TypeOf(value);
    // Custom-encoded results (CreateTaskResult) write their own discriminator.
    if (@hasDecl(T, "jsonEncode")) return value.jsonEncode(s);
    try s.beginObject();
    if (lead) |l| {
        try s.objectField(l[0]);
        try s.write(l[1]);
    }
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "extra")) continue;
        const v = @field(value, f.name);
        if (!omit(f, v)) {
            try s.objectField(comptime jsonName(T, f.name));
            try encodeValue(s, v);
        }
    }
    if (@hasField(T, "extra")) if (value.extra) |extra| if (extra == .object) {
        var it = extra.object.iterator();
        while (it.next()) |e| {
            if (lead != null and std.mem.eql(u8, e.key_ptr.*, lead.?[0])) continue;
            try s.objectField(e.key_ptr.*);
            try s.write(e.value_ptr.*);
        }
    };
    try s.endObject();
}

fn omit(comptime f: std.builtin.Type.StructField, v: f.type) bool {
    switch (@typeInfo(f.type)) {
        .optional => return v == null,
        .pointer => |p| {
            if (p.size == .slice and p.child != u8 and f.default_value_ptr != null) return v.len == 0;
            return false;
        },
        else => return false,
    }
}

/// Writes integral floats without a fraction (`50`, not `5e1`).
fn writeFloat(s: *Stringify, x: anytype) Stringify.Error!void {
    const f: f64 = x;
    if (@abs(f) < 9007199254740992.0 and @floor(f) == f) return s.write(@as(i64, @intFromFloat(f)));
    return s.write(f);
}

/// The JSON member name of field `field` of struct `T`.
pub fn jsonName(comptime T: type, comptime field: []const u8) []const u8 {
    comptime {
        validateNames(T);
        if (@hasDecl(T, "json_names") and @hasField(@TypeOf(T.json_names), field))
            return @field(T.json_names, field);
        if (std.mem.eql(u8, field, "meta")) return "_meta";
        return snakeToCamel(field);
    }
}

fn validateNames(comptime T: type) void {
    if (!@hasDecl(T, "json_names")) return;
    for (@typeInfo(@TypeOf(T.json_names)).@"struct".fields) |nf| {
        if (!@hasField(T, nf.name))
            @compileError(@typeName(T) ++ ".json_names names unknown field '" ++ nf.name ++ "'");
    }
}

/// `input_schema` -> `inputSchema` at comptime.
pub fn snakeToCamel(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        var n: usize = 0;
        var up = false;
        for (s) |c| {
            if (c == '_') {
                up = true;
                continue;
            }
            out[n] = if (up) std.ascii.toUpper(c) else c;
            up = false;
            n += 1;
        }
        const final = out[0..n].*;
        return &final;
    }
}

fn enumWire(comptime T: type, v: T) []const u8 {
    inline for (@typeInfo(T).@"enum".fields) |f| {
        if (@intFromEnum(v) == f.value) return comptime enumName(T, f.name);
    }
    unreachable;
}

fn enumName(comptime T: type, comptime tag: []const u8) []const u8 {
    if (@hasDecl(T, "json_values") and @hasField(@TypeOf(T.json_values), tag)) return @field(T.json_values, tag);
    return tag;
}

/// The enum value whose wire name is `s`, or null.
pub fn enumFromWire(comptime T: type, s: []const u8) ?T {
    inline for (@typeInfo(T).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, comptime enumName(T, f.name))) return @enumFromInt(f.value);
    }
    return null;
}

fn decodeValue(comptime T: type, ctx: *Ctx, v: Value) DecodeError!T {
    if (T == Value) return v;
    if (T == zg_jsonrpc.message.Id) return @import("ids.zig").decodeId(ctx, v, false);
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => if (@hasDecl(T, "jsonDecode")) return T.jsonDecode(ctx, v),
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => return if (v == .bool) v.bool else ctx.fail(error.TypeMismatch),
        .int => return switch (v) {
            .integer => |i| std.math.cast(T, i) orelse ctx.fail(error.TypeMismatch),
            .float => |f| if (@floor(f) == f and @abs(f) < 9007199254740992.0)
                std.math.cast(T, @as(i64, @intFromFloat(f))) orelse ctx.fail(error.TypeMismatch)
            else
                ctx.fail(error.TypeMismatch),
            else => ctx.fail(error.TypeMismatch),
        },
        .float => return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            .number_string => |s| std.fmt.parseFloat(T, s) catch ctx.fail(error.TypeMismatch),
            else => ctx.fail(error.TypeMismatch),
        },
        .optional => |o| return if (v == .null) null else try decodeValue(o.child, ctx, v),
        .pointer => |p| {
            if (p.size != .slice) @compileError("codec cannot decode " ++ @typeName(T));
            if (p.child == u8) return if (v == .string) v.string else ctx.fail(error.TypeMismatch);
            if (v != .array) return ctx.fail(error.TypeMismatch);
            const out = try ctx.arena.alloc(p.child, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                ctx.push(.{ .index = i });
                defer ctx.pop();
                out[i] = try decodeValue(p.child, ctx, item);
            }
            return out;
        },
        .@"enum" => {
            if (v != .string) return ctx.fail(error.TypeMismatch);
            return enumFromWire(T, v.string) orelse ctx.fail(error.InvalidEnum);
        },
        .@"struct" => return decodeStruct(T, ctx, v, null),
        else => @compileError("codec cannot decode " ++ @typeName(T)),
    }
}

fn decodeStruct(comptime T: type, ctx: *Ctx, v: Value, skip: ?[]const u8) DecodeError!T {
    if (v != .object) return ctx.fail(error.TypeMismatch);
    const obj = v.object;
    const fields = @typeInfo(T).@"struct".fields;
    var out: T = undefined;
    inline for (fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "extra")) continue;
        const name = comptime jsonName(T, f.name);
        if (obj.get(name)) |mv| {
            ctx.push(.{ .key = name });
            defer ctx.pop();
            @field(out, f.name) = try decodeValue(f.type, ctx, mv);
        } else if (f.defaultValue()) |d| {
            @field(out, f.name) = d;
        } else if (@typeInfo(f.type) == .optional) {
            @field(out, f.name) = null;
        } else {
            return ctx.missing(name);
        }
    }
    if (@hasField(T, "extra")) {
        var extra: ?std.json.ObjectMap = null;
        var it = obj.iterator();
        while (it.next()) |e| {
            if (isKnown(T, e.key_ptr.*)) continue;
            if (skip) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue;
            if (extra == null) extra = .empty;
            try extra.?.put(ctx.arena, e.key_ptr.*, e.value_ptr.*);
        }
        out.extra = if (extra) |m| .{ .object = m } else null;
    }
    return out;
}

fn isKnown(comptime T: type, key: []const u8) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "extra")) continue;
        if (std.mem.eql(u8, key, comptime jsonName(T, f.name))) return true;
    }
    return false;
}

/// Whether `body` is a JSON-RPC batch (a top-level array). Batches were
/// removed in 2025-06-18; answer one with `-32600` and a null id.
pub fn isBatch(body: []const u8) bool {
    for (body) |c| switch (c) {
        ' ', '\t', '\r', '\n' => continue,
        '[' => return true,
        else => return false,
    };
    return false;
}

/// Writes the `-32600 Invalid Request` reply to a batch.
pub fn writeBatchRejection(w: *std.Io.Writer) std.Io.Writer.Error!void {
    return zg_jsonrpc.message.writeError(w, .null, -32600, "JSON-RPC batches are not supported", {});
}

/// Deep equality of two JSON values; numbers compare numerically, objects
/// ignore member order. Used by golden round-trip tests and the conformance
/// harness.
pub fn jsonEql(a: Value, b: Value) bool {
    if (asNumber(a)) |x| {
        const y = asNumber(b) orelse return false;
        return x.eql(y);
    }
    switch (a) {
        .null => return b == .null,
        .bool => |x| return b == .bool and b.bool == x,
        .string => |x| return b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| {
            if (b != .array or b.array.items.len != x.items.len) return false;
            for (x.items, b.array.items) |p, q| if (!jsonEql(p, q)) return false;
            return true;
        },
        .object => |x| {
            if (b != .object or b.object.count() != x.count()) return false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse return false;
                if (!jsonEql(e.value_ptr.*, other)) return false;
            }
            return true;
        },
        else => return false,
    }
}

const Num = union(enum) {
    int: i64,
    float: f64,
    big: []const u8,
    fn eql(a: Num, b: Num) bool {
        return switch (a) {
            .big => |s| b == .big and std.mem.eql(u8, s, b.big),
            .int => |i| switch (b) {
                .int => |j| i == j,
                .float => |f| @as(f64, @floatFromInt(i)) == f,
                .big => false,
            },
            .float => |f| switch (b) {
                .int => |j| f == @as(f64, @floatFromInt(j)),
                .float => |g| f == g,
                .big => false,
            },
        };
    }
};

fn asNumber(v: Value) ?Num {
    return switch (v) {
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .big = s },
        else => null,
    };
}

const testing = std.testing;

test "codec: snake to camel" {
    try testing.expectEqualStrings("inputSchema", comptime snakeToCamel("input_schema"));
    try testing.expectEqualStrings("name", comptime snakeToCamel("name"));
    try testing.expectEqualStrings("readOnlyHint", comptime snakeToCamel("read_only_hint"));
}

test "codec: struct round trip with extra, defaults and missing" {
    const T = struct {
        name: []const u8,
        read_only_hint: ?bool = null,
        tags: []const []const u8 = &.{},
        meta: ?Value = null,
        extra: ?Value = null,
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try decodeBytes(T, a, "{\"name\":\"x\",\"readOnlyHint\":true,\"_meta\":{\"k\":1},\"zz\":[1]}", .{});
    try testing.expectEqualStrings("x", t.name);
    try testing.expectEqual(true, t.read_only_hint.?);
    try testing.expect(t.extra.?.object.contains("zz"));
    const out = try encodeAlloc(a, t);
    try testing.expectEqualStrings("{\"name\":\"x\",\"readOnlyHint\":true,\"_meta\":{\"k\":1},\"zz\":[1]}", out);

    var diag: Diagnostic = .{};
    try testing.expectError(error.MissingField, decodeBytes(struct { list: []const T }, a, "{\"list\":[{\"name\":\"a\"},{}]}", .{ .diag = &diag }));
    try testing.expectEqualStrings("/list/1/name", diag.pointer());
}

test "codec: integral floats are written as integers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try encodeAlloc(arena.allocator(), struct { a: f64 = 50, b: f64 = 0.5 }{});
    try testing.expectEqualStrings("{\"a\":50,\"b\":0.5}", out);
}
