//! Compiles schema JSON into a `Schema` (flat node graph).
//!
//! 1. The document is copied into the schema's arena (node pointers into it
//!    stay valid for the schema's lifetime).
//! 2. `scan` walks the subschema keywords, records each subschema's base URI
//!    and resource, and indexes `$id` resources, `$anchor`s and
//!    `$dynamicAnchor`s. Values inside `enum`, `const` and unknown keywords
//!    are not subschemas, so an `$id` there identifies nothing.
//! 3. `node` compiles one subschema, memoized by address; references are
//!    resolved to the target's `NodeId` (cycles are fine: the id is
//!    reserved before the children compile).
//!
//! References resolve against embedded resources, the bundled official
//! metaschemas and, only when `CompileOptions.remote` is set, a fetcher.
//! Any other `http(s)` reference is `error.RemoteRefRefused` (MCP: clients
//! must not follow network references).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Schema = @import("Schema.zig");
const Num = @import("number.zig").Num;
const formats = @import("formats.zig");

const NodeId = Schema.NodeId;
const Node = Schema.Node;
const Dialect = Schema.Dialect;

/// Compile options.
pub const CompileOptions = struct {
    /// Dialect when the root has no `$schema`.
    default_dialect: Dialect = .draft2020_12,
    /// Base URI when the root has no `$id`.
    base_uri: []const u8 = "zg:/schema.json",
    /// Remote documents; null refuses network references.
    remote: ?Schema.RemoteRefFetcher = null,
    format_assertion: formats.FormatAssertion = .none,
    regex: ?Schema.RegexEngine = null,
    /// `pattern` the engine cannot compile (or no engine): keep it as an
    /// annotation with a warning, or reject the schema.
    unsupported_pattern: enum { annotate, reject } = .annotate,
    limits: Schema.Limits = .{},
};

/// Why a schema did not compile.
pub const CompileError = error{ InvalidSchema, UnsupportedDialect, RemoteRefRefused, UnresolvedRef, SchemaTooLarge, SchemaTooDeep, OutOfMemory };

const vocab_validation = "https://json-schema.org/draft/2020-12/vocab/validation";

/// The bundled metaschemas, by `$id` (without fragment).
const builtin = [_]struct { uri: []const u8, json: []const u8 }{
    .{ .uri = "https://json-schema.org/draft/2020-12/schema", .json = @embedFile("meta/draft2020-12-schema.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/core", .json = @embedFile("meta/draft2020-12-meta-core.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/applicator", .json = @embedFile("meta/draft2020-12-meta-applicator.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/unevaluated", .json = @embedFile("meta/draft2020-12-meta-unevaluated.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/validation", .json = @embedFile("meta/draft2020-12-meta-validation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/meta-data", .json = @embedFile("meta/draft2020-12-meta-meta-data.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-annotation", .json = @embedFile("meta/draft2020-12-meta-format-annotation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/content", .json = @embedFile("meta/draft2020-12-meta-content.json") },
    .{ .uri = "http://json-schema.org/draft-07/schema", .json = @embedFile("meta/draft-07-schema.json") },
};

const Resource = struct { value: *const Value, dialect: Dialect, index: u32, uri: []const u8 };

const Info = struct {
    /// Base URI (no fragment).
    base: []const u8,
    resource: u32,
    dialect: Dialect,
    /// JSON Pointer from the resource root.
    pointer: []const u8,
};

const DynDef = struct { resource: u32, name: []const u8, value: *const Value };

const Compiler = struct {
    a: Allocator,
    opts: *const CompileOptions,
    resources: std.StringHashMapUnmanaged(Resource) = .empty,
    resource_count: u32 = 0,
    anchors: std.StringHashMapUnmanaged(*const Value) = .empty,
    dyn_defs: std.ArrayList(DynDef) = .empty,
    infos: std.AutoHashMapUnmanaged(*const Value, Info) = .empty,
    memo: std.AutoHashMapUnmanaged(*const Value, NodeId) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,
    depth: u32 = 0,
    /// Whether validation keywords apply (false under a metaschema whose
    /// `$vocabulary` omits the validation vocabulary).
    validation: bool = true,

    fn resolve(c: *Compiler, base: []const u8, ref: []const u8) CompileError![]const u8 {
        return resolveUri(c.a, base, ref) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidSchema,
        };
    }

    fn addResource(c: *Compiler, uri: []const u8, v: *const Value, dialect: Dialect) !u32 {
        const gop = try c.resources.getOrPut(c.a, uri);
        if (gop.found_existing) return gop.value_ptr.index;
        const idx = c.resource_count;
        c.resource_count += 1;
        gop.value_ptr.* = .{ .value = v, .dialect = dialect, .index = idx, .uri = uri };
        return idx;
    }

    /// Indexes `v` (a subschema at `pointer` in resource `res`).
    fn scan(c: *Compiler, v: *const Value, base_in: []const u8, res_in: u32, dialect: Dialect, pointer: []const u8, depth: u32) CompileError!void {
        if (depth > c.opts.limits.max_depth) return error.SchemaTooDeep;
        if (c.infos.contains(v)) return;
        var base = base_in;
        var res = res_in;
        var ptr = pointer;
        if (v.* == .object) {
            const o = &v.object;
            const has_ref = o.get("$ref") != null;
            if (o.get("$id")) |idv| if (idv == .string and !(dialect == .draft7 and has_ref)) {
                const full = try c.resolve(base, idv.string);
                const split = splitFragment(full);
                if (split.uri.len > 0 and !(dialect == .draft7 and idv.string.len > 0 and idv.string[0] == '#')) {
                    base = split.uri;
                    res = try c.addResource(split.uri, v, dialect);
                    ptr = "";
                }
                if (dialect == .draft7 and split.fragment.len > 0)
                    try c.anchors.put(c.a, try std.fmt.allocPrint(c.a, "{s}#{s}", .{ base, split.fragment }), v);
            };
            if (dialect == .draft2020_12) {
                if (o.get("$anchor")) |an| if (an == .string)
                    try c.anchors.put(c.a, try std.fmt.allocPrint(c.a, "{s}#{s}", .{ base, an.string }), v);
                if (o.get("$dynamicAnchor")) |an| if (an == .string) {
                    try c.anchors.put(c.a, try std.fmt.allocPrint(c.a, "{s}#{s}", .{ base, an.string }), v);
                    try c.dyn_defs.append(c.a, .{ .resource = res, .name = an.string, .value = v });
                };
            }
        }
        try c.infos.put(c.a, v, .{ .base = base, .resource = res, .dialect = dialect, .pointer = ptr });
        if (v.* != .object) return;
        const o = &v.object;
        const maps = [_][]const u8{ "$defs", "definitions", "properties", "patternProperties", "dependentSchemas", "dependencies" };
        const singles = [_][]const u8{ "not", "if", "then", "else", "contains", "additionalProperties", "propertyNames", "unevaluatedItems", "unevaluatedProperties", "additionalItems", "items" };
        const lists = [_][]const u8{ "allOf", "anyOf", "oneOf", "prefixItems", "items" };
        for (maps) |k| if (o.getPtr(k)) |m| if (m.* == .object) {
            var it = m.object.iterator();
            while (it.next()) |e| if (isSchemaLike(e.value_ptr.*))
                try c.scan(e.value_ptr, base, res, dialect, try childPointer(c.a, ptr, &.{ k, e.key_ptr.* }), depth + 1);
        };
        for (singles) |k| if (o.getPtr(k)) |s| if (isSchemaLike(s.*))
            try c.scan(s, base, res, dialect, try childPointer(c.a, ptr, &.{k}), depth + 1);
        for (lists) |k| if (o.getPtr(k)) |l| if (l.* == .array) for (l.array.items, 0..) |*s, i| {
            var ib: [20]u8 = undefined;
            const is = std.fmt.bufPrint(&ib, "{d}", .{i}) catch unreachable;
            if (isSchemaLike(s.*)) try c.scan(s, base, res, dialect, try childPointer(c.a, ptr, &.{ k, is }), depth + 1);
        };
    }

    /// Loads the document for absolute `uri` (no fragment): an indexed
    /// resource, a bundled metaschema or a fetched remote.
    fn resource(c: *Compiler, uri: []const u8, dialect: Dialect) CompileError!Resource {
        if (c.resources.get(uri)) |r| return r;
        const v = try c.a.create(Value);
        var found = false;
        for (builtin) |b| if (std.mem.eql(u8, b.uri, uri)) {
            v.* = std.json.parseFromSliceLeaky(Value, c.a, b.json, .{ .allocate = .alloc_always }) catch return error.InvalidSchema;
            found = true;
        };
        if (!found) {
            if (c.opts.remote) |r| {
                if (r.fetch(r.ctx, c.a, uri) catch null) |doc| {
                    v.* = doc;
                    found = true;
                }
            }
        }
        if (!found) {
            if (std.ascii.startsWithIgnoreCase(uri, "http://") or std.ascii.startsWithIgnoreCase(uri, "https://"))
                return error.RemoteRefRefused;
            return error.UnresolvedRef;
        }
        var d = dialect;
        if (v.* == .object) if (v.object.get("$schema")) |s| if (s == .string) {
            d = Dialect.fromSchemaUri(s.string) orelse d;
        };
        const idx = try c.addResource(uri, v, d);
        try c.scan(v, uri, idx, d, "", 0);
        // The document's own `$id` may differ from the URI it was fetched by.
        return c.resources.get(uri).?;
    }

    /// The value a reference points to, with its info.
    fn target(c: *Compiler, from: Info, ref: []const u8) CompileError!*const Value {
        const full = try c.resolve(from.base, ref);
        const split = splitFragment(full);
        const frag = percentDecode(c.a, split.fragment) catch return error.InvalidSchema;
        if (frag.len > 0 and frag[0] != '/') {
            const key = try std.fmt.allocPrint(c.a, "{s}#{s}", .{ split.uri, frag });
            if (c.anchors.get(key)) |t| return t;
            _ = try c.resource(split.uri, from.dialect);
            return c.anchors.get(key) orelse error.UnresolvedRef;
        }
        const r = try c.resource(split.uri, from.dialect);
        const t = try walkPointer(r.value, frag);
        if (!c.infos.contains(t)) {
            // A pointer into a non-subschema location (an unknown keyword).
            const rinfo = c.infos.get(r.value).?;
            try c.scan(t, rinfo.base, rinfo.resource, rinfo.dialect, frag, 0);
        }
        return t;
    }

    fn refNode(c: *Compiler, from: Info, s: []const u8) CompileError!NodeId {
        return c.node(try c.target(from, s));
    }

    fn sub(c: *Compiler, o: *const std.json.ObjectMap, key: []const u8) CompileError!?NodeId {
        const v = o.getPtr(key) orelse return null;
        if (!isSchemaLike(v.*)) return error.InvalidSchema;
        return try c.node(v);
    }

    fn subList(c: *Compiler, o: *const std.json.ObjectMap, key: []const u8) CompileError![]const NodeId {
        const v = o.getPtr(key) orelse return &.{};
        if (v.* != .array or v.array.items.len == 0) return error.InvalidSchema;
        const ids = try c.a.alloc(NodeId, v.array.items.len);
        for (v.array.items, ids) |*s, *id| {
            if (!isSchemaLike(s.*)) return error.InvalidSchema;
            id.* = try c.node(s);
        }
        return ids;
    }

    fn subMap(c: *Compiler, o: *const std.json.ObjectMap, key: []const u8) CompileError![]const Schema.NamedNode {
        const v = o.getPtr(key) orelse return &.{};
        if (v.* != .object) return error.InvalidSchema;
        var list: std.ArrayList(Schema.NamedNode) = .empty;
        var it = v.object.iterator();
        while (it.next()) |e| {
            if (!isSchemaLike(e.value_ptr.*)) {
                if (std.mem.eql(u8, key, "dependencies")) continue; // Array form: dependentRequired.
                return error.InvalidSchema;
            }
            try list.append(c.a, .{ .name = e.key_ptr.*, .node = try c.node(e.value_ptr) });
        }
        return list.items;
    }

    fn node(c: *Compiler, v: *const Value) CompileError!NodeId {
        if (c.memo.get(v)) |id| return id;
        if (c.nodes.items.len >= c.opts.limits.max_subschemas) return error.SchemaTooLarge;
        if (c.depth > c.opts.limits.max_depth) return error.SchemaTooDeep;
        const info = c.infos.get(v) orelse return error.InvalidSchema;
        const id: NodeId = @intCast(c.nodes.items.len);
        try c.nodes.append(c.a, .{});
        try c.memo.put(c.a, v, id);
        c.depth += 1;
        defer c.depth -= 1;
        var n: Node = .{
            .resource = info.resource,
            .location = try std.fmt.allocPrint(c.a, "{s}#{s}", .{ info.base, info.pointer }),
        };
        switch (v.*) {
            .bool => |b| n.bool_schema = b,
            .object => |*o| try c.keywords(&n, o, info),
            else => return error.InvalidSchema,
        }
        c.nodes.items[id] = n;
        return id;
    }

    fn keywords(c: *Compiler, n: *Node, o: *const std.json.ObjectMap, info: Info) CompileError!void {
        const d7 = info.dialect == .draft7;
        if (o.get("$ref")) |r| {
            if (r != .string) return error.InvalidSchema;
            n.applicators.ref = try c.refNode(info, r.string);
            if (d7) return; // Draft 7 ignores every sibling of `$ref`.
        }
        if (!d7) if (o.get("$dynamicRef")) |r| {
            if (r != .string) return error.InvalidSchema;
            const t = try c.target(info, r.string);
            const frag = splitFragment(try c.resolve(info.base, r.string)).fragment;
            var anchor: ?[]const u8 = null;
            if (frag.len > 0 and frag[0] != '/' and t.* == .object) {
                if (t.object.get("$dynamicAnchor")) |da| if (da == .string and std.mem.eql(u8, da.string, frag)) {
                    anchor = da.string;
                };
            }
            n.applicators.dynamic_ref = .{ .static = try c.node(t), .anchor = anchor };
        };
        if (c.validation) try c.validationKeywords(n, o, d7);
        if (o.get("format")) |f| if (f == .string) {
            n.format = f.string;
        };

        const ap = &n.applicators;
        ap.all_of = try c.subList(o, "allOf");
        ap.any_of = try c.subList(o, "anyOf");
        ap.one_of = try c.subList(o, "oneOf");
        ap.not = try c.sub(o, "not");
        ap.if_ = try c.sub(o, "if");
        if (ap.if_ != null) {
            ap.then_ = try c.sub(o, "then");
            ap.else_ = try c.sub(o, "else");
        }
        ap.contains = try c.sub(o, "contains");
        ap.properties = try c.subMap(o, "properties");
        ap.additional_properties = try c.sub(o, "additionalProperties");
        ap.property_names = try c.sub(o, "propertyNames");
        if (o.getPtr("patternProperties")) |pp| {
            if (pp.* != .object) return error.InvalidSchema;
            var list: std.ArrayList(Schema.PatternNode) = .empty;
            var it = pp.object.iterator();
            while (it.next()) |e| {
                if (!isSchemaLike(e.value_ptr.*)) return error.InvalidSchema;
                try list.append(c.a, .{ .source = e.key_ptr.*, .regex = try c.regex(e.key_ptr.*), .node = try c.node(e.value_ptr) });
            }
            ap.pattern_properties = list.items;
        }
        if (d7) {
            ap.dependent_schemas = try c.subMap(o, "dependencies");
            if (o.getPtr("items")) |items| switch (items.*) {
                .array => {
                    ap.prefix_items = try c.subList(o, "items");
                    ap.items = try c.sub(o, "additionalItems");
                },
                else => ap.items = try c.sub(o, "items"),
            };
        } else {
            ap.dependent_schemas = try c.subMap(o, "dependentSchemas");
            ap.prefix_items = if (o.get("prefixItems") != null) try c.subList(o, "prefixItems") else &.{};
            ap.items = try c.sub(o, "items");
            ap.unevaluated_items = try c.sub(o, "unevaluatedItems");
            ap.unevaluated_properties = try c.sub(o, "unevaluatedProperties");
        }
    }

    fn regex(c: *Compiler, source: []const u8) CompileError!?*const anyopaque {
        if (c.opts.regex) |engine| if (engine.compile(engine.ctx, c.a, source)) |re| return re;
        if (c.opts.unsupported_pattern == .reject) return error.InvalidSchema;
        try c.warnings.append(c.a, try std.fmt.allocPrint(c.a, "pattern /{s}/ is not supported; kept as an annotation", .{source}));
        return null;
    }

    fn validationKeywords(c: *Compiler, n: *Node, o: *const std.json.ObjectMap, d7: bool) CompileError!void {
        if (o.get("type")) |t| n.types = try typeSet(t);
        if (o.get("enum")) |e| {
            if (e != .array) return error.InvalidSchema;
            n.enum_values = e.array.items;
        }
        if (o.get("const")) |cv| n.const_value = cv;
        if (o.get("multipleOf")) |m| {
            const num = try number(m);
            if (num.neg or num.isZero()) return error.InvalidSchema;
            n.multiple_of = num;
        }
        if (o.get("maximum")) |m| n.maximum = try number(m);
        if (o.get("minimum")) |m| n.minimum = try number(m);
        if (o.get("exclusiveMaximum")) |m| n.exclusive_maximum = try number(m);
        if (o.get("exclusiveMinimum")) |m| n.exclusive_minimum = try number(m);
        if (o.get("maxLength")) |m| n.max_length = try count(m);
        if (o.get("minLength")) |m| n.min_length = try count(m);
        if (o.get("pattern")) |p| {
            if (p != .string) return error.InvalidSchema;
            n.pattern_src = p.string;
            n.pattern = try c.regex(p.string);
        }
        if (o.get("maxItems")) |m| n.max_items = try count(m);
        if (o.get("minItems")) |m| n.min_items = try count(m);
        if (o.get("uniqueItems")) |u| {
            if (u != .bool) return error.InvalidSchema;
            n.unique_items = u.bool;
        }
        if (!d7) {
            if (o.get("maxContains")) |m| n.max_contains = try count(m);
            if (o.get("minContains")) |m| n.min_contains = try count(m);
        }
        if (o.get("maxProperties")) |m| n.max_properties = try count(m);
        if (o.get("minProperties")) |m| n.min_properties = try count(m);
        if (o.get("required")) |r| n.required = try c.stringList(r);
        const dep_key = if (d7) "dependencies" else "dependentRequired";
        if (o.get(dep_key)) |dr| {
            if (dr != .object) return error.InvalidSchema;
            var list: std.ArrayList(Schema.DepReq) = .empty;
            var it = dr.object.iterator();
            while (it.next()) |e| {
                if (d7 and e.value_ptr.* != .array) continue; // Schema form: dependentSchemas.
                try list.append(c.a, .{ .name = e.key_ptr.*, .required = try c.stringList(e.value_ptr.*) });
            }
            n.dependent_required = list.items;
        }
    }

    /// The dialect a root `$schema` selects. A custom metaschema (a known or
    /// fetched document) selects its own dialect, and drops the validation
    /// keywords when its `$vocabulary` omits the validation vocabulary.
    fn dialectOf(c: *Compiler, uri: []const u8) CompileError!Dialect {
        if (Dialect.fromSchemaUri(uri)) |d| return d;
        const split = splitFragment(uri);
        const r = c.resource(split.uri, .draft2020_12) catch |e| switch (e) {
            error.RemoteRefRefused, error.UnresolvedRef => return error.UnsupportedDialect,
            else => return e,
        };
        if (r.value.* != .object) return error.UnsupportedDialect;
        const meta = r.value.object;
        const parent = if (meta.get("$schema")) |p| (if (p == .string) Dialect.fromSchemaUri(p.string) else null) else null;
        const d = parent orelse return error.UnsupportedDialect;
        if (meta.get("$vocabulary")) |voc| if (voc == .object) {
            c.validation = voc.object.get(vocab_validation) != null;
        };
        return d;
    }

    fn stringList(c: *Compiler, v: Value) CompileError![]const []const u8 {
        if (v != .array) return error.InvalidSchema;
        const out = try c.a.alloc([]const u8, v.array.items.len);
        for (v.array.items, out) |s, *d| {
            if (s != .string) return error.InvalidSchema;
            d.* = s.string;
        }
        return out;
    }
};

fn typeSet(v: Value) CompileError!Schema.TypeSet {
    var t: Schema.TypeSet = .{};
    switch (v) {
        .string => |s| try addType(&t, s),
        .array => |a| for (a.items) |e| {
            if (e != .string) return error.InvalidSchema;
            try addType(&t, e.string);
        },
        else => return error.InvalidSchema,
    }
    return t;
}

fn addType(t: *Schema.TypeSet, name: []const u8) CompileError!void {
    const map = std.StaticStringMap(u3).initComptime(.{
        .{ "null", 0 }, .{ "boolean", 1 }, .{ "object", 2 }, .{ "array", 3 }, .{ "number", 4 }, .{ "integer", 5 }, .{ "string", 6 },
    });
    switch (map.get(name) orelse return error.InvalidSchema) {
        0 => t.null = true,
        1 => t.boolean = true,
        2 => t.object = true,
        3 => t.array = true,
        4 => t.number = true,
        5 => t.integer = true,
        6 => t.string = true,
        else => unreachable,
    }
}

fn number(v: Value) CompileError!Num {
    return Num.fromValue(v) orelse error.InvalidSchema;
}

/// A non-negative integer keyword value (`2.0` allowed).
fn count(v: Value) CompileError!u64 {
    const n = try number(v);
    if (n.neg and !n.isZero()) return error.InvalidSchema;
    if (!n.isInteger()) return error.InvalidSchema;
    if (n.exp > 19) return std.math.maxInt(u64);
    var m: u128 = n.mant;
    var e = n.exp;
    while (e > 0) : (e -= 1) {
        m = std.math.mul(u128, m, 10) catch return std.math.maxInt(u64);
    }
    return std.math.cast(u64, m) orelse std.math.maxInt(u64);
}

fn isSchemaLike(v: Value) bool {
    return v == .object or v == .bool;
}

fn childPointer(a: Allocator, base: []const u8, parts: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, base);
    for (parts) |p| {
        try out.append(a, '/');
        for (p) |ch| switch (ch) {
            '~' => try out.appendSlice(a, "~0"),
            '/' => try out.appendSlice(a, "~1"),
            else => try out.append(a, ch),
        };
    }
    return out.items;
}

const Split = struct { uri: []const u8, fragment: []const u8 };

fn splitFragment(s: []const u8) Split {
    const i = std.mem.indexOfScalar(u8, s, '#') orelse return .{ .uri = s, .fragment = "" };
    return .{ .uri = s[0..i], .fragment = s[i + 1 ..] };
}

/// Resolves `ref` against absolute `base` (RFC 3986 §5).
pub fn resolveUri(a: Allocator, base: []const u8, ref: []const u8) ![]const u8 {
    const b = std.Uri.parse(base) catch return error.InvalidUri;
    const aux = try a.alloc(u8, ref.len + base.len + 64);
    @memcpy(aux[0..ref.len], ref);
    var buf = aux;
    const r = b.resolveInPlace(ref.len, &buf) catch return error.InvalidUri;
    const s = try std.fmt.allocPrint(a, "{f}", .{r.fmt(.{ .scheme = true, .authentication = true, .authority = true, .path = true, .query = true, .fragment = true })});
    // An empty fragment names the same resource.
    return if (s.len > 0 and s[s.len - 1] == '#') s[0 .. s.len - 1] else s;
}

fn percentDecode(a: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    const out = try a.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.InvalidPointer;
            i += 2;
        } else out[n] = s[i];
        n += 1;
    }
    return out[0..n];
}

/// Follows RFC 6901 pointer `p` (already percent-decoded) from `root`.
fn walkPointer(root: *const Value, p: []const u8) CompileError!*const Value {
    if (p.len == 0) return root;
    if (p[0] != '/') return error.UnresolvedRef;
    var cur = root;
    var it = std.mem.splitScalar(u8, p[1..], '/');
    var buf: [1024]u8 = undefined;
    while (it.next()) |raw| {
        if (raw.len > buf.len) return error.UnresolvedRef;
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '~' and i + 1 < raw.len) {
                buf[n] = if (raw[i + 1] == '1') '/' else '~';
                i += 1;
            } else buf[n] = raw[i];
            n += 1;
        }
        const seg = buf[0..n];
        cur = switch (cur.*) {
            .object => |*o| o.getPtr(seg) orelse return error.UnresolvedRef,
            .array => |*arr| blk: {
                const idx = std.fmt.parseInt(usize, seg, 10) catch return error.UnresolvedRef;
                if (idx >= arr.items.len) return error.UnresolvedRef;
                break :blk &arr.items[idx];
            },
            else => return error.UnresolvedRef,
        };
    }
    return cur;
}

fn deepCopy(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = try std.json.Array.initCapacity(a, arr.items.len);
            for (arr.items) |e| out.appendAssumeCapacity(try deepCopy(a, e));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: std.json.ObjectMap = .empty;
            try out.ensureTotalCapacity(a, o.count());
            var it = o.iterator();
            while (it.next()) |e| out.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), try deepCopy(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
        else => v,
    };
}

/// Compiles `root` (copied; the caller keeps ownership of it).
pub fn compile(gpa: Allocator, root: Value, opts: CompileOptions) CompileError!*Schema {
    const s = try gpa.create(Schema);
    errdefer gpa.destroy(s);
    s.arena = .init(gpa);
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    const doc = try a.create(Value);
    doc.* = try deepCopy(a, root);

    var c: Compiler = .{ .a = a, .opts = &opts };
    var dialect = opts.default_dialect;
    if (doc.* == .object) if (doc.object.get("$schema")) |sv| {
        if (sv != .string) return error.InvalidSchema;
        dialect = try c.dialectOf(sv.string);
    };
    const base = resolveUri(a, "zg:/", opts.base_uri) catch return error.InvalidSchema;
    const root_res = try c.addResource(base, doc, dialect);
    try c.scan(doc, base, root_res, dialect, "", 0);
    const root_id = try c.node(doc);

    // Every `$dynamicAnchor` is a potential `$dynamicRef` target. Loading
    // one may index more resources, so iterate until no new ones appear.
    var dyn: std.ArrayList(Schema.DynamicAnchor) = .empty;
    var i: usize = 0;
    while (i < c.dyn_defs.items.len) : (i += 1) {
        const d = c.dyn_defs.items[i];
        try dyn.append(a, .{ .resource = d.resource, .name = d.name, .node = try c.node(d.value) });
    }
    s.* = .{
        .arena = s.arena,
        .nodes = c.nodes.items,
        .root = root_id,
        .dialect = dialect,
        .dynamic_anchors = dyn.items,
        .format_assertion = opts.format_assertion,
        .regex = opts.regex,
        .limits = opts.limits,
        .warnings = c.warnings.items,
    };
    return s;
}

const testing = std.testing;

test "compile: resolveUri" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("http://x.test/a/b.json#/defs", try resolveUri(a, "http://x.test/a/root.json", "b.json#/defs"));
    try testing.expectEqualStrings("http://x.test/a/root.json", try resolveUri(a, "http://x.test/a/root.json", "#"));
    try testing.expectEqualStrings("urn:uuid:deadbeef#foo", try resolveUri(a, "urn:uuid:deadbeef", "#foo"));
}
