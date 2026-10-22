//! The LSP meta model (`metaModel.json`) as Zig data.
//!
//! The JSON is read with `std.json.parseFromSlice` into a `std.json.Value`
//! and converted by hand, because a type node's `value` is a string, a
//! number, a boolean, a type or a property list depending on its `kind`.
//! Unknown type kinds are an error, never silently dropped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// A type reference in the meta model.
pub const Type = union(enum) {
    /// `integer`, `uinteger`, `decimal`, `boolean`, `string`, `null`,
    /// `DocumentUri`, `URI` or `RegExp`.
    base: []const u8,
    /// A structure, enumeration or type alias by name.
    reference: []const u8,
    array: *const Type,
    map: Map,
    @"and": []const Type,
    @"or": []const Type,
    tuple: []const Type,
    /// An anonymous structure.
    literal: []const Property,
    string_literal: []const u8,
    integer_literal: i64,
    boolean_literal: bool,

    pub const Map = struct { key: *const Type, value: *const Type };

    /// Whether this is the base type `null`.
    pub fn isNull(t: Type) bool {
        return t == .base and std.mem.eql(u8, t.base, "null");
    }
};

/// A structure (or literal) property.
pub const Property = struct {
    name: []const u8,
    type: Type,
    optional: bool,
    documentation: ?[]const u8,
    since: ?[]const u8,
    proposed: bool,
    deprecated: ?[]const u8,
};

/// A named structure.
pub const Structure = struct {
    name: []const u8,
    properties: []const Property,
    extends: []const Type,
    mixins: []const Type,
    documentation: ?[]const u8,
    since: ?[]const u8,
    proposed: bool,
};

/// One enumeration member; `value` is a string or an integer.
pub const EnumValue = struct {
    name: []const u8,
    value: union(enum) { string: []const u8, integer: i64 },
    documentation: ?[]const u8,
    since: ?[]const u8,
    proposed: bool,
};

/// A named enumeration.
pub const Enumeration = struct {
    name: []const u8,
    /// `string`, `integer` or `uinteger`.
    base: []const u8,
    values: []const EnumValue,
    supports_custom_values: bool,
    documentation: ?[]const u8,
    since: ?[]const u8,
    proposed: bool,
};

/// A named type alias.
pub const TypeAlias = struct {
    name: []const u8,
    type: Type,
    documentation: ?[]const u8,
    since: ?[]const u8,
    proposed: bool,
};

/// Who sends a request or notification.
pub const Direction = enum { client_to_server, server_to_client, both };

/// A request or a notification (`result` is null for notifications).
pub const Message = struct {
    method: []const u8,
    type_name: ?[]const u8,
    /// Null when the message has no params; a `tuple` for positional params.
    params: ?Type,
    result: ?Type,
    partial_result: ?Type,
    registration_options: ?Type,
    registration_method: ?[]const u8,
    error_data: ?Type,
    direction: Direction,
    documentation: ?[]const u8,
    since: ?[]const u8,
    proposed: bool,
    client_capability: ?[]const u8,
    server_capability: ?[]const u8,
};

/// The whole meta model.
pub const Model = struct {
    version: []const u8,
    requests: []const Message,
    notifications: []const Message,
    structures: []const Structure,
    enumerations: []const Enumeration,
    type_aliases: []const TypeAlias,
};

/// Conversion failures.
pub const Error = error{ OutOfMemory, InvalidMetaModel };

/// Parses `bytes`. Everything is allocated in `arena`.
pub fn parse(arena: Allocator, bytes: []const u8) (Error || std.json.ParseError(std.json.Scanner))!Model {
    const root = try std.json.parseFromSliceLeaky(Value, arena, bytes, .{});
    const obj = try object(root);
    const meta = try object(try field(obj, "metaData"));
    return .{
        .version = try string(try field(meta, "version")),
        .requests = try messages(arena, try array(try field(obj, "requests")), true),
        .notifications = try messages(arena, try array(try field(obj, "notifications")), false),
        .structures = try structures(arena, try array(try field(obj, "structures"))),
        .enumerations = try enumerations(arena, try array(try field(obj, "enumerations"))),
        .type_aliases = try aliases(arena, try array(try field(obj, "typeAliases"))),
    };
}

fn object(v: Value) Error!std.json.ObjectMap {
    return if (v == .object) v.object else error.InvalidMetaModel;
}

fn array(v: Value) Error![]const Value {
    return if (v == .array) v.array.items else error.InvalidMetaModel;
}

fn string(v: Value) Error![]const u8 {
    return if (v == .string) v.string else error.InvalidMetaModel;
}

fn field(o: std.json.ObjectMap, name: []const u8) Error!Value {
    return o.get(name) orelse {
        if (!@import("builtin").is_test) std.log.warn("meta model: missing \"{s}\"", .{name});
        return error.InvalidMetaModel;
    };
}

fn optString(o: std.json.ObjectMap, name: []const u8) Error!?[]const u8 {
    const v = o.get(name) orelse return null;
    return try string(v);
}

fn optBool(o: std.json.ObjectMap, name: []const u8) bool {
    const v = o.get(name) orelse return false;
    return v == .bool and v.bool;
}

fn optType(arena: Allocator, o: std.json.ObjectMap, name: []const u8) Error!?Type {
    const v = o.get(name) orelse return null;
    return try parseType(arena, v);
}

fn parseTypes(arena: Allocator, items: []const Value) Error![]const Type {
    const out = try arena.alloc(Type, items.len);
    for (items, out) |v, *t| t.* = try parseType(arena, v);
    return out;
}

/// Converts one type node.
pub fn parseType(arena: Allocator, v: Value) Error!Type {
    const o = try object(v);
    const kind = try string(try field(o, "kind"));
    const K = enum { base, reference, array, map, @"and", @"or", tuple, literal, stringLiteral, integerLiteral, booleanLiteral };
    const k = std.meta.stringToEnum(K, kind) orelse {
        if (!@import("builtin").is_test) std.log.warn("meta model: unknown type kind \"{s}\"", .{kind});
        return error.InvalidMetaModel;
    };
    return switch (k) {
        .base => .{ .base = try string(try field(o, "name")) },
        .reference => .{ .reference = try string(try field(o, "name")) },
        .array => blk: {
            const e = try arena.create(Type);
            e.* = try parseType(arena, try field(o, "element"));
            break :blk .{ .array = e };
        },
        .map => blk: {
            const key = try arena.create(Type);
            key.* = try parseType(arena, try field(o, "key"));
            const val = try arena.create(Type);
            val.* = try parseType(arena, try field(o, "value"));
            break :blk .{ .map = .{ .key = key, .value = val } };
        },
        .@"and" => .{ .@"and" = try parseTypes(arena, try array(try field(o, "items"))) },
        .@"or" => .{ .@"or" = try parseTypes(arena, try array(try field(o, "items"))) },
        .tuple => .{ .tuple = try parseTypes(arena, try array(try field(o, "items"))) },
        .literal => blk: {
            const body = try object(try field(o, "value"));
            break :blk .{ .literal = try properties(arena, try array(try field(body, "properties"))) };
        },
        .stringLiteral => .{ .string_literal = try string(try field(o, "value")) },
        .integerLiteral => blk: {
            const x = try field(o, "value");
            if (x != .integer) return error.InvalidMetaModel;
            break :blk .{ .integer_literal = x.integer };
        },
        .booleanLiteral => blk: {
            const x = try field(o, "value");
            if (x != .bool) return error.InvalidMetaModel;
            break :blk .{ .boolean_literal = x.bool };
        },
    };
}

fn properties(arena: Allocator, items: []const Value) Error![]const Property {
    const out = try arena.alloc(Property, items.len);
    for (items, out) |v, *p| {
        const o = try object(v);
        p.* = .{
            .name = try string(try field(o, "name")),
            .type = try parseType(arena, try field(o, "type")),
            .optional = optBool(o, "optional"),
            .documentation = try optString(o, "documentation"),
            .since = try optString(o, "since"),
            .proposed = optBool(o, "proposed"),
            .deprecated = try optString(o, "deprecated"),
        };
    }
    return out;
}

fn structures(arena: Allocator, items: []const Value) Error![]const Structure {
    const out = try arena.alloc(Structure, items.len);
    for (items, out) |v, *s| {
        const o = try object(v);
        s.* = .{
            .name = try string(try field(o, "name")),
            .properties = try properties(arena, try array(try field(o, "properties"))),
            .extends = if (o.get("extends")) |e| try parseTypes(arena, try array(e)) else &.{},
            .mixins = if (o.get("mixins")) |e| try parseTypes(arena, try array(e)) else &.{},
            .documentation = try optString(o, "documentation"),
            .since = try optString(o, "since"),
            .proposed = optBool(o, "proposed"),
        };
    }
    return out;
}

fn enumerations(arena: Allocator, items: []const Value) Error![]const Enumeration {
    const out = try arena.alloc(Enumeration, items.len);
    for (items, out) |v, *e| {
        const o = try object(v);
        const t = try parseType(arena, try field(o, "type"));
        if (t != .base) return error.InvalidMetaModel;
        const vals = try array(try field(o, "values"));
        const values = try arena.alloc(EnumValue, vals.len);
        for (vals, values) |vv, *ev| {
            const vo = try object(vv);
            const raw = try field(vo, "value");
            ev.* = .{
                .name = try string(try field(vo, "name")),
                .value = switch (raw) {
                    .string => |s| .{ .string = s },
                    .integer => |i| .{ .integer = i },
                    else => return error.InvalidMetaModel,
                },
                .documentation = try optString(vo, "documentation"),
                .since = try optString(vo, "since"),
                .proposed = optBool(vo, "proposed"),
            };
        }
        e.* = .{
            .name = try string(try field(o, "name")),
            .base = t.base,
            .values = values,
            .supports_custom_values = optBool(o, "supportsCustomValues"),
            .documentation = try optString(o, "documentation"),
            .since = try optString(o, "since"),
            .proposed = optBool(o, "proposed"),
        };
    }
    return out;
}

fn aliases(arena: Allocator, items: []const Value) Error![]const TypeAlias {
    const out = try arena.alloc(TypeAlias, items.len);
    for (items, out) |v, *a| {
        const o = try object(v);
        a.* = .{
            .name = try string(try field(o, "name")),
            .type = try parseType(arena, try field(o, "type")),
            .documentation = try optString(o, "documentation"),
            .since = try optString(o, "since"),
            .proposed = optBool(o, "proposed"),
        };
    }
    return out;
}

fn messages(arena: Allocator, items: []const Value, is_request: bool) Error![]const Message {
    const out = try arena.alloc(Message, items.len);
    for (items, out) |v, *m| {
        const o = try object(v);
        const dir = try string(try field(o, "messageDirection"));
        const params: ?Type = if (o.get("params")) |p| switch (p) {
            // Positional params (none in 3.17/3.18) become a tuple.
            .array => |a| .{ .tuple = try parseTypes(arena, a.items) },
            else => try parseType(arena, p),
        } else null;
        m.* = .{
            .method = try string(try field(o, "method")),
            .type_name = try optString(o, "typeName"),
            .params = params,
            .result = if (is_request) try parseType(arena, try field(o, "result")) else null,
            .partial_result = try optType(arena, o, "partialResult"),
            .registration_options = try optType(arena, o, "registrationOptions"),
            .registration_method = try optString(o, "registrationMethod"),
            .error_data = try optType(arena, o, "errorData"),
            .direction = if (std.mem.eql(u8, dir, "clientToServer"))
                .client_to_server
            else if (std.mem.eql(u8, dir, "serverToClient"))
                .server_to_client
            else if (std.mem.eql(u8, dir, "both"))
                .both
            else
                return error.InvalidMetaModel,
            .documentation = try optString(o, "documentation"),
            .since = try optString(o, "since"),
            .proposed = optBool(o, "proposed"),
            .client_capability = try optString(o, "clientCapability"),
            .server_capability = try optString(o, "serverCapability"),
        };
    }
    return out;
}

test "lspgen: parses 3.17 and 3.18 models" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m17 = try parse(arena.allocator(), @embedFile("data/metaModel-3.17.json"));
    try std.testing.expectEqualStrings("3.17.0", m17.version);
    try std.testing.expectEqual(@as(usize, 67), m17.requests.len);
    try std.testing.expectEqual(@as(usize, 26), m17.notifications.len);
    try std.testing.expectEqual(@as(usize, 324), m17.structures.len);
    try std.testing.expectEqual(@as(usize, 37), m17.enumerations.len);
    try std.testing.expectEqual(@as(usize, 21), m17.type_aliases.len);
    const m18 = try parse(arena.allocator(), @embedFile("data/metaModel-3.18.json"));
    try std.testing.expectEqualStrings("3.18.0", m18.version);
    try std.testing.expectEqual(@as(usize, 69), m18.requests.len);
    try std.testing.expectEqual(@as(usize, 26), m18.notifications.len);
    try std.testing.expectEqual(@as(usize, 387), m18.structures.len);
    try std.testing.expectEqual(@as(usize, 40), m18.enumerations.len);
    try std.testing.expectEqual(@as(usize, 23), m18.type_aliases.len);
}

test "lspgen: unknown type kind is an error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"kind\":\"intersection\"}", .{});
    try std.testing.expectError(error.InvalidMetaModel, parseType(arena.allocator(), v));
}
