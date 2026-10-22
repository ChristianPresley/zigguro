//! The settings schema: the `settings_schema.zon` format every package uses
//! to declare its settings, comptime aggregation into one `SchemaRegistry`
//! with dense `SettingId`s, and validation of loaded values.
//!
//! A package's `settings_schema.zon` is `@import`ed *untyped*, so `.default`
//! can be any ZON literal. `comptimeDefs` turns each entry into a
//! `SettingDef` (missing fields take the `SettingDef` defaults) and converts
//! the default to a `Value` at comptime, so defaults are read-only data with
//! no startup parse.
//!
//! ```zig
//! .{ .package = "editor", .settings = .{
//!     .{ .key = "editor.tabSize", .type = .int, .default = 4, .minimum = 1, .maximum = 16,
//!        .scope = .language_overridable, .title = "Tab Size", .description = "..." },
//!     .{ .key = "files.exclude", .type = .object, .additional_properties = .bool,
//!        .merge = .merge_object, .default = .{ .@"**/.git" = true } },
//! } }
//! ```

const std = @import("std");
const value_mod = @import("value.zig");
const zon_load = @import("zon_load.zig");
const diag = @import("diag.zig");
const regex_lite = @import("regex_lite.zig");

const Allocator = std.mem.Allocator;
/// The dynamic value type.
pub const Value = value_mod.Value;
const Node = zon_load.Node;
const Diags = diag.Diags;

/// Dense id of a setting: its index in the registry. Static ids come first
/// (sorted by key); dynamic (extension) ids are appended and never reused.
pub const SettingId = enum(u32) {
    _,

    /// The id as an array index.
    pub fn index(id: SettingId) u32 {
        return @intFromEnum(id);
    }
};

/// The value type of a setting.
pub const SettingType = enum {
    bool,
    int,
    float,
    string,
    enum_,
    array,
    object,
    /// `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` or `oklch(...)`.
    color,
    /// A path; `~` and `${workspaceFolder}`/`${env:NAME}` are allowed, not resolved here.
    path,
    /// A glob pattern (syntax-checked).
    glob,
    /// A key spec such as `mod+shift+p` (E15.F04).
    keybinding,
    /// A command id; existence is checked at use time.
    command_id,
    /// A when-clause (E15.F03).
    when_clause,
    any,
};

/// Where a setting may be set. See `docs/settings-model.md`.
pub const Scope = enum { application, machine, machine_overridable, window, resource, language_overridable };

/// How values from several layers combine.
pub const Merge = enum { replace, merge_object, concat_unique };

/// How the settings editor edits a setting.
pub const EditHint = enum { auto, multiline, file_only };

/// One declared setting.
pub const SettingDef = struct {
    key: []const u8,
    type: SettingType,
    default: Value = .null,
    title: []const u8 = "",
    description: []const u8 = "",
    markdown_description: ?[]const u8 = null,
    enum_values: []const []const u8 = &.{},
    enum_descriptions: []const []const u8 = &.{},
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    pattern: ?[]const u8 = null,
    min_items: ?u32 = null,
    max_items: ?u32 = null,
    items: ?SettingType = null,
    /// Object sub-schema; keys are relative to the setting.
    properties: []const SettingDef = &.{},
    additional_properties: ?SettingType = null,
    scope: Scope = .window,
    /// Ignored in untrusted workspaces (E16).
    restricted: bool = false,
    merge: Merge = .replace,
    tags: []const []const u8 = &.{},
    order: i32 = 0,
    deprecated: ?[]const u8 = null,
    replaced_by: ?[]const u8 = null,
    edit: EditHint = .auto,
    platform: ?[]const std.Target.Os.Tag = null,
    /// The declaring package (filled by `comptimeDefs`) or extension.
    package: []const u8 = "",
};

/// Converts an anonymous ZON literal to a `Value` at comptime.
pub fn comptimeValue(comptime v: anytype) Value {
    comptime {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .comptime_int, .int => return .{ .int = v },
            .comptime_float, .float => return .{ .float = v },
            .bool => return .{ .bool = v },
            .null => return .null,
            .optional => return if (v) |x| comptimeValue(x) else .null,
            .enum_literal => return .{ .enum_lit = @tagName(v) },
            .@"enum" => return .{ .enum_lit = @tagName(v) },
            .pointer => |p| {
                if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8)
                    return .{ .string = v };
                if (p.size == .slice and p.child == u8) return .{ .string = v };
                @compileError("unsupported ZON value of type " ++ @typeName(T));
            },
            .@"struct" => |s| {
                if (s.is_tuple and s.fields.len > 0) {
                    var arr: [s.fields.len]Value = undefined;
                    for (s.fields, 0..) |f, i| arr[i] = comptimeValue(@field(v, f.name));
                    const final = arr;
                    return .{ .array = &final };
                }
                var fields: [s.fields.len]Value.Field = undefined;
                for (s.fields, 0..) |f, i| fields[i] = .{ .key = f.name, .value = comptimeValue(@field(v, f.name)) };
                value_mod.sortFields(&fields);
                const final = fields;
                return .{ .object = &final };
            },
            else => @compileError("unsupported ZON value of type " ++ @typeName(T)),
        }
    }
}

/// Converts one package's untyped schema literal to `SettingDef`s, checking
/// every default against its declared type at comptime.
pub fn comptimeDefs(comptime schema: anytype) []const SettingDef {
    comptime {
        @setEvalBranchQuota(200_000);
        const pkg: []const u8 = if (@hasField(@TypeOf(schema), "package")) schema.package else "";
        const entries = schema.settings;
        const n = @typeInfo(@TypeOf(entries)).@"struct".fields.len;
        var defs: [n]SettingDef = undefined;
        for (0..n) |i| {
            defs[i] = defFromEntry(entries[i], pkg);
            if (checkDefault(&defs[i])) |msg|
                @compileError(pkg ++ ": default of '" ++ defs[i].key ++ "' " ++ msg);
        }
        const final = defs;
        return &final;
    }
}

fn defFromEntry(comptime e: anytype, comptime pkg: []const u8) SettingDef {
    comptime {
        var d: SettingDef = .{ .key = e.key, .type = e.type, .package = pkg };
        for (@typeInfo(SettingDef).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "key") or std.mem.eql(u8, f.name, "type") or std.mem.eql(u8, f.name, "package")) continue;
            if (!@hasField(@TypeOf(e), f.name)) continue;
            @field(d, f.name) = coerce(f.type, @field(e, f.name), pkg);
        }
        for (@typeInfo(@TypeOf(e)).@"struct".fields) |f| {
            if (!@hasField(SettingDef, f.name)) @compileError(pkg ++ ": unknown schema field '" ++ f.name ++ "' in '" ++ e.key ++ "'");
        }
        // `.{}` defaults to an empty object; an array setting wants an empty array.
        if (d.type == .array and d.default == .object and d.default.object.len == 0) d.default = .{ .array = &.{} };
        return d;
    }
}

fn coerce(comptime T: type, comptime v: anytype, comptime pkg: []const u8) T {
    comptime {
        if (T == Value) return comptimeValue(v);
        if (T == []const SettingDef) {
            const n = @typeInfo(@TypeOf(v)).@"struct".fields.len;
            var arr: [n]SettingDef = undefined;
            for (0..n) |i| arr[i] = defFromEntry(v[i], pkg);
            const final = arr;
            return &final;
        }
        switch (@typeInfo(T)) {
            .optional => |o| return coerce(o.child, v, pkg),
            .pointer => |p| if (p.size == .slice and p.child != u8) {
                const n = @typeInfo(@TypeOf(v)).@"struct".fields.len;
                var arr: [n]p.child = undefined;
                for (0..n) |i| arr[i] = coerce(p.child, v[i], pkg);
                const final = arr;
                return &final;
            },
            else => {},
        }
        return v;
    }
}

/// Comptime check of a default; returns an error message or null.
fn checkDefault(comptime d: *const SettingDef) ?[]const u8 {
    comptime {
        if (d.default == .null) return null;
        var buf: [256]u8 = undefined;
        if (checkValue(d, d.default, &buf)) |m| return m;
        return null;
    }
}

/// Validates `v` against `d` without diagnostics; returns a message on error.
/// Used at comptime for defaults and at runtime for args.
pub fn checkValue(d: *const SettingDef, v: Value, buf: []u8) ?[]const u8 {
    return checkTyped(d.type, d, v, buf);
}

fn checkTyped(t: SettingType, d: ?*const SettingDef, v: Value, buf: []u8) ?[]const u8 {
    switch (t) {
        .any => return null,
        .bool => if (v != .bool) return "must be a bool",
        .int => switch (v) {
            .int => |i| return checkRange(d, @floatFromInt(i), buf),
            .float => |f| {
                if (f != @trunc(f)) return "must be an integer";
                return checkRange(d, f, buf);
            },
            else => return "must be an integer",
        },
        .float => switch (v) {
            .int => |i| return checkRange(d, @floatFromInt(i), buf),
            .float => |f| return checkRange(d, f, buf),
            else => return "must be a number",
        },
        .string, .path, .command_id, .keybinding, .when_clause => {
            if (v != .string) return "must be a string";
            if (d) |def| if (def.pattern) |pat| {
                const re = regex_lite.Regex.compile(pat, false) catch return "has an invalid pattern in its schema";
                if (!re.isMatch(v.string)) return std.fmt.bufPrint(buf, "must match /{s}/", .{pat}) catch "must match the pattern";
            };
        },
        .glob => {
            if (v != .string) return "must be a glob string";
            if (globError(v.string)) |m| return m;
        },
        .color => {
            if (v != .string) return "must be a color string";
            if (!isColor(v.string)) return "must be a color (#RGB, #RGBA, #RRGGBB, #RRGGBBAA or oklch(...))";
        },
        .enum_ => {
            const s = switch (v) {
                .string, .enum_lit => |s| s,
                else => return "must be one of the allowed values",
            };
            if (d) |def| {
                for (def.enum_values) |ev| {
                    if (std.mem.eql(u8, ev, s)) return null;
                }
                return "must be one of the allowed values";
            }
        },
        .array => {
            const xs = switch (v) {
                .array => |a| a,
                .object => |o| if (o.len == 0) &[_]Value{} else return "must be an array",
                else => return "must be an array",
            };
            if (d) |def| {
                if (def.min_items) |m| if (xs.len < m) return std.fmt.bufPrint(buf, "needs at least {d} items", .{m}) catch "too few items";
                if (def.max_items) |m| if (xs.len > m) return std.fmt.bufPrint(buf, "allows at most {d} items", .{m}) catch "too many items";
                if (def.items) |it| for (xs) |x| {
                    if (checkTyped(it, null, x, buf)) |m| return m;
                };
            }
        },
        .object => {
            if (v != .object) return "must be an object";
            if (d) |def| for (v.object) |f| {
                if (findProp(def.properties, f.key)) |p| {
                    if (checkValue(p, f.value, buf)) |m| return m;
                } else if (def.additional_properties) |ap| {
                    if (checkTyped(ap, null, f.value, buf)) |m| return m;
                } else if (def.properties.len > 0) return "has an unknown property";
            };
        },
    }
    return null;
}

fn checkRange(d: ?*const SettingDef, x: f64, buf: []u8) ?[]const u8 {
    const def = d orelse return null;
    if (def.minimum) |m| if (x < m) return std.fmt.bufPrint(buf, "must be >= {d}", .{m}) catch "is too small";
    if (def.maximum) |m| if (x > m) return std.fmt.bufPrint(buf, "must be <= {d}", .{m}) catch "is too large";
    return null;
}

fn findProp(props: []const SettingDef, key: []const u8) ?*const SettingDef {
    for (props) |*p| if (std.mem.eql(u8, p.key, key)) return p;
    return null;
}

/// Whether `s` is a supported color literal.
pub fn isColor(s: []const u8) bool {
    if (s.len > 0 and s[0] == '#') {
        const hex = s[1..];
        if (hex.len != 3 and hex.len != 4 and hex.len != 6 and hex.len != 8) return false;
        for (hex) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    if (std.mem.startsWith(u8, s, "oklch(") and std.mem.endsWith(u8, s, ")")) {
        var it = std.mem.tokenizeAny(u8, s[6 .. s.len - 1], " ,/");
        var n: u32 = 0;
        while (it.next()) |tok| : (n += 1) {
            const t = std.mem.trimEnd(u8, tok, "%");
            _ = std.fmt.parseFloat(f64, t) catch return false;
        }
        return n == 3 or n == 4;
    }
    return false;
}

/// A syntax error message for glob `g`, or null. Checks balanced `[]`/`{}`
/// and no empty pattern.
pub fn globError(g: []const u8) ?[]const u8 {
    if (g.len == 0) return "must not be empty";
    var brace: i32 = 0;
    var i: usize = 0;
    while (i < g.len) : (i += 1) switch (g[i]) {
        '\\' => i += 1,
        '[' => {
            const close = std.mem.indexOfScalarPos(u8, g, i + 1, ']') orelse return "has an unterminated '['";
            i = close;
        },
        '{' => brace += 1,
        '}' => {
            brace -= 1;
            if (brace < 0) return "has an unbalanced '}'";
        },
        else => {},
    };
    if (brace != 0) return "has an unbalanced '{'";
    return null;
}

/// Who added a dynamic setting.
pub const Owner = union(enum) { extension: []const u8, test_only };

/// The aggregate of every package schema plus dynamically added settings.
pub const SchemaRegistry = struct {
    /// Static defs sorted by key; index == SettingId.
    defs: []const SettingDef,
    by_key: std.StaticStringMap(SettingId),
    /// Default per static id.
    defaults: []const Value,
    dynamic: Dynamic = .{},

    const Dynamic = struct {
        defs: std.ArrayList(SettingDef) = .empty,
        owners: std.ArrayList(?Owner) = .empty,
        map: std.StringHashMapUnmanaged(SettingId) = .empty,
        arena: ?*std.heap.ArenaAllocator = null,
    };

    /// Aggregates a tuple of untyped schema literals at comptime. Duplicate
    /// keys are a compile error naming both packages.
    pub fn comptimeInit(comptime schemas: anytype) SchemaRegistry {
        comptime {
            @setEvalBranchQuota(1_000_000);
            var total = 0;
            for (schemas) |s| total += comptimeDefs(s).len;
            var all: [total]SettingDef = undefined;
            var n = 0;
            for (schemas) |s| for (comptimeDefs(s)) |d| {
                all[n] = d;
                n += 1;
            };
            std.sort.insertion(SettingDef, &all, {}, struct {
                fn lt(_: void, a: SettingDef, b: SettingDef) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.lt);
            for (1..total) |i| if (std.mem.eql(u8, all[i - 1].key, all[i].key))
                @compileError("duplicate setting '" ++ all[i].key ++ "' declared by packages '" ++ all[i - 1].package ++ "' and '" ++ all[i].package ++ "'");
            var kvs: [total]struct { []const u8, SettingId } = undefined;
            var defaults: [total]Value = undefined;
            for (all, 0..) |d, i| {
                kvs[i] = .{ d.key, @enumFromInt(i) };
                defaults[i] = d.default;
            }
            const final_defs = all;
            const final_defaults = defaults;
            return .{
                .defs = &final_defs,
                .by_key = .initComptime(kvs),
                .defaults = &final_defaults,
            };
        }
    }

    /// Frees dynamic registrations.
    pub fn deinit(r: *SchemaRegistry, gpa: Allocator) void {
        r.dynamic.defs.deinit(gpa);
        r.dynamic.owners.deinit(gpa);
        r.dynamic.map.deinit(gpa);
        if (r.dynamic.arena) |a| {
            a.deinit();
            gpa.destroy(a);
        }
        r.dynamic = .{};
    }

    /// Number of ids (static + dynamic, including tombstones).
    pub fn count(r: *const SchemaRegistry) u32 {
        return @intCast(r.defs.len + r.dynamic.defs.items.len);
    }

    /// Adds extension-contributed settings after the static range. Defs and
    /// their strings are copied. Keys already registered are skipped with
    /// `error.DuplicateKey` after adding the others.
    pub fn addDynamic(r: *SchemaRegistry, gpa: Allocator, defs: []const SettingDef, owner: Owner) error{ OutOfMemory, DuplicateKey }!void {
        if (r.dynamic.arena == null) {
            const a = try gpa.create(std.heap.ArenaAllocator);
            a.* = .init(gpa);
            r.dynamic.arena = a;
        }
        const arena = r.dynamic.arena.?.allocator();
        var dup = false;
        for (defs) |d| {
            if (r.lookup(d.key) != null) {
                dup = true;
                continue;
            }
            var copy = d;
            copy.key = try arena.dupe(u8, d.key);
            copy.default = try d.default.clone(arena);
            const id: SettingId = @enumFromInt(r.count());
            try r.dynamic.defs.append(gpa, copy);
            try r.dynamic.owners.append(gpa, owner);
            try r.dynamic.map.put(gpa, copy.key, id);
        }
        if (dup) return error.DuplicateKey;
    }

    /// Removes every dynamic setting of `owner`. Their ids become tombstones
    /// (never reused); `lookup` no longer finds them.
    pub fn removeDynamic(r: *SchemaRegistry, owner: Owner) void {
        for (r.dynamic.owners.items, 0..) |*o, i| {
            const cur = o.* orelse continue;
            if (!ownerEql(cur, owner)) continue;
            _ = r.dynamic.map.remove(r.dynamic.defs.items[i].key);
            o.* = null;
        }
    }

    fn ownerEql(a: Owner, b: Owner) bool {
        return switch (a) {
            .test_only => b == .test_only,
            .extension => |x| b == .extension and std.mem.eql(u8, x, b.extension),
        };
    }

    /// The id of `key`, static first, then dynamic.
    pub fn lookup(r: *const SchemaRegistry, key: []const u8) ?SettingId {
        if (r.by_key.get(key)) |id| return id;
        return r.dynamic.map.get(key);
    }

    /// The definition of `id`.
    pub fn def(r: *const SchemaRegistry, id: SettingId) *const SettingDef {
        const i = id.index();
        if (i < r.defs.len) return &r.defs[i];
        return &r.dynamic.defs.items[i - r.defs.len];
    }

    /// The default value of `id`.
    pub fn default(r: *const SchemaRegistry, id: SettingId) Value {
        const i = id.index();
        if (i < r.defaults.len) return r.defaults[i];
        return r.dynamic.defs.items[i - r.defs.len].default;
    }

    /// Whether `id` is a removed dynamic setting.
    pub fn isTombstone(r: *const SchemaRegistry, id: SettingId) bool {
        const i = id.index();
        return i >= r.defs.len and r.dynamic.owners.items[i - r.defs.len] == null;
    }

    /// The closest key to `key` sharing its first segment (Damerau-Levenshtein ≤ 2).
    pub fn suggest(r: *const SchemaRegistry, key: []const u8) ?[]const u8 {
        const seg = key[0 .. std.mem.indexOfScalar(u8, key, '.') orelse key.len];
        var best: ?[]const u8 = null;
        var best_d: usize = 3;
        for (0..r.count()) |i| {
            const k = r.def(@enumFromInt(i)).key;
            if (!std.mem.startsWith(u8, k, seg)) continue;
            const dist = editDistance(key, k, best_d);
            if (dist < best_d) {
                best_d = dist;
                best = k;
            }
        }
        return best;
    }

    /// Validates node `n` (spans for diagnostics) for setting `id` and
    /// returns its value in `arena`, or null when invalid (the store then
    /// falls back to the next lower layer). Warnings do not reject.
    pub fn validate(r: *const SchemaRegistry, arena: Allocator, id: SettingId, n: Node, diags: *Diags) error{OutOfMemory}!?Value {
        const d = r.def(id);
        if (d.deprecated) |why| {
            if (d.replaced_by) |nk| diags.add(n.span, .warning, "'{s}' is deprecated ({s}); use '{s}'", .{ d.key, why, nk }) else diags.add(n.span, .warning, "'{s}' is deprecated: {s}", .{ d.key, why });
        }
        return validateNode(arena, d.type, d, n, diags);
    }
};

fn validateNode(arena: Allocator, t: SettingType, d: ?*const SettingDef, n: Node, diags: *Diags) error{OutOfMemory}!?Value {
    const key = if (d) |x| x.key else "item";
    // Element-level checks with spans for containers, then the scalar check.
    switch (t) {
        .array => if (n.v == .array) {
            if (d) |def| if (def.items) |it| {
                const out = try arena.alloc(Value, n.v.array.len);
                for (n.v.array, out) |x, *o| {
                    o.* = (try validateNode(arena, it, null, x, diags)) orelse return null;
                }
                var buf: [128]u8 = undefined;
                if (checkTyped(.array, def, .{ .array = out }, &buf)) |m| {
                    diags.add(n.span, .err, "'{s}' {s}", .{ key, m });
                    return null;
                }
                return .{ .array = out };
            };
        },
        .object => if (n.v == .object) if (d) |def| if (def.properties.len > 0 or def.additional_properties != null) {
            for (n.v.object) |f| {
                if (findProp(def.properties, f.key)) |p| {
                    if (try validateNode(arena, p.type, p, f.value, diags) == null) return null;
                } else if (def.additional_properties) |ap| {
                    if (try validateNode(arena, ap, null, f.value, diags) == null) return null;
                } else {
                    diags.add(f.key_span, .err, "'{s}' has no property '{s}'", .{ key, f.key });
                    return null;
                }
            }
        },
        else => {},
    }
    const v = try zon_load.toValue(arena, n);
    var buf: [128]u8 = undefined;
    if (checkTyped(t, d, v, &buf)) |m| {
        diags.add(n.span, .err, "'{s}' {s}", .{ key, m });
        return null;
    }
    if (t == .int and v == .float) {
        diags.add(n.span, .warning, "'{s}' should be written as an integer", .{key});
        return .{ .int = @intFromFloat(v.float) };
    }
    if (t == .float and v == .int) return .{ .float = @floatFromInt(v.int) };
    // Enum settings store the value as written; normalize to a string.
    if (t == .enum_ and v == .enum_lit) return .{ .string = v.enum_lit };
    if (t == .array and v == .object) return .{ .array = &.{} };
    return v;
}

/// Optimal string alignment distance, giving up (returning `limit`) once it
/// cannot be below `limit`.
pub fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
    if (a.len > b.len + limit or b.len > a.len + limit) return limit;
    if (b.len > 128) return limit;
    var prev2: [129]usize = undefined;
    var prev: [129]usize = undefined;
    var cur: [129]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 1..) |ca, i| {
        cur[0] = i;
        var row_min = cur[0];
        for (b, 1..) |cb, j| {
            const cost: usize = @intFromBool(ca != cb);
            var v = @min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
            if (i > 1 and j > 1 and ca == b[j - 2] and a[i - 2] == cb) v = @min(v, prev2[j - 2] + 1);
            cur[j] = v;
            row_min = @min(row_min, v);
        }
        if (row_min >= limit) return limit;
        prev2 = prev;
        prev = cur;
    }
    return @min(prev[b.len], limit);
}

const test_schema_a = .{ .package = "editor", .settings = .{
    .{ .key = "editor.tabSize", .type = .int, .default = 4, .minimum = 1, .maximum = 16, .scope = .language_overridable, .title = "Tab Size", .tags = .{"indentation"} },
    .{ .key = "editor.wordWrap", .type = .enum_, .enum_values = .{ "off", "on", "bounded" }, .default = "off" },
    .{ .key = "editor.rulers", .type = .array, .items = .int, .default = .{} },
    .{ .key = "editor.fontSize", .type = .float, .default = 14 },
    .{ .key = "editor.oldThing", .type = .bool, .default = false, .deprecated = "renamed", .replaced_by = "editor.newThing" },
} };
const test_schema_b = .{ .package = "files", .settings = .{
    .{ .key = "files.exclude", .type = .object, .additional_properties = .bool, .merge = .merge_object, .default = .{ .@"**/.git" = true } },
    .{ .key = "workbench.colorTheme", .type = .string, .default = "zigguro-dark", .pattern = "^[a-z-]+$" },
    .{ .key = "workbench.accent", .type = .color, .default = "#336699" },
    .{ .key = "lsp.servers", .type = .object, .properties = .{
        .{ .key = "cmd", .type = .array, .items = .string },
        .{ .key = "enabled", .type = .bool },
    }, .additional_properties = .any, .default = .{} },
} };

/// A registry over two small test schemas (used by tests in other files).
pub const test_registry = SchemaRegistry.comptimeInit(.{ test_schema_a, test_schema_b });

test "schema: comptime aggregation sorts and indexes" {
    const r = test_registry;
    try std.testing.expectEqual(@as(u32, 9), r.count());
    var prev: []const u8 = "";
    for (r.defs) |d| {
        try std.testing.expect(std.mem.order(u8, prev, d.key) == .lt);
        prev = d.key;
    }
    const id = r.lookup("editor.tabSize").?;
    try std.testing.expectEqualStrings("editor.tabSize", r.def(id).key);
    try std.testing.expectEqualStrings("editor", r.def(id).package);
    try std.testing.expectEqual(@as(i64, 4), r.default(id).int);
    try std.testing.expectEqual(Scope.language_overridable, r.def(id).scope);
    try std.testing.expectEqualStrings("indentation", r.def(id).tags[0]);
    try std.testing.expect(r.lookup("nope") == null);
    try std.testing.expect(@inComptime() == false);
    // Defaults are comptime data: the registry value itself is a comptime constant.
    comptime std.debug.assert(test_registry.defaults.len == 9);
}

test "schema: comptimeValue table" {
    const v = comptime comptimeValue(.{ .b = 1, .a = .{ 1.5, true, null, .on, "s" }, .@"x.y" = .{} });
    try std.testing.expectEqualStrings("a", v.object[0].key);
    const arr = v.object[0].value.array;
    try std.testing.expectEqual(@as(f64, 1.5), arr[0].float);
    try std.testing.expect(arr[1].bool);
    try std.testing.expect(arr[2] == .null);
    try std.testing.expectEqualStrings("on", arr[3].enum_lit);
    try std.testing.expectEqualStrings("s", arr[4].string);
    try std.testing.expectEqual(@as(usize, 0), v.get("x.y").?.object.len);
    const rulers = test_registry.default(test_registry.lookup("editor.rulers").?);
    try std.testing.expectEqual(@as(usize, 0), rulers.array.len);
    try std.testing.expect(test_registry.default(test_registry.lookup("files.exclude").?).get("**/.git").?.bool);
}

fn validateText(src: [:0]const u8, key: []const u8) !struct { ?Value, Diags, std.heap.ArenaAllocator } {
    var d = Diags.init(std.testing.allocator);
    errdefer d.deinit();
    var doc = try zon_load.loadZon(std.testing.allocator, src, &d);
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    errdefer arena.deinit();
    const v = try test_registry.validate(arena.allocator(), test_registry.lookup(key).?, doc.root.get("v").?, &d);
    // Values reference the doc arena; clone them out before it is freed.
    return .{ if (v) |x| try x.clone(arena.allocator()) else null, d, arena };
}

fn expectValid(src: [:0]const u8, key: []const u8, ok: bool) !void {
    const v, var d, var a = try validateText(src, key);
    defer d.deinit();
    defer a.deinit();
    if ((v != null) != ok) {
        for (d.items()) |x| std.debug.print("diag: {s}\n", .{x.message});
        return error.TestUnexpectedResult;
    }
}

test "validate: each type ok/err" {
    try expectValid(".{ .v = 3 }", "editor.tabSize", true);
    try expectValid(".{ .v = 0 }", "editor.tabSize", false);
    try expectValid(".{ .v = 17 }", "editor.tabSize", false);
    try expectValid(".{ .v = \"x\" }", "editor.tabSize", false);
    try expectValid(".{ .v = 3.0 }", "editor.tabSize", true);
    try expectValid(".{ .v = 3.5 }", "editor.tabSize", false);
    try expectValid(".{ .v = 12 }", "editor.fontSize", true);
    try expectValid(".{ .v = .on }", "editor.wordWrap", true);
    try expectValid(".{ .v = \"bounded\" }", "editor.wordWrap", true);
    try expectValid(".{ .v = .sometimes }", "editor.wordWrap", false);
    try expectValid(".{ .v = .{ 80, 120 } }", "editor.rulers", true);
    try expectValid(".{ .v = .{} }", "editor.rulers", true);
    try expectValid(".{ .v = .{ 80, \"x\" } }", "editor.rulers", false);
    try expectValid(".{ .v = .{ .@\"*.o\" = true } }", "files.exclude", true);
    try expectValid(".{ .v = .{ .@\"*.o\" = 1 } }", "files.exclude", false);
    try expectValid(".{ .v = .{ .zls = .{ .x = 1 } } }", "lsp.servers", true);
    try expectValid(".{ .v = true }", "editor.oldThing", true);
}

test "validate: pattern via regex_lite" {
    try expectValid(".{ .v = \"one-dark\" }", "workbench.colorTheme", true);
    try expectValid(".{ .v = \"One Dark\" }", "workbench.colorTheme", false);
}

test "validate: color forms" {
    for ([_][:0]const u8{ ".{ .v = \"#abc\" }", ".{ .v = \"#abcd\" }", ".{ .v = \"#aabbcc\" }", ".{ .v = \"#aabbccdd\" }", ".{ .v = \"oklch(70% 0.1 250)\" }", ".{ .v = \"oklch(0.7 0.1 250 / 0.5)\" }" }) |s|
        try expectValid(s, "workbench.accent", true);
    for ([_][:0]const u8{ ".{ .v = \"#ab\" }", ".{ .v = \"red\" }", ".{ .v = \"#ggg\" }", ".{ .v = \"oklch(1 2)\" }" }) |s|
        try expectValid(s, "workbench.accent", false);
}

test "validate: diagnostics carry spans; deprecated warns" {
    const src = ".{ .v = 99 }";
    const v, var d, var a = try validateText(src, "editor.tabSize");
    defer d.deinit();
    defer a.deinit();
    try std.testing.expect(v == null);
    try std.testing.expectEqualStrings("99", d.items()[0].span.slice(src));
    try std.testing.expect(d.contains("<= 16"));
    const v2, var d2, var a2 = try validateText(".{ .v = true }", "editor.oldThing");
    defer d2.deinit();
    defer a2.deinit();
    try std.testing.expect(v2 != null);
    try std.testing.expect(d2.contains("editor.newThing"));
}

test "validate: unknown key did-you-mean" {
    try std.testing.expectEqualStrings("editor.tabSize", test_registry.suggest("editor.tabsize").?);
    try std.testing.expectEqualStrings("editor.fontSize", test_registry.suggest("editor.fontSzie").?);
    try std.testing.expect(test_registry.suggest("terminal.tabSize") == null);
}

test "schema: dynamic settings and tombstones" {
    var r = test_registry;
    defer r.deinit(std.testing.allocator);
    try r.addDynamic(std.testing.allocator, &.{.{ .key = "ext.hello.greeting", .type = .string, .default = .{ .string = "hi" } }}, .{ .extension = "hello" });
    const id = r.lookup("ext.hello.greeting").?;
    try std.testing.expectEqual(@as(u32, 9), id.index());
    try std.testing.expectEqualStrings("hi", r.default(id).string);
    try std.testing.expectError(error.DuplicateKey, r.addDynamic(std.testing.allocator, &.{.{ .key = "editor.tabSize", .type = .int }}, .test_only));
    r.removeDynamic(.{ .extension = "hello" });
    try std.testing.expect(r.lookup("ext.hello.greeting") == null);
    try std.testing.expect(r.isTombstone(id));
    try r.addDynamic(std.testing.allocator, &.{.{ .key = "ext.hello.greeting", .type = .string }}, .{ .extension = "hello" });
    try std.testing.expectEqual(@as(u32, 10), r.lookup("ext.hello.greeting").?.index());
}

test "schema: editDistance" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("abc", "acb", 3));
    try std.testing.expectEqual(@as(usize, 0), editDistance("abc", "abc", 3));
    try std.testing.expectEqual(@as(usize, 3), editDistance("abc", "xyzw", 3));
}
