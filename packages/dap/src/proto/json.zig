//! `std.json` support for the generated DAP types (`gen/protocol.zig`).
//!
//! This mirrors `zg_lsp`'s `proto/json.zig` (the two packages sit on the
//! same layer and cannot import each other); the differences are that
//! closed string enums decode unknown values to `_unknown` instead of
//! failing, because adapters routinely extend them.
//!
//! The generator emits plain structs, enums and `union(enum)` types and
//! delegates the parts `std.json` reflection cannot do to this file:
//!
//! - `or` types: `parseUnion` / `parseUnionFromValue` pick the alternative.
//!   When the next token's type admits only one alternative it is parsed
//!   directly from the token stream; otherwise the value is read into a
//!   `std.json.Value` and the alternative whose shape matches best wins
//!   (`valueMatches`): the right JSON type, every required property present
//!   and string-literal properties (`kind: "create"`) equal. Ties go to the
//!   alternative with the most required properties, then to declaration
//!   order.
//! - Optional properties are omitted when null (`writeStruct`), whatever
//!   options the caller stringifies with; properties the protocol marks
//!   required but nullable (`processId: integer | null`) are written as
//!   `null`.
//! - Open string enums (`supportsCustomValues`) keep unknown values
//!   (`OpenEnum`), and integer enums are written as numbers (`writeIntEnum`).
//!
//! Parse protocol values with `parse_options` (unknown properties are
//! ignored, so newer servers never break decoding).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const TokenType = std.json.TokenType;
const ParseOptions = std.json.ParseOptions;
const Stringify = std.json.Stringify;

/// Options for decoding protocol messages: unknown fields are ignored and
/// strings are always copied into the arena, so the input may be freed.
pub const parse_options: ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

/// Decodes `bytes` as `T`, allocating only from `arena`.
pub fn parse(comptime T: type, arena: Allocator, bytes: []const u8) std.json.ParseError(std.json.Scanner)!T {
    return std.json.parseFromSliceLeaky(T, arena, bytes, parse_options);
}

/// Encodes `value` as compact JSON into `gpa`-owned memory.
pub fn stringifyAlloc(gpa: Allocator, value: anytype) error{OutOfMemory}![]u8 {
    return Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}

/// An open string enumeration: a known value of `E`, or any other string.
pub fn OpenEnum(comptime E: type) type {
    return union(enum) {
        known: E,
        other: []const u8,

        const Self = @This();
        /// Marks the type as a JSON string for union discrimination.
        pub const json_string = true;

        /// Wraps the value `s`, known or not.
        pub fn fromString(s: []const u8) Self {
            return if (enumFromWire(E, s)) |k| .{ .known = k } else .{ .other = s };
        }

        /// The wire value.
        pub fn toString(self: Self) []const u8 {
            return switch (self) {
                .known => |k| enumToWire(k),
                .other => |s| s,
            };
        }

        /// Whether the value is `k`.
        pub fn is(self: Self, k: E) bool {
            return self == .known and self.known == k;
        }

        pub fn jsonParse(a: Allocator, source: anytype, options: ParseOptions) !Self {
            const s = try std.json.innerParse([]const u8, a, source, options);
            return fromString(s);
        }

        pub fn jsonParseFromValue(a: Allocator, v: Value, options: ParseOptions) !Self {
            const s = try std.json.innerParseFromValue([]const u8, a, v, options);
            return fromString(s);
        }

        pub fn jsonStringify(self: Self, w: *Stringify) Stringify.Error!void {
            try w.write(self.toString());
        }
    };
}

/// The enum member whose wire value is `s`. Generated string enums list
/// their wire values in `json_values` (tags are the meta model names,
/// because wire values may be empty or repeat); other enums use tag names.
pub fn enumFromWire(comptime E: type, s: []const u8) ?E {
    if (!@hasDecl(E, "json_values")) return std.meta.stringToEnum(E, s);
    inline for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        if (std.mem.eql(u8, E.json_values[i], s)) return @field(E, f.name);
    }
    return null;
}

/// The wire value of string enum member `e`.
pub fn enumToWire(e: anytype) []const u8 {
    const E = @TypeOf(e);
    if (!@hasDecl(E, "json_values")) return @tagName(e);
    return E.json_values[@intFromEnum(e)];
}

/// `jsonParse` for closed string enums; unknown values become `_unknown`.
pub fn parseStringEnum(comptime E: type, a: Allocator, source: anytype, options: ParseOptions) !E {
    const s = try std.json.innerParse([]const u8, a, source, options);
    return enumFromWire(E, s) orelse unknownMember(E);
}

/// `jsonParseFromValue` for closed string enums.
pub fn parseStringEnumFromValue(comptime E: type, a: Allocator, v: Value, options: ParseOptions) !E {
    const s = try std.json.innerParseFromValue([]const u8, a, v, options);
    return enumFromWire(E, s) orelse unknownMember(E);
}

fn unknownMember(comptime E: type) error{InvalidEnumTag}!E {
    if (@hasField(E, "_unknown")) return ._unknown;
    return error.InvalidEnumTag;
}

/// `jsonStringify` for closed string enums.
pub fn writeStringEnum(self: anytype, w: *Stringify) Stringify.Error!void {
    try w.write(enumToWire(self));
}

/// `jsonStringify` for integer enums: writes the number, known or not.
pub fn writeIntEnum(self: anytype, w: *Stringify) Stringify.Error!void {
    try w.write(@intFromEnum(self));
}

/// `jsonStringify` for structs: optional fields are omitted when null,
/// except those named in `required_nullable`, which are written as `null`.
pub fn writeStruct(self: anytype, w: *Stringify, comptime required_nullable: []const []const u8) Stringify.Error!void {
    const T = @TypeOf(self);
    try w.beginObject();
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const val = @field(self, f.name);
        if (@typeInfo(f.type) == .optional) {
            if (val == null) {
                if (comptime contains(required_nullable, f.name)) {
                    try w.objectField(f.name);
                    try w.write(null);
                }
            } else {
                try w.objectField(f.name);
                try w.write(val.?);
            }
        } else {
            try w.objectField(f.name);
            try w.write(val);
        }
    }
    try w.endObject();
}

fn contains(comptime list: []const []const u8, comptime name: []const u8) bool {
    inline for (list) |n| if (comptime std.mem.eql(u8, n, name)) return true;
    return false;
}

/// `jsonStringify` for `or` unions: writes the active alternative.
pub fn writeUnion(self: anytype, w: *Stringify) Stringify.Error!void {
    switch (self) {
        inline else => |payload| try w.write(payload),
    }
}

/// `jsonParse` for `or` unions.
pub fn parseUnion(comptime U: type, a: Allocator, source: anytype, options: ParseOptions) !U {
    const tok = try source.peekNextTokenType();
    const fields = @typeInfo(U).@"union".fields;
    var only: ?usize = null;
    var count: usize = 0;
    inline for (fields, 0..) |f, i| {
        if (tokenCan(f.type, tok)) {
            count += 1;
            only = i;
        }
    }
    if (count == 0) return error.UnexpectedToken;
    if (count == 1) {
        inline for (fields, 0..) |f, i| {
            if (i == only.?) return @unionInit(U, f.name, try std.json.innerParse(f.type, a, source, options));
        }
        unreachable;
    }
    const v = try std.json.innerParse(Value, a, source, options);
    return parseUnionFromValue(U, a, v, options);
}

/// `jsonParseFromValue` for `or` unions.
pub fn parseUnionFromValue(comptime U: type, a: Allocator, v: Value, options: ParseOptions) !U {
    const fields = @typeInfo(U).@"union".fields;
    var best: ?usize = null;
    var best_score: usize = 0;
    var best_known: usize = 0;
    inline for (fields, 0..) |f, i| {
        if (valueMatches(f.type, v)) {
            const s = specificity(f.type);
            // Ties go to the alternative that declares more of the
            // object's keys (registration options carry `documentSelector`).
            const k = knownKeys(f.type, v);
            if (best == null or s > best_score or (s == best_score and k > best_known)) {
                best = i;
                best_score = s;
                best_known = k;
            }
        }
    }
    const pick = best orelse return error.UnexpectedToken;
    inline for (fields, 0..) |f, i| {
        if (i == pick) return @unionInit(U, f.name, try std.json.innerParseFromValue(f.type, a, v, options));
    }
    unreachable;
}

fn isUnionType(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasDecl(T, "json_any_of");
}

fn isIntEnum(comptime T: type) bool {
    return @typeInfo(T) == .@"enum" and @hasDecl(T, "json_integer");
}

/// Whether a JSON value of `T` can start with a token of type `tok`.
pub fn tokenCan(comptime T: type, tok: TokenType) bool {
    if (T == Value) return true;
    if (T == void) return tok == .null;
    switch (@typeInfo(T)) {
        .bool => return tok == .true or tok == .false,
        .int, .float => return tok == .number,
        .@"enum" => return if (isIntEnum(T)) tok == .number else tok == .string,
        .optional => |o| return tok == .null or tokenCan(o.child, tok),
        .array => return tok == .array_begin,
        .pointer => |p| {
            if (p.size == .one) return tokenCan(p.child, tok);
            if (p.child == u8) return tok == .string;
            return tok == .array_begin;
        },
        .@"union" => {
            if (@hasDecl(T, "json_string")) return tok == .string;
            inline for (@typeInfo(T).@"union".fields) |f| if (tokenCan(f.type, tok)) return true;
            return false;
        },
        .@"struct" => return tok == .object_begin,
        else => @compileError("unsupported protocol type " ++ @typeName(T)),
    }
}

/// Whether `v` has the shape of a `T`.
pub fn valueMatches(comptime T: type, v: Value) bool {
    if (T == Value) return true;
    if (T == void) return v == .null;
    switch (@typeInfo(T)) {
        .bool => return v == .bool,
        .int => return v == .integer,
        .float => return v == .integer or v == .float or v == .number_string,
        .@"enum" => {
            if (isIntEnum(T)) return v == .integer;
            return v == .string and (@hasField(T, "_unknown") or enumFromWire(T, v.string) != null);
        },
        .optional => |o| return v == .null or valueMatches(o.child, v),
        .array => |arr| return v == .array and v.array.items.len == arr.len,
        .pointer => |p| {
            if (p.size == .one) return valueMatches(p.child, v);
            if (p.child == u8) return v == .string;
            if (v != .array) return false;
            return v.array.items.len == 0 or valueMatches(p.child, v.array.items[0]);
        },
        .@"union" => {
            if (@hasDecl(T, "json_string")) return v == .string;
            inline for (@typeInfo(T).@"union".fields) |f| if (valueMatches(f.type, v)) return true;
            return false;
        },
        .@"struct" => |s| {
            if (v != .object) return false;
            if (comptime isMap(T)) return true;
            inline for (s.fields) |f| {
                if (f.default_value_ptr == null) {
                    if (v.object.get(f.name) == null) return false;
                } else if (comptime isLiteral(T, f.name)) {
                    const want: *const f.type = @ptrCast(@alignCast(f.default_value_ptr.?));
                    const got = v.object.get(f.name) orelse return false;
                    if (!literalEql(f.type, want.*, got)) return false;
                }
            }
            return true;
        },
        else => @compileError("unsupported protocol type " ++ @typeName(T)),
    }
}

/// Whether `T` is a `std.json.ArrayHashMap` (a JSON object of any keys).
fn isMap(comptime T: type) bool {
    const fields = @typeInfo(T).@"struct".fields;
    return fields.len == 1 and std.mem.eql(u8, fields[0].name, "map") and @hasDecl(T, "jsonParseFromValue");
}

fn isLiteral(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, "json_literals")) return false;
    return contains(T.json_literals, name);
}

fn literalEql(comptime F: type, want: F, got: Value) bool {
    return switch (@typeInfo(F)) {
        .bool => got == .bool and got.bool == want,
        .int => got == .integer and got.integer == want,
        else => got == .string and std.mem.eql(u8, got.string, want),
    };
}

/// How specific a matching alternative is: required properties count one,
/// literal properties two.
/// How many keys of object `v` are fields of struct `T` (0 otherwise).
fn knownKeys(comptime T: type, v: Value) usize {
    if (v != .object) return 0;
    switch (@typeInfo(T)) {
        .optional => |o| return knownKeys(o.child, v),
        .pointer => |p| return if (p.size == .one) knownKeys(p.child, v) else 0,
        .@"struct" => |st| {
            if (T == Value or comptime isMap(T)) return 0;
            var n: usize = 0;
            inline for (st.fields) |f| {
                if (v.object.get(f.name) != null) n += 1;
            }
            return n;
        },
        else => return 0,
    }
}

fn specificity(comptime T: type) usize {
    switch (@typeInfo(T)) {
        .optional => |o| return specificity(o.child),
        .pointer => |p| {
            if (p.size == .one or (p.child != u8)) return specificity(p.child);
            return 0;
        },
        .@"union" => |u| {
            if (@hasDecl(T, "json_string")) return 0;
            var n: usize = 0;
            inline for (u.fields) |f| n = @max(n, specificity(f.type));
            return n;
        },
        .@"struct" => |s| {
            if (T == Value or comptime isMap(T)) return 0;
            var n: usize = 1;
            inline for (s.fields) |f| {
                if (f.default_value_ptr == null) n += 1 else if (comptime isLiteral(T, f.name)) n += 2;
            }
            return n;
        },
        else => return 0,
    }
}
