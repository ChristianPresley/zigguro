//! The per-document undo tree (Vim-style): grouping, selections before and
//! after each step, linear undo/redo along the current branch,
//! chronological traversal across branches (`g-`/`g+`), travel by time,
//! a saved-state marker and selective undo of one group via transform.
//!
//! Each node is one undo group: the ChangeSet that produced its state from
//! its parent's (`forward`) and the one that restores the parent
//! (`inverse`). Nodes are stored in creation order, so index order is
//! chronological (`seq`) order and a parent always precedes its children.
//! `older`/`newer` therefore move to the previous/next index, along the
//! path through the lowest common ancestor.
//!
//! Steps returned by `undo`, `redo`, `older`, `newer` and `travel` borrow
//! from the tree and are valid until the next call that records or prunes.
//! Node ids are invalidated by pruning (the tree is compacted).

const std = @import("std");
const cs_mod = @import("change_set.zig");
const sel_mod = @import("selection.zig");
const EditOrigin = @import("../document.zig").EditOrigin;
const Snapshot = @import("../snapshot.zig").Snapshot;

const Allocator = std.mem.Allocator;
const ChangeSet = cs_mod.ChangeSet;
const Range = cs_mod.Range;
const Selection = sel_mod.Selection;
const Timestamp = std.Io.Timestamp;

/// Which kind of repeated command an edit is, for grouping.
pub const CoalesceKey = enum { typing_word, typing_space, delete_left, delete_right };

/// Describes the edit being recorded.
pub const GroupMeta = struct {
    /// Shown in the undo-history panel ("Agent: edit_file (session 3)").
    label: []const u8 = "",
    origin: EditOrigin,
    timestamp: Timestamp,
    /// Edits with compatible keys coalesce into one group; null never does.
    coalesce_key: ?CoalesceKey = null,
};

/// A node of the tree. `root` is the oldest reachable state.
pub const NodeId = enum(u32) {
    root = 0,
    none = std.math.maxInt(u32),
    _,

    fn idx(id: NodeId) usize {
        return @intFromEnum(id);
    }

    fn of(i: usize) NodeId {
        return @enumFromInt(@as(u32, @intCast(i)));
    }
};

/// Pruning and grouping limits.
pub const Limits = struct {
    max_nodes: u32 = 10_000,
    max_bytes: usize = 64 << 20,
    /// `editor.undoGroupMs`: a pause this long starts a new group.
    group_ms: u32 = 1000,
};

/// One step to apply to the document: `changes` against its current text,
/// then set the selections to `selections`. Borrowed from the tree.
pub const Step = struct { changes: *const ChangeSet, selections: []const Selection };

/// Ranges (in current coordinates) that a selective undo could not revert
/// because later edits changed the same text.
pub const ConflictInfo = struct {
    ranges: []Range,

    /// Frees the ranges.
    pub fn deinit(c: *ConflictInfo, gpa: Allocator) void {
        gpa.free(c.ranges);
        c.* = undefined;
    }
};

/// The result of `selectiveUndo`. `ok` is owned by the caller.
pub const SelectiveResult = union(enum) { ok: ChangeSet, conflict: ConflictInfo };

/// A forward and inverse ChangeSet between two states (owned by the
/// caller).
pub const PathChange = struct {
    forward: ChangeSet,
    inverse: ChangeSet,

    /// Frees both ChangeSets.
    pub fn deinit(p: *PathChange) void {
        p.forward.deinit();
        p.inverse.deinit();
        p.* = undefined;
    }
};

/// One undo group, as shown by the history panel.
pub const Node = struct {
    parent: NodeId,
    /// Children, newest first, linked through `next_sibling`.
    first_child: NodeId = .none,
    next_sibling: NodeId = .none,
    /// The child `redo` goes to: the one most recently undone or created.
    redo_child: NodeId = .none,
    /// Global chronological counter (creation order).
    seq: u64,
    /// Time of the last edit in the group.
    timestamp: Timestamp,
    origin: EditOrigin,
    coalesce_key: ?CoalesceKey,
    /// Owned copy of the group label.
    label: []const u8,
    forward: ChangeSet,
    inverse: ChangeSet,
    sel_before: []Selection,
    sel_after: []Selection,

    fn bytes(n: *const Node) usize {
        return @sizeOf(Node) + n.forward.memoryBytes() + n.inverse.memoryBytes() + n.label.len +
            (n.sel_before.len + n.sel_after.len) * @sizeOf(Selection);
    }

    fn deinit(n: *Node, gpa: Allocator) void {
        n.forward.deinit();
        n.inverse.deinit();
        gpa.free(n.sel_before);
        gpa.free(n.sel_after);
        gpa.free(n.label);
    }
};

pub const Error = Allocator.Error;

/// The undo tree of one document.
pub const UndoTree = struct {
    gpa: Allocator,
    limits: Limits,
    items: std.ArrayList(Node) = .empty,
    current: NodeId = .root,
    /// The node whose state is on disk; `.none` when that state was pruned
    /// or never reached.
    saved: NodeId = .root,
    next_seq: u64 = 1,
    bytes: usize = 0,
    /// Forces the next `record` to start a new group.
    break_next: bool = false,
    /// Set once the oldest history was dropped to honour the limits.
    truncated: bool = false,
    steps: std.ArrayList(Step) = .empty,

    /// An empty tree whose root is the current state.
    pub fn init(gpa: Allocator, limits: Limits) UndoTree {
        return .{ .gpa = gpa, .limits = limits };
    }

    /// Frees every node.
    pub fn deinit(u: *UndoTree) void {
        for (u.items.items) |*n| n.deinit(u.gpa);
        u.items.deinit(u.gpa);
        u.steps.deinit(u.gpa);
        u.* = undefined;
    }

    fn ensureRoot(u: *UndoTree) Error!void {
        if (u.items.items.len > 0) return;
        try u.items.append(u.gpa, .{
            .parent = .none,
            .seq = 0,
            .timestamp = .zero,
            .origin = .reload,
            .coalesce_key = null,
            .label = &.{},
            .forward = .identity(u.gpa, 0),
            .inverse = .identity(u.gpa, 0),
            .sel_before = &.{},
            .sel_after = &.{},
        });
    }

    fn node(u: *const UndoTree, id: NodeId) *Node {
        return &u.items.items[id.idx()];
    }

    /// Every node in chronological order (index = `NodeId`).
    pub fn nodes(u: *const UndoTree) []const Node {
        return u.items.items;
    }

    /// The selections after reaching `id`'s state (empty for the root).
    pub fn selectionsAt(u: *const UndoTree, id: NodeId) []const Selection {
        if (u.items.items.len == 0) return &.{};
        return u.node(id).sel_after;
    }

    /// Forces the next `record` to start a new group.
    pub fn breakGroup(u: *UndoTree) void {
        u.break_next = true;
    }

    fn compatible(prev: CoalesceKey, next: CoalesceKey) bool {
        // A word keeps its trailing space; space then word starts a group.
        return prev == next or (prev == .typing_word and next == .typing_space);
    }

    fn canCoalesce(u: *const UndoTree, sel_before: []const Selection, meta: GroupMeta) bool {
        if (u.break_next or u.current == .root) return false;
        if (u.current.idx() != u.items.items.len - 1) return false;
        const n = u.node(u.current);
        if (n.origin != .user or meta.origin != .user) return false;
        const pk = n.coalesce_key orelse return false;
        const k = meta.coalesce_key orelse return false;
        if (!compatible(pk, k)) return false;
        const dt = meta.timestamp.nanoseconds - n.timestamp.nanoseconds;
        if (dt < 0 or dt >= @as(i96, u.limits.group_ms) * std.time.ns_per_ms) return false;
        return sel_mod.eql(n.sel_after, sel_before);
    }

    /// Records an edit: `forward` was applied to the current state and
    /// `inverse` restores it. Takes ownership of both ChangeSets (also on
    /// error). Coalesces into the current group when the grouping rules
    /// allow it; otherwise adds a child of the current node.
    pub fn record(u: *UndoTree, forward: ChangeSet, inverse: ChangeSet, sel_before: []const Selection, sel_after: []const Selection, meta: GroupMeta) Error!void {
        var f = forward;
        var inv = inverse;
        defer f.deinit();
        defer inv.deinit();
        try u.ensureRoot();
        if (u.canCoalesce(sel_before, meta)) {
            const n = u.node(u.current);
            var nf = try n.forward.compose(&f, u.gpa);
            errdefer nf.deinit();
            var ni = try inv.compose(&n.inverse, u.gpa);
            errdefer ni.deinit();
            const sa = try u.gpa.dupe(Selection, sel_after);
            u.bytes -= n.bytes();
            n.forward.deinit();
            n.inverse.deinit();
            u.gpa.free(n.sel_after);
            n.forward = nf;
            n.inverse = ni;
            n.sel_after = sa;
            n.timestamp = meta.timestamp;
            n.coalesce_key = meta.coalesce_key;
            u.bytes += n.bytes();
            return;
        }
        const label = try u.gpa.dupe(u8, meta.label);
        errdefer u.gpa.free(label);
        const sb = try u.gpa.dupe(Selection, sel_before);
        errdefer u.gpa.free(sb);
        const sa = try u.gpa.dupe(Selection, sel_after);
        errdefer u.gpa.free(sa);
        try u.items.ensureUnusedCapacity(u.gpa, 1);
        const id = NodeId.of(u.items.items.len);
        const parent = u.node(u.current);
        u.items.appendAssumeCapacity(.{
            .parent = u.current,
            .next_sibling = parent.first_child,
            .seq = u.next_seq,
            .timestamp = meta.timestamp,
            .origin = meta.origin,
            .coalesce_key = meta.coalesce_key,
            .label = label,
            .forward = f,
            .inverse = inv,
            .sel_before = sb,
            .sel_after = sa,
        });
        // Ownership moved into the node.
        f = .identity(u.gpa, 0);
        inv = .identity(u.gpa, 0);
        const p = u.node(u.current);
        p.first_child = id;
        p.redo_child = id;
        u.next_seq += 1;
        u.current = id;
        u.break_next = false;
        u.bytes += u.node(id).bytes();
        u.enforceLimits() catch {}; // Pruning is best-effort under OOM.
    }

    /// Moves to the parent state along the current branch.
    pub fn undo(u: *UndoTree) ?Step {
        if (u.items.items.len == 0 or u.current == .root) return null;
        const id = u.current;
        const n = u.node(id);
        u.node(n.parent).redo_child = id;
        u.current = n.parent;
        u.break_next = true;
        return .{ .changes = &n.inverse, .selections = n.sel_before };
    }

    /// Moves to the most recently visited (or newest) child.
    pub fn redo(u: *UndoTree) ?Step {
        if (u.items.items.len == 0) return null;
        const cur = u.node(u.current);
        const child = if (cur.redo_child != .none) cur.redo_child else cur.first_child;
        if (child == .none) return null;
        u.current = child;
        u.break_next = true;
        const n = u.node(child);
        return .{ .changes = &n.forward, .selections = n.sel_after };
    }

    /// Whether `undo` would do anything.
    pub fn canUndo(u: *const UndoTree) bool {
        return u.items.items.len > 0 and u.current != .root;
    }

    /// Whether `redo` would do anything.
    pub fn canRedo(u: *const UndoTree) bool {
        if (u.items.items.len == 0) return false;
        return u.node(u.current).first_child != .none;
    }

    /// Steps from `from` to `to` through their lowest common ancestor:
    /// inverses going up, forwards going down. Fills `u.steps`.
    fn path(u: *UndoTree, from: NodeId, to: NodeId) Error![]const Step {
        u.steps.clearRetainingCapacity();
        var a = from.idx();
        var b = to.idx();
        // Up steps go first; down steps are appended then reversed.
        var down: std.ArrayList(Step) = .empty;
        defer down.deinit(u.gpa);
        while (a != b) {
            if (a > b) {
                const n = &u.items.items[a];
                try u.steps.append(u.gpa, .{ .changes = &n.inverse, .selections = n.sel_before });
                a = n.parent.idx();
            } else {
                const n = &u.items.items[b];
                try down.append(u.gpa, .{ .changes = &n.forward, .selections = n.sel_after });
                b = n.parent.idx();
            }
        }
        try u.steps.ensureUnusedCapacity(u.gpa, down.items.len);
        var i = down.items.len;
        while (i > 0) {
            i -= 1;
            u.steps.appendAssumeCapacity(down.items[i]);
        }
        return u.steps.items;
    }

    /// Moves to `target`, returning the steps to apply in order. Redo from
    /// any node on the way down then follows this path.
    pub fn travel(u: *UndoTree, target: NodeId) Error![]const Step {
        if (u.items.items.len == 0) return &.{};
        std.debug.assert(target.idx() < u.items.items.len);
        const steps = try u.path(u.current, target);
        var c = target;
        while (c != .root) {
            const p = u.node(c).parent;
            u.node(p).redo_child = c;
            c = p;
        }
        u.current = target;
        u.break_next = true;
        return steps;
    }

    /// Moves to the chronologically previous state (`g-`); null at the
    /// oldest one.
    pub fn older(u: *UndoTree) Error!?[]const Step {
        if (u.items.items.len == 0 or u.current == .root) return null;
        return try u.travel(NodeId.of(u.current.idx() - 1));
    }

    /// Moves to the chronologically next state (`g+`); null at the newest.
    pub fn newer(u: *UndoTree) Error!?[]const Step {
        if (u.current.idx() + 1 >= u.items.items.len) return null;
        return try u.travel(NodeId.of(u.current.idx() + 1));
    }

    /// The newest state whose last edit is at or before `t` (the root when
    /// none is).
    pub fn nodeAtTime(u: *const UndoTree, t: Timestamp) NodeId {
        const items = u.items.items;
        if (items.len <= 1) return .root;
        // Timestamps grow with index (only the newest node coalesces).
        var lo: usize = 1;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].timestamp.nanoseconds <= t.nanoseconds) lo = mid + 1 else hi = mid;
        }
        return NodeId.of(lo - 1);
    }

    /// The `steps` back `n` states chronologically (`:earlier N`).
    pub fn nodeStepsBack(u: *const UndoTree, n: usize) NodeId {
        return NodeId.of(u.current.idx() -| n);
    }

    /// One ChangeSet from the current state to `target` and its inverse,
    /// without moving. "Revert to 10 minutes ago" applies `forward` and
    /// records it as a new group (Vim's `:earlier 10m`, made undoable).
    pub fn changesTo(u: *UndoTree, target: NodeId, base_len: u64, gpa: Allocator) Error!PathChange {
        var fwd = try composeSteps(try u.path(u.current, target), base_len, gpa);
        errdefer fwd.deinit();
        const inv = try composeSteps(try u.path(target, u.current), fwd.newLen(), gpa);
        return .{ .forward = fwd, .inverse = inv };
    }

    /// Marks `id` as the state on disk.
    pub fn markSaved(u: *UndoTree, id: NodeId) void {
        u.saved = id;
    }

    /// Whether the current state is the saved one (the dirty flag is the
    /// negation).
    pub fn isAtSaved(u: *const UndoTree) bool {
        return u.current == u.saved;
    }

    /// The inverse of group `id` (which must be on the path from the root
    /// to the current node), transformed through every later group so it
    /// applies to `current`. Conflicts when later edits touched the text
    /// it would restore.
    pub fn selectiveUndo(u: *UndoTree, id: NodeId, current: Snapshot) (Error || error{ NotOnCurrentPath, HistoryTooLong, VersionMismatch })!SelectiveResult {
        if (u.items.items.len == 0 or id == .root) return error.NotOnCurrentPath;
        var later: std.ArrayList(NodeId) = .empty;
        defer later.deinit(u.gpa);
        var c = u.current;
        while (c != id) {
            if (c == .root) return error.NotOnCurrentPath;
            if (later.items.len >= 10_000) return error.HistoryTooLong;
            try later.append(u.gpa, c);
            c = u.node(c).parent;
        }
        const target = u.node(id);
        const at_len = target.forward.newLen();
        var f: ChangeSet = .identity(u.gpa, at_len);
        defer f.deinit();
        var i = later.items.len;
        while (i > 0) {
            i -= 1;
            const next = try f.compose(&u.node(later.items[i]).forward, u.gpa);
            f.deinit();
            f = next;
        }
        if (current.len() != f.newLen()) return error.VersionMismatch;

        var conflicts: std.ArrayList(Range) = .empty;
        errdefer conflicts.deinit(u.gpa);
        const inv = &target.inverse;
        var j: usize = 0;
        for (inv.replaces) |r| {
            while (j < f.replaces.len and f.replaces[j].range.end < r.range.start) j += 1;
            var k = j;
            var hit = false;
            while (k < f.replaces.len and f.replaces[k].range.start <= r.range.end) : (k += 1) {
                if (touches(r.range, f.replaces[k].range)) hit = true;
            }
            if (hit) try conflicts.append(u.gpa, f.mapRange(r.range, .expand).?);
        }
        if (conflicts.items.len == 0) {
            var t = try inv.transform(&f, true, u.gpa);
            if (!t.conflicted) return .{ .ok = t };
            t.deinit();
            try conflicts.append(u.gpa, .{ .start = 0, .end = current.len() });
        }
        return .{ .conflict = .{ .ranges = try conflicts.toOwnedSlice(u.gpa) } };
    }

    fn enforceLimits(u: *UndoTree) Error!void {
        const items = u.items.items;
        if (items.len <= u.limits.max_nodes and u.bytes <= u.limits.max_bytes) return;
        const target_nodes = u.limits.max_nodes - u.limits.max_nodes / 10;
        const target_bytes = u.limits.max_bytes - u.limits.max_bytes / 10;
        const n = items.len;

        var on_path = try std.DynamicBitSetUnmanaged.initEmpty(u.gpa, n);
        defer on_path.deinit(u.gpa);
        var c = u.current;
        while (true) {
            on_path.set(c.idx());
            if (c == .root) break;
            c = u.node(c).parent;
        }
        // Newest activity and size of every subtree (children follow
        // parents, so one reverse pass suffices).
        const newest = try u.gpa.alloc(usize, n);
        defer u.gpa.free(newest);
        const sub_bytes = try u.gpa.alloc(usize, n);
        defer u.gpa.free(sub_bytes);
        const sub_count = try u.gpa.alloc(usize, n);
        defer u.gpa.free(sub_count);
        for (items, 0..) |*it, i| {
            newest[i] = i;
            sub_bytes[i] = it.bytes();
            sub_count[i] = 1;
        }
        var i = n;
        while (i > 1) {
            i -= 1;
            const p = items[i].parent.idx();
            newest[p] = @max(newest[p], newest[i]);
            sub_bytes[p] += sub_bytes[i];
            sub_count[p] += sub_count[i];
        }
        // Branches hanging off the path, least recently active first.
        var branches: std.ArrayList(usize) = .empty;
        defer branches.deinit(u.gpa);
        for (1..n) |k| if (!on_path.isSet(k) and on_path.isSet(items[k].parent.idx())) try branches.append(u.gpa, k);
        std.sort.pdq(usize, branches.items, newest, struct {
            fn lt(nw: []const usize, x: usize, y: usize) bool {
                return nw[x] < nw[y];
            }
        }.lt);
        var dead = try std.DynamicBitSetUnmanaged.initEmpty(u.gpa, n);
        defer dead.deinit(u.gpa);
        var count = n;
        var bytes = u.bytes;
        for (branches.items) |b| {
            if (count <= target_nodes and bytes <= target_bytes) break;
            dead.set(b);
            count -= sub_count[b];
            bytes -= sub_bytes[b];
        }
        for (1..n) |k| if (dead.isSet(items[k].parent.idx())) dead.set(k);
        // Still over: drop the oldest states on the path (truncation).
        var new_root: usize = 0;
        if (count > target_nodes or bytes > target_bytes) {
            var chain: std.ArrayList(usize) = .empty;
            defer chain.deinit(u.gpa);
            c = u.current;
            while (true) {
                try chain.append(u.gpa, c.idx());
                if (c == .root) break;
                c = u.node(c).parent;
            }
            std.mem.reverse(usize, chain.items);
            var k: usize = 0;
            while (k + 1 < chain.items.len and (count > target_nodes or bytes > target_bytes)) : (k += 1) {
                dead.set(chain.items[k]);
                count -= 1;
                bytes -= items[chain.items[k]].bytes();
            }
            new_root = chain.items[k];
            // Branches of the dropped states go too.
            for (1..n) |m| if (m != new_root and dead.isSet(items[m].parent.idx())) dead.set(m);
            u.truncated = true;
        }
        if (new_root != 0) {
            const r = &items[new_root];
            u.bytes -= r.bytes();
            r.forward.deinit();
            r.inverse.deinit();
            r.forward = .identity(u.gpa, 0);
            r.inverse = .identity(u.gpa, 0);
            u.gpa.free(r.sel_before);
            r.sel_before = &.{};
            r.parent = .none;
            u.bytes += r.bytes();
        }
        u.compact(&dead);
    }

    /// Removes dead nodes, keeping order, and relinks everything.
    fn compact(u: *UndoTree, dead: *const std.DynamicBitSetUnmanaged) void {
        const items = u.items.items;
        const n = items.len;
        // Reuse `next_sibling` as the remap table while moving.
        var w: usize = 0;
        for (0..n) |r| {
            if (dead.isSet(r)) {
                u.bytes -= items[r].bytes();
                items[r].deinit(u.gpa);
                items[r].seq = std.math.maxInt(u64); // marks the slot dead
                continue;
            }
            items[r].next_sibling = NodeId.of(w);
            w += 1;
        }
        const mapId = struct {
            fn f(its: []Node, id: NodeId) NodeId {
                if (id == .none) return .none;
                if (its[id.idx()].seq == std.math.maxInt(u64)) return .none;
                return its[id.idx()].next_sibling;
            }
        }.f;
        u.current = mapId(items, u.current);
        u.saved = mapId(items, u.saved);
        for (items) |*it| {
            if (it.seq == std.math.maxInt(u64)) continue;
            it.parent = mapId(items, it.parent);
            it.redo_child = mapId(items, it.redo_child);
        }
        w = 0;
        for (0..n) |r| {
            if (items[r].seq == std.math.maxInt(u64)) continue;
            items[w] = items[r];
            w += 1;
        }
        u.items.shrinkRetainingCapacity(w);
        for (u.items.items) |*it| {
            it.first_child = .none;
            it.next_sibling = .none;
        }
        for (u.items.items, 0..) |*it, k| {
            if (it.parent == .none) continue;
            const p = &u.items.items[it.parent.idx()];
            it.next_sibling = p.first_child;
            p.first_child = NodeId.of(k);
        }
        std.debug.assert(u.items.items[0].parent == .none);
    }
};

/// Whether a later replacement `b` touches text that `a` would restore:
/// proper overlap, or an insertion strictly inside the other range.
fn touches(a: Range, b: Range) bool {
    if (a.len() > 0 and b.len() > 0) return @max(a.start, b.start) < @min(a.end, b.end);
    if (b.len() == 0) return b.start > a.start and b.start < a.end;
    return a.start > b.start and a.start < b.end;
}

fn composeSteps(steps: []const Step, base_len: u64, gpa: Allocator) Error!ChangeSet {
    var acc: ChangeSet = .identity(gpa, base_len);
    errdefer acc.deinit();
    for (steps) |s| {
        const next = try acc.compose(s.changes, gpa);
        acc.deinit();
        acc = next;
    }
    return acc;
}
