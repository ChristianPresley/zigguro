//! Graph lane layout: where to draw each commit and its edges when showing
//! history as a DAG. Shared by the CLI graph (E09.F10) and the GUI stack
//! view (E09.F11); no GUI imports.
//!
//! The input is the displayed commits in topological order, children
//! first. The sweep keeps `lanes[col]`, the commit each column is waiting
//! for:
//! - a commit takes the column waiting for it, or the lowest free one;
//! - its first parent continues in that column (a straight first-parent
//!   line), other parents join a column already waiting for them or take
//!   the lowest free one;
//! - when two columns wait for the same commit, the leftmost keeps it and
//!   the other converges into it; trailing free columns are dropped.
//!
//! Parents should appear later in the input (the read model passes only
//! displayed parents and marks hidden stretches as `elided_parents`); a
//! parent that never appears keeps its lane to the bottom of the graph.
//!
//! Columns from `max_columns - 1` on are one overflow column ("…") that
//! holds every lane that did not fit.
//!
//! Rows are stored in immutable chunks of up to `chunk_rows` rows, each
//! with its edges in flat arrays and the lane state after each row.
//! `computeIncremental` shares the unchanged chunks with the old layout
//! (reference counted) and copies only the rows of the chunks an edit
//! touches: the unchanged prefix, then, once the lane state matches the
//! old layout again, the unchanged suffix. Same input, same layout:
//! nothing depends on hash order.

const std = @import("std");
const index_mod = @import("index.zig");
const Allocator = std.mem.Allocator;

pub const Pos = index_mod.Pos;

pub const NodeKind = enum { normal, wc, immutable, conflict, divergent, elided_marker };

pub const GraphNodeIn = struct {
    id: Pos,
    /// Displayed parents, first parent first.
    parents: []const Pos = &.{},
    /// Displayed ancestors reached through hidden commits.
    elided_parents: []const Pos = &.{},
    kind: NodeKind = .normal,

    pub fn eql(a: GraphNodeIn, b: GraphNodeIn) bool {
        return a.id == b.id and a.kind == b.kind and
            std.mem.eql(Pos, a.parents, b.parents) and std.mem.eql(Pos, a.elided_parents, b.elided_parents);
    }
};

pub const LayoutOptions = struct {
    /// At least 2; the last column is the overflow column.
    max_columns: u16 = 32,
    /// Keep a first parent in its child's column even when another column
    /// already waits for it (that column converges instead).
    prefer_first_parent_straight: bool = true,
    /// Draw edges through hidden commits dashed (`elided`); otherwise as
    /// ordinary edges.
    collapse_elided: bool = true,
    /// Rows per storage chunk (at least 1): an incremental relayout copies
    /// at most two chunks' worth of unchanged rows and shares the rest.
    chunk_rows: u32 = 512,
};

pub const EdgeKind = enum {
    /// A first-parent edge, or a lane continuing.
    direct,
    /// Through hidden commits (dashed).
    elided,
    /// To a second or later parent.
    merge,
};

pub const Edge = struct {
    from_col: u16,
    to_col: u16,
    kind: EdgeKind,
};

pub const LaneKind = enum { solid, dashed, overflow };

/// A lane crossing a row beside its commit.
pub const Lane = struct {
    col: u16,
    kind: LaneKind,
};

pub const Row = struct {
    node_col: u16,
    /// Every edge from this row to the next: the commit's own edges (from
    /// `node_col`) and lanes passing through, sorted by `from_col` then
    /// `to_col`.
    edges_out: []const Edge,
    /// Lanes crossing the commit's row, sorted by column.
    edges_through: []const Lane,
};

/// Layouts made by `computeIncremental` share chunks with the layout they
/// came from; any of them may be freed first, from any thread.
pub const Layout = struct {
    gpa: Allocator,
    /// Columns used by the widest row.
    width: u16,
    max_columns: u16,
    count: usize,
    chunks: []*Chunk,
    /// The first row of each chunk.
    starts: []usize,

    pub fn deinit(l: *Layout) void {
        for (l.chunks) |c| c.release(l.gpa);
        l.gpa.free(l.chunks);
        l.gpa.free(l.starts);
        l.* = undefined;
    }

    /// The number of rows: one per commit.
    pub fn len(l: *const Layout) usize {
        return l.count;
    }

    /// Row `i`; its slices live as long as the layout.
    pub fn row(l: *const Layout, i: usize) Row {
        const c = l.chunkOf(i);
        return l.chunks[c].row(i - l.starts[c]);
    }

    /// The rows in order.
    pub fn iterator(l: *const Layout) RowIterator {
        return .{ .chunks = l.chunks };
    }

    /// The chunk holding row `i`.
    fn chunkOf(l: *const Layout, i: usize) usize {
        std.debug.assert(i < l.count);
        var lo: usize = 0;
        var hi: usize = l.starts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (l.starts[mid] <= i) lo = mid else hi = mid;
        }
        return lo;
    }

    fn state(l: *const Layout, i: usize) State {
        const c = l.chunkOf(i);
        return l.chunks[c].state(i - l.starts[c]);
    }
};

pub const RowIterator = struct {
    chunks: []const *Chunk,
    c: usize = 0,
    i: usize = 0,

    pub fn next(it: *RowIterator) ?Row {
        while (it.c < it.chunks.len) {
            const ch = it.chunks[it.c];
            if (it.i < ch.recs.len) {
                it.i += 1;
                return ch.row(it.i - 1);
            }
            it.c += 1;
            it.i = 0;
        }
        return null;
    }
};

/// Up to `chunk_rows` rows; immutable once built.
const Chunk = struct {
    refs: std.atomic.Value(u32),
    /// Columns used by the widest row of the chunk.
    width: u16,
    recs: []Rec,
    edges: []Edge,
    through: []Lane,
    states: []Slot,

    fn row(c: *const Chunk, i: usize) Row {
        const r = c.recs[i];
        return .{
            .node_col = r.node_col,
            .edges_out = c.edges[r.e_start..][0..r.e_len],
            .edges_through = c.through[r.t_start..][0..r.t_len],
        };
    }

    fn state(c: *const Chunk, i: usize) State {
        const r = c.recs[i];
        return .{ .slots = c.states[r.s_start..][0..r.s_len], .regular = r.s_reg };
    }

    fn release(c: *Chunk, gpa: Allocator) void {
        if (c.refs.fetchSub(1, .acq_rel) != 1) return;
        gpa.free(c.recs);
        gpa.free(c.edges);
        gpa.free(c.through);
        gpa.free(c.states);
        gpa.destroy(c);
    }
};

const none: u32 = std.math.maxInt(u32);

/// A lane: the commit it waits for (`none` when free) and how it is drawn.
const Slot = struct {
    target: u32,
    kind: LaneKind,

    fn free(s: Slot) bool {
        return s.target == none;
    }
};

/// Offsets of one row's data in its chunk's flat arrays.
const Rec = struct {
    node_col: u16,
    e_start: u32,
    e_len: u16,
    t_start: u32,
    t_len: u16,
    s_start: u32,
    /// Regular columns in the state; the rest are overflow targets.
    s_reg: u16,
    s_len: u32,
};

const State = struct {
    slots: []const Slot,
    regular: u16,

    fn eql(a: State, b: State) bool {
        if (a.regular != b.regular or a.slots.len != b.slots.len) return false;
        for (a.slots, b.slots) |x, y| if (x.target != y.target or x.kind != y.kind) return false;
        return true;
    }
};

const Builder = struct {
    gpa: Allocator,
    opts: LayoutOptions,
    lanes: std.ArrayList(Slot) = .empty,
    overflow: std.ArrayList(u32) = .empty,
    next: std.ArrayList(Slot) = .empty,
    // The chunk being built.
    recs: std.ArrayList(Rec) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    through: std.ArrayList(Lane) = .empty,
    states: std.ArrayList(Slot) = .empty,
    chunk_width: u16 = 0,
    // Finished chunks.
    chunks: std.ArrayList(*Chunk) = .empty,
    starts: std.ArrayList(usize) = .empty,
    sealed_rows: usize = 0,
    width: u16 = 0,

    fn deinit(b: *Builder) void {
        const gpa = b.gpa;
        b.lanes.deinit(gpa);
        b.overflow.deinit(gpa);
        b.next.deinit(gpa);
        b.recs.deinit(gpa);
        b.edges.deinit(gpa);
        b.through.deinit(gpa);
        b.states.deinit(gpa);
        for (b.chunks.items) |c| c.release(gpa);
        b.chunks.deinit(gpa);
        b.starts.deinit(gpa);
    }

    fn regularCap(b: *const Builder) u16 {
        return b.opts.max_columns - 1;
    }

    fn overflowCol(b: *const Builder) u16 {
        return b.opts.max_columns - 1;
    }

    /// Room for a chunk of `n` rows.
    fn reserve(b: *Builder, n: usize) !void {
        const gpa = b.gpa;
        try b.recs.ensureTotalCapacity(gpa, n);
        try b.edges.ensureTotalCapacity(gpa, n * 2);
        try b.through.ensureTotalCapacity(gpa, n);
        try b.states.ensureTotalCapacity(gpa, n * 2);
    }

    /// Ends the chunk being built, if it has rows.
    fn seal(b: *Builder) !void {
        if (b.recs.items.len == 0) return;
        const gpa = b.gpa;
        try b.chunks.ensureUnusedCapacity(gpa, 1);
        try b.starts.ensureUnusedCapacity(gpa, 1);
        const c = try gpa.create(Chunk);
        errdefer gpa.destroy(c);
        const states = try b.states.toOwnedSlice(gpa);
        errdefer gpa.free(states);
        const through = try b.through.toOwnedSlice(gpa);
        errdefer gpa.free(through);
        const edges = try b.edges.toOwnedSlice(gpa);
        errdefer gpa.free(edges);
        const recs = try b.recs.toOwnedSlice(gpa);
        c.* = .{ .refs = .init(1), .width = b.chunk_width, .recs = recs, .edges = edges, .through = through, .states = states };
        b.push(c);
        b.chunk_width = 0;
    }

    fn sealIfFull(b: *Builder) !void {
        if (b.recs.items.len < b.opts.chunk_rows) return;
        try b.seal();
        try b.reserve(b.opts.chunk_rows);
    }

    fn push(b: *Builder, c: *Chunk) void {
        b.chunks.appendAssumeCapacity(c);
        b.starts.appendAssumeCapacity(b.sealed_rows);
        b.sealed_rows += c.recs.len;
        b.width = @max(b.width, c.width);
    }

    /// Appends `c`, shared with the layout it came from.
    fn share(b: *Builder, c: *Chunk) !void {
        try b.seal();
        try b.chunks.ensureUnusedCapacity(b.gpa, 1);
        try b.starts.ensureUnusedCapacity(b.gpa, 1);
        _ = c.refs.fetchAdd(1, .monotonic);
        b.push(c);
    }

    /// Appends a copy of row `i` of `c`.
    fn copyRow(b: *Builder, c: *const Chunk, i: usize) !void {
        const gpa = b.gpa;
        const r = c.recs[i];
        var n = r;
        n.e_start = @intCast(b.edges.items.len);
        n.t_start = @intCast(b.through.items.len);
        n.s_start = @intCast(b.states.items.len);
        try b.edges.appendSlice(gpa, c.edges[r.e_start..][0..r.e_len]);
        try b.through.appendSlice(gpa, c.through[r.t_start..][0..r.t_len]);
        try b.states.appendSlice(gpa, c.states[r.s_start..][0..r.s_len]);
        try b.recs.append(gpa, n);
        b.chunk_width = @max(b.chunk_width, rowWidth(c, r));
        try b.sealIfFull();
    }

    /// Appends rows `from..to` of `l`: copies of the rows of chunks only
    /// partly in range, the whole chunks shared.
    fn appendRows(b: *Builder, l: *const Layout, from: usize, to: usize) !void {
        if (from >= to) return;
        var c = l.chunkOf(from);
        var i = from;
        while (i < to) : (c += 1) {
            const ch = l.chunks[c];
            const start = l.starts[c];
            const end = start + ch.recs.len;
            if (i == start and end <= to) {
                try b.share(ch);
            } else {
                for (i - start..@min(end, to) - start) |x| try b.copyRow(ch, x);
            }
            i = @min(end, to);
        }
    }

    /// The lane state after the last row added.
    fn lastState(b: *const Builder) State {
        if (b.recs.items.len > 0) {
            const r = b.recs.getLast();
            return .{ .slots = b.states.items[r.s_start..][0..r.s_len], .regular = r.s_reg };
        }
        if (b.chunks.items.len == 0) return .{ .slots = &.{}, .regular = 0 };
        const c = b.chunks.getLast();
        return c.state(c.recs.len - 1);
    }

    fn find(slots: []const Slot, target: u32) ?u16 {
        for (slots, 0..) |s, c| if (s.target == target) return @intCast(c);
        return null;
    }

    fn findOverflow(b: *const Builder, target: u32) ?usize {
        for (b.overflow.items, 0..) |t, k| if (t == target) return k;
        return null;
    }

    /// The lowest free column of `next`, growing it within the cap.
    fn freeCol(b: *Builder) !?u16 {
        for (b.next.items, 0..) |s, c| if (s.free()) return @intCast(c);
        if (b.next.items.len < b.regularCap()) {
            try b.next.append(b.gpa, .{ .target = none, .kind = .solid });
            return @intCast(b.next.items.len - 1);
        }
        return null;
    }

    /// Where `target` waits after this row: a regular column, else the
    /// overflow column.
    fn colOf(b: *const Builder, target: u32) u16 {
        return find(b.next.items, target) orelse b.overflowCol();
    }

    fn addRow(b: *Builder, node: GraphNodeIn) !void {
        const gpa = b.gpa;
        const id = @intFromEnum(node.id);
        const ovf = b.overflowCol();

        // The commit's column.
        var node_col: u16 = undefined;
        var in_overflow = false;
        if (find(b.lanes.items, id)) |c| {
            node_col = c;
        } else {
            if (b.findOverflow(id)) |k| _ = b.overflow.orderedRemove(k);
            node_col = for (b.lanes.items, 0..) |s, c| {
                if (s.free()) break @intCast(c);
            } else if (b.lanes.items.len < b.regularCap()) blk: {
                try b.lanes.append(gpa, .{ .target = none, .kind = .solid });
                break :blk @intCast(b.lanes.items.len - 1);
            } else blk: {
                in_overflow = true;
                break :blk ovf;
            };
        }

        // Lanes crossing the row.
        const t_start = b.through.items.len;
        for (b.lanes.items, 0..) |s, c| {
            if (c == node_col or s.free()) continue;
            try b.through.append(gpa, .{ .col = @intCast(c), .kind = s.kind });
        }
        if (b.overflow.items.len > 0 and !in_overflow) try b.through.append(gpa, .{ .col = ovf, .kind = .overflow });

        // The lane state after the row.
        b.next.clearRetainingCapacity();
        try b.next.appendSlice(gpa, b.lanes.items);
        if (!in_overflow) b.next.items[node_col] = .{ .target = none, .kind = .solid };
        const overflow_before = b.overflow.items.len;

        const NodeEdge = struct { target: u32, kind: EdgeKind };
        var node_edges: [64]NodeEdge = undefined;
        var n_node_edges: usize = 0;
        var extra: std.ArrayList(NodeEdge) = .empty;
        defer extra.deinit(gpa);
        const elided_kind: EdgeKind = if (b.opts.collapse_elided) .elided else .direct;
        var first = true;
        for ([2][]const Pos{ node.parents, node.elided_parents }, 0..) |list, li| {
            for (list) |p| {
                const t = @intFromEnum(p);
                const kind: EdgeKind = if (li == 1) elided_kind else if (first) .direct else .merge;
                const lane_kind: LaneKind = if (kind == .elided) .dashed else .solid;
                // Skip a parent listed twice.
                const dup = for (node_edges[0..n_node_edges]) |e| {
                    if (e.target == t) break true;
                } else for (extra.items) |e| {
                    if (e.target == t) break true;
                } else false;
                if (dup) continue;
                if (first and !in_overflow) {
                    try b.placeFirst(node_col, t, lane_kind);
                } else if (find(b.next.items, t) == null and b.findOverflow(t) == null) {
                    if (try b.freeCol()) |c| {
                        b.next.items[c] = .{ .target = t, .kind = lane_kind };
                    } else try b.overflow.append(gpa, t);
                } else if (find(b.next.items, t)) |c| {
                    if (lane_kind == .solid) b.next.items[c].kind = .solid;
                }
                first = false;
                const e: NodeEdge = .{ .target = t, .kind = kind };
                if (n_node_edges < node_edges.len) {
                    node_edges[n_node_edges] = e;
                    n_node_edges += 1;
                } else try extra.append(gpa, e);
            }
        }
        while (b.next.items.len > 0 and b.next.getLast().free()) _ = b.next.pop();

        // Edges, sorted by (from, to).
        const e_start = b.edges.items.len;
        for (b.lanes.items, 0..) |s, c| {
            if (c == node_col and !in_overflow) {
                try b.appendNodeEdges(node_col, node_edges[0..n_node_edges], extra.items);
                continue;
            }
            if (s.free()) continue;
            try b.edges.append(gpa, .{ .from_col = @intCast(c), .to_col = b.colOf(s.target), .kind = if (s.kind == .dashed) .elided else .direct });
        }
        if (in_overflow) try b.appendNodeEdges(ovf, node_edges[0..n_node_edges], extra.items);
        if (overflow_before > 0 and b.overflow.items.len > 0) {
            try b.edges.append(gpa, .{ .from_col = ovf, .to_col = ovf, .kind = .direct });
        }
        const out = b.edges.items[e_start..];
        std.mem.sort(Edge, out, {}, edgeLess);

        // Record the row.
        const s_start = b.states.items.len;
        try b.states.appendSlice(gpa, b.next.items);
        for (b.overflow.items) |t| try b.states.append(gpa, .{ .target = t, .kind = .overflow });
        try b.recs.append(gpa, .{
            .node_col = node_col,
            .e_start = @intCast(e_start),
            .e_len = @intCast(out.len),
            .t_start = @intCast(t_start),
            .t_len = @intCast(b.through.items.len - t_start),
            .s_start = @intCast(s_start),
            .s_reg = @intCast(b.next.items.len),
            .s_len = @intCast(b.states.items.len - s_start),
        });
        b.chunk_width = @max(b.chunk_width, widthOf(node_col, b.through.items[t_start..], out));
        std.mem.swap(std.ArrayList(Slot), &b.lanes, &b.next);
    }

    /// Puts first parent `t` in the commit's column, or, when another
    /// column waits for it, keeps the leftmost (or, without
    /// `prefer_first_parent_straight`, the existing one).
    fn placeFirst(b: *Builder, node_col: u16, t: u32, kind: LaneKind) !void {
        if (find(b.next.items, t)) |c| {
            if (!b.opts.prefer_first_parent_straight or c < node_col) {
                if (kind == .solid) b.next.items[c].kind = .solid;
                return;
            }
            // Converge the other column into the commit's.
            const other = b.next.items[c].kind;
            b.next.items[c] = .{ .target = none, .kind = .solid };
            b.next.items[node_col] = .{ .target = t, .kind = if (kind == .solid or other == .solid) .solid else .dashed };
            return;
        }
        if (b.findOverflow(t)) |k| _ = b.overflow.orderedRemove(k);
        b.next.items[node_col] = .{ .target = t, .kind = kind };
    }

    fn appendNodeEdges(b: *Builder, from: u16, a: anytype, extra: anytype) !void {
        for (a) |e| try b.edges.append(b.gpa, .{ .from_col = from, .to_col = b.colOf(e.target), .kind = e.kind });
        for (extra) |e| try b.edges.append(b.gpa, .{ .from_col = from, .to_col = b.colOf(e.target), .kind = e.kind });
    }

    fn finish(b: *Builder) !Layout {
        const gpa = b.gpa;
        try b.seal();
        const starts = try b.starts.toOwnedSlice(gpa);
        errdefer gpa.free(starts);
        const chunks = try b.chunks.toOwnedSlice(gpa);
        return .{ .gpa = gpa, .width = b.width, .max_columns = b.opts.max_columns, .count = b.sealed_rows, .chunks = chunks, .starts = starts };
    }
};

fn edgeLess(_: void, a: Edge, b: Edge) bool {
    if (a.from_col != b.from_col) return a.from_col < b.from_col;
    if (a.to_col != b.to_col) return a.to_col < b.to_col;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

pub fn compute(gpa: Allocator, nodes: []const GraphNodeIn, opts: LayoutOptions) !Layout {
    std.debug.assert(opts.max_columns >= 2);
    std.debug.assert(opts.chunk_rows >= 1);
    var b: Builder = .{ .gpa = gpa, .opts = opts };
    defer b.deinit();
    try b.reserve(@min(nodes.len, opts.chunk_rows));
    for (nodes) |n| {
        try b.addRow(n);
        try b.sealIfFull();
    }
    return b.finish();
}

/// The layout of `nodes`, reusing `prev` (the layout of `prev_nodes` with
/// the same options): rows before the first changed commit are reused,
/// and so is the tail once the lane state matches the old layout's at the
/// same distance from the end. Whole chunks are shared with `prev`.
pub fn computeIncremental(prev: *const Layout, prev_nodes: []const GraphNodeIn, nodes: []const GraphNodeIn, opts: LayoutOptions, gpa: Allocator) !Layout {
    std.debug.assert(prev.count == prev_nodes.len and prev.max_columns == opts.max_columns and opts.chunk_rows >= 1);
    var k: usize = 0;
    const m = @min(nodes.len, prev_nodes.len);
    while (k < m and nodes[k].eql(prev_nodes[k])) k += 1;
    var s: usize = 0;
    while (s < m - k and nodes[nodes.len - 1 - s].eql(prev_nodes[prev_nodes.len - 1 - s])) s += 1;

    var b: Builder = .{ .gpa = gpa, .opts = opts };
    defer b.deinit();
    try b.reserve(@min(nodes.len, opts.chunk_rows));

    // The prefix.
    if (k > 0) {
        try b.appendRows(prev, 0, k);
        const st = prev.state(k - 1);
        try b.lanes.appendSlice(gpa, st.slots[0..st.regular]);
        for (st.slots[st.regular..]) |o| try b.overflow.append(gpa, o.target);
    }

    // Changed rows, until the lane state lines up with the old layout.
    const suffix_start = nodes.len - s;
    var j = k;
    while (j < nodes.len) : (j += 1) {
        try b.addRow(nodes[j]);
        if (j + 1 < suffix_start or j + 1 == nodes.len) {
            try b.sealIfFull();
            continue;
        }
        // The old row at the same distance from the end (-1: before the
        // first row).
        const old_j: isize = @as(isize, @intCast(j + prev_nodes.len)) - @as(isize, @intCast(nodes.len));
        const was: State = if (old_j < 0) .{ .slots = &.{}, .regular = 0 } else prev.state(@intCast(old_j));
        const same = b.lastState().eql(was);
        try b.sealIfFull();
        if (!same) continue;
        try b.appendRows(prev, @intCast(old_j + 1), prev.count);
        break;
    }
    return b.finish();
}

fn rowWidth(c: *const Chunk, r: Rec) u16 {
    return widthOf(r.node_col, c.through[r.t_start..][0..r.t_len], c.edges[r.e_start..][0..r.e_len]);
}

/// The columns a row draws in.
fn widthOf(node_col: u16, through: []const Lane, edges: []const Edge) u16 {
    var w: u16 = node_col + 1;
    for (through) |t| w = @max(w, t.col + 1);
    for (edges) |e| w = @max(w, @max(e.from_col, e.to_col) + 1);
    return w;
}

pub const Glyphs = struct {
    normal: []const u8 = "o",
    wc: []const u8 = "@",
    immutable: []const u8 = "#",
    conflict: []const u8 = "x",
    divergent: []const u8 = "?",
    elided_marker: []const u8 = "~",
    pipe: []const u8 = "|",
    dashed: []const u8 = ":",
    overflow: []const u8 = ".",
    up_left: []const u8 = "/",
    up_right: []const u8 = "\\",
    across: []const u8 = "_",

    pub const ascii: Glyphs = .{};
    pub const unicode: Glyphs = .{
        .normal = "○",
        .wc = "@",
        .immutable = "◆",
        .conflict = "×",
        .divergent = "◌",
        .elided_marker = "~",
        .pipe = "│",
        .dashed = "┆",
        .overflow = "…",
        .up_left = "╱",
        .up_right = "╲",
        .across = "─",
    };

    fn node(g: Glyphs, k: NodeKind) []const u8 {
        return switch (k) {
            .normal => g.normal,
            .wc => g.wc,
            .immutable => g.immutable,
            .conflict => g.conflict,
            .divergent => g.divergent,
            .elided_marker => g.elided_marker,
        };
    }
};

/// Draws the graph: one line per commit (two characters per column) and
/// one connector line between commits.
pub fn renderAscii(layout: *const Layout, nodes: []const GraphNodeIn, w: *std.Io.Writer, glyphs: Glyphs) !void {
    return renderLabeled(layout, nodes, w, glyphs, &.{});
}

/// `renderAscii`, with `labels[i]` after commit `i`'s line.
pub fn renderLabeled(layout: *const Layout, nodes: []const GraphNodeIn, w: *std.Io.Writer, glyphs: Glyphs, labels: []const []const u8) !void {
    // Cells name glyphs, so wide glyphs still take one cell. Columns past
    // 1024 are not drawn.
    var cells_buf: [2 * 1024]Cell = undefined;
    const ncells = @min(cells_buf.len, 2 * @as(usize, layout.width));
    const cells = cells_buf[0..ncells];
    var rows = layout.iterator();
    var i: usize = 0;
    while (rows.next()) |row| : (i += 1) {
        @memset(cells, .space);
        for (row.edges_through) |t| {
            if (2 * t.col >= cells.len) continue;
            cells[2 * t.col] = switch (t.kind) {
                .solid => .pipe,
                .dashed => .dashed,
                .overflow => .overflow,
            };
        }
        if (2 * row.node_col < cells.len) cells[2 * row.node_col] = .node;
        var end = cells.len;
        while (end > 0 and cells[end - 1] == .space) end -= 1;
        for (cells[0..end]) |c| try w.writeAll(switch (c) {
            .space => " ",
            .node => glyphs.node(nodes[i].kind),
            .pipe => glyphs.pipe,
            .dashed => glyphs.dashed,
            .overflow => glyphs.overflow,
            else => unreachable,
        });
        if (i < labels.len) try w.print("  {s}", .{labels[i]});
        try w.writeByte('\n');
        if (row.edges_out.len == 0) continue;

        @memset(cells, .space);
        for (row.edges_out) |e| {
            const from = 2 * @as(usize, e.from_col);
            const to = 2 * @as(usize, e.to_col);
            if (from == to) {
                put(cells, from, if (isOverflowLane(row, e)) .overflow else if (e.kind == .elided) .dashed else .pipe);
            } else if (to < from) {
                put(cells, from - 1, .up_left);
                var x = to + 1;
                while (x + 1 < from) : (x += 1) put(cells, x, .across);
            } else {
                put(cells, from + 1, .up_right);
                var x = from + 2;
                while (x < to) : (x += 1) put(cells, x, .across);
            }
        }
        end = cells.len;
        while (end > 0 and cells[end - 1] == .space) end -= 1;
        for (cells[0..end]) |c| try w.writeAll(switch (c) {
            .space => " ",
            .pipe => glyphs.pipe,
            .dashed => glyphs.dashed,
            .overflow => glyphs.overflow,
            .up_left => glyphs.up_left,
            .up_right => glyphs.up_right,
            .across => glyphs.across,
            .node => unreachable,
        });
        try w.writeByte('\n');
    }
}

const Cell = enum(u8) { space, node, pipe, dashed, overflow, up_left, up_right, across };

/// Sets a cell unless a stronger glyph is there: lines beat diagonals,
/// diagonals beat `_`.
fn put(cells: []Cell, at: usize, c: Cell) void {
    if (at >= cells.len) return;
    if (rank(c) > rank(cells[at])) cells[at] = c;
}

fn rank(c: Cell) u8 {
    return switch (c) {
        .space => 0,
        .across => 1,
        .up_left, .up_right => 2,
        else => 3,
    };
}

fn isOverflowLane(row: Row, e: Edge) bool {
    if (row.node_col == e.from_col) return false;
    for (row.edges_through) |t| if (t.col == e.from_col) return t.kind == .overflow;
    return false;
}
