//! The subset of JSON Schema draft-04 used by `debugAdapterProtocol.json`,
//! as Zig data.
//!
//! Keywords read: `$ref`, `type` (a name or a list), `properties`,
//! `required`, `items`, `additionalProperties`, `enum`, `_enum` (VS Code's
//! "suggested values"), `allOf`, `oneOf`, `title` and `description`.
//! Anything else (`format`, `minimum`, ...) only documents a value and is
//! ignored. Property order follows the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// One schema node.
pub const Schema = struct {
    /// `#/definitions/<name>` target name.
    ref: ?[]const u8 = null,
    /// `type`: empty when absent; several entries for a type list.
    types: []const []const u8 = &.{},
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},
    items: ?*const Schema = null,
    additional_properties: ?*const Schema = null,
    /// Closed set of values.
    enum_values: ?[]const []const u8 = null,
    /// Open set of suggested values (`_enum`).
    open_enum: ?[]const []const u8 = null,
    all_of: []const Schema = &.{},
    one_of: []const Schema = &.{},
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,

    /// Whether `types` contains `name`.
    pub fn hasType(s: Schema, name: []const u8) bool {
        for (s.types) |t| if (std.mem.eql(u8, t, name)) return true;
        return false;
    }

    /// Whether `name` is in `required`.
    pub fn isRequired(s: Schema, name: []const u8) bool {
        for (s.required) |r| if (std.mem.eql(u8, r, name)) return true;
        return false;
    }
};

/// A named property.
pub const Property = struct { name: []const u8, schema: Schema };

/// A named definition.
pub const Definition = struct { name: []const u8, schema: Schema };

/// The whole protocol schema.
pub const Document = struct {
    /// Definitions in file order.
    definitions: []const Definition,

    /// The definition called `name`.
    pub fn get(d: Document, name: []const u8) ?*const Schema {
        for (d.definitions) |*def| if (std.mem.eql(u8, def.name, name)) return &def.schema;
        return null;
    }
};

/// Conversion failures.
pub const Error = error{ OutOfMemory, InvalidSchema };

/// Parses `bytes`. Everything is allocated in `arena`.
pub fn parse(arena: Allocator, bytes: []const u8) (Error || std.json.ParseError(std.json.Scanner))!Document {
    const root = try std.json.parseFromSliceLeaky(Value, arena, bytes, .{});
    if (root != .object) return error.InvalidSchema;
    const defs = root.object.get("definitions") orelse return error.InvalidSchema;
    if (defs != .object) return error.InvalidSchema;
    const out = try arena.alloc(Definition, defs.object.count());
    var it = defs.object.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        out[i] = .{ .name = e.key_ptr.*, .schema = try node(arena, e.value_ptr.*) };
    }
    return .{ .definitions = out };
}

fn strings(arena: Allocator, v: Value) Error![]const []const u8 {
    if (v != .array) return error.InvalidSchema;
    const out = try arena.alloc([]const u8, v.array.items.len);
    for (v.array.items, out) |x, *o| {
        if (x != .string) return error.InvalidSchema;
        o.* = x.string;
    }
    return out;
}

fn nodes(arena: Allocator, v: Value) Error![]const Schema {
    if (v != .array) return error.InvalidSchema;
    const out = try arena.alloc(Schema, v.array.items.len);
    for (v.array.items, out) |x, *o| o.* = try node(arena, x);
    return out;
}

/// Converts one schema node.
pub fn node(arena: Allocator, v: Value) Error!Schema {
    if (v != .object) return error.InvalidSchema;
    const o = v.object;
    var s: Schema = .{};
    if (o.get("$ref")) |r| {
        if (r != .string) return error.InvalidSchema;
        const prefix = "#/definitions/";
        if (!std.mem.startsWith(u8, r.string, prefix)) return error.InvalidSchema;
        s.ref = r.string[prefix.len..];
    }
    if (o.get("type")) |t| switch (t) {
        .string => |name| {
            const one = try arena.alloc([]const u8, 1);
            one[0] = name;
            s.types = one;
        },
        .array => s.types = try strings(arena, t),
        else => return error.InvalidSchema,
    };
    if (o.get("properties")) |p| {
        if (p != .object) return error.InvalidSchema;
        const props = try arena.alloc(Property, p.object.count());
        var it = p.object.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) props[i] = .{ .name = e.key_ptr.*, .schema = try node(arena, e.value_ptr.*) };
        s.properties = props;
    }
    if (o.get("required")) |r| s.required = try strings(arena, r);
    if (o.get("items")) |x| {
        const p = try arena.create(Schema);
        p.* = try node(arena, x);
        s.items = p;
    }
    if (o.get("additionalProperties")) |x| switch (x) {
        .object => {
            const p = try arena.create(Schema);
            p.* = try node(arena, x);
            s.additional_properties = p;
        },
        .bool => {},
        else => return error.InvalidSchema,
    };
    if (o.get("enum")) |x| s.enum_values = try strings(arena, x);
    if (o.get("_enum")) |x| s.open_enum = try strings(arena, x);
    if (o.get("allOf")) |x| s.all_of = try nodes(arena, x);
    if (o.get("oneOf")) |x| s.one_of = try nodes(arena, x);
    if (o.get("title")) |x| if (x == .string) {
        s.title = x.string;
    };
    if (o.get("description")) |x| if (x == .string) {
        s.description = x.string;
    };
    return s;
}

test "dapgen: counts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), @embedFile("data/debugAdapterProtocol.json"));
    try std.testing.expectEqual(@as(usize, 192), doc.definitions.len);
    var requests: usize = 0;
    var responses: usize = 0;
    var events: usize = 0;
    for (doc.definitions) |d| {
        if (d.schema.all_of.len == 0) continue;
        const base = d.schema.all_of[0].ref orelse continue;
        if (std.mem.eql(u8, base, "Request")) requests += 1;
        if (std.mem.eql(u8, base, "Response")) responses += 1;
        if (std.mem.eql(u8, base, "Event")) events += 1;
    }
    try std.testing.expectEqual(@as(usize, 45), requests);
    try std.testing.expectEqual(@as(usize, 46), responses);
    try std.testing.expectEqual(@as(usize, 17), events);
}
