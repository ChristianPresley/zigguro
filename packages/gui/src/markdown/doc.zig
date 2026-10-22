//! `Doc`: a parsed Markdown document (E04.F06): the source, the block and
//! inline arrays (ast.zig), the text pools and the link reference map.

const std = @import("std");
const ast = @import("ast.zig");

const Allocator = std.mem.Allocator;
const Block = ast.Block;
const Inline = ast.Inline;
const none = ast.none;

/// Parses a leaf block's inlines (inline.zig); null keeps each leaf's
/// text as one `text` inline.
pub const InlineParser = struct {
    ptr: ?*anyopaque = null,
    parseLeaf: *const fn (?*anyopaque, doc: *Doc, block: u32) error{OutOfMemory}!void,
};

pub const Doc = struct {
    gpa: Allocator,
    opts: ast.Options,
    /// The Markdown source (owned; streaming appends to it).
    src: std.ArrayList(u8) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    inlines: std.ArrayList(Inline) = .empty,
    /// Leaf block text (container prefixes stripped).
    content: std.ArrayList(u8) = .empty,
    /// Decoded inline text (escapes, entities), destinations and labels.
    text_pool: std.ArrayList(u8) = .empty,
    refs: std.ArrayList(ast.RefDef) = .empty,
    /// Labels, destinations and titles of `refs`.
    ref_pool: std.ArrayList(u8) = .empty,
    /// Normalized label → index in `refs` (first definition wins).
    ref_map: std.StringHashMapUnmanaged(u32) = .empty,
    /// Normalized labels of reference links that did not resolve, with
    /// the top-level block they are in (streaming re-resolution).
    unresolved: std.ArrayList(Unresolved) = .empty,
    inline_parser: ?InlineParser = null,
    /// Streaming state (stream.zig).
    stream: StreamState = .{},

    pub const Unresolved = struct { label: []u8, top: u32 };

    pub const StreamState = struct {
        /// Top-level blocks that no later text can change.
        stable_blocks: u32 = 0,
        /// Array lengths after the stable blocks' inlines were parsed.
        stable_inlines: u32 = 0,
        stable_pool: u32 = 0,
        /// Up to 3 bytes of an incomplete UTF-8 sequence not yet in `src`.
        carry: [4]u8 = undefined,
        carry_len: u8 = 0,
        finished: bool = false,
        /// Where parsing resumes when every top-level block is stable.
        resume_src: u32 = 0,
    };

    pub fn init(gpa: Allocator, opts: ast.Options) Doc {
        return .{ .gpa = gpa, .opts = opts };
    }

    pub fn deinit(d: *Doc) void {
        d.src.deinit(d.gpa);
        d.blocks.deinit(d.gpa);
        d.inlines.deinit(d.gpa);
        d.content.deinit(d.gpa);
        d.text_pool.deinit(d.gpa);
        d.refs.deinit(d.gpa);
        d.ref_pool.deinit(d.gpa);
        var it = d.ref_map.keyIterator();
        while (it.next()) |k| d.gpa.free(k.*);
        d.ref_map.deinit(d.gpa);
        for (d.unresolved.items) |u| d.gpa.free(u.label);
        d.unresolved.deinit(d.gpa);
        d.* = undefined;
    }

    /// The block at `i`.
    pub fn block(d: *const Doc, i: u32) *Block {
        return &d.blocks.items[i];
    }

    /// The document's top-level blocks, in order.
    pub fn topLevel(d: *const Doc) ChildIterator {
        return .{ .doc = d, .next_idx = d.blocks.items[0].first_child };
    }

    /// The children of block `i`.
    pub fn children(d: *const Doc, i: u32) ChildIterator {
        return .{ .doc = d, .next_idx = d.blocks.items[i].first_child };
    }

    pub const ChildIterator = struct {
        doc: *const Doc,
        next_idx: u32,
        pub fn next(it: *ChildIterator) ?u32 {
            if (it.next_idx == none) return null;
            const i = it.next_idx;
            it.next_idx = it.doc.blocks.items[i].next;
            return i;
        }
    };

    /// A range of `content`.
    pub fn contentOf(d: *const Doc, r: [2]u32) []const u8 {
        return d.content.items[r[0]..r[1]];
    }

    /// A range of `text_pool`.
    pub fn pooled(d: *const Doc, r: [2]u32) []const u8 {
        return d.text_pool.items[r[0]..r[1]];
    }

    /// An inline's text.
    pub fn inlineText(d: *const Doc, in: *const Inline) []const u8 {
        return if (in.pooled) d.pooled(in.text) else d.contentOf(in.text);
    }

    /// A link's destination and title.
    pub fn destOf(d: *const Doc, in: *const Inline) []const u8 {
        return if (in.dest_pooled) d.pooled(in.dest) else d.contentOf(in.dest);
    }
    pub fn titleOf(d: *const Doc, in: *const Inline) []const u8 {
        return if (in.dest_pooled) d.pooled(in.title) else d.contentOf(in.title);
    }

    /// Appends `s` to `text_pool` and returns its range.
    pub fn pool(d: *Doc, s: []const u8) Allocator.Error![2]u32 {
        const start: u32 = @intCast(d.text_pool.items.len);
        try d.text_pool.appendSlice(d.gpa, s);
        return .{ start, @intCast(d.text_pool.items.len) };
    }

    /// Adds an inline and returns its index.
    pub fn addInline(d: *Doc, in: Inline) Allocator.Error!u32 {
        const i: u32 = @intCast(d.inlines.items.len);
        try d.inlines.append(d.gpa, in);
        return i;
    }

    /// The first child inline of a leaf block, iterated with `next`.
    pub fn inlineChildren(d: *const Doc, first: u32) InlineIterator {
        return .{ .doc = d, .next_idx = first };
    }

    pub const InlineIterator = struct {
        doc: *const Doc,
        next_idx: u32,
        pub fn next(it: *InlineIterator) ?u32 {
            if (it.next_idx == none) return null;
            const i = it.next_idx;
            it.next_idx = it.doc.inlines.items[i].next;
            return i;
        }
    };

    /// A range of `ref_pool` (a `RefDef` field).
    pub fn refText(d: *const Doc, r: [2]u32) []const u8 {
        return d.ref_pool.items[r[0]..r[1]];
    }

    fn refPool(d: *Doc, s: []const u8) Allocator.Error![2]u32 {
        const start: u32 = @intCast(d.ref_pool.items.len);
        try d.ref_pool.appendSlice(d.gpa, s);
        return .{ start, @intCast(d.ref_pool.items.len) };
    }

    /// The definition for a normalized label.
    pub fn lookupRef(d: *const Doc, normalized: []const u8) ?*const ast.RefDef {
        const i = d.ref_map.get(normalized) orelse return null;
        return &d.refs.items[i];
    }

    /// Adds a definition; a label already defined keeps its first one.
    pub fn addRef(d: *Doc, normalized: []const u8, dest: []const u8, title: []const u8, blk: u32) Allocator.Error!void {
        if (d.ref_map.contains(normalized)) return;
        const key = try d.gpa.dupe(u8, normalized);
        errdefer d.gpa.free(key);
        const label = try d.refPool(normalized);
        const dr = try d.refPool(dest);
        const tr = try d.refPool(title);
        try d.refs.append(d.gpa, .{ .label = label, .dest = dr, .title = tr, .block = blk });
        try d.ref_map.put(d.gpa, key, @intCast(d.refs.items.len - 1));
    }

    /// Records an unresolved reference label under top-level block `top`.
    pub fn noteUnresolved(d: *Doc, normalized: []const u8, top: u32) Allocator.Error!void {
        const l = try d.gpa.dupe(u8, normalized);
        errdefer d.gpa.free(l);
        try d.unresolved.append(d.gpa, .{ .label = l, .top = top });
    }

    /// The top-level block containing block `i`.
    pub fn topOf(d: *const Doc, i: u32) u32 {
        var b = i;
        while (b != none and d.blocks.items[b].parent != 0 and d.blocks.items[b].parent != none) b = d.blocks.items[b].parent;
        return b;
    }

    /// Drops everything from top-level block `first_top` on (its block
    /// index, which is also where its descendants start), restoring the
    /// arrays to `inl` inlines and `pool_len` pool bytes (streaming).
    pub fn truncate(d: *Doc, first_top: u32, inl: u32, pool_len: u32) void {
        // Refs defined by dropped blocks.
        var keep = d.refs.items.len;
        while (keep > 0 and d.refs.items[keep - 1].block >= first_top) : (keep -= 1) {
            const r = d.refs.items[keep - 1];
            if (d.ref_map.fetchRemove(d.refText(r.label))) |kv| d.gpa.free(kv.key);
            d.ref_pool.shrinkRetainingCapacity(r.label[0]);
        }
        d.refs.shrinkRetainingCapacity(keep);
        var u: usize = 0;
        while (u < d.unresolved.items.len) {
            if (d.unresolved.items[u].top >= first_top) {
                d.gpa.free(d.unresolved.items[u].label);
                _ = d.unresolved.swapRemove(u);
            } else u += 1;
        }
        const content_len = d.blocks.items[first_top].content_mark;
        d.blocks.shrinkRetainingCapacity(first_top);
        d.inlines.shrinkRetainingCapacity(inl);
        d.content.shrinkRetainingCapacity(content_len);
        d.text_pool.shrinkRetainingCapacity(pool_len);
        // Unlink the dropped blocks from the document.
        const docb = &d.blocks.items[0];
        if (first_top == 0) return;
        var last: u32 = none;
        var c = docb.first_child;
        while (c != none and c < first_top) : (c = d.blocks.items[c].next) last = c;
        docb.last_child = last;
        if (last == none) docb.first_child = none else d.blocks.items[last].next = none;
        docb.closed = false;
    }
};

test {
    std.testing.refAllDecls(@This());
}
