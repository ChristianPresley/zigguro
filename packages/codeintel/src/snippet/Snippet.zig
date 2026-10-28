//! Snippets (E07.F03.S01.T01): the VS Code snippet grammar (a superset
//! of the LSP's), parsed to nodes and expanded into text plus tab stops.
//! Used by completion (`insertTextFormat: Snippet`), user snippets and
//! agent templates; the editing session over the stops is `Session`.
//!
//! `parse` never fails on syntax: a construct that does not parse is
//! literal text. Equal indices are linked: the first placeholder (or
//! choice) for an index gives its text, every occurrence shows it, and
//! occurrences after the first are mirrors. `$0` is the final stop; one
//! is added at the end when the snippet has none. A variable the
//! resolver does not know becomes a placeholder showing its name (the
//! LSP rule) unless it has a default.
//!
//! Expansion indents every line after the first like the line the
//! snippet goes on and turns a tab in the snippet's text into the
//! indentation unit, as VS Code does.

const Snippet = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const transform = @import("transform.zig");
const parser = @import("parser.zig");

pub const Transform = transform.Transform;
pub const FormatItem = transform.FormatItem;
pub const CaseOp = transform.CaseOp;
pub const applyTransform = transform.applyTransform;

pub const Node = union(enum) {
    text: []const u8,
    tabstop: struct { index: u32, transform: ?*Transform = null },
    placeholder: struct { index: u32, children: []const Node },
    choice: struct { index: u32, options: []const []const u8 },
    variable: struct { name: []const u8, default: ?[]const Node = null, transform: ?*Transform = null },
};

/// One tab stop of an expansion: byte offsets into `Expansion.text`.
pub const StopRange = struct {
    index: u32,
    start: u32,
    end: u32,
    choice: ?[]const []const u8 = null,
    /// Set on every occurrence of an index after the first: it shows the
    /// first's text (through `transform`, when it has one).
    mirror_of: ?u32 = null,
    transform: ?*const Transform = null,
    /// Order in which the stop was closed while expanding: text order,
    /// except that a placeholder comes after the stops nested in it.
    seq: u32 = 0,
};

pub const Expansion = struct {
    text: std.ArrayList(u8) = .empty,
    /// In visiting order: ascending index, `$0` last; occurrences of one
    /// index in text order.
    stops: std.ArrayList(StopRange) = .empty,

    pub fn deinit(e: *Expansion, gpa: Allocator) void {
        e.text.deinit(gpa);
        e.stops.deinit(gpa);
    }

    pub fn clear(e: *Expansion) void {
        e.text.clearRetainingCapacity();
        e.stops.clearRetainingCapacity();
    }
};

pub const IndentCtx = struct {
    /// The indentation of the line the snippet is inserted on.
    line_indent: []const u8 = "",
    /// What a tab in the snippet becomes.
    indent_unit: []const u8 = "\t",
};

/// Variable values; null for a variable it does not know (the empty
/// string for a known one without a value, which takes the default).
pub const VariableResolver = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, name: []const u8, arena: Allocator) ?[]const u8,

    /// Knows no variable.
    pub const none: VariableResolver = .{ .get = struct {
        fn f(_: ?*anyopaque, _: []const u8, _: Allocator) ?[]const u8 {
            return null;
        }
    }.f };
};

gpa: Allocator,
nodes: []const Node,
arena: std.heap.ArenaAllocator,
transforms: []*Transform,
/// Whether the text has an explicit `$0`.
has_final: bool,
max_index: u32,

/// Parses `text` (syntax errors become literal text).
pub fn parse(gpa: Allocator, text: []const u8) Allocator.Error!Snippet {
    var s: Snippet = .{ .gpa = gpa, .nodes = &.{}, .arena = .init(gpa), .transforms = &.{}, .has_final = false, .max_index = 0 };
    errdefer s.deinit();
    var p: parser.Parser = .{ .gpa = gpa, .a = s.arena.allocator(), .src = text };
    defer p.transforms.deinit(gpa);
    errdefer for (p.transforms.items) |t| t.deinit(gpa);
    s.nodes = try p.parseAll();
    s.transforms = try s.arena.allocator().dupe(*Transform, p.transforms.items);
    s.has_final = p.has_final;
    s.max_index = p.max_index;
    return s;
}

pub fn deinit(s: *Snippet) void {
    for (s.transforms) |t| t.deinit(s.gpa);
    s.arena.deinit();
}

/// The text of a snippet with no stops or variables (for labels and
/// filtering): placeholders show their text, choices their first option.
pub fn plainText(s: *const Snippet, gpa: Allocator) Allocator.Error![]u8 {
    var e: Expansion = .{};
    defer e.stops.deinit(gpa);
    try s.expand(gpa, .none, .{ .indent_unit = "\t" }, &e);
    return e.text.toOwnedSlice(gpa);
}

/// Expands into `out` (cleared first).
pub fn expand(s: *const Snippet, gpa: Allocator, vars: VariableResolver, indent: IndentCtx, out: *Expansion) Allocator.Error!void {
    out.clear();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var x: Expander = .{ .gpa = gpa, .arena = arena.allocator(), .vars = vars, .indent = indent, .out = out, .next_index = s.max_index + 1 };
    try x.findDefaults(s.nodes);
    try x.nodes(s.nodes);
    if (!s.has_final and !x.seen_final) try out.stops.append(gpa, .{ .index = 0, .start = x.len(), .end = x.len() });
    for (out.stops.items, 0..) |*st, i| st.seq = @intCast(i);
    std.sort.pdq(StopRange, out.stops.items, {}, struct {
        fn key(r: StopRange) u64 {
            return if (r.index == 0) std.math.maxInt(u32) else r.index;
        }
        fn lt(_: void, a: StopRange, b: StopRange) bool {
            if (key(a) != key(b)) return key(a) < key(b);
            return a.start < b.start;
        }
    }.lt);
}

const Expander = struct {
    gpa: Allocator,
    arena: Allocator,
    vars: VariableResolver,
    indent: IndentCtx,
    out: *Expansion,
    /// Index for the next unknown variable's placeholder.
    next_index: u32,
    seen_final: bool = false,
    /// The defining occurrence of each index (placeholder or choice).
    defaults: std.AutoHashMapUnmanaged(u32, *const Node) = .empty,
    /// Indices already given their first stop.
    placed: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Inside a mirror: nested stops are text only.
    in_mirror: u32 = 0,

    fn len(x: *const Expander) u32 {
        return @intCast(x.out.text.items.len);
    }

    fn findDefaults(x: *Expander, ns: []const Node) Allocator.Error!void {
        for (ns) |*n| switch (n.*) {
            .placeholder => |p| {
                const g = try x.defaults.getOrPut(x.arena, p.index);
                if (!g.found_existing) g.value_ptr.* = n;
                try x.findDefaults(p.children);
            },
            .choice => |c| {
                const g = try x.defaults.getOrPut(x.arena, c.index);
                if (!g.found_existing) g.value_ptr.* = n;
            },
            .variable => |v| if (v.default) |d| try x.findDefaults(d),
            else => {},
        };
    }

    /// Snippet text: newlines take the line's indentation, tabs the unit.
    fn text(x: *Expander, t: []const u8, tabs: bool) Allocator.Error!void {
        const o = &x.out.text;
        var i: usize = 0;
        while (i < t.len) {
            const end = std.mem.indexOfAnyPos(u8, t, i, if (tabs) "\n\t" else "\n") orelse t.len;
            try o.appendSlice(x.gpa, t[i..end]);
            if (end == t.len) break;
            if (t[end] == '\n') {
                try o.append(x.gpa, '\n');
                try o.appendSlice(x.gpa, x.indent.line_indent);
            } else try o.appendSlice(x.gpa, x.indent.indent_unit);
            i = end + 1;
        }
    }

    fn nodes(x: *Expander, ns: []const Node) Allocator.Error!void {
        for (ns) |*n| try x.node(n);
    }

    fn node(x: *Expander, n: *const Node) Allocator.Error!void {
        switch (n.*) {
            .text => |t| try x.text(t, true),
            .tabstop => |t| try x.stop(t.index, n, t.transform),
            .placeholder => |p| try x.stop(p.index, n, null),
            .choice => |c| try x.stop(c.index, n, null),
            .variable => |v| try x.variable(v.name, v.default, v.transform),
        }
    }

    /// An occurrence of index `index` at node `n`.
    fn stop(x: *Expander, index: u32, n: *const Node, tr: ?*const Transform) Allocator.Error!void {
        if (index == 0) x.seen_final = true;
        const def = x.defaults.get(index);
        const first = !x.placed.contains(index);
        const start = x.len();
        if (x.in_mirror > 0) {
            // A stop inside a mirrored placeholder is plain text.
            if (def) |d| try x.defaultText(d);
            return;
        }
        if (first and tr == null) {
            try x.placed.put(x.arena, index, {});
            // The first occurrence holds the default (nested stops live).
            if (def) |d| switch (d.*) {
                .placeholder => |p| {
                    // The defining placeholder may come later; its text
                    // shows here, its nested stops at the definition.
                    if (d == n) try x.nodes(p.children) else try x.mirrorText(d);
                },
                .choice => |c| if (c.options.len > 0) try x.text(c.options[0], true),
                else => {},
            };
            const choice: ?[]const []const u8 = if (def) |d| if (d.* == .choice) d.choice.options else null else null;
            try x.out.stops.append(x.gpa, .{ .index = index, .start = start, .end = x.len(), .choice = choice });
            return;
        }
        // A mirror: the first's text, transformed when asked.
        if (tr) |t| {
            var buf: std.ArrayList(u8) = .empty;
            const saved = x.out.text;
            x.out.text = buf;
            if (def) |d| try x.mirrorText(d);
            buf = x.out.text;
            x.out.text = saved;
            var res: std.ArrayList(u8) = .empty;
            try applyTransform(x.arena, t, buf.items, &res);
            buf.deinit(x.gpa);
            try x.out.text.appendSlice(x.gpa, res.items);
        } else if (def) |d| try x.mirrorText(d);
        // Transformed occurrences are always mirrors.
        try x.out.stops.append(x.gpa, .{ .index = index, .start = start, .end = x.len(), .mirror_of = index, .transform = tr });
    }

    fn mirrorText(x: *Expander, d: *const Node) Allocator.Error!void {
        x.in_mirror += 1;
        defer x.in_mirror -= 1;
        try x.defaultText(d);
    }

    fn defaultText(x: *Expander, d: *const Node) Allocator.Error!void {
        switch (d.*) {
            .placeholder => |p| try x.nodes(p.children),
            .choice => |c| if (c.options.len > 0) try x.text(c.options[0], true),
            else => {},
        }
    }

    fn variable(x: *Expander, name: []const u8, default: ?[]const Node, tr: ?*const Transform) Allocator.Error!void {
        const val = x.vars.get(x.vars.ctx, name, x.arena);
        if (val) |v| if (v.len > 0 or default == null) {
            if (tr) |t| {
                var res: std.ArrayList(u8) = .empty;
                try applyTransform(x.arena, t, v, &res);
                return x.text(res.items, false);
            }
            return x.text(v, false);
        };
        if (default) |d| return x.nodes(d);
        // Unknown and no default: a placeholder showing the name.
        const index = x.next_index;
        x.next_index += 1;
        const start = x.len();
        try x.text(name, false);
        if (x.in_mirror == 0) try x.out.stops.append(x.gpa, .{ .index = index, .start = start, .end = x.len() });
    }
};

test {
    _ = @import("snippet_test.zig");
    _ = @import("session_test.zig");
}
