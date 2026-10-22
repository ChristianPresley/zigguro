//! The visible rows of a tree, flattened (E04.F04.S02.T02).
//!
//! `FlatTree` keeps the rows a tree view shows, in order: every root and,
//! below each expanded node, its children. Expanding splices the node's
//! visible descendants in after it, collapsing cuts them out, so both cost
//! the rows they touch, not the size of the tree. Nodes stay expanded while
//! an ancestor is collapsed, so reopening the ancestor brings them back.
//!
//! The tree's data comes from a `TreeSource`. A node whose children are not
//! known yet (`child_count` returns `.unknown_loading`) shows one
//! placeholder row while the source loads them; the source then calls the
//! `LoadDone` it was given, on the UI thread, and the rows are refreshed.
//!
//! Node ids are the source's: unique, stable `u64`s.

const std = @import("std");
const Ui = @import("../core/ui.zig").Ui;

const Allocator = std.mem.Allocator;

/// How many children a node has.
pub const ChildCount = union(enum) {
    known: u32,
    /// Not known yet; expanding the node asks the source to load them.
    unknown_loading,
    leaf,
};

/// Called by a source when a node's children have loaded (on the UI
/// thread).
pub const LoadDone = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, node: u64) void,

    pub fn call(d: LoadDone, node: u64) void {
        d.f(d.ctx, node);
    }
};

/// Facts about a row, for `TreeSource.build_row`.
pub const RowInfo = struct {
    index: usize,
    depth: u16,
    expanded: bool,
    selected: bool,
    active: bool,
};

/// Where a tree's data comes from.
pub const TreeSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        root_count: *const fn (ptr: *anyopaque) u32,
        /// `node`'s children, as far as they are known.
        child_count: *const fn (ptr: *anyopaque, node: u64) ChildCount,
        /// Child `i` of `parent`, or root `i` when `parent` is null.
        child: *const fn (ptr: *anyopaque, parent: ?u64, i: u32) u64,
        /// Starts loading `node`'s children (after `.unknown_loading`); call
        /// `done` on the UI thread when `child_count` knows them. Null for
        /// sources that always know.
        load: ?*const fn (ptr: *anyopaque, node: u64, done: LoadDone) void = null,
        /// The row's text (also its accessible name and type-ahead key).
        label: *const fn (ptr: *anyopaque, node: u64) []const u8,
        /// Builds the row's content instead of the label (inside the row,
        /// after the indent and chevron). Null draws the label.
        build_row: ?*const fn (ptr: *anyopaque, ui: *Ui, node: u64, info: RowInfo) void = null,
    };

    pub fn rootCount(s: TreeSource) u32 {
        return s.vtable.root_count(s.ptr);
    }
    pub fn childCount(s: TreeSource, node: u64) ChildCount {
        return s.vtable.child_count(s.ptr, node);
    }
    pub fn child(s: TreeSource, parent: ?u64, i: u32) u64 {
        return s.vtable.child(s.ptr, parent, i);
    }
    pub fn label(s: TreeSource, node: u64) []const u8 {
        return s.vtable.label(s.ptr, node);
    }
};

/// Row flags.
pub const Flags = packed struct(u16) {
    /// The node is expanded (its children follow).
    expanded: bool = false,
    /// The node has or may have children.
    expandable: bool = false,
    /// A "loading" row standing in for the children of `node`.
    placeholder: bool = false,
    _pad: u13 = 0,
};

/// One visible row.
pub const Row = struct {
    node: u64,
    depth: u16,
    flags: Flags = .{},
};

/// The visible rows.
pub const FlatTree = struct {
    gpa: Allocator,
    rows: std.ArrayList(Row) = .empty,
    expanded: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Nodes whose children are loading.
    loading: std.AutoHashMapUnmanaged(u64, void) = .empty,
    scratch: std.ArrayList(Row) = .empty,

    pub fn init(gpa: Allocator) FlatTree {
        return .{ .gpa = gpa };
    }

    pub fn deinit(t: *FlatTree) void {
        t.rows.deinit(t.gpa);
        t.expanded.deinit(t.gpa);
        t.loading.deinit(t.gpa);
        t.scratch.deinit(t.gpa);
    }

    pub fn len(t: *const FlatTree) usize {
        return t.rows.items.len;
    }

    pub fn isExpanded(t: *const FlatTree, node: u64) bool {
        return t.expanded.contains(node);
    }

    /// Rebuilds every row from the source (after the source changed).
    pub fn rebuild(t: *FlatTree, src: TreeSource, done: ?LoadDone) Allocator.Error!void {
        t.rows.clearRetainingCapacity();
        t.scratch.clearRetainingCapacity();
        const n = src.rootCount();
        var i: u32 = 0;
        while (i < n) : (i += 1) try t.emit(src, &t.scratch, src.child(null, i), 0, done);
        try t.rows.appendSlice(t.gpa, t.scratch.items);
    }

    /// Appends `node`'s row and, when it is expanded, its visible
    /// descendants to `out`.
    fn emit(t: *FlatTree, src: TreeSource, out: *std.ArrayList(Row), node: u64, depth: u16, done: ?LoadDone) Allocator.Error!void {
        const cc = src.childCount(node);
        const open = cc != .leaf and t.expanded.contains(node);
        try out.append(t.gpa, .{ .node = node, .depth = depth, .flags = .{ .expanded = open, .expandable = cc != .leaf } });
        if (open) try t.emitChildren(src, out, node, cc, depth + 1, done);
    }

    fn emitChildren(t: *FlatTree, src: TreeSource, out: *std.ArrayList(Row), node: u64, cc: ChildCount, depth: u16, done: ?LoadDone) Allocator.Error!void {
        switch (cc) {
            .leaf => {},
            .known => |n| {
                var i: u32 = 0;
                while (i < n) : (i += 1) try t.emit(src, out, src.child(node, i), depth, done);
            },
            .unknown_loading => {
                try out.append(t.gpa, .{ .node = node, .depth = depth, .flags = .{ .placeholder = true } });
                try t.startLoad(src, node, done);
            },
        }
    }

    fn startLoad(t: *FlatTree, src: TreeSource, node: u64, done: ?LoadDone) Allocator.Error!void {
        const load = src.vtable.load orelse return;
        const d = done orelse return;
        const gop = try t.loading.getOrPut(t.gpa, node);
        if (gop.found_existing) return;
        load(src.ptr, node, d);
    }

    /// One past the last row of row `i`'s subtree.
    pub fn subtreeEnd(t: *const FlatTree, i: usize) usize {
        const rows = t.rows.items;
        const d = rows[i].depth;
        var j = i + 1;
        while (j < rows.len and rows[j].depth > d) : (j += 1) {}
        return j;
    }

    /// The row of `i`'s parent, or null for a root.
    pub fn parentRow(t: *const FlatTree, i: usize) ?usize {
        const rows = t.rows.items;
        if (rows[i].depth == 0) return null;
        var j = i;
        while (j > 0) {
            j -= 1;
            if (rows[j].depth < rows[i].depth) return j;
        }
        return null;
    }

    /// The row showing `node` (not a placeholder), if visible.
    pub fn rowOf(t: *const FlatTree, node: u64) ?usize {
        for (t.rows.items, 0..) |r, i| if (r.node == node and !r.flags.placeholder) return i;
        return null;
    }

    /// Expands row `i`; false when it was a leaf or already open.
    pub fn expand(t: *FlatTree, src: TreeSource, i: usize, done: ?LoadDone) Allocator.Error!bool {
        const r = &t.rows.items[i];
        if (r.flags.placeholder or !r.flags.expandable or r.flags.expanded) return false;
        const cc = src.childCount(r.node);
        if (cc == .leaf) {
            r.flags.expandable = false;
            return false;
        }
        try t.expanded.put(t.gpa, r.node, {});
        r.flags.expanded = true;
        t.scratch.clearRetainingCapacity();
        try t.emitChildren(src, &t.scratch, r.node, cc, r.depth + 1, done);
        try t.rows.insertSlice(t.gpa, i + 1, t.scratch.items);
        return true;
    }

    /// Collapses row `i`; false when it was not open.
    pub fn collapse(t: *FlatTree, i: usize) bool {
        const r = &t.rows.items[i];
        if (!r.flags.expanded) return false;
        _ = t.expanded.remove(r.node);
        r.flags.expanded = false;
        const end = t.subtreeEnd(i);
        t.rows.replaceRangeAssumeCapacity(i + 1, end - (i + 1), &.{});
        return true;
    }

    /// Expands every collapsed sibling of row `i` (APG `*`); returns how
    /// many opened.
    pub fn expandSiblings(t: *FlatTree, src: TreeSource, i: usize, done: ?LoadDone) Allocator.Error!usize {
        const d = t.rows.items[i].depth;
        var j: usize = if (t.parentRow(i)) |p| p + 1 else 0;
        var opened: usize = 0;
        while (j < t.rows.items.len and t.rows.items[j].depth >= d) {
            if (t.rows.items[j].depth == d and try t.expand(src, j, done)) opened += 1;
            j = t.subtreeEnd(j);
        }
        return opened;
    }

    /// Re-reads `node`'s children (after its load finished or the source
    /// changed them).
    pub fn refresh(t: *FlatTree, src: TreeSource, node: u64, done: ?LoadDone) Allocator.Error!void {
        _ = t.loading.remove(node);
        const i = t.rowOf(node) orelse return;
        const r = &t.rows.items[i];
        const cc = src.childCount(node);
        r.flags.expandable = cc != .leaf;
        if (!r.flags.expanded) return;
        const end = t.subtreeEnd(i);
        t.rows.replaceRangeAssumeCapacity(i + 1, end - (i + 1), &.{});
        if (cc == .leaf) {
            r.flags.expanded = false;
            _ = t.expanded.remove(node);
            return;
        }
        const depth = r.depth + 1;
        t.scratch.clearRetainingCapacity();
        try t.emitChildren(src, &t.scratch, node, cc, depth, done);
        try t.rows.insertSlice(t.gpa, i + 1, t.scratch.items);
    }
};

// -- tests ------------------------------------------------------------------

/// A random tree: node `n`'s children are `n * 8 + 1 ..`, up to depth 4.
/// Nodes divisible by 7 load lazily until `loaded` holds them.
const TestSource = struct {
    seed: u64,
    loaded: std.AutoHashMapUnmanaged(u64, void) = .empty,
    loads: u32 = 0,

    fn kids(s: *const TestSource, node: u64) u32 {
        if (node > 8 * 8 * 8 * 8) return 0;
        return @intCast(std.hash.Wyhash.hash(s.seed, std.mem.asBytes(&node)) % 5);
    }

    fn rootCount(_: *anyopaque) u32 {
        return 4;
    }
    fn childCount(p: *anyopaque, node: u64) ChildCount {
        const s: *TestSource = @ptrCast(@alignCast(p));
        const k = s.kids(node);
        if (k == 0) return .leaf;
        if (node % 7 == 0 and !s.loaded.contains(node)) return .unknown_loading;
        return .{ .known = k };
    }
    fn child(_: *anyopaque, parent: ?u64, i: u32) u64 {
        return if (parent) |q| q * 8 + 1 + i else i + 1;
    }
    fn load(p: *anyopaque, _: u64, _: LoadDone) void {
        const s: *TestSource = @ptrCast(@alignCast(p));
        s.loads += 1;
    }
    fn label(_: *anyopaque, _: u64) []const u8 {
        return "";
    }

    const vt: TreeSource.VTable = .{ .root_count = rootCount, .child_count = childCount, .child = child, .load = load, .label = label };

    fn source(s: *TestSource) TreeSource {
        return .{ .ptr = s, .vtable = &vt };
    }
};

fn noopDone(_: *anyopaque, _: u64) void {}

test "flat tree: incremental expand/collapse matches a full rebuild" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x7eee);
    const rnd = prng.random();
    var seed: u64 = 0;
    while (seed < 20) : (seed += 1) {
        var s: TestSource = .{ .seed = seed };
        defer s.loaded.deinit(gpa);
        const src = s.source();
        var dummy: u8 = 0;
        const done: LoadDone = .{ .ctx = &dummy, .f = noopDone };
        var t: FlatTree = .init(gpa);
        defer t.deinit();
        try t.rebuild(src, done);
        var step: u32 = 0;
        while (step < 200) : (step += 1) {
            const i = rnd.uintLessThan(usize, t.len());
            switch (rnd.uintLessThan(u8, 5)) {
                0, 1 => _ = try t.expand(src, i, done),
                2 => _ = t.collapse(i),
                3 => _ = try t.expandSiblings(src, i, done),
                else => {
                    // A pending load finishes.
                    var it = t.loading.keyIterator();
                    if (it.next()) |k| {
                        const node = k.*;
                        try s.loaded.put(gpa, node, {});
                        try t.refresh(src, node, done);
                    }
                },
            }
            var naive: FlatTree = .init(gpa);
            defer naive.deinit();
            var eit = t.expanded.keyIterator();
            while (eit.next()) |k| try naive.expanded.put(gpa, k.*, {});
            try naive.rebuild(src, null);
            try std.testing.expectEqual(naive.len(), t.len());
            for (naive.rows.items, t.rows.items) |a, b| {
                try std.testing.expectEqual(a.node, b.node);
                try std.testing.expectEqual(a.depth, b.depth);
                try std.testing.expectEqual(@as(u16, @bitCast(a.flags)), @as(u16, @bitCast(b.flags)));
            }
            if (t.len() == 0) break;
        }
    }
}

test "flat tree: collapsed descendants stay expanded; placeholders load once" {
    const gpa = std.testing.allocator;
    var s: TestSource = .{ .seed = 3 };
    defer s.loaded.deinit(gpa);
    const src = s.source();
    var dummy: u8 = 0;
    const done: LoadDone = .{ .ctx = &dummy, .f = noopDone };
    var t: FlatTree = .init(gpa);
    defer t.deinit();
    try t.rebuild(src, done);
    try std.testing.expectEqual(@as(usize, 4), t.len());
    // Find an expandable root with an expandable child.
    var root: ?usize = null;
    for (t.rows.items, 0..) |r, i| if (r.flags.expandable) {
        root = i;
        break;
    };
    const ri = root orelse return;
    const before = t.len();
    try std.testing.expect(try t.expand(src, ri, done));
    try std.testing.expect(t.len() > before);
    const end = t.subtreeEnd(ri);
    var inner: ?usize = null;
    for (ri + 1..end) |j| if (t.rows.items[j].flags.expandable) {
        inner = j;
        break;
    };
    if (inner) |j| {
        _ = try t.expand(src, j, done);
        const with_inner = t.len();
        try std.testing.expect(t.collapse(ri));
        try std.testing.expectEqual(before, t.len());
        _ = try t.expand(src, ri, done);
        try std.testing.expectEqual(with_inner, t.len());
    }
    try std.testing.expectEqual(@as(?usize, null), t.parentRow(ri));
    // Open everything: lazy nodes show one placeholder row each and load
    // once, however often they are reopened.
    var i: usize = 0;
    while (i < t.len()) : (i += 1) _ = try t.expand(src, i, done);
    var ph: ?usize = null;
    for (t.rows.items, 0..) |r, j| if (r.flags.placeholder) {
        ph = j;
        break;
    };
    const p = ph orelse return error.SkipZigTest;
    const owner = p - 1;
    try std.testing.expectEqual(t.rows.items[owner].node, t.rows.items[p].node);
    try std.testing.expectEqual(t.subtreeEnd(owner), p + 1);
    const loads = s.loads;
    try std.testing.expectEqual(@as(usize, loads), t.loading.count());
    _ = t.collapse(owner);
    _ = try t.expand(src, owner, done);
    try std.testing.expectEqual(loads, s.loads);
    // The load finishes: the placeholder becomes the children.
    try s.loaded.put(gpa, t.rows.items[owner].node, {});
    try t.refresh(src, t.rows.items[owner].node, done);
    try std.testing.expect(!t.rows.items[owner + 1].flags.placeholder);
    try std.testing.expectEqual(t.rows.items[owner].depth + 1, t.rows.items[owner + 1].depth);
}
