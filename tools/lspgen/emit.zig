//! Emits `packages/lsp/src/gen/protocol.zig` from a parsed meta model.
//!
//! Mapping rules (see E07.F01.S01.T01):
//! - base types: `integer` -> i32, `uinteger` -> u32, `decimal` -> f64,
//!   `string`/`DocumentUri`/`URI`/`RegExp` -> []const u8, `boolean` -> bool;
//! - `extends` and `mixins` are flattened into each struct, and `and`
//!   types are merged into one synthesized struct;
//! - `T | null` becomes `?T`; other `or` types become a `union(enum)` whose
//!   parse/stringify hooks live in `proto/json.zig`;
//! - optional properties become `?T = null`; required-but-nullable ones
//!   are listed so they are written as `null` instead of being omitted;
//! - string-literal properties (`kind: "create"`) get the literal as their
//!   default and are listed in `json_literals` for union discrimination;
//! - enum members keep their meta model names (`PlainText`); string enums
//!   carry their wire values in `json_values`, because a wire value may be
//!   empty (`CodeActionKind.Empty`) or shared (`LanguageKind` Delphi and
//!   Pascal); open ones (with `supportsCustomValues`) are wrapped in
//!   `json.OpenEnum`; integer enums are non-exhaustive and written as
//!   numbers;
//! - by-value references that would make a type contain itself (such as
//!   `SelectionRange.parent`) become `*const T`;
//! - anonymous types get synthesized names: the owner's name followed by the
//!   property name in PascalCase (`HoverContents`), with a numeric suffix
//!   if that name is taken.
//!
//! Declarations are sorted by name and the source is rendered through
//! `std.zig.Ast`, so the output is canonical and byte-identical across runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Type = model.Type;
const Property = model.Property;

/// Generation options.
pub const Options = struct {
    /// Leave out messages, properties and enum values newer than this.
    since_max: ?[]const u8 = null,
    /// Include entities marked `proposed`.
    include_proposed: bool = false,
    /// File name recorded in the header comment.
    source_name: []const u8 = "metaModel.json",
};

/// Emission failures.
pub const Error = error{ OutOfMemory, Unsupported, InvalidOutput, WriteFailed };

const Decl = struct { name: []const u8, text: []const u8 };

/// Returns the formatted Zig source for `m`.
pub fn emit(arena: Allocator, m: *const model.Model, opts: Options) Error![]const u8 {
    var e: Emitter = .{ .arena = arena, .m = m, .opts = opts };
    try e.index();
    try e.findCycles();
    return e.run();
}

const special_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "LSPAny", "std.json.Value" },
    .{ "LSPObject", "std.json.ArrayHashMap(std.json.Value)" },
    .{ "LSPArray", "[]const std.json.Value" },
});

const reserved = [_][]const u8{
    "std",              "json",               "Direction",    "Method", "RequestInfo", "method_names", "NotificationMethod",
    "NotificationInfo", "notification_names", "meta_version",
};

const Emitter = struct {
    arena: Allocator,
    m: *const model.Model,
    opts: Options,
    structs: std.StringHashMapUnmanaged(*const model.Structure) = .empty,
    enums: std.StringHashMapUnmanaged(*const model.Enumeration) = .empty,
    aliases: std.StringHashMapUnmanaged(*const model.TypeAlias) = .empty,
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// Strongly connected component of each structure/alias in a by-value
    /// reference cycle.
    cycle: std.StringHashMapUnmanaged(u32) = .empty,
    decls: std.ArrayList(Decl) = .empty,

    fn index(e: *Emitter) Error!void {
        for (e.m.structures) |*s| {
            if (!e.keep(s.proposed, s.since)) continue;
            try e.structs.put(e.arena, s.name, s);
            try e.reserve(s.name);
        }
        for (e.m.enumerations) |*x| {
            if (!e.keep(x.proposed, x.since)) continue;
            try e.enums.put(e.arena, x.name, x);
            try e.reserve(x.name);
        }
        for (e.m.type_aliases) |*a| {
            if (!e.keep(a.proposed, a.since)) continue;
            try e.aliases.put(e.arena, a.name, a);
            try e.reserve(a.name);
        }
        for (reserved) |r| try e.reserve(r);
    }

    fn reserve(e: *Emitter, name: []const u8) Error!void {
        if (e.names.contains(name)) {
            std.log.err("lspgen: duplicate name {s}", .{name});
            return error.Unsupported;
        }
        try e.names.put(e.arena, name, {});
    }

    /// A fresh top-level name based on `base`.
    fn unique(e: *Emitter, base: []const u8) Error![]const u8 {
        if (!e.names.contains(base)) {
            try e.names.put(e.arena, base, {});
            return base;
        }
        var n: usize = 2;
        while (true) : (n += 1) {
            const cand = try std.fmt.allocPrint(e.arena, "{s}{d}", .{ base, n });
            if (!e.names.contains(cand)) {
                try e.names.put(e.arena, cand, {});
                return cand;
            }
        }
    }

    fn keep(e: *const Emitter, proposed: bool, since: ?[]const u8) bool {
        if (proposed and !e.opts.include_proposed) return false;
        if (e.opts.since_max) |max| if (since) |s| return versionLe(s, max);
        return true;
    }

    // ---------------------------------------------------------------- cycles

    /// Collects names referenced by value (not through arrays or maps).
    fn byValueRefs(e: *Emitter, t: Type, out: *std.ArrayList([]const u8)) Error!void {
        switch (t) {
            .reference => |n| if (e.structs.contains(n) or e.aliases.contains(n)) try out.append(e.arena, n),
            .@"or", .@"and", .tuple => |items| for (items) |it| try e.byValueRefs(it, out),
            .literal => |props| for (props) |p| try e.byValueRefs(p.type, out),
            else => {},
        }
    }

    fn edgesOf(e: *Emitter, name: []const u8) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (special_types.has(name)) return out.items;
        if (e.structs.get(name)) |s| {
            for (s.extends) |t| try e.byValueRefs(t, &out);
            for (s.mixins) |t| try e.byValueRefs(t, &out);
            for (s.properties) |p| try e.byValueRefs(p.type, &out);
        } else if (e.aliases.get(name)) |a| try e.byValueRefs(a.type, &out);
        return out.items;
    }

    /// Tarjan's strongly connected components over by-value references.
    fn findCycles(e: *Emitter) Error!void {
        var nodes: std.ArrayList([]const u8) = .empty;
        var sit = e.structs.keyIterator();
        while (sit.next()) |k| try nodes.append(e.arena, k.*);
        var ait = e.aliases.keyIterator();
        while (ait.next()) |k| try nodes.append(e.arena, k.*);
        std.mem.sort([]const u8, nodes.items, {}, lessThan);

        const State = struct { index: u32, low: u32, on_stack: bool };
        var state: std.StringHashMapUnmanaged(State) = .empty;
        var stack: std.ArrayList([]const u8) = .empty;
        var next_index: u32 = 0;
        var comp: u32 = 0;

        const Frame = struct { node: []const u8, edges: []const []const u8, i: usize };
        var frames: std.ArrayList(Frame) = .empty;
        for (nodes.items) |root| {
            if (state.contains(root)) continue;
            try state.put(e.arena, root, .{ .index = next_index, .low = next_index, .on_stack = true });
            next_index += 1;
            try stack.append(e.arena, root);
            try frames.append(e.arena, .{ .node = root, .edges = try e.edgesOf(root), .i = 0 });
            while (frames.items.len > 0) {
                const f = &frames.items[frames.items.len - 1];
                if (f.i < f.edges.len) {
                    const w = f.edges[f.i];
                    f.i += 1;
                    if (state.getPtr(w)) |ws| {
                        if (ws.on_stack) {
                            const vs = state.getPtr(f.node).?;
                            vs.low = @min(vs.low, ws.index);
                        }
                    } else {
                        try state.put(e.arena, w, .{ .index = next_index, .low = next_index, .on_stack = true });
                        next_index += 1;
                        try stack.append(e.arena, w);
                        try frames.append(e.arena, .{ .node = w, .edges = try e.edgesOf(w), .i = 0 });
                    }
                    continue;
                }
                const v = f.node;
                const edges = f.edges;
                _ = frames.pop();
                const vs = state.getPtr(v).?;
                if (frames.items.len > 0) {
                    const parent = state.getPtr(frames.items[frames.items.len - 1].node).?;
                    parent.low = @min(parent.low, vs.low);
                }
                if (vs.low != vs.index) continue;
                // Pop the component rooted at v.
                var members: std.ArrayList([]const u8) = .empty;
                while (true) {
                    const w = stack.pop().?;
                    state.getPtr(w).?.on_stack = false;
                    try members.append(e.arena, w);
                    if (std.mem.eql(u8, w, v)) break;
                }
                const self_loop = for (edges) |x| {
                    if (std.mem.eql(u8, x, v)) break true;
                } else false;
                if (members.items.len > 1 or self_loop) {
                    for (members.items) |w| try e.cycle.put(e.arena, w, comp);
                    comp += 1;
                }
            }
        }
    }

    fn sameCycle(e: *const Emitter, owner: ?[]const u8, target: []const u8) bool {
        const o = owner orelse return false;
        const a = e.cycle.get(o) orelse return false;
        const b = e.cycle.get(target) orelse return false;
        return a == b;
    }

    // ---------------------------------------------------------------- types

    fn baseType(name: []const u8) Error![]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "integer", "i32" },
            .{ "uinteger", "u32" },
            .{ "decimal", "f64" },
            .{ "boolean", "bool" },
            .{ "string", "[]const u8" },
            .{ "DocumentUri", "[]const u8" },
            .{ "URI", "[]const u8" },
            .{ "RegExp", "[]const u8" },
            .{ "null", "void" },
        });
        return map.get(name) orelse {
            std.log.err("lspgen: unknown base type {s}", .{name});
            return error.Unsupported;
        };
    }

    /// The Zig type expression for `t`. `hint` names any synthesized type;
    /// `owner` is the model entity whose value contains `t` (null inside an
    /// array or map, which break containment cycles).
    fn typeExpr(e: *Emitter, t: Type, hint: []const u8, owner: ?[]const u8) Error![]const u8 {
        return switch (t) {
            .base => |n| baseType(n),
            .reference => |n| blk: {
                if (!e.structs.contains(n) and !e.enums.contains(n) and !e.aliases.contains(n)) {
                    std.log.err("lspgen: reference to unknown or filtered type {s}", .{n});
                    return error.Unsupported;
                }
                const id = try e.ident(n);
                if (e.sameCycle(owner, n)) break :blk try std.fmt.allocPrint(e.arena, "*const {s}", .{id});
                break :blk id;
            },
            .array => |el| try std.fmt.allocPrint(e.arena, "[]const {s}", .{try e.typeExpr(el.*, try cat(e.arena, hint, "Item"), null)}),
            .map => |mp| blk: {
                if (!e.isStringLike(mp.key.*)) {
                    std.log.err("lspgen: map with non-string keys in {s}", .{hint});
                    return error.Unsupported;
                }
                break :blk try std.fmt.allocPrint(e.arena, "std.json.ArrayHashMap({s})", .{try e.typeExpr(mp.value.*, try cat(e.arena, hint, "Value"), null)});
            },
            .@"or" => |items| try e.orExpr(items, hint, owner, false),
            .@"and" => |items| blk: {
                var props: std.ArrayList(Property) = .empty;
                for (items) |it| try e.collectTypeProps(it, &props);
                const name = try e.unique(hint);
                try e.emitStruct(name, props.items, null, null, owner);
                break :blk name;
            },
            .tuple => |items| blk: {
                if (items.len == 0) return error.Unsupported;
                const first = try e.typeExpr(items[0], hint, owner);
                for (items[1..]) |it| {
                    if (!std.mem.eql(u8, first, try e.typeExpr(it, hint, owner))) {
                        std.log.err("lspgen: heterogeneous tuple in {s}", .{hint});
                        return error.Unsupported;
                    }
                }
                break :blk try std.fmt.allocPrint(e.arena, "[{d}]{s}", .{ items.len, first });
            },
            .literal => |props| blk: {
                const name = try e.unique(hint);
                try e.emitStruct(name, props, null, null, owner);
                break :blk name;
            },
            .string_literal => "[]const u8",
            .integer_literal => "i32",
            .boolean_literal => "bool",
        };
    }

    fn isStringLike(e: *const Emitter, t: Type) bool {
        return switch (t) {
            .base => |n| std.mem.eql(u8, n, "string") or std.mem.eql(u8, n, "DocumentUri") or std.mem.eql(u8, n, "URI"),
            .reference => |n| if (e.aliases.get(n)) |a| e.isStringLike(a.type) else false,
            else => false,
        };
    }

    fn flattenOr(e: *Emitter, items: []const Type, out: *std.ArrayList(Type)) Error!void {
        for (items) |it| switch (it) {
            .@"or" => |inner| try e.flattenOr(inner, out),
            else => try out.append(e.arena, it),
        };
    }

    /// `or` types. With `exact`, the union is emitted under `hint` itself
    /// (a type alias of an `or`).
    fn orExpr(e: *Emitter, items_in: []const Type, hint: []const u8, owner: ?[]const u8, exact: bool) Error![]const u8 {
        var flat: std.ArrayList(Type) = .empty;
        try e.flattenOr(items_in, &flat);
        var rest: std.ArrayList(Type) = .empty;
        var nullable = false;
        var all_strlit = true;
        for (flat.items) |it| {
            if (it.isNull()) {
                nullable = true;
                continue;
            }
            if (it != .string_literal) all_strlit = false;
            try rest.append(e.arena, it);
        }
        const opt: []const u8 = if (nullable) "?" else "";
        if (rest.items.len == 1 or (all_strlit and rest.items.len > 0)) {
            const inner = if (all_strlit) "[]const u8" else try e.typeExpr(rest.items[0], hint, owner);
            const text = if (nullable and inner[0] != '?') try cat(e.arena, opt, inner) else inner;
            if (exact) {
                try e.addDecl(hint, try std.fmt.allocPrint(e.arena, "pub const {s} = {s};", .{ try e.ident(hint), text }));
                return hint;
            }
            return text;
        }
        const name = if (exact) hint else try e.unique(hint);
        var body: std.ArrayList(u8) = .empty;
        var field_names: std.StringHashMapUnmanaged(void) = .empty;
        var sigs: std.ArrayList(struct { field: []const u8, sig: []const u8 }) = .empty;
        var notes: std.ArrayList(u8) = .empty;
        for (rest.items) |alt| {
            var fname = try e.altName(alt);
            if (field_names.contains(fname)) {
                var n: usize = 2;
                while (field_names.contains(try std.fmt.allocPrint(e.arena, "{s}_{d}", .{ fname, n }))) n += 1;
                fname = try std.fmt.allocPrint(e.arena, "{s}_{d}", .{ fname, n });
            }
            try field_names.put(e.arena, fname, {});
            const ftype = try e.typeExpr(alt, try cat(e.arena, name, try pascal(e.arena, fname)), owner);
            try body.print(e.arena, "{f}: {s},\n", .{ std.zig.fmtId(fname), ftype });
            if (try e.objectSignature(alt)) |sig| {
                for (sigs.items) |o| if (std.mem.eql(u8, o.sig, sig)) {
                    try notes.print(e.arena, "// No unique discriminator between `{s}` and `{s}`: the first listed wins.\n", .{ o.field, fname });
                };
                try sigs.append(e.arena, .{ .field = fname, .sig = sig });
            }
        }
        const text = try std.fmt.allocPrint(e.arena,
            \\pub const {s} = union(enum) {{
            \\{s}{s}
            \\pub const json_any_of = true;
            \\pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {{
            \\    return json.parseUnion(@This(), a, source, options);
            \\}}
            \\pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, options: std.json.ParseOptions) !@This() {{
            \\    return json.parseUnionFromValue(@This(), a, v, options);
            \\}}
            \\pub fn jsonStringify(self: @This(), w: *std.json.Stringify) std.json.Stringify.Error!void {{
            \\    return json.writeUnion(self, w);
            \\}}
            \\}};
        , .{ try e.ident(name), notes.items, body.items });
        try e.addDecl(name, text);
        return if (exact) name else try cat(e.arena, opt, name);
    }

    /// A field name for an `or` alternative.
    fn altName(e: *Emitter, t: Type) Error![]const u8 {
        return switch (t) {
            .base => |n| try snake(e.arena, n),
            .reference => |n| try snake(e.arena, n),
            .array => |el| try cat(e.arena, try e.altName(el.*), "_array"),
            .map => "map",
            .literal => "object",
            .tuple => "tuple",
            .@"and" => "merged",
            .@"or" => "any_of",
            .string_literal => |s| try snake(e.arena, s),
            .integer_literal => "integer",
            .boolean_literal => "boolean",
        };
    }

    /// Required keys and literal values of an object alternative, sorted;
    /// null for non-object types.
    fn objectSignature(e: *Emitter, t: Type) Error!?[]const u8 {
        var props: std.ArrayList(Property) = .empty;
        switch (t) {
            .reference => |n| {
                if (!e.structs.contains(n)) return null;
                try e.collectTypeProps(t, &props);
            },
            .literal => |p| try props.appendSlice(e.arena, p),
            else => return null,
        }
        var keys: std.ArrayList([]const u8) = .empty;
        for (props.items) |p| {
            if (p.optional) continue;
            const k = if (p.type == .string_literal) try std.fmt.allocPrint(e.arena, "{s}={s}", .{ p.name, p.type.string_literal }) else p.name;
            try keys.append(e.arena, k);
        }
        std.mem.sort([]const u8, keys.items, {}, lessThan);
        return try std.mem.join(e.arena, ",", keys.items);
    }

    // ---------------------------------------------------------------- structs

    /// Appends the properties of a structure reference or literal type,
    /// flattening `extends` and `mixins`. Later properties replace earlier
    /// ones with the same name, in place.
    fn collectTypeProps(e: *Emitter, t: Type, out: *std.ArrayList(Property)) Error!void {
        switch (t) {
            .reference => |n| {
                const s = e.structs.get(n) orelse {
                    std.log.err("lspgen: cannot flatten non-structure {s}", .{n});
                    return error.Unsupported;
                };
                for (s.extends) |x| try e.collectTypeProps(x, out);
                for (s.mixins) |x| try e.collectTypeProps(x, out);
                for (s.properties) |p| try appendProp(e.arena, out, p);
            },
            .literal => |props| for (props) |p| try appendProp(e.arena, out, p),
            else => {
                std.log.err("lspgen: cannot merge type kind {t}", .{t});
                return error.Unsupported;
            },
        }
    }

    fn appendProp(arena: Allocator, out: *std.ArrayList(Property), p: Property) Error!void {
        for (out.items) |*q| if (std.mem.eql(u8, q.name, p.name)) {
            q.* = p;
            return;
        };
        try out.append(arena, p);
    }

    fn emitStruct(e: *Emitter, name: []const u8, props: []const Property, doc: ?[]const u8, since: ?[]const u8, owner_in: ?[]const u8) Error!void {
        // A named structure owns its own cycle membership.
        const owner = if (e.structs.contains(name)) name else owner_in;
        var body: std.ArrayList(u8) = .empty;
        var literals: std.ArrayList([]const u8) = .empty;
        var nullable: std.ArrayList([]const u8) = .empty;
        for (props) |p| {
            if (!e.keep(p.proposed, p.since)) continue;
            try e.writeDoc(&body, p.documentation, p.since, p.deprecated);
            const fid = std.zig.fmtId(p.name);
            switch (p.type) {
                .string_literal => |lit| if (!p.optional) {
                    try body.print(e.arena, "{f}: []const u8 = \"{f}\",\n", .{ fid, std.zig.fmtString(lit) });
                    try literals.append(e.arena, p.name);
                    continue;
                },
                .integer_literal => |lit| if (!p.optional) {
                    try body.print(e.arena, "{f}: i32 = {d},\n", .{ fid, lit });
                    try literals.append(e.arena, p.name);
                    continue;
                },
                .boolean_literal => |lit| if (!p.optional) {
                    try body.print(e.arena, "{f}: bool = {},\n", .{ fid, lit });
                    try literals.append(e.arena, p.name);
                    continue;
                },
                else => {},
            }
            const inner = try e.typeExpr(p.type, try cat(e.arena, name, try pascal(e.arena, p.name)), owner);
            const is_opt = inner[0] == '?';
            if (p.optional) {
                try body.print(e.arena, "{f}: {s}{s} = null,\n", .{ fid, if (is_opt) "" else "?", inner });
            } else if (is_opt) {
                try body.print(e.arena, "{f}: {s} = null,\n", .{ fid, inner });
                try nullable.append(e.arena, p.name);
            } else {
                try body.print(e.arena, "{f}: {s},\n", .{ fid, inner });
            }
        }
        var text: std.ArrayList(u8) = .empty;
        try e.writeDoc(&text, doc, since, null);
        try text.print(e.arena, "pub const {f} = struct {{\n{s}", .{ std.zig.fmtId(name), body.items });
        if (literals.items.len > 0) {
            try text.appendSlice(e.arena, "/// Properties fixed to a literal value (used to tell union alternatives apart).\npub const json_literals: []const []const u8 = &.{");
            for (literals.items) |l| try text.print(e.arena, "\"{f}\",", .{std.zig.fmtString(l)});
            try text.appendSlice(e.arena, "};\n");
        }
        try text.appendSlice(e.arena, "pub fn jsonStringify(self: @This(), w: *std.json.Stringify) std.json.Stringify.Error!void {\nreturn json.writeStruct(self, w, &.{");
        for (nullable.items) |l| try text.print(e.arena, "\"{f}\",", .{std.zig.fmtString(l)});
        try text.appendSlice(e.arena, "});\n}\n};");
        try e.addDecl(name, text.items);
    }

    // ---------------------------------------------------------------- enums

    fn emitEnum(e: *Emitter, x: *const model.Enumeration) Error!void {
        var body: std.ArrayList(u8) = .empty;
        var values: std.ArrayList(u8) = .empty;
        const is_string = std.mem.eql(u8, x.base, "string");
        for (x.values) |v| {
            if (!e.keep(v.proposed, v.since)) continue;
            try e.writeDoc(&body, v.documentation, v.since, null);
            const tag = std.zig.fmtIdFlags(v.name, .{ .allow_primitive = true, .allow_underscore = true });
            switch (v.value) {
                .string => |s| {
                    try body.print(e.arena, "{f},\n", .{tag});
                    try values.print(e.arena, "\"{f}\",", .{std.zig.fmtString(s)});
                },
                .integer => |i| try body.print(e.arena, "{f} = {d},\n", .{ tag, i }),
            }
        }
        var text: std.ArrayList(u8) = .empty;
        try e.writeDoc(&text, x.documentation, x.since, null);
        const id = try e.ident(x.name);
        if (is_string) {
            const values_decl = try std.fmt.allocPrint(e.arena, "/// Wire value of each member, in declaration order.\npub const json_values = [_][]const u8{{ {s} }};\n", .{values.items});
            if (x.supports_custom_values) {
                try text.print(e.arena, "pub const {s} = json.OpenEnum(enum {{\n{s}{s}}});", .{ id, body.items, values_decl });
            } else {
                try text.print(e.arena,
                    \\pub const {s} = enum {{
                    \\{s}{s}
                    \\pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {{
                    \\    return json.parseStringEnum(@This(), a, source, options);
                    \\}}
                    \\pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, options: std.json.ParseOptions) !@This() {{
                    \\    return json.parseStringEnumFromValue(@This(), a, v, options);
                    \\}}
                    \\pub fn jsonStringify(self: @This(), w: *std.json.Stringify) std.json.Stringify.Error!void {{
                    \\    return json.writeStringEnum(self, w);
                    \\}}
                    \\}};
                , .{ id, body.items, values_decl });
            }
        } else {
            const tag = if (std.mem.eql(u8, x.base, "uinteger")) "u32" else "i32";
            try text.print(e.arena,
                \\pub const {s} = enum({s}) {{
                \\{s}_,
                \\pub const json_integer = true;
                \\pub fn jsonStringify(self: @This(), w: *std.json.Stringify) std.json.Stringify.Error!void {{
                \\    return json.writeIntEnum(self, w);
                \\}}
                \\}};
            , .{ id, tag, body.items });
        }
        try e.addDecl(x.name, text.items);
    }

    // ---------------------------------------------------------------- messages

    fn optTypeExpr(e: *Emitter, t: ?Type, hint: []const u8) Error![]const u8 {
        const tt = t orelse return "void";
        return e.typeExpr(tt, hint, null);
    }

    fn emitMessages(e: *Emitter, out: *std.ArrayList(u8), msgs: []const model.Message, comptime requests: bool) Error!void {
        var list: std.ArrayList(*const model.Message) = .empty;
        for (msgs) |*msg| if (e.keep(msg.proposed, msg.since)) try list.append(e.arena, msg);
        std.mem.sort(*const model.Message, list.items, {}, struct {
            fn lt(_: void, a: *const model.Message, b: *const model.Message) bool {
                return std.mem.lessThan(u8, a.method, b.method);
            }
        }.lt);
        const enum_name = if (requests) "Method" else "NotificationMethod";
        const info_name = if (requests) "RequestInfo" else "NotificationInfo";
        const map_name = if (requests) "method_names" else "notification_names";

        try out.print(e.arena, "/// Every {s} in the protocol, by method name.\npub const {s} = enum {{\n", .{ if (requests) "request" else "notification", enum_name });
        for (list.items) |msg| {
            try e.writeDoc(out, msg.documentation, msg.since, null);
            try out.print(e.arena, "{f},\n", .{std.zig.fmtIdFlags(msg.method, .{ .allow_primitive = true, .allow_underscore = true })});
        }
        try out.appendSlice(e.arena, "};\n\n");

        try out.print(e.arena,
            \\/// Static facts about a {s}: its params{s}, registration options, direction and the LSP version that introduced it.
            \\pub fn {s}(comptime m: {s}) type {{
            \\    return switch (m) {{
            \\
        , .{ if (requests) "request" else "notification", if (requests) ", result, partial result, error data" else "", info_name, enum_name });
        for (list.items) |msg| {
            const base = try pascal(e.arena, msg.method);
            const params = try e.optTypeExpr(msg.params, try cat(e.arena, base, "Params"));
            try out.print(e.arena, ".{f} => struct {{\npub const Params = {s};\n", .{ std.zig.fmtIdFlags(msg.method, .{ .allow_primitive = true, .allow_underscore = true }), params });
            if (requests) {
                const result = try e.optTypeExpr(msg.result, try cat(e.arena, base, "Result"));
                const partial = try e.optTypeExpr(msg.partial_result, try cat(e.arena, base, "PartialResult"));
                const err_data = try e.optTypeExpr(msg.error_data, try cat(e.arena, base, "ErrorData"));
                try out.print(e.arena, "pub const Result = {s};\npub const PartialResult = {s};\npub const ErrorData = {s};\n", .{ result, partial, err_data });
            }
            const reg = try e.optTypeExpr(msg.registration_options, try cat(e.arena, base, "RegistrationOptions"));
            try out.print(e.arena, "pub const RegistrationOptions = {s};\npub const direction: Direction = .{t};\n", .{ reg, msg.direction });
            try writeOptStr(e.arena, out, "since", msg.since);
            try writeOptStr(e.arena, out, "registration_method", msg.registration_method);
            try writeOptStr(e.arena, out, "client_capability", msg.client_capability);
            try writeOptStr(e.arena, out, "server_capability", msg.server_capability);
            try out.appendSlice(e.arena, "},\n");
        }
        try out.appendSlice(e.arena, "};\n}\n\n");

        try out.print(e.arena, "/// Looks up a {s} by its wire name.\npub const {s} = std.StaticStringMap({s}).initComptime(.{{\n", .{ enum_name, map_name, enum_name });
        for (list.items) |msg| {
            try out.print(e.arena, ".{{ \"{f}\", .{f} }},\n", .{ std.zig.fmtString(msg.method), std.zig.fmtIdFlags(msg.method, .{ .allow_primitive = true, .allow_underscore = true }) });
        }
        try out.appendSlice(e.arena, "});\n\n");
    }

    // ---------------------------------------------------------------- driver

    fn run(e: *Emitter) Error![]const u8 {
        // Named types, in sorted order so synthesized names are stable.
        var names: std.ArrayList([]const u8) = .empty;
        var sit = e.structs.keyIterator();
        while (sit.next()) |k| try names.append(e.arena, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |n| {
            const s = e.structs.get(n).?;
            var props: std.ArrayList(Property) = .empty;
            try e.collectTypeProps(.{ .reference = n }, &props);
            try e.emitStruct(n, props.items, s.documentation, s.since, n);
        }
        names.clearRetainingCapacity();
        var eit = e.enums.keyIterator();
        while (eit.next()) |k| try names.append(e.arena, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |n| try e.emitEnum(e.enums.get(n).?);
        names.clearRetainingCapacity();
        var ait = e.aliases.keyIterator();
        while (ait.next()) |k| try names.append(e.arena, k.*);
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |n| {
            const a = e.aliases.get(n).?;
            var doc: std.ArrayList(u8) = .empty;
            try e.writeDoc(&doc, a.documentation, a.since, null);
            if (special_types.get(n)) |zig_type| {
                try e.addDecl(n, try std.fmt.allocPrint(e.arena, "{s}pub const {s} = {s};", .{ doc.items, n, zig_type }));
            } else if (a.type == .@"or") {
                const before = e.decls.items.len;
                _ = try e.orExpr(a.type.@"or", n, n, true);
                // Attach the alias documentation to the emitted declaration.
                for (e.decls.items[before..]) |*d| if (std.mem.eql(u8, d.name, n)) {
                    d.text = try cat(e.arena, doc.items, d.text);
                };
            } else {
                const t = try e.typeExpr(a.type, n, n);
                try e.addDecl(n, try std.fmt.allocPrint(e.arena, "{s}pub const {s} = {s};", .{ doc.items, try e.ident(n), t }));
            }
        }

        var msgs: std.ArrayList(u8) = .empty;
        try msgs.appendSlice(e.arena,
            \\/// Who sends a request or notification.
            \\pub const Direction = enum { client_to_server, server_to_client, both };
            \\
            \\
        );
        try e.emitMessages(&msgs, e.m.requests, true);
        try e.emitMessages(&msgs, e.m.notifications, false);

        std.mem.sort(Decl, e.decls.items, {}, struct {
            fn lt(_: void, a: Decl, b: Decl) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);

        var src: std.ArrayList(u8) = .empty;
        try src.print(e.arena,
            \\//! LSP {s} protocol types. Generated by `tools/lspgen` from
            \\//! `tools/lspgen/data/{s}`; do not edit. Regenerate with `zig build lspgen`.
            \\
            \\const std = @import("std");
            \\const json = @import("../proto/json.zig");
            \\
            \\/// The meta model version these types were generated from.
            \\pub const meta_version = "{s}";
            \\
            \\
        , .{ e.m.version, e.opts.source_name, e.m.version });
        try src.appendSlice(e.arena, msgs.items);
        for (e.decls.items) |d| {
            try src.appendSlice(e.arena, d.text);
            try src.appendSlice(e.arena, "\n\n");
        }
        return format(e.arena, src.items);
    }

    fn addDecl(e: *Emitter, name: []const u8, text: []const u8) Error!void {
        try e.decls.append(e.arena, .{ .name = name, .text = text });
    }

    fn ident(e: *Emitter, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(e.arena, "{f}", .{std.zig.fmtId(name)});
    }

    /// Writes the first paragraph of `doc` as `///` lines, plus the
    /// version and deprecation notes.
    fn writeDoc(e: *Emitter, out: *std.ArrayList(u8), doc: ?[]const u8, since: ?[]const u8, deprecated: ?[]const u8) Error!void {
        var any = false;
        if (doc) |d| {
            const para = if (std.mem.indexOf(u8, d, "\n\n")) |i| d[0..i] else d;
            var it = std.mem.splitScalar(u8, std.mem.trim(u8, para, " \n\r\t"), '\n');
            while (it.next()) |line| {
                const l = std.mem.trimEnd(u8, line, " \r\t");
                if (l.len == 0) try out.appendSlice(e.arena, "///\n") else try out.print(e.arena, "/// {s}\n", .{l});
                any = true;
            }
        }
        if (since) |s| {
            if (any) try out.appendSlice(e.arena, "///\n");
            try writeLines(e.arena, out, "Since LSP ", s);
            any = true;
        }
        if (deprecated) |d| {
            if (any) try out.appendSlice(e.arena, "///\n");
            try writeLines(e.arena, out, "Deprecated: ", d);
        }
    }
};

/// Writes `text` as `///` lines, the first one prefixed with `lead`.
fn writeLines(arena: Allocator, out: *std.ArrayList(u8), lead: []const u8, text: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \n\r\t"), '\n');
    var first = true;
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \r\t");
        if (first) {
            try out.print(arena, "/// {s}{s}{s}\n", .{ lead, l, if (std.mem.eql(u8, lead, "Since LSP ") and it.peek() == null and std.mem.indexOfScalar(u8, l, ' ') == null) "." else "" });
            first = false;
        } else if (l.len == 0) {
            try out.appendSlice(arena, "///\n");
        } else try out.print(arena, "/// {s}\n", .{l});
    }
}

fn writeOptStr(arena: Allocator, out: *std.ArrayList(u8), name: []const u8, v: ?[]const u8) Error!void {
    if (v) |s| {
        try out.print(arena, "pub const {s}: ?[]const u8 = \"{f}\";\n", .{ name, std.zig.fmtString(s) });
    } else {
        try out.print(arena, "pub const {s}: ?[]const u8 = null;\n", .{name});
    }
}

/// Parses and re-renders `src` in canonical `zig fmt` style.
pub fn format(arena: Allocator, src: []const u8) Error![]const u8 {
    const z = try arena.dupeZ(u8, src);
    var tree = try std.zig.Ast.parse(arena, z, .zig);
    if (tree.errors.len > 0) {
        for (tree.errors) |pe| {
            const loc = tree.tokenLocation(0, pe.token);
            std.log.err("lspgen: generated source does not parse at {d}:{d} ({t}): {s}", .{ loc.line + 1, loc.column + 1, pe.tag, z[loc.line_start..loc.line_end] });
        }
        return error.InvalidOutput;
    }
    return tree.renderAlloc(arena);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn cat(arena: Allocator, a: []const u8, b: []const u8) Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ a, b });
}

/// `textDocument/didOpen` -> `TextDocumentDidOpen`, `kind` -> `Kind`.
pub fn pascal(arena: Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var up = true;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            up = true;
            continue;
        }
        try out.append(arena, if (up) std.ascii.toUpper(c) else c);
        up = false;
    }
    return out.items;
}

/// `TextDocumentEdit` -> `text_document_edit`, `DocumentUri` -> `document_uri`.
pub fn snake(arena: Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c)) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '_') try out.append(arena, '_');
            continue;
        }
        if (std.ascii.isUpper(c)) {
            const prev_lower = i > 0 and (std.ascii.isLower(s[i - 1]) or std.ascii.isDigit(s[i - 1]));
            const next_lower = i + 1 < s.len and std.ascii.isLower(s[i + 1]) and i > 0 and std.ascii.isUpper(s[i - 1]);
            if ((prev_lower or next_lower) and out.items.len > 0 and out.items[out.items.len - 1] != '_') try out.append(arena, '_');
            try out.append(arena, std.ascii.toLower(c));
        } else try out.append(arena, c);
    }
    return out.items;
}

/// Compares dotted versions numerically: `a <= b`.
pub fn versionLe(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return true;
        const xn = std.fmt.parseInt(u32, x orelse "0", 10) catch 0;
        const yn = std.fmt.parseInt(u32, y orelse "0", 10) catch 0;
        if (xn != yn) return xn < yn;
    }
}

test "lspgen: name helpers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("TextDocumentDidOpen", try pascal(a, "textDocument/didOpen"));
    try std.testing.expectEqualStrings("CancelRequest", try pascal(a, "$/cancelRequest"));
    try std.testing.expectEqualStrings("text_document_edit", try snake(a, "TextDocumentEdit"));
    try std.testing.expectEqualStrings("document_uri", try snake(a, "DocumentUri"));
    try std.testing.expectEqualStrings("uri", try snake(a, "URI"));
    try std.testing.expect(versionLe("3.17.0", "3.18.0"));
    try std.testing.expect(!versionLe("3.18.0", "3.17.0"));
    try std.testing.expect(versionLe("3.16.0", "3.16.0"));
}
