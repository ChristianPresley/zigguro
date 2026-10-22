//! The bracket-pair tree: which brackets match, how deep each pair is
//! (rainbow colors, guides) and which brackets are unmatched, kept up to
//! date incrementally (the VS Code bracket pair colorization design).
//!
//! The text is a sequence of bracket tokens and the text between them. A
//! parse turns it into nodes: `pair` (an opening bracket, the list inside
//! and the closing bracket, if any), `bracket` (an unmatched closing
//! bracket), `text`, and `list`, a (2,3)-tree of nodes of equal height.
//! Nodes store their length, not their position, so an edit only touches
//! the nodes that contain it and their ancestors.
//!
//! After an edit, the parser reads the new tokens but reuses every old node
//! that lies entirely between changes and would parse the same way in its
//! new context: it is closed, and it holds no unmatched closing bracket
//! that one of the currently open brackets would match. Reused nodes are
//! concatenated with (2,3)-tree rebalancing, so an edit costs about
//! O(log³ N + E) and a query O(log² N + R).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A set of bracket pair ids (indexes into `Language.brackets`).
pub const BracketSet = u64;

/// Pair ids are below this.
pub const max_pairs = 64;

/// Opening brackets nested deeper than this are treated as text (VS Code
/// does the same), which bounds the parser's recursion.
pub const max_nesting = 256;

/// A bracket token: `len` bytes at `offset`.
pub const BracketToken = struct {
    offset: u64,
    len: u8,
    /// Index into the language's bracket pairs.
    pair: u6,
    open: bool,
};

/// The bracket tokens of the current text. Tokens inside strings and
/// comments are not brackets: the lexer decides.
pub const BracketSource = struct {
    ctx: *anyopaque,
    /// Length of the text.
    len: u64,
    /// The first bracket token starting at or after `from`, or null.
    /// Calls usually come in increasing order of `from`.
    nextFn: *const fn (ctx: *anyopaque, from: u64) Allocator.Error!?BracketToken,

    pub fn next(src: BracketSource, from: u64) Allocator.Error!?BracketToken {
        return src.nextFn(src.ctx, from);
    }
};

/// Bytes `[start, end)`.
pub const Range = struct { start: u64, end: u64 };

/// A text edit in old-text offsets: `[start, end)` became `new_len` bytes.
pub const TextEdit = struct { start: u64, end: u64, new_len: u64 };

/// A pair, for rainbow brackets and guides.
pub const BracketPairInfo = struct {
    open: u64,
    open_len: u8,
    /// Null when the pair is not closed.
    close: ?u64,
    close_len: u8,
    /// Enclosing pairs (0 at top level).
    depth: u32,
    pair: u6,

    /// The bytes between the brackets.
    pub fn inner(p: BracketPairInfo, text_len: u64) Range {
        return .{ .start = p.open + p.open_len, .end = p.close orelse text_len };
    }
};

const NodeId = u32;
const nil: NodeId = std.math.maxInt(NodeId);

const Kind = enum(u8) { text, bracket, pair, list };

/// 32 bytes.
const Node = struct {
    len: u32 = 0,
    /// Closing brackets in the subtree that found no opening bracket
    /// (VS Code's `missingOpeningBracketIds`).
    missing: BracketSet = 0,
    /// List: children. Pair: `kids[0]` is the content (or nil).
    kids: [3]NodeId = .{ nil, nil, nil },
    kind: Kind,
    /// List height (children have height - 1); 0 for other nodes.
    height: u8 = 0,
    /// List: number of children (2 or 3).
    n: u8 = 0,
    /// Pair or unmatched bracket: the pair id.
    pair: u6 = 0,
    open_len: u8 = 0,
    /// Pair: 0 when it is not closed.
    close_len: u8 = 0,
    /// The subtree holds an unmatched bracket.
    bad: bool = false,
    /// Reused by the parse in progress.
    reused: bool = false,
};

pub const BracketTree = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    free_head: NodeId = nil,
    root: NodeId = nil,
    /// Parse scratch, kept between parses.
    items: std.ArrayList(NodeId) = .empty,
    reused: std.ArrayList(NodeId) = .empty,
    reader: Reader = .{},
    merged: std.ArrayList(Edit2) = .empty,
    /// Counters for tests and benches.
    stats: struct { reused_nodes: u64 = 0, new_nodes: u64 = 0 } = .{},

    /// An empty tree.
    pub fn init(gpa: Allocator) BracketTree {
        return .{ .gpa = gpa };
    }

    /// Parses all of `src`.
    pub fn build(gpa: Allocator, src: BracketSource) Allocator.Error!BracketTree {
        var bt: BracketTree = .init(gpa);
        errdefer bt.deinit();
        try bt.rebuild(src);
        return bt;
    }

    pub fn deinit(bt: *BracketTree) void {
        bt.nodes.deinit(bt.gpa);
        bt.items.deinit(bt.gpa);
        bt.reused.deinit(bt.gpa);
        bt.reader.deinit(bt.gpa);
        bt.merged.deinit(bt.gpa);
        bt.* = undefined;
    }

    /// Length of the text the tree was parsed from.
    pub fn len(bt: *const BracketTree) u64 {
        return if (bt.root == nil) 0 else bt.nodes.items[bt.root].len;
    }

    /// Forgets everything and parses all of `src`.
    pub fn rebuild(bt: *BracketTree, src: BracketSource) Allocator.Error!void {
        bt.nodes.clearRetainingCapacity();
        bt.free_head = nil;
        bt.root = nil;
        // Code has about one node per 8-16 bytes; growing by doubling
        // would copy the array several times.
        try bt.nodes.ensureTotalCapacity(bt.gpa, @intCast(@min(src.len / 12, 1 << 26)));
        var p: Parser = .{ .bt = bt, .tz = .{ .src = src } };
        bt.root = try p.parseList(0, 0);
    }

    /// Updates the tree for `edits` (sorted, disjoint, in old offsets) and
    /// for `retokenized` ranges (new offsets, any order) where the lexer
    /// changed tokens outside the edits, e.g. after a quote opened a string
    /// that runs on. `src` serves the new text.
    pub fn applyEdits(bt: *BracketTree, edits: []const TextEdit, retokenized: []const Range, src: BracketSource) Allocator.Error!void {
        if (bt.root == nil) return bt.rebuild(src);
        try bt.mergeEdits(edits, retokenized);
        const old_root = bt.root;
        try bt.reader.reset(bt.gpa, old_root);
        var p: Parser = .{ .bt = bt, .tz = .{ .src = src }, .incremental = true, .mapper = .{ .edits = bt.merged.items } };
        const new_root = try p.parseList(0, 0);
        bt.root = new_root;
        // Free the old nodes that were not reused.
        bt.freeOld(old_root);
        for (bt.reused.items) |id| bt.nodes.items[id].reused = false;
        bt.stats.reused_nodes += bt.reused.items.len;
        bt.reused.clearRetainingCapacity();
        std.debug.assert(bt.len() == textEnd(src));
    }

    /// The pair whose opening or closing bracket covers `pos`.
    pub fn matching(bt: *const BracketTree, pos: u64) ?BracketPairInfo {
        var id = bt.root;
        var off: u64 = 0;
        var depth: u32 = 0;
        while (id != nil) {
            const n = bt.nodes.items[id];
            if (pos < off or pos >= off + n.len) return null;
            switch (n.kind) {
                .text, .bracket => return null,
                .list => {
                    var i: u8 = 0;
                    while (i < n.n) : (i += 1) {
                        const c = bt.nodes.items[n.kids[i]];
                        if (pos < off + c.len) break;
                        off += c.len;
                    }
                    id = n.kids[i];
                },
                .pair => {
                    if (pos < off + n.open_len or (n.close_len > 0 and pos >= off + n.len - n.close_len))
                        return pairInfo(n, off, depth);
                    off += n.open_len;
                    depth += 1;
                    id = n.kids[0];
                },
            }
        }
        return null;
    }

    /// The innermost pair whose inside contains `pos` (between the end of
    /// the opening bracket and the start of the closing one, both counted).
    pub fn enclosing(bt: *const BracketTree, pos: u64) ?BracketPairInfo {
        var best: ?BracketPairInfo = null;
        var id = bt.root;
        var off: u64 = 0;
        var depth: u32 = 0;
        while (id != nil) {
            const n = bt.nodes.items[id];
            switch (n.kind) {
                .text, .bracket => break,
                .list => {
                    // The first child that ends after `pos`, or the last.
                    var i: u8 = 0;
                    while (i + 1 < n.n) : (i += 1) {
                        const c = bt.nodes.items[n.kids[i]];
                        if (pos < off + c.len) break;
                        off += c.len;
                    }
                    id = n.kids[i];
                },
                .pair => {
                    const inner_end = off + n.len - n.close_len;
                    if (pos < off + n.open_len or pos > inner_end) break;
                    best = pairInfo(n, off, depth);
                    off += n.open_len;
                    depth += 1;
                    id = n.kids[0];
                },
            }
        }
        return best;
    }

    /// Pairs that intersect `r` (or contain it), in document order. An
    /// empty `r` selects pairs containing its position.
    pub fn pairsInRange(bt: *const BracketTree, gpa: Allocator, r: Range, out: *std.ArrayList(BracketPairInfo)) Allocator.Error!void {
        out.clearRetainingCapacity();
        try bt.collectPairs(gpa, bt.root, 0, 0, .{ .start = r.start, .end = @max(r.end, r.start + 1) }, out);
    }

    fn collectPairs(bt: *const BracketTree, gpa: Allocator, id: NodeId, off: u64, depth: u32, r: Range, out: *std.ArrayList(BracketPairInfo)) Allocator.Error!void {
        if (id == nil) return;
        const n = bt.nodes.items[id];
        if (off >= r.end or off + n.len <= r.start) return;
        switch (n.kind) {
            .text, .bracket => {},
            .list => {
                var o = off;
                for (n.kids[0..n.n]) |c| {
                    try bt.collectPairs(gpa, c, o, depth, r, out);
                    o += bt.nodes.items[c].len;
                    if (o >= r.end) break;
                }
            },
            .pair => {
                try out.append(gpa, pairInfo(n, off, depth));
                try bt.collectPairs(gpa, n.kids[0], off + n.open_len, depth + 1, r, out);
            },
        }
    }

    /// Offsets of unmatched brackets in `r`, in order: closing brackets
    /// with no opening one, and opening brackets that are never closed.
    pub fn unmatched(bt: *const BracketTree, gpa: Allocator, r: Range, out: *std.ArrayList(u64)) Allocator.Error!void {
        out.clearRetainingCapacity();
        try bt.collectUnmatched(gpa, bt.root, 0, r, out);
    }

    fn collectUnmatched(bt: *const BracketTree, gpa: Allocator, id: NodeId, off: u64, r: Range, out: *std.ArrayList(u64)) Allocator.Error!void {
        if (id == nil) return;
        const n = bt.nodes.items[id];
        if (!n.bad or off >= r.end or off + n.len <= r.start) return;
        switch (n.kind) {
            .text => {},
            .bracket => try out.append(gpa, off),
            .list => {
                var o = off;
                for (n.kids[0..n.n]) |c| {
                    try bt.collectUnmatched(gpa, c, o, r, out);
                    o += bt.nodes.items[c].len;
                }
            },
            .pair => {
                if (n.close_len == 0 and off >= r.start) try out.append(gpa, off);
                try bt.collectUnmatched(gpa, n.kids[0], off + n.open_len, r, out);
            },
        }
    }

    /// Asserts the tree's invariants (tests).
    pub fn check(bt: *const BracketTree) !void {
        var seen: std.DynamicBitSetUnmanaged = try .initEmpty(bt.gpa, bt.nodes.items.len);
        defer seen.deinit(bt.gpa);
        var f = bt.free_head;
        while (f != nil) : (f = bt.nodes.items[f].kids[0]) seen.set(f);
        if (bt.root != nil) _ = try bt.checkNode(bt.root, &seen);
    }

    fn checkNode(bt: *const BracketTree, id: NodeId, seen: *std.DynamicBitSetUnmanaged) !Node {
        if (seen.isSet(id)) return error.SharedNode;
        seen.set(id);
        const n = bt.nodes.items[id];
        switch (n.kind) {
            .text => if (n.missing != 0 or n.bad) return error.BadNode,
            .bracket => if (n.missing != bit(n.pair) or !n.bad) return error.BadNode,
            .pair => {
                var want: Node = .{ .kind = .pair, .len = @as(u32, n.open_len) + n.close_len, .bad = n.close_len == 0 };
                if (n.kids[0] != nil) {
                    const c = try bt.checkNode(n.kids[0], seen);
                    want.len += c.len;
                    want.missing = c.missing;
                    want.bad = want.bad or c.bad;
                }
                if (want.len != n.len or want.missing != n.missing or want.bad != n.bad) return error.BadNode;
            },
            .list => {
                if (n.n < 2 or n.n > 3) return error.BadList;
                var l: u64 = 0;
                var m: BracketSet = 0;
                var b = false;
                for (n.kids[0..n.n]) |k| {
                    const c = try bt.checkNode(k, seen);
                    if (c.height + 1 != n.height) return error.BadHeight;
                    l += c.len;
                    m |= c.missing;
                    b = b or c.bad;
                }
                if (l != n.len or m != n.missing or b != n.bad) return error.BadNode;
            },
        }
        if (n.reused) return error.BadNode;
        return n;
    }

    /// Live nodes (tests and benches).
    pub fn nodeCount(bt: *const BracketTree) usize {
        var free: usize = 0;
        var f = bt.free_head;
        while (f != nil) : (f = bt.nodes.items[f].kids[0]) free += 1;
        return bt.nodes.items.len - free;
    }

    fn pairInfo(n: Node, off: u64, depth: u32) BracketPairInfo {
        return .{
            .open = off,
            .open_len = n.open_len,
            .close = if (n.close_len > 0) off + n.len - n.close_len else null,
            .close_len = n.close_len,
            .depth = depth,
            .pair = n.pair,
        };
    }

    // Nodes.

    fn alloc(bt: *BracketTree, n: Node) Allocator.Error!NodeId {
        bt.stats.new_nodes += 1;
        if (bt.free_head != nil) {
            const id = bt.free_head;
            bt.free_head = bt.nodes.items[id].kids[0];
            bt.nodes.items[id] = n;
            return id;
        }
        const id: NodeId = @intCast(bt.nodes.items.len);
        try bt.nodes.append(bt.gpa, n);
        return id;
    }

    fn release(bt: *BracketTree, id: NodeId) void {
        bt.nodes.items[id] = .{ .kind = .text, .kids = .{ bt.free_head, nil, nil } };
        bt.free_head = id;
    }

    /// Frees `id` and its subtree, except reused nodes (now in the new
    /// tree) and their subtrees.
    fn freeOld(bt: *BracketTree, id: NodeId) void {
        if (id == nil) return;
        const n = bt.nodes.items[id];
        if (n.reused) return;
        switch (n.kind) {
            .text, .bracket => {},
            .pair => bt.freeOld(n.kids[0]),
            .list => for (n.kids[0..n.n]) |k| bt.freeOld(k),
        }
        bt.release(id);
    }

    fn newPair(bt: *BracketTree, pair: u6, open_len: u8, child: NodeId, close_len: u8) Allocator.Error!NodeId {
        var n: Node = .{ .kind = .pair, .pair = pair, .open_len = open_len, .close_len = close_len, .kids = .{ child, nil, nil } };
        n.len = @as(u32, open_len) + close_len;
        n.bad = close_len == 0;
        if (child != nil) {
            const c = bt.nodes.items[child];
            n.len += c.len;
            n.missing = c.missing;
            n.bad = n.bad or c.bad;
        }
        return bt.alloc(n);
    }

    fn list23(bt: *BracketTree, a: NodeId, b: NodeId, c: NodeId) Allocator.Error!NodeId {
        const id = try bt.alloc(.{ .kind = .list, .kids = .{ a, b, c }, .n = if (c == nil) 2 else 3 });
        bt.summarize(id);
        return id;
    }

    /// Recomputes a list's length, height and sets from its children.
    fn summarize(bt: *BracketTree, id: NodeId) void {
        const nodes = bt.nodes.items;
        const n = &nodes[id];
        n.len = 0;
        n.missing = 0;
        n.bad = false;
        n.height = nodes[n.kids[0]].height + 1;
        for (n.kids[0..n.n]) |k| {
            std.debug.assert(nodes[k].height + 1 == n.height);
            n.len += nodes[k].len;
            n.missing |= nodes[k].missing;
            n.bad = n.bad or nodes[k].bad;
        }
    }

    fn height(bt: *const BracketTree, id: NodeId) u8 {
        return bt.nodes.items[id].height;
    }

    /// Whether old node `id` parses the same way inside `opened`.
    fn canBeReused(bt: *const BracketTree, id: NodeId, opened: BracketSet) bool {
        var n = bt.nodes.items[id];
        if (n.missing & opened != 0) return false;
        while (true) switch (n.kind) {
            .text, .bracket => return true,
            // An unclosed pair might be closed by what follows.
            .pair => return n.close_len > 0,
            // So might a list ending in one.
            .list => n = bt.nodes.items[n.kids[n.n - 1]],
        };
    }

    // (2,3)-tree concatenation.

    /// Joins `items`, all of one height, bottom up.
    fn concatSameHeight(bt: *BracketTree, items: []NodeId) Allocator.Error!NodeId {
        if (items.len == 0) return nil;
        var n = items.len;
        while (n > 3) {
            const half = n >> 1;
            for (0..half) |i| {
                const j = i << 1;
                items[i] = try bt.list23(items[j], items[j + 1], if (j + 3 == n) items[j + 2] else nil);
            }
            n = half;
        }
        if (n == 1) return items[0];
        return bt.list23(items[0], items[1], if (n == 3) items[2] else nil);
    }

    /// Joins `items` of any heights, preferring to join trees of similar
    /// height (the cost of a join is their height difference).
    fn concat(bt: *BracketTree, items: []NodeId) Allocator.Error!NodeId {
        if (items.len == 0) return nil;
        var i: usize = 0;
        const Run = struct {
            fn next(t: *BracketTree, xs: []NodeId, at: *usize) Allocator.Error!NodeId {
                if (at.* >= xs.len) return nil;
                const start = at.*;
                const h = t.height(xs[start]);
                at.* += 1;
                while (at.* < xs.len and t.height(xs[at.*]) == h) at.* += 1;
                if (at.* - start >= 2) return t.concatSameHeight(xs[start..at.*]);
                return xs[start];
            }
        };
        var first = try Run.next(bt, items, &i);
        var second = try Run.next(bt, items, &i);
        if (second == nil) return first;
        var item = try Run.next(bt, items, &i);
        while (item != nil) : (item = try Run.next(bt, items, &i)) {
            if (heightDiff(bt, first, second) <= heightDiff(bt, second, item)) {
                first = try bt.join(first, second);
                second = item;
            } else {
                second = try bt.join(second, item);
            }
        }
        return bt.join(first, second);
    }

    fn heightDiff(bt: *const BracketTree, a: NodeId, b: NodeId) u8 {
        const x = bt.height(a);
        const y = bt.height(b);
        return if (x > y) x - y else y - x;
    }

    fn join(bt: *BracketTree, a: NodeId, b: NodeId) Allocator.Error!NodeId {
        const ha = bt.height(a);
        const hb = bt.height(b);
        if (ha == hb) return bt.list23(a, b, nil);
        if (ha > hb) return bt.append(a, b);
        return bt.prepend(b, a);
    }

    /// Appends `node` to the list `list`, which is taller.
    fn append(bt: *BracketTree, list: NodeId, node: NodeId) Allocator.Error!NodeId {
        var parents: [64]NodeId = undefined;
        var np: usize = 0;
        var cur = list;
        const h = bt.height(node);
        while (bt.height(cur) != h) {
            const c = bt.nodes.items[cur];
            std.debug.assert(c.kind == .list);
            parents[np] = cur;
            np += 1;
            cur = c.kids[c.n - 1];
        }
        var carry = node;
        var i = np;
        while (i > 0) {
            i -= 1;
            const p = parents[i];
            if (carry != nil) {
                const pn = &bt.nodes.items[p];
                if (pn.n == 3) {
                    // Split: the third child and the carry go up together.
                    const third = pn.kids[2];
                    pn.kids[2] = nil;
                    pn.n = 2;
                    bt.summarize(p);
                    carry = try bt.list23(third, carry, nil);
                } else {
                    pn.kids[2] = carry;
                    pn.n = 3;
                    bt.summarize(p);
                    carry = nil;
                }
            } else bt.summarize(p);
        }
        if (carry != nil) return bt.list23(list, carry, nil);
        return list;
    }

    /// Prepends `node` to the list `list`, which is taller.
    fn prepend(bt: *BracketTree, list: NodeId, node: NodeId) Allocator.Error!NodeId {
        var parents: [64]NodeId = undefined;
        var np: usize = 0;
        var cur = list;
        const h = bt.height(node);
        while (bt.height(cur) != h) {
            const c = bt.nodes.items[cur];
            std.debug.assert(c.kind == .list);
            parents[np] = cur;
            np += 1;
            cur = c.kids[0];
        }
        var carry = node;
        var i = np;
        while (i > 0) {
            i -= 1;
            const p = parents[i];
            if (carry != nil) {
                const pn = &bt.nodes.items[p];
                if (pn.n == 3) {
                    // Split: the carry and the first child go up together.
                    const k = pn.kids;
                    const first = k[0];
                    pn.kids = .{ k[1], k[2], nil };
                    pn.n = 2;
                    bt.summarize(p);
                    carry = try bt.list23(carry, first, nil);
                } else {
                    // Copy first: the literal would alias the field.
                    const k = pn.kids;
                    pn.kids = .{ carry, k[0], k[1] };
                    pn.n = 3;
                    bt.summarize(p);
                    carry = nil;
                }
            } else bt.summarize(p);
        }
        if (carry != nil) return bt.list23(carry, list, nil);
        return list;
    }

    // Edits.

    /// Builds `merged`: the edits and the retokenized ranges as disjoint
    /// changes with both old and new extents, sorted.
    fn mergeEdits(bt: *BracketTree, edits: []const TextEdit, retokenized: []const Range) Allocator.Error!void {
        const m = &bt.merged;
        m.clearRetainingCapacity();
        var delta: i128 = 0;
        for (edits) |e| {
            std.debug.assert(e.start <= e.end);
            const ns: u64 = @intCast(@as(i128, e.start) + delta);
            try m.append(bt.gpa, .{ .old_start = e.start, .old_end = e.end, .new_start = ns, .new_end = ns + e.new_len });
            delta += @as(i128, e.new_len) - @as(i128, e.end - e.start);
        }
        if (retokenized.len == 0) return;
        const n_edits = m.items.len;
        for (retokenized) |r| {
            if (r.end <= r.start) continue;
            try m.append(bt.gpa, .{
                .old_start = newToOld(m.items[0..n_edits], r.start, .start),
                .old_end = newToOld(m.items[0..n_edits], r.end, .end),
                .new_start = r.start,
                .new_end = r.end,
            });
        }
        std.sort.pdq(Edit2, m.items, {}, struct {
            fn lt(_: void, a: Edit2, b: Edit2) bool {
                return a.new_start < b.new_start or (a.new_start == b.new_start and a.old_start < b.old_start);
            }
        }.lt);
        // Merge overlapping or touching changes (the new-to-old mapping is
        // monotonic, so the extreme ends agree in both coordinates).
        var out: usize = 0;
        for (m.items) |e| {
            if (out > 0) {
                const last = &m.items[out - 1];
                if (e.new_start <= last.new_end) {
                    last.old_start = @min(last.old_start, e.old_start);
                    last.old_end = @max(last.old_end, e.old_end);
                    last.new_end = @max(last.new_end, e.new_end);
                    continue;
                }
            }
            m.items[out] = e;
            out += 1;
        }
        m.items.len = out;
    }

    fn newToOld(edits: []const Edit2, p: u64, side: enum { start, end }) u64 {
        // The last edit starting at or before `p`.
        var lo: usize = 0;
        var hi: usize = edits.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (edits[mid].new_start <= p) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return p;
        const e = edits[lo - 1];
        if (p < e.new_end or (p == e.new_end and p == e.new_start)) return if (side == .start) e.old_start else e.old_end;
        return p - e.new_end + e.old_end;
    }
};

const Edit2 = struct { old_start: u64, old_end: u64, new_start: u64, new_end: u64 };

/// Maps new offsets (visited in increasing order) to old ones and tells
/// how far the next change is.
const Mapper = struct {
    edits: []const Edit2,
    i: usize = 0,

    fn adjust(m: *Mapper, p: u64) void {
        while (m.i < m.edits.len and m.edits[m.i].new_end <= p) m.i += 1;
    }

    /// Bytes from `p` to the next change; null when there is none.
    fn distance(m: *Mapper, p: u64) ?u64 {
        m.adjust(p);
        if (m.i == m.edits.len) return null;
        const e = m.edits[m.i];
        return if (e.new_start <= p) 0 else e.new_start - p;
    }

    /// The old offset of `p`, which is not inside a change.
    fn toOld(m: *Mapper, p: u64) u64 {
        m.adjust(p);
        if (m.i == 0) return p;
        const e = m.edits[m.i - 1];
        return p - e.new_end + e.old_end;
    }
};

const TokKind = enum { text, open, close };
const Tok = struct { kind: TokKind, len: u32, pair: u6 = 0 };

/// Turns the bracket source into text and bracket tokens.
const Tokenizer = struct {
    src: BracketSource,
    pos: u64 = 0,
    peeked: ?Tok = null,
    /// The source's answer for a query at `nb_from`; still valid at `pos`
    /// when `nb_from <= pos` and the token does not start before `pos`.
    nb: ?BracketToken = null,
    nb_from: u64 = std.math.maxInt(u64),

    fn nextBracket(t: *Tokenizer) Allocator.Error!?BracketToken {
        if (t.nb_from <= t.pos) {
            if (t.nb) |b| {
                if (b.offset >= t.pos) return b;
            } else return null;
        }
        t.nb_from = t.pos;
        t.nb = try t.src.next(t.pos);
        return t.nb;
    }

    fn peek(t: *Tokenizer) Allocator.Error!?Tok {
        if (t.peeked) |p| return p;
        const end = textEnd(t.src);
        if (t.pos >= end) return null;
        const tok: Tok = if (try t.nextBracket()) |b| tok: {
            if (b.offset > t.pos) break :tok .{ .kind = .text, .len = @intCast(@min(b.offset, end) - t.pos) };
            if (b.len == 0) break :tok .{ .kind = .text, .len = 1 };
            break :tok .{ .kind = if (b.open) .open else .close, .len = b.len, .pair = b.pair };
        } else .{ .kind = .text, .len = @intCast(end - t.pos) };
        t.peeked = tok;
        return tok;
    }

    fn read(t: *Tokenizer) Allocator.Error!?Tok {
        const tok = (try t.peek()) orelse return null;
        t.pos += tok.len;
        t.peeked = null;
        return tok;
    }

    fn skip(t: *Tokenizer, n: u64) void {
        t.pos += n;
        t.peeked = null;
    }
};

/// Walks the old tree in order, finding the longest node that starts at
/// a given old offset and passes a test.
const Reader = struct {
    nodes: std.ArrayList(NodeId) = .empty,
    offs: std.ArrayList(u64) = .empty,
    idxs: std.ArrayList(u8) = .empty,

    fn deinit(r: *Reader, gpa: Allocator) void {
        r.nodes.deinit(gpa);
        r.offs.deinit(gpa);
        r.idxs.deinit(gpa);
    }

    fn reset(r: *Reader, gpa: Allocator, root: NodeId) Allocator.Error!void {
        r.nodes.clearRetainingCapacity();
        r.offs.clearRetainingCapacity();
        r.idxs.clearRetainingCapacity();
        if (root != nil) {
            try r.nodes.append(gpa, root);
            try r.offs.append(gpa, 0);
        }
    }

    /// The reader's child `idx` of `n`: a list's children, a pair's
    /// content (the brackets themselves are never reused).
    fn child(n: Node, idx: u8) ?NodeId {
        return switch (n.kind) {
            .list => if (idx < n.n) n.kids[idx] else null,
            .pair => if (idx == 0 and n.kids[0] != nil) n.kids[0] else null,
            .text, .bracket => null,
        };
    }

    /// Descends into the first child of the top node, or moves past it.
    fn descend(r: *Reader, gpa: Allocator, bt: *const BracketTree) Allocator.Error!void {
        const n = bt.nodes.items[r.nodes.items[r.nodes.items.len - 1]];
        if (child(n, 0)) |c| {
            const off = r.offs.items[r.offs.items.len - 1] + (if (n.kind == .pair) @as(u64, n.open_len) else 0);
            try r.nodes.append(gpa, c);
            try r.offs.append(gpa, off);
            try r.idxs.append(gpa, 0);
        } else r.advance(bt);
    }

    /// Moves to the node after the top one.
    fn advance(r: *Reader, bt: *const BracketTree) void {
        while (true) {
            const cur = r.nodes.pop().?;
            const cur_off = r.offs.pop().?;
            if (r.idxs.items.len == 0) return;
            const parent = bt.nodes.items[r.nodes.items[r.nodes.items.len - 1]];
            const idx = &r.idxs.items[r.idxs.items.len - 1];
            if (child(parent, idx.* + 1)) |c| {
                // Capacity is there: two entries were just popped.
                r.nodes.appendAssumeCapacity(c);
                r.offs.appendAssumeCapacity(cur_off + bt.nodes.items[cur].len);
                idx.* += 1;
                return;
            }
            _ = r.idxs.pop();
        }
    }

    /// The longest node starting at old offset `off`, shorter than
    /// `max_len`, that parses the same way inside `opened`. Calls must
    /// come in increasing order of `off`.
    fn readLongest(r: *Reader, gpa: Allocator, bt: *const BracketTree, off: u64, max_len: ?u64, opened: BracketSet) Allocator.Error!?NodeId {
        while (r.nodes.items.len > 0) {
            const id = r.nodes.items[r.nodes.items.len - 1];
            const n_off = r.offs.items[r.offs.items.len - 1];
            const n = bt.nodes.items[id];
            // The next node starts later: nothing to reuse here.
            if (off < n_off) return null;
            if (n_off < off) {
                if (n_off + n.len <= off) r.advance(bt) else try r.descend(gpa, bt);
                continue;
            }
            const fits = if (max_len) |m| n.len < m else true;
            if (fits and bt.canBeReused(id, opened)) {
                r.advance(bt);
                return id;
            }
            if (child(n, 0) == null) {
                r.advance(bt);
                return null;
            }
            try r.descend(gpa, bt);
        }
        return null;
    }
};

const Parser = struct {
    bt: *BracketTree,
    tz: Tokenizer,
    incremental: bool = false,
    mapper: Mapper = .{ .edits = &.{} },

    fn parseList(p: *Parser, opened: BracketSet, depth: u32) Allocator.Error!NodeId {
        const bt = p.bt;
        const base = bt.items.items.len;
        while (true) {
            var child = try p.fromCache(opened);
            if (child == nil) {
                const tok = (try p.tz.peek()) orelse break;
                if (tok.kind == .close and opened & bit(tok.pair) != 0) break;
                child = try p.parseChild(opened, depth);
            }
            try bt.items.append(bt.gpa, child);
        }
        const items = bt.items.items[base..];
        const res = if (p.incremental) try bt.concat(items) else try bt.concatSameHeight(items);
        bt.items.items.len = base;
        return res;
    }

    fn fromCache(p: *Parser, opened: BracketSet) Allocator.Error!NodeId {
        if (!p.incremental) return nil;
        const pos = p.tz.pos;
        const dist = p.mapper.distance(pos);
        if (dist) |d| if (d == 0) return nil;
        const old = p.mapper.toOld(pos);
        const id = (try p.bt.reader.readLongest(p.bt.gpa, p.bt, old, dist, opened)) orelse return nil;
        const n = &p.bt.nodes.items[id];
        n.reused = true;
        try p.bt.reused.append(p.bt.gpa, id);
        p.tz.skip(n.len);
        return id;
    }

    fn parseChild(p: *Parser, opened: BracketSet, depth: u32) Allocator.Error!NodeId {
        const bt = p.bt;
        const tok = (try p.tz.read()).?;
        switch (tok.kind) {
            .text => return bt.alloc(.{ .kind = .text, .len = tok.len }),
            .close => return bt.alloc(.{ .kind = .bracket, .len = tok.len, .pair = tok.pair, .missing = bit(tok.pair), .bad = true }),
            .open => {
                if (depth >= max_nesting) return bt.alloc(.{ .kind = .text, .len = tok.len });
                const child = try p.parseList(opened | bit(tok.pair), depth + 1);
                var close_len: u8 = 0;
                if (try p.tz.peek()) |nt| if (nt.kind == .close and nt.pair == tok.pair) {
                    _ = try p.tz.read();
                    close_len = @intCast(nt.len);
                };
                return bt.newPair(tok.pair, @intCast(tok.len), child, close_len);
            },
        }
    }
};

/// Where parsing stops: node lengths are 32-bit, so brackets past 4 GiB
/// are not tracked.
fn textEnd(src: BracketSource) u64 {
    return @min(src.len, std.math.maxInt(u32));
}

fn bit(pair: u6) BracketSet {
    return @as(BracketSet, 1) << pair;
}

/// A source over a slice of bracket tokens sorted by offset (tests and
/// simple callers).
pub const SliceSource = struct {
    tokens: []const BracketToken,
    text_len: u64,

    pub fn source(s: *SliceSource) BracketSource {
        return .{ .ctx = s, .len = s.text_len, .nextFn = next };
    }

    fn next(ctx: *anyopaque, from: u64) Allocator.Error!?BracketToken {
        const s: *SliceSource = @ptrCast(@alignCast(ctx));
        var lo: usize = 0;
        var hi: usize = s.tokens.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (s.tokens[mid].offset < from) lo = mid + 1 else hi = mid;
        }
        return if (lo < s.tokens.len) s.tokens[lo] else null;
    }
};

comptime {
    std.debug.assert(@sizeOf(Node) == 32);
}
