//! Selection across Markdown blocks (E04.F06.S01.T02): positions are
//! (leaf block, byte offset in its flattened text), ordered by block
//! index, which follows document order. Copy joins the selected text of
//! each leaf: paragraphs with a blank line, table cells with tabs and rows
//! with newlines, list items with their markers, code verbatim.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");

const Allocator = std.mem.Allocator;
const Doc = doc_mod.Doc;
const none = ast.none;

/// A point in the rendered document.
pub const Pos = struct {
    block: u32,
    off: u32,

    /// `a` comes before `b`.
    pub fn lessThan(a: Pos, b: Pos) bool {
        return a.block < b.block or (a.block == b.block and a.off < b.off);
    }

    /// Same position.
    pub fn eql(a: Pos, b: Pos) bool {
        return a.block == b.block and a.off == b.off;
    }
};

/// A selection from `anchor` (where the drag started) to `head`.
pub const DocSelection = struct {
    anchor: Pos,
    head: Pos,

    /// The selection's start and end in document order.
    pub fn ordered(s: DocSelection) [2]Pos {
        return if (s.head.lessThan(s.anchor)) .{ s.head, s.anchor } else .{ s.anchor, s.head };
    }

    /// Nothing is selected.
    pub fn isEmpty(s: DocSelection) bool {
        return s.anchor.eql(s.head);
    }

    /// The selected byte range of leaf `block` whose text is `len` bytes,
    /// or null when the leaf is outside the selection.
    pub fn rangeIn(s: DocSelection, block: u32, len: u32) ?[2]u32 {
        const o = s.ordered();
        if (block < o[0].block or block > o[1].block) return null;
        const a = if (block == o[0].block) @min(o[0].off, len) else 0;
        const b = if (block == o[1].block) @min(o[1].off, len) else len;
        if (a >= b) return null;
        return .{ a, b };
    }
};

/// Leaves that render as selectable text.
pub fn isTextLeaf(k: ast.BlockKind) bool {
    return switch (k) {
        .paragraph, .heading, .table_cell, .code_fenced, .code_indented, .math_block, .html_literal => true,
        else => false,
    };
}

/// The flattened text of a leaf, supplied by the view's cache.
pub const TextOf = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, block: u32) []const u8,
};

/// The plain text of `sel` (caller frees).
pub fn copyText(gpa: Allocator, d: *const Doc, sel: DocSelection, text_of: TextOf) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const o = sel.ordered();
    var prev: u32 = none;
    var i = o[0].block;
    while (i <= o[1].block and i < d.blocks.items.len) : (i += 1) {
        const b = d.blocks.items[i];
        if (!isTextLeaf(b.kind)) continue;
        const t = text_of.f(text_of.ctx, i);
        const r = sel.rangeIn(i, @intCast(t.len)) orelse continue;
        if (prev != none) try out.appendSlice(gpa, separator(d, prev, i));
        if (r[0] == 0) try marker(gpa, d, i, &out);
        try out.appendSlice(gpa, t[r[0]..r[1]]);
        prev = i;
    }
    return out.toOwnedSlice(gpa);
}

fn separator(d: *const Doc, a: u32, b: u32) []const u8 {
    const ba = d.blocks.items[a];
    const bb = d.blocks.items[b];
    if (ba.kind == .table_cell and bb.kind == .table_cell) {
        if (ba.parent == bb.parent) return "\t";
        if (d.blocks.items[ba.parent].parent == d.blocks.items[bb.parent].parent) return "\n";
    }
    // Items of a tight list: one per line.
    if (itemOf(d, a)) |ia| if (itemOf(d, b)) |ib| {
        const list = d.blocks.items[ib].parent;
        if (ia != ib and d.blocks.items[ia].parent == list and d.blocks.items[list].list.tight) return "\n";
    };
    return "\n\n";
}

/// The list item whose first child is `blk`.
fn itemOf(d: *const Doc, blk: u32) ?u32 {
    const p = d.blocks.items[blk].parent;
    if (p == none or d.blocks.items[p].kind != .list_item) return null;
    if (d.blocks.items[p].first_child != blk) return null;
    return p;
}

/// Writes the list marker (and task box) of the item `blk` starts.
fn marker(gpa: Allocator, d: *const Doc, blk: u32, out: *std.ArrayList(u8)) Allocator.Error!void {
    const item = itemOf(d, blk) orelse return;
    const list = d.blocks.items[item].parent;
    const ld = d.blocks.items[list].list;
    if (ld.ordered) {
        var n: u32 = ld.start;
        var c = d.blocks.items[list].first_child;
        while (c != none and c != item) : (c = d.blocks.items[c].next) n += 1;
        try out.print(gpa, "{d}{c} ", .{ n, ld.marker });
    } else try out.appendSlice(gpa, "- ");
    switch (d.blocks.items[item].task) {
        .none => {},
        .unchecked => try out.appendSlice(gpa, "[ ] "),
        .checked => try out.appendSlice(gpa, "[x] "),
    }
}

test "copy joins leaves with markers, tabs and blank lines" {
    const stream = @import("stream.zig");
    const rich = @import("rich.zig");
    const gpa = std.testing.allocator;
    var d = try stream.parse(gpa,
        \\Intro *text*
        \\
        \\- one
        \\- [x] two
        \\
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
        \\```
        \\code  here
        \\```
        \\
    , .{});
    defer d.deinit();
    const Cache = struct {
        d: *const Doc,
        flats: [64]rich.Flat = [_]rich.Flat{.{}} ** 64,
        fn text(ctx: *anyopaque, blk: u32) []const u8 {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            rich.flatten(gpa, c.d, blk, &c.flats[blk]) catch return "";
            return c.flats[blk].text.items;
        }
    };
    var cache: Cache = .{ .d = &d };
    defer for (&cache.flats) |*f| f.deinit(gpa);
    const last: u32 = @intCast(d.blocks.items.len - 1);
    const sel: DocSelection = .{ .anchor = .{ .block = 1, .off = 2 }, .head = .{ .block = last, .off = 4 } };
    const got = try copyText(gpa, &d, sel, .{ .ctx = &cache, .f = Cache.text });
    defer gpa.free(got);
    try std.testing.expectEqualStrings("tro text\n\n- one\n- [x] two\n\na\tb\n1\t2\n\ncode", got);
    try std.testing.expectEqual([2]u32{ 2, 10 }, sel.rangeIn(1, 10).?);
    try std.testing.expect(sel.rangeIn(0, 5) == null);
}
