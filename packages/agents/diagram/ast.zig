//! The flowchart AST (E13.F07.S02.T01): nodes, edges, subgraphs and
//! styles with source spans. Every string points into the source or the
//! parser's arena.

const std = @import("std");

/// A byte range of the source.
pub const Span = struct {
    start: u32,
    end: u32,
};

/// Layout direction; `TD` parses as `TB`.
pub const Dir = enum { TB, BT, LR, RL };

pub const Shape = enum {
    rect,
    round,
    stadium,
    subroutine,
    cylinder,
    circle,
    double_circle,
    asymmetric,
    rhombus,
    hexagon,
    parallelogram,
    parallelogram_alt,
    trapezoid,
    trapezoid_alt,
};

/// The properties a style may set; only colours, widths and dashes are
/// honoured.
pub const Style = struct {
    /// 0xRRGGBB.
    fill: ?u32 = null,
    stroke: ?u32 = null,
    stroke_width: ?f32 = null,
    /// Text colour.
    color: ?u32 = null,
    stroke_dasharray: ?[]const f32 = null,

    /// `b`'s set fields over `a`'s.
    pub fn merge(a: Style, b: Style) Style {
        var out = a;
        inline for (std.meta.fields(Style)) |f| {
            if (@field(b, f.name)) |v| @field(out, f.name) = v;
        }
        return out;
    }

    pub fn isEmpty(s: Style) bool {
        inline for (std.meta.fields(Style)) |f| {
            if (@field(s, f.name) != null) return false;
        }
        return true;
    }
};

pub const Node = struct {
    id: []const u8,
    /// The id when no label is given.
    label: []const u8,
    shape: Shape,
    /// `class` statements and `:::name`, in order.
    classes: []const []const u8,
    /// From `style id …`.
    style: Style = .{},
    /// The first declaration (or reference).
    span: Span,
};

pub const EdgeStyle = enum { solid, dotted, thick, invisible };
pub const EdgeEnd = enum { none, arrow, circle, cross };

/// An end of an edge: a node, or a subgraph (an edge to the cluster).
pub const End = enum { node, subgraph };

pub const Edge = struct {
    /// Indexes into `nodes`, or `subgraphs` when `from_kind`/`to_kind`
    /// say so.
    from: u32,
    to: u32,
    style: EdgeStyle,
    /// At `to`.
    head: EdgeEnd,
    /// At `from`.
    tail: EdgeEnd,
    label: ?[]const u8,
    /// Extra dashes (dots, equals) beyond the shortest link.
    min_len: u8,
    span: Span,
    from_kind: End = .node,
    to_kind: End = .node,
};

pub const Subgraph = struct {
    id: []const u8,
    title: []const u8,
    dir: ?Dir,
    /// Nodes directly inside.
    members: []const u32,
    /// Subgraphs directly inside.
    children: []const u32,
    style: Style = .{},
    classes: []const []const u8 = &.{},
    span: Span,
};

pub const ClassDef = struct {
    name: []const u8,
    style: Style,
    span: Span,
};

pub const LinkStyle = struct {
    /// The edge's index; null for `default`.
    index: ?u32,
    style: Style,
    span: Span,
};

pub const Diagram = struct {
    dir: Dir,
    /// From frontmatter `title:`.
    title: ?[]const u8 = null,
    acc_title: ?[]const u8 = null,
    acc_descr: ?[]const u8 = null,
    nodes: []const Node,
    edges: []const Edge,
    subgraphs: []const Subgraph,
    class_defs: []const ClassDef,
    link_styles: []const LinkStyle,

    /// Subgraphs with no parent, in order.
    pub fn roots(d: *const Diagram, a: std.mem.Allocator) ![]u32 {
        const child = try a.alloc(bool, d.subgraphs.len);
        defer a.free(child);
        @memset(child, false);
        for (d.subgraphs) |s| for (s.children) |c| {
            child[c] = true;
        };
        var out: std.ArrayList(u32) = .empty;
        for (child, 0..) |c, i| if (!c) try out.append(a, @intCast(i));
        return out.toOwnedSlice(a);
    }

    pub fn nodeIndex(d: *const Diagram, id: []const u8) ?u32 {
        for (d.nodes, 0..) |n, i| if (std.mem.eql(u8, n.id, id)) return @intCast(i);
        return null;
    }
};

/// Writes `d` as ZON, one node, edge, subgraph or style per line (the
/// corpus goldens' format).
pub fn dump(w: *std.Io.Writer, d: Diagram) std.Io.Writer.Error!void {
    const ser = std.zon.stringify.serialize;
    const o: std.zon.stringify.SerializeOptions = .{ .whitespace = false, .emit_default_optional_fields = false };
    try w.print(".{{\n    .dir = .{s},\n", .{@tagName(d.dir)});
    inline for (.{ "title", "acc_title", "acc_descr" }) |f| if (@field(d, f)) |v| {
        try w.print("    .{s} = ", .{f});
        try ser(v, o, w);
        try w.writeAll(",\n");
    };
    inline for (.{ "nodes", "edges", "subgraphs", "class_defs", "link_styles" }) |f| {
        const items = @field(d, f);
        if (items.len == 0) {
            try w.print("    .{s} = .{{}},\n", .{f});
        } else {
            try w.print("    .{s} = .{{\n", .{f});
            for (items) |it| {
                try w.writeAll("        ");
                try ser(it, o, w);
                try w.writeAll(",\n");
            }
            try w.writeAll("    },\n");
        }
    }
    try w.writeAll("}\n");
}

test {
    std.testing.refAllDecls(@This());
}
