//! Semantic-token legends: a server's token type and modifier names,
//! compiled to highlight ids.
//!
//! Standard LSP types map to the fixed highlight vocabulary (`method` to
//! `function.method`, `parameter` to `variable.parameter`, ...); unknown
//! types become `semantic.<name>`. One modifier refines the name, chosen
//! by priority: `defaultLibrary` turns `function`, `variable`, `type` and
//! `constant` names into their `.builtin` form, and otherwise the first
//! set modifier among deprecated, readonly, static, abstract, async,
//! declaration, definition, modification, documentation (then custom ones
//! in legend order) is appended, as in `variable.readonly`. Themes resolve
//! by dotted prefix, so unstyled refinements fall back to the base.

const std = @import("std");
const names_mod = @import("../highlight_names.zig");

const Allocator = std.mem.Allocator;
const HighlightId = names_mod.HighlightId;
const HighlightNames = names_mod.HighlightNames;

/// A server's `SemanticTokensLegend`.
pub const Legend = struct {
    types: []const []const u8,
    modifiers: []const []const u8,

    /// Compiles the legend against `names` (which must outlive the result).
    pub fn compile(l: Legend, gpa: Allocator, names: *HighlightNames) !CompiledLegend {
        var c: CompiledLegend = .{ .gpa = gpa, .names = names };
        errdefer c.deinit();
        try c.types.ensureTotalCapacity(gpa, l.types.len);
        for (l.types) |t| {
            const base = try baseName(gpa, t);
            errdefer gpa.free(base);
            c.types.appendAssumeCapacity(.{ .name = base, .id = try names.intern(base) });
        }
        try c.mods.ensureTotalCapacity(gpa, l.modifiers.len);
        for (l.modifiers) |m| c.mods.appendAssumeCapacity(try gpa.dupe(u8, m));
        // Modifier bits in priority order.
        for (priority) |p| for (c.mods.items, 0..) |m, bit| if (std.mem.eql(u8, m, p) and bit < 32) try c.order.append(gpa, @intCast(bit));
        for (c.mods.items, 0..) |m, bit| {
            if (bit >= 32) break;
            if (!isStandard(m)) try c.order.append(gpa, @intCast(bit));
        }
        return c;
    }
};

const standard_types = [_][2][]const u8{
    .{ "namespace", "type.namespace" }, .{ "class", "type.class" },
    .{ "enum", "type.enum" },           .{ "interface", "type.interface" },
    .{ "struct", "type.struct" },       .{ "typeParameter", "type.parameter" },
    .{ "type", "type" },                .{ "parameter", "variable.parameter" },
    .{ "variable", "variable" },        .{ "property", "property" },
    .{ "enumMember", "constant.enum" }, .{ "decorator", "attribute" },
    .{ "event", "property.event" },     .{ "function", "function" },
    .{ "method", "function.method" },   .{ "macro", "function.macro" },
    .{ "label", "label" },              .{ "comment", "comment" },
    .{ "string", "string" },            .{ "keyword", "keyword" },
    .{ "number", "number" },            .{ "regexp", "string.regexp" },
    .{ "operator", "operator" },        .{ "modifier", "keyword.storage" },
};

/// Standard modifiers that refine a name, most important first
/// (`defaultLibrary` is handled separately).
const priority = [_][]const u8{ "defaultLibrary", "deprecated", "readonly", "static", "abstract", "async", "declaration", "definition", "modification", "documentation" };

fn isStandard(m: []const u8) bool {
    for (priority) |p| if (std.mem.eql(u8, p, m)) return true;
    return false;
}

fn baseName(gpa: Allocator, t: []const u8) ![]u8 {
    for (standard_types) |s| if (std.mem.eql(u8, s[0], t)) return gpa.dupe(u8, s[1]);
    return std.fmt.allocPrint(gpa, "semantic.{s}", .{t});
}

/// A legend resolved to highlight ids; combinations are cached.
pub const CompiledLegend = struct {
    gpa: Allocator,
    names: *HighlightNames,
    types: std.ArrayList(struct { name: []u8, id: HighlightId }) = .empty,
    mods: std.ArrayList([]u8) = .empty,
    /// Modifier bits to consider, most important first.
    order: std.ArrayList(u5) = .empty,
    cache: std.AutoHashMapUnmanaged(u64, HighlightId) = .empty,

    /// Frees the legend.
    pub fn deinit(c: *CompiledLegend) void {
        for (c.types.items) |t| c.gpa.free(t.name);
        c.types.deinit(c.gpa);
        for (c.mods.items) |m| c.gpa.free(m);
        c.mods.deinit(c.gpa);
        c.order.deinit(c.gpa);
        c.cache.deinit(c.gpa);
        c.* = undefined;
    }

    /// The highlight for token type `ty` with modifier bits `mods`;
    /// `none` for a type outside the legend.
    pub fn resolve(c: *CompiledLegend, ty: u32, mods: u32) Allocator.Error!HighlightId {
        if (ty >= c.types.items.len) return .none;
        const t = c.types.items[ty];
        const bit = for (c.order.items) |b| {
            if (mods & (@as(u32, 1) << b) != 0) break b;
        } else return t.id;
        const key = (@as(u64, ty) << 32) | bit;
        if (c.cache.get(key)) |id| return id;
        const m = c.mods.items[bit];
        const family = t.name[0 .. std.mem.indexOfScalar(u8, t.name, '.') orelse t.name.len];
        const builtin_family = for ([_][]const u8{ "function", "variable", "type", "constant" }) |f| {
            if (std.mem.eql(u8, f, family)) break true;
        } else false;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(c.gpa);
        if (std.mem.eql(u8, m, "defaultLibrary") and builtin_family) {
            try buf.print(c.gpa, "{s}.builtin", .{family});
        } else {
            try buf.print(c.gpa, "{s}.{s}", .{ t.name, m });
        }
        const id = try c.names.intern(buf.items);
        try c.cache.put(c.gpa, key, id);
        return id;
    }
};

test "legend: modifier bit mapping" {
    const gpa = std.testing.allocator;
    var names: HighlightNames = .init(gpa);
    defer names.deinit();
    var c = try (Legend{
        .types = &.{ "variable", "function", "method", "lifetime", "class" },
        .modifiers = &.{ "declaration", "readonly", "defaultLibrary", "mutable" },
    }).compile(gpa, &names);
    defer c.deinit();
    try std.testing.expectEqual(HighlightId.variable, try c.resolve(0, 0));
    try std.testing.expectEqualStrings("variable.readonly", names.name(try c.resolve(0, 0b0010)));
    // readonly outranks declaration.
    try std.testing.expectEqualStrings("variable.readonly", names.name(try c.resolve(0, 0b0011)));
    try std.testing.expectEqual(HighlightId.function_builtin, try c.resolve(1, 0b0100));
    try std.testing.expectEqual(HighlightId.function_builtin, try c.resolve(2, 0b0100));
    try std.testing.expectEqualStrings("function.method", names.name(try c.resolve(2, 0)));
    try std.testing.expectEqualStrings("semantic.lifetime", names.name(try c.resolve(3, 0)));
    try std.testing.expectEqualStrings("type.class.mutable", names.name(try c.resolve(4, 0b1000)));
    try std.testing.expectEqualStrings("variable.declaration", names.name(try c.resolve(0, 0b0001)));
    try std.testing.expectEqual(HighlightId.none, try c.resolve(9, 0));
    // Cached: the same id again.
    try std.testing.expectEqual(try c.resolve(0, 0b0010), try c.resolve(0, 0b0010));
}
