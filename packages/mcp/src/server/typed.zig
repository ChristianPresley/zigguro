//! Typed tools: a Zig struct describes a tool, and its JSON Schema, argument
//! decoding and output encoding are generated at comptime from the types.
//!
//! A tool type declares:
//!
//! ```zig
//! const Weather = struct {
//!     pub const name = "get_weather";
//!     pub const description = "Current weather for a city.";
//!     pub const annotations: typed.Annotations = .{ .read_only_hint = true };
//!     pub const Args = struct {
//!         city: []const u8,
//!         units: enum { metric, imperial } = .metric,
//!         pub const docs = .{ .city = "City name" };
//!     };
//!     pub const Output = struct { temperature: f64 };
//!     pub fn call(cc: *Server.CallCtx, args: Args) anyerror!typed.ToolReturn(Output) { ... }
//! };
//! ```
//!
//! Zig to JSON Schema: `bool` is boolean; integers are integer with their
//! range clamped to ±(2^53-1); floats are number; `[]const u8` is string;
//! enums are string with `enum`; `?T` is T and not required; a field with a
//! default is not required; `[]const T` is array; structs are objects with
//! `additionalProperties: false` and camelCase member names (as the codec);
//! `union(enum)` is `oneOf` of objects discriminated by `"kind"`;
//! `std.json.Value` is `{}`. Struct decls `docs`, `formats` and `headers`
//! add `description`, `format` and `x-mcp-header` per field; a header is
//! allowed only on a primitive field of the top-level `Args`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const protocol = @import("../protocol/root.zig");
const codec = protocol.codec;

/// Tool behaviour hints (TOOLS "Annotations"); untrusted by clients.
pub const Annotations = struct {
    title: ?[]const u8 = null,
    read_only_hint: ?bool = null,
    destructive_hint: ?bool = null,
    idempotent_hint: ?bool = null,
    open_world_hint: ?bool = null,
};

/// What a typed tool's `call` returns.
pub fn ToolReturn(comptime Out: type) type {
    return union(enum) {
        /// Success: `value` becomes `structuredContent` plus one text block
        /// with the same JSON; `content` blocks are appended.
        ok: struct { value: Out, content: ?[]const protocol.ContentBlock = null },
        /// A tool-level failure the model should see (`isError: true`).
        tool_error: []const u8,
        /// Unstructured success.
        content: []const protocol.ContentBlock,
    };
}

/// Checks tool type `T` and returns its comptime description.
pub fn ToolSpecOf(comptime T: type) type {
    comptime {
        for (.{ "name", "description", "Args", "call" }) |d| {
            if (!@hasDecl(T, d)) @compileError(@typeName(T) ++ " is not a tool: missing pub decl `" ++ d ++ "`");
        }
        if (@typeInfo(T.Args) != .@"struct") @compileError(@typeName(T) ++ ".Args must be a struct");
    }
    return struct {
        pub const name: []const u8 = T.name;
        pub const description: []const u8 = T.description;
        pub const Args = T.Args;
        pub const Output = if (@hasDecl(T, "Output")) T.Output else void;
        pub const annotations: Annotations = if (@hasDecl(T, "annotations")) T.annotations else .{};
        pub const input_schema: []const u8 = jsonSchemaFor(T.Args);
        pub const output_schema: ?[]const u8 = if (Output == void) null else jsonSchemaFor(Output);
    };
}

/// The JSON Schema of `A` as JSON text (2020-12, the MCP default dialect).
pub fn jsonSchemaFor(comptime A: type) []const u8 {
    return comptime schemaOf(A, "", true);
}

const max_safe: i128 = (1 << 53) - 1;

fn schemaOf(comptime T: type, comptime ann: []const u8, comptime top: bool) []const u8 {
    comptime {
        if (T == Value) return "{" ++ (if (ann.len > 0) ann[1..] else "") ++ "}";
        switch (@typeInfo(T)) {
            .bool => return "{\"type\":\"boolean\"" ++ ann ++ "}",
            .int => |i| {
                const lo: i128 = if (i.signedness == .signed) @max(-max_safe, std.math.minInt(T)) else 0;
                const hi: i128 = @min(max_safe, std.math.maxInt(T));
                return std.fmt.comptimePrint("{{\"type\":\"integer\",\"minimum\":{d},\"maximum\":{d}{s}}}", .{ lo, hi, ann });
            },
            .float => return "{\"type\":\"number\"" ++ ann ++ "}",
            .optional => |o| return schemaOf(o.child, ann, false),
            .@"enum" => |e| {
                var vals: []const u8 = "";
                for (e.fields, 0..) |f, n| vals = vals ++ (if (n > 0) "," else "") ++ jsonString(f.name);
                return "{\"type\":\"string\",\"enum\":[" ++ vals ++ "]" ++ ann ++ "}";
            },
            .pointer => |p| {
                if (p.size != .slice) @compileError("unsupported tool type " ++ @typeName(T));
                if (p.child == u8) return "{\"type\":\"string\"" ++ ann ++ "}";
                return "{\"type\":\"array\",\"items\":" ++ schemaOf(p.child, "", false) ++ ann ++ "}";
            },
            .@"struct" => return objectSchema(T, "", "", ann, top),
            .@"union" => |u| {
                if (u.tag_type == null) @compileError("unions must be tagged: " ++ @typeName(T));
                var alts: []const u8 = "";
                for (u.fields, 0..) |f, n| {
                    const kind = "\"kind\":{\"const\":" ++ jsonString(f.name) ++ "}";
                    const alt = switch (@typeInfo(f.type)) {
                        .@"struct" => objectSchema(f.type, kind, "\"kind\"", "", false),
                        .void => "{\"type\":\"object\",\"properties\":{" ++ kind ++ "},\"required\":[\"kind\"],\"additionalProperties\":false}",
                        else => "{\"type\":\"object\",\"properties\":{" ++ kind ++ ",\"value\":" ++ schemaOf(f.type, "", false) ++
                            "},\"required\":[\"kind\",\"value\"],\"additionalProperties\":false}",
                    };
                    alts = alts ++ (if (n > 0) "," else "") ++ alt;
                }
                return "{\"oneOf\":[" ++ alts ++ "]" ++ ann ++ "}";
            },
            else => @compileError("unsupported tool type " ++ @typeName(T)),
        }
    }
}

/// `{"type":"object",...}` for struct `T`, with extra leading properties
/// (`pre_props`) and required names (`pre_req`) for union discriminators.
fn objectSchema(comptime T: type, comptime pre_props: []const u8, comptime pre_req: []const u8, comptime ann: []const u8, comptime top: bool) []const u8 {
    comptime {
        checkDeclFields(T, "docs");
        checkDeclFields(T, "formats");
        checkDeclFields(T, "headers");
        if (headerError(T, top)) |msg| @compileError(msg);
        var props: []const u8 = pre_props;
        var req: []const u8 = pre_req;
        for (@typeInfo(T).@"struct".fields) |f| {
            var fann: []const u8 = "";
            if (declField(T, "docs", f.name)) |d| fann = fann ++ ",\"description\":" ++ jsonString(d);
            if (declField(T, "formats", f.name)) |d| fann = fann ++ ",\"format\":" ++ jsonString(d);
            if (declField(T, "headers", f.name)) |d| fann = fann ++ ",\"x-mcp-header\":" ++ jsonString(d);
            const key = jsonString(codec.snakeToCamel(f.name));
            props = props ++ (if (props.len > 0) "," else "") ++ key ++ ":" ++ schemaOf(f.type, fann, false);
            if (@typeInfo(f.type) != .optional and f.default_value_ptr == null)
                req = req ++ (if (req.len > 0) "," else "") ++ key;
        }
        const required = if (req.len > 0) ",\"required\":[" ++ req ++ "]" else "";
        return "{\"type\":\"object\",\"properties\":{" ++ props ++ "}" ++ required ++ ",\"additionalProperties\":false" ++ ann ++ "}";
    }
}

/// Why `T`'s `headers` decl is invalid, or null. Headers (`x-mcp-header`)
/// must sit on primitive fields of the top-level arguments, so that the
/// client can mirror them without walking nested values.
pub fn headerError(comptime T: type, comptime top: bool) ?[]const u8 {
    comptime {
        if (!@hasDecl(T, "headers")) return null;
        if (!top) return @typeName(T) ++ ": x-mcp-header is allowed only on top-level tool arguments";
        for (std.meta.fieldNames(@TypeOf(T.headers))) |name| {
            const F = @FieldType(T, name);
            const C = switch (@typeInfo(F)) {
                .optional => |o| o.child,
                else => F,
            };
            const primitive = switch (@typeInfo(C)) {
                .bool, .int, .float, .@"enum" => true,
                .pointer => |p| p.size == .slice and p.child == u8,
                else => false,
            };
            if (!primitive) return @typeName(T) ++ "." ++ name ++ ": x-mcp-header needs a primitive field";
        }
        return null;
    }
}

fn checkDeclFields(comptime T: type, comptime decl: []const u8) void {
    if (!@hasDecl(T, decl)) return;
    for (std.meta.fieldNames(@TypeOf(@field(T, decl)))) |name| {
        if (!@hasField(T, name)) @compileError(@typeName(T) ++ "." ++ decl ++ " names unknown field `" ++ name ++ "`");
    }
}

fn declField(comptime T: type, comptime decl: []const u8, comptime field: []const u8) ?[]const u8 {
    if (!@hasDecl(T, decl)) return null;
    const D = @field(T, decl);
    if (!@hasField(@TypeOf(D), field)) return null;
    return @field(D, field);
}

/// `s` as a JSON string literal, at comptime.
fn jsonString(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (s) |c| out = out ++ switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...0x1f => std.fmt.comptimePrint("\\u{x:0>4}", .{c}),
            else => &[_]u8{c},
        };
        return out ++ "\"";
    }
}

// ---------------------------------------------------------------- values

/// Errors from `decode`.
pub const DecodeError = error{ OutOfMemory, TypeMismatch, MissingField, UnknownField, InvalidEnum };

/// Decodes `v` as `T` with the same mapping as the schema. Strings borrow
/// from `v`; slices are allocated in `arena`.
pub fn decode(comptime T: type, arena: Allocator, v: Value) DecodeError!T {
    if (T == Value) return v;
    switch (@typeInfo(T)) {
        .bool => return if (v == .bool) v.bool else error.TypeMismatch,
        .int => return switch (v) {
            .integer => |i| std.math.cast(T, i) orelse error.TypeMismatch,
            .float => |f| if (@floor(f) == f and f >= -@as(f64, max_safe) and f <= @as(f64, max_safe))
                std.math.cast(T, @as(i64, @intFromFloat(f))) orelse error.TypeMismatch
            else
                error.TypeMismatch,
            else => error.TypeMismatch,
        },
        .float => return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            .number_string => |s| std.fmt.parseFloat(T, s) catch error.TypeMismatch,
            else => error.TypeMismatch,
        },
        .optional => |o| return if (v == .null) null else try decode(o.child, arena, v),
        .@"enum" => return if (v == .string) std.meta.stringToEnum(T, v.string) orelse error.InvalidEnum else error.TypeMismatch,
        .pointer => |p| {
            if (p.child == u8) return if (v == .string) v.string else error.TypeMismatch;
            if (v != .array) return error.TypeMismatch;
            const out = try arena.alloc(p.child, v.array.items.len);
            for (v.array.items, out) |item, *o| o.* = try decode(p.child, arena, item);
            return out;
        },
        .@"struct" => return decodeStruct(T, arena, v, null),
        .@"union" => |u| {
            if (v != .object) return error.TypeMismatch;
            const kind = v.object.get("kind") orelse return error.MissingField;
            if (kind != .string) return error.TypeMismatch;
            inline for (u.fields) |f| if (std.mem.eql(u8, kind.string, f.name)) {
                return @unionInit(T, f.name, switch (@typeInfo(f.type)) {
                    .@"struct" => try decodeStruct(f.type, arena, v, "kind"),
                    .void => {},
                    else => try decode(f.type, arena, v.object.get("value") orelse return error.MissingField),
                });
            };
            return error.InvalidEnum;
        },
        else => @compileError("unsupported tool type " ++ @typeName(T)),
    }
}

fn decodeStruct(comptime T: type, arena: Allocator, v: Value, skip: ?[]const u8) DecodeError!T {
    if (v != .object) return error.TypeMismatch;
    var out: T = undefined;
    var seen: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const key = comptime codec.snakeToCamel(f.name);
        if (v.object.get(key)) |fv| {
            @field(out, f.name) = try decode(f.type, arena, fv);
            seen += 1;
        } else if (f.default_value_ptr) |dp| {
            @field(out, f.name) = @as(*const f.type, @ptrCast(@alignCast(dp))).*;
        } else if (@typeInfo(f.type) == .optional) {
            @field(out, f.name) = null;
        } else return error.MissingField;
    }
    // additionalProperties: false.
    const extra = v.object.count() - seen - @intFromBool(skip != null and v.object.contains(skip.?));
    if (extra != 0) return error.UnknownField;
    return out;
}

/// Encodes `value` with the same mapping (nulls omitted).
pub fn encode(s: *Stringify, value: anytype) Stringify.Error!void {
    const T = @TypeOf(value);
    if (T == Value) return s.write(value);
    switch (@typeInfo(T)) {
        .bool, .int, .float => return s.write(value),
        .optional => return if (value) |x| encode(s, x) else s.write(null),
        .@"enum" => return s.write(@tagName(value)),
        .pointer => |p| {
            if (p.child == u8) return s.write(value);
            try s.beginArray();
            for (value) |x| try encode(s, x);
            return s.endArray();
        },
        .@"struct" => {
            try s.beginObject();
            try encodeFields(s, value);
            return s.endObject();
        },
        .@"union" => {
            try s.beginObject();
            try s.objectField("kind");
            try s.write(@tagName(value));
            switch (value) {
                inline else => |payload| switch (@typeInfo(@TypeOf(payload))) {
                    .@"struct" => try encodeFields(s, payload),
                    .void => {},
                    else => {
                        try s.objectField("value");
                        try encode(s, payload);
                    },
                },
            }
            return s.endObject();
        },
        else => @compileError("unsupported tool type " ++ @typeName(T)),
    }
}

fn encodeFields(s: *Stringify, value: anytype) Stringify.Error!void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |f| {
        const x = @field(value, f.name);
        const present = if (@typeInfo(f.type) == .optional) x != null else true;
        if (present) {
            try s.objectField(comptime codec.snakeToCamel(f.name));
            try encode(s, x);
        }
    }
}

/// `encode` into a new slice owned by `gpa`.
pub fn encodeAlloc(gpa: Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: Stringify = .{ .writer = &aw.writer };
    encode(&s, value) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;

const Shape = union(enum) {
    circle: struct { radius: f64 },
    square: f64,
    point,
};

const AllKinds = struct {
    flag: bool,
    count: u8,
    big: i64 = 0,
    ratio: f32,
    name: []const u8,
    mode: enum { fast, safe },
    note: ?[]const u8 = null,
    tags: []const []const u8,
    nested: struct { when_utc: []const u8 },
    shape: Shape,
    any: Value,

    pub const docs = .{ .name = "Display \"name\"", .count = "How many" };
    pub const formats = .{ .name = "email" };
};

test "typed: schema for primitives/optionals/enums/unions/nested structs" {
    const want =
        \\{"type":"object","properties":{"flag":{"type":"boolean"},"count":{"type":"integer","minimum":0,"maximum":255,"description":"How many"},"big":{"type":"integer","minimum":-9007199254740991,"maximum":9007199254740991},"ratio":{"type":"number"},"name":{"type":"string","description":"Display \"name\"","format":"email"},"mode":{"type":"string","enum":["fast","safe"]},"note":{"type":"string"},"tags":{"type":"array","items":{"type":"string"}},"nested":{"type":"object","properties":{"whenUtc":{"type":"string"}},"required":["whenUtc"],"additionalProperties":false},"shape":{"oneOf":[{"type":"object","properties":{"kind":{"const":"circle"},"radius":{"type":"number"}},"required":["kind","radius"],"additionalProperties":false},{"type":"object","properties":{"kind":{"const":"square"},"value":{"type":"number"}},"required":["kind","value"],"additionalProperties":false},{"type":"object","properties":{"kind":{"const":"point"}},"required":["kind"],"additionalProperties":false}]},"any":{}},"required":["flag","count","ratio","name","mode","tags","nested","shape","any"],"additionalProperties":false}
    ;
    try testing.expectEqualStrings(want, jsonSchemaFor(AllKinds));
    // The generated schema is valid JSON and compiles.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(), want, .{});
    const s = try @import("../schema/root.zig").compile(testing.allocator, v, .{});
    defer s.deinit();
}

test "typed: decode and encode round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"flag":true,"count":7,"ratio":0.5,"name":"x","mode":"safe","tags":["a","b"],"nested":{"whenUtc":"now"},"shape":{"kind":"circle","radius":2},"any":[1]}
    ;
    const v = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    const d = try decode(AllKinds, a, v);
    try testing.expectEqual(@as(u8, 7), d.count);
    try testing.expectEqual(@as(i64, 0), d.big);
    try testing.expect(d.note == null);
    try testing.expectEqual(@as(f64, 2), d.shape.circle.radius);
    try testing.expectEqualStrings(
        \\{"flag":true,"count":7,"big":0,"ratio":0.5,"name":"x","mode":"safe","tags":["a","b"],"nested":{"whenUtc":"now"},"shape":{"kind":"circle","radius":2},"any":[1]}
    , try encodeAlloc(a, d));
    const sq = try decode(Shape, a, try std.json.parseFromSliceLeaky(Value, a, "{\"kind\":\"square\",\"value\":3}", .{}));
    try testing.expectEqual(@as(f64, 3), sq.square);
    try testing.expectError(error.UnknownField, decode(struct { a: u8 }, a, try std.json.parseFromSliceLeaky(Value, a, "{\"a\":1,\"b\":2}", .{})));
    try testing.expectError(error.TypeMismatch, decode(u8, a, .{ .integer = 300 }));
    try testing.expectError(error.MissingField, decode(struct { a: u8 }, a, .{ .object = .empty }));
}

test "typed: x-mcp-header decl only on primitive top-level field" {
    const Good = struct {
        region: []const u8,
        pub const headers = .{ .region = "Region" };
    };
    try testing.expectEqualStrings(
        \\{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}},"required":["region"],"additionalProperties":false}
    , jsonSchemaFor(Good));
    const Nested = struct {
        inner: struct { region: []const u8 },
        pub const headers = .{ .inner = "Inner" };
    };
    // `jsonSchemaFor` turns these messages into compile errors.
    try testing.expect(comptime headerError(Nested, true) != null);
    try testing.expect(comptime headerError(Good, false) != null);
    try testing.expect(comptime headerError(Good, true) == null);
}

test "typed: tool spec" {
    const Echo = struct {
        pub const name = "echo";
        pub const description = "Echoes";
        pub const annotations: Annotations = .{ .read_only_hint = true };
        pub const Args = struct { text: []const u8 };
        pub const Output = struct { text: []const u8 };
        pub fn call(_: *anyopaque, args: Args) anyerror!ToolReturn(Output) {
            return .{ .ok = .{ .value = .{ .text = args.text } } };
        }
    };
    const S = ToolSpecOf(Echo);
    try testing.expectEqualStrings("echo", S.name);
    try testing.expectEqual(@as(?bool, true), S.annotations.read_only_hint);
    try testing.expect(S.output_schema != null);
}
