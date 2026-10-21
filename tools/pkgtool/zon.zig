//! Minimal read-only access to a parsed `.zon` document via `std.zig.Zoir`,
//! for zon shapes that cannot be typed for `std.zon.parse` (maps with
//! arbitrary keys such as `.dependencies`).

const std = @import("std");
const Zoir = std.zig.Zoir;

/// A parsed zon document. Owns its AST and ZOIR.
pub const Doc = struct {
    ast: std.zig.Ast,
    zoir: Zoir,

    /// Parses `source`. Returns `error.ParseZon` on syntax errors.
    pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !Doc {
        var ast = try std.zig.Ast.parse(gpa, source, .zon);
        errdefer ast.deinit(gpa);
        if (ast.errors.len != 0) return error.ParseZon;
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = true });
        if (zoir.hasCompileErrors()) {
            zoir.deinit(gpa);
            return error.ParseZon;
        }
        return .{ .ast = ast, .zoir = zoir };
    }

    /// Frees the document.
    pub fn deinit(d: *Doc, gpa: std.mem.Allocator) void {
        d.zoir.deinit(gpa);
        d.ast.deinit(gpa);
    }

    /// The root node.
    pub fn root(d: *const Doc) Node {
        return .{ .doc = d, .index = .root };
    }
};

/// A node in a `Doc`.
pub const Node = struct {
    doc: *const Doc,
    index: Zoir.Node.Index,

    /// The decoded node.
    pub fn get(n: Node) Zoir.Node {
        return n.index.get(n.doc.zoir);
    }

    /// The value of field `name` when this node is a struct literal.
    pub fn field(n: Node, name: []const u8) ?Node {
        switch (n.get()) {
            .struct_literal => |s| {
                for (s.names, 0..) |fname, i| {
                    if (std.mem.eql(u8, fname.get(n.doc.zoir), name)) return .{ .doc = n.doc, .index = s.vals.at(@intCast(i)) };
                }
                return null;
            },
            else => return null,
        }
    }

    /// Number of fields (struct) or elements (array); 0 for `.{}`.
    pub fn len(n: Node) usize {
        return switch (n.get()) {
            .struct_literal => |s| s.names.len,
            .array_literal => |a| a.len,
            else => 0,
        };
    }

    /// Field name `i` of a struct literal.
    pub fn fieldName(n: Node, i: usize) []const u8 {
        return n.get().struct_literal.names[i].get(n.doc.zoir);
    }

    /// Element or field value `i` of an array or struct literal.
    pub fn at(n: Node, i: usize) Node {
        return switch (n.get()) {
            .struct_literal => |s| .{ .doc = n.doc, .index = s.vals.at(@intCast(i)) },
            .array_literal => |a| .{ .doc = n.doc, .index = a.at(@intCast(i)) },
            else => unreachable,
        };
    }

    /// The string value, for string literals.
    pub fn string(n: Node) ?[]const u8 {
        return switch (n.get()) {
            .string_literal => |s| s,
            else => null,
        };
    }

    /// The enum literal name, e.g. `zg_core` for `.zg_core`.
    pub fn enumLiteral(n: Node) ?[]const u8 {
        return switch (n.get()) {
            .enum_literal => |e| e.get(n.doc.zoir),
            else => null,
        };
    }

    /// The integer value, for small integer literals.
    pub fn int(n: Node) ?i64 {
        return switch (n.get()) {
            .int_literal => |i| switch (i) {
                .small => |v| v,
                .big => |b| b.toInt(i64) catch null,
            },
            else => null,
        };
    }
};

test "zon: reads nested fields" {
    const gpa = std.testing.allocator;
    var doc = try Doc.parse(gpa, ".{ .name = .zg_x, .dependencies = .{ .a = .{ .path = \"../a\" } }, .n = 3, .l = .{ .{ \"p\", \"q\" } } }");
    defer doc.deinit(gpa);
    const r = doc.root();
    try std.testing.expectEqualStrings("zg_x", r.field("name").?.enumLiteral().?);
    const deps = r.field("dependencies").?;
    try std.testing.expectEqual(@as(usize, 1), deps.len());
    try std.testing.expectEqualStrings("a", deps.fieldName(0));
    try std.testing.expectEqualStrings("../a", deps.at(0).field("path").?.string().?);
    try std.testing.expectEqual(@as(i64, 3), r.field("n").?.int().?);
    try std.testing.expectEqualStrings("q", r.field("l").?.at(0).at(1).string().?);
}
