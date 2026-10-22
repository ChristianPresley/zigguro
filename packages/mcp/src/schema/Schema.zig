//! A compiled JSON Schema: a flat array of nodes whose children and
//! reference targets are `NodeId`s, so recursive schemas are plain cycles.
//! Built by `compile.zig`, evaluated by `validate.zig`. The schema owns an
//! arena holding the nodes and a private copy of the schema JSON;
//! validation never mutates it, so one `Schema` serves many threads.

const Schema = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Num = @import("number.zig").Num;
const formats = @import("formats.zig");

/// Index into `nodes`.
pub const NodeId = u32;

arena: std.heap.ArenaAllocator,
nodes: []const Node,
root: NodeId,
dialect: Dialect,
/// Targets of `$dynamicAnchor`s, for `$dynamicRef` resolution.
dynamic_anchors: []const DynamicAnchor,
format_assertion: formats.FormatAssertion,
regex: ?RegexEngine,
limits: Limits,
/// Compile notes (an unsupported `pattern` kept as annotation, ...).
warnings: []const []const u8,

/// Frees everything.
pub fn deinit(self: *Schema) void {
    const gpa = self.arena.child_allocator;
    self.arena.deinit();
    gpa.destroy(self);
}

/// The JSON Schema dialects understood.
pub const Dialect = enum {
    draft2020_12,
    draft7,

    /// The dialect named by a `$schema` URI (with or without empty fragment).
    pub fn fromSchemaUri(uri: []const u8) ?Dialect {
        const u = std.mem.trimEnd(u8, uri, "#");
        if (std.mem.eql(u8, u, "https://json-schema.org/draft/2020-12/schema")) return .draft2020_12;
        if (std.mem.eql(u8, u, "http://json-schema.org/draft-07/schema")) return .draft7;
        return null;
    }
};

/// Resource limits (MCP: composition keywords must not exhaust resources).
pub const Limits = struct {
    /// Nesting of subschemas in the schema document.
    max_depth: u32 = 128,
    /// Total compiled subschemas.
    max_subschemas: u32 = 20_000,
    /// Keyword evaluations per `validate` call.
    max_steps_per_validation: u64 = 1_000_000,
    /// Errors kept in an `Output`.
    max_errors: u32 = 100,
};

/// A regular expression engine for `pattern`, `patternProperties` and the
/// `regex` format (`ecma.engine`: zg_regex in ECMA-compat mode).
pub const RegexEngine = struct {
    ctx: ?*anyopaque,
    /// Compiles `source` into `arena`; null when the engine does not
    /// support the pattern (lookaround, backreferences, ...).
    compile: *const fn (ctx: ?*anyopaque, arena: Allocator, source: []const u8) ?*const anyopaque,
    /// Unanchored search.
    search: *const fn (ctx: ?*anyopaque, re: *const anyopaque, s: []const u8) bool,
};

/// Fetches a remote schema document by absolute URI (without fragment).
/// Only the test-suite runner and explicitly trusted hosts set this: MCP
/// forbids following network references by default.
pub const RemoteRefFetcher = struct {
    ctx: ?*anyopaque,
    fetch: *const fn (ctx: ?*anyopaque, arena: Allocator, uri: []const u8) anyerror!?Value,
};

/// The JSON types, as a bitset.
pub const TypeSet = packed struct(u8) {
    null: bool = false,
    boolean: bool = false,
    object: bool = false,
    array: bool = false,
    number: bool = false,
    integer: bool = false,
    string: bool = false,
    _pad: u1 = 0,

    /// Every type (no `type` keyword).
    pub const any: TypeSet = .{ .null = true, .boolean = true, .object = true, .array = true, .number = true, .integer = true, .string = true };

    /// Whether every type is allowed.
    pub fn isAny(t: TypeSet) bool {
        return t == any;
    }

    /// Whether `v` has one of the types (`integer` admits `1.0`).
    pub fn matches(t: TypeSet, v: Value) bool {
        return switch (v) {
            .null => t.null,
            .bool => t.boolean,
            .object => t.object,
            .array => t.array,
            .string => t.string,
            .integer, .float, .number_string => t.number or (t.integer and if (Num.fromValue(v)) |n| n.isInteger() else false),
        };
    }
};

/// A subschema under a name (`properties`, `dependentSchemas`).
pub const NamedNode = struct { name: []const u8, node: NodeId };

/// A `patternProperties` entry; `regex` is null when no engine accepted it.
pub const PatternNode = struct { source: []const u8, regex: ?*const anyopaque, node: NodeId };

/// A `dependentRequired` entry.
pub const DepReq = struct { name: []const u8, required: []const []const u8 };

/// A `$dynamicRef`: `static` is the initially resolved target; `anchor` is
/// set when that target carries the matching `$dynamicAnchor`, which makes
/// the reference dynamic.
pub const DynRef = struct { static: NodeId, anchor: ?[]const u8 };

/// One `$dynamicAnchor` of a schema resource.
pub const DynamicAnchor = struct { resource: u32, name: []const u8, node: NodeId };

/// The applicator keywords (JSON Schema core §10, §11).
pub const Applicators = struct {
    all_of: []const NodeId = &.{},
    any_of: []const NodeId = &.{},
    one_of: []const NodeId = &.{},
    not: ?NodeId = null,
    if_: ?NodeId = null,
    then_: ?NodeId = null,
    else_: ?NodeId = null,
    dependent_schemas: []const NamedNode = &.{},
    prefix_items: []const NodeId = &.{},
    items: ?NodeId = null,
    contains: ?NodeId = null,
    properties: []const NamedNode = &.{},
    pattern_properties: []const PatternNode = &.{},
    additional_properties: ?NodeId = null,
    property_names: ?NodeId = null,
    unevaluated_items: ?NodeId = null,
    unevaluated_properties: ?NodeId = null,
    ref: ?NodeId = null,
    dynamic_ref: ?DynRef = null,
};

/// One compiled schema object (or boolean schema).
pub const Node = struct {
    /// `true` / `false` schemas.
    bool_schema: ?bool = null,
    types: TypeSet = .any,
    enum_values: ?[]const Value = null,
    const_value: ?Value = null,
    multiple_of: ?Num = null,
    maximum: ?Num = null,
    exclusive_maximum: ?Num = null,
    minimum: ?Num = null,
    exclusive_minimum: ?Num = null,
    max_length: ?u64 = null,
    min_length: ?u64 = null,
    /// Compiled by `Schema.regex`; null with `pattern_src` set when no
    /// engine accepted it (then `pattern` is an annotation).
    pattern: ?*const anyopaque = null,
    pattern_src: ?[]const u8 = null,
    max_items: ?u64 = null,
    min_items: ?u64 = null,
    unique_items: bool = false,
    max_contains: ?u64 = null,
    min_contains: ?u64 = null,
    max_properties: ?u64 = null,
    min_properties: ?u64 = null,
    required: []const []const u8 = &.{},
    dependent_required: []const DepReq = &.{},
    format: ?[]const u8 = null,
    applicators: Applicators = .{},
    /// The schema resource (`$id` scope) the node belongs to.
    resource: u32 = 0,
    /// Absolute location of the schema object: `<resource uri>#<pointer>`.
    location: []const u8 = "",
};
