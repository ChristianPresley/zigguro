//! Undo, restore, the op log listing and op abandon.
//!
//! - `undo` (op revert) reverts one operation's effect, even when later
//!   operations happened: the current view is merged three ways with
//!   base `view(X)` and `view(parent(X))` as the other side. For an adopt
//!   operation the parent is the one it was adopted onto.
//! - `restore` replaces the whole view with an older one; history is kept.
//! - `abandonAncestors` drops old operations so GC can reclaim them: the
//!   kept operations are rewritten with their abandoned parents replaced
//!   by the root operation.
//!
//! After undo or restore the caller checks out the new working-copy commit
//! (F03.S01.T02).

const std = @import("std");
const id_mod = @import("../store/id.zig");
const enc = @import("../store/encode.zig");
const op_mod = @import("operation.zig");
const view_mod = @import("view.zig");
const op_heads = @import("op_heads.zig");
const merge_views = @import("merge_views.zig");
const repo_mod = @import("repo.zig");
const ObjectId = id_mod.ObjectId;
const Operation = op_mod.Operation;
const OpMeta = op_mod.OpMeta;
const View = view_mod.View;
const Repo = repo_mod.Repo;
const Allocator = std.mem.Allocator;

/// Reverts the effect of operation `which` on top of `repo`'s current
/// state, as a new operation.
pub fn undo(repo: *Repo, which: ObjectId, meta: OpMeta) !*Repo {
    const t = try repo.startTransaction(meta);
    errdefer t.discard();
    const a = t.arena();
    const x = try op_mod.read(Operation, repo.store, a, which);
    if (x.parents.len == 0) return error.CannotUndoRoot;
    // An adopt operation (adopt.zig) is undone against the operation it
    // was adopted onto, its first parent; other merges have no single
    // "before".
    if (x.parents.len > 1 and x.meta.tag("adopted") == null) return error.CannotUndoMerge;
    const parent = try op_mod.read(Operation, repo.store, a, x.parents[0]);
    const base = try op_mod.read(View, repo.store, a, x.view);
    const right = try op_mod.read(View, repo.store, a, parent.view);
    const merged = try merge_views.mergeViews(repo.gpa, a, base, repo.view().*, right);
    try t.setView(merged);
    return t.commit();
}

/// Sets the view to the one operation `to` produced, as a new operation.
pub fn restore(repo: *Repo, to: ObjectId, meta: OpMeta) !*Repo {
    const t = try repo.startTransaction(meta);
    errdefer t.discard();
    const a = t.arena();
    const target = try op_mod.read(Operation, repo.store, a, to);
    try t.setView(try op_mod.read(View, repo.store, a, target.view));
    return t.commit();
}

pub const OpSummary = struct {
    id: ObjectId,
    parents: []const ObjectId,
    view: ObjectId,
    meta: OpMeta,
};

/// Operations listed newest first; strings live in the arena.
pub const OpLog = struct {
    arena_state: std.heap.ArenaAllocator,
    entries: []const OpSummary,

    pub fn deinit(l: *OpLog) void {
        l.arena_state.deinit();
    }
};

/// Up to `limit` operations reachable from `from`, newest (by end time)
/// first.
pub fn opLog(repo: *const Repo, gpa: Allocator, from: ObjectId, limit: u32) !OpLog {
    var out: OpLog = .{ .arena_state = .init(gpa), .entries = &.{} };
    errdefer out.deinit();
    const a = out.arena_state.allocator();
    const Item = struct { end: i64, id: ObjectId };
    const Q = std.PriorityQueue(Item, void, struct {
        fn cmp(_: void, x: Item, y: Item) std.math.Order {
            if (x.end != y.end) return std.math.order(y.end, x.end);
            return y.id.order(x.id);
        }
    }.cmp);
    var q: Q = .empty;
    defer q.deinit(gpa);
    var seen: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
    defer seen.deinit(gpa);
    var list: std.ArrayList(OpSummary) = .empty;
    var pending: std.AutoHashMapUnmanaged(ObjectId, Operation) = .empty;
    defer pending.deinit(gpa);

    const first = try op_mod.read(Operation, repo.store, a, from);
    try seen.put(gpa, from, {});
    try pending.put(gpa, from, first);
    try q.push(gpa, .{ .end = first.meta.end_ms, .id = from });
    while (list.items.len < limit) {
        const it = q.pop() orelse break;
        const o = pending.fetchRemove(it.id).?.value;
        try list.append(a, .{ .id = it.id, .parents = o.parents, .view = o.view, .meta = o.meta });
        for (o.parents) |p| {
            if ((try seen.getOrPut(gpa, p)).found_existing) continue;
            const po = try op_mod.read(Operation, repo.store, a, p);
            try pending.put(gpa, p, po);
            try q.push(gpa, .{ .end = po.meta.end_ms, .id = p });
        }
    }
    out.entries = list.items;
    return out;
}

/// Abandons `upto` and all its ancestors except the root operation. The
/// operations after it, up to `repo`'s operation, are rewritten (same view
/// and metadata, re-parented) and the rewritten head replaces `repo`'s
/// operation in the op heads. Returns the repo at the new head.
pub fn abandonAncestors(repo: *Repo, upto: ObjectId) !*Repo {
    const gpa = repo.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    if (upto.eql(repo.op())) return error.CannotAbandonHead;

    // Every operation reachable from the head, children before parents.
    var ops: std.AutoArrayHashMapUnmanaged(ObjectId, Operation) = .empty;
    defer ops.deinit(gpa);
    var stack: std.ArrayList(ObjectId) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, repo.op());
    var root: ?ObjectId = null;
    while (stack.pop()) |x| {
        const gop = try ops.getOrPut(gpa, x);
        if (gop.found_existing) continue;
        gop.value_ptr.* = try op_mod.read(Operation, repo.store, a, x);
        if (gop.value_ptr.parents.len == 0) root = x;
        try stack.appendSlice(gpa, gop.value_ptr.parents);
    }
    const root_id = root orelse return error.CorruptOpLog;
    if (!ops.contains(upto)) return error.OpNotFound;
    if (upto.eql(root_id)) return error.CannotAbandonRoot;

    // Abandoned: `upto` and its ancestors, minus the root.
    var dropped: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
    defer dropped.deinit(gpa);
    try stack.append(gpa, upto);
    while (stack.pop()) |x| {
        if (x.eql(root_id)) continue;
        if ((try dropped.getOrPut(gpa, x)).found_existing) continue;
        try stack.appendSlice(gpa, ops.get(x).?.parents);
    }

    // Rewrite the kept operations, parents first (iterative post-order).
    var mapped: std.AutoHashMapUnmanaged(ObjectId, ObjectId) = .empty;
    defer mapped.deinit(gpa);
    try mapped.put(gpa, root_id, root_id);
    var b = repo.store.batch();
    defer b.abort();
    const Frame = struct { id: ObjectId, expanded: bool };
    var work: std.ArrayList(Frame) = .empty;
    defer work.deinit(gpa);
    try work.append(gpa, .{ .id = repo.op(), .expanded = false });
    while (work.pop()) |f| {
        if (mapped.contains(f.id)) continue;
        const o = ops.get(f.id).?;
        if (!f.expanded) {
            try work.append(gpa, .{ .id = f.id, .expanded = true });
            for (o.parents) |p| {
                if (dropped.contains(p) or mapped.contains(p)) continue;
                try work.append(gpa, .{ .id = p, .expanded = false });
            }
            continue;
        }
        var parents: std.ArrayList(ObjectId) = .empty;
        for (o.parents) |p| {
            const np = if (dropped.contains(p)) root_id else mapped.get(p).?;
            for (parents.items) |q| {
                if (q.eql(np)) break;
            } else try parents.append(a, np);
        }
        var n = o;
        n.parents = parents.items;
        const bytes = try enc.encodeAlloc(gpa, Operation, n);
        defer gpa.free(bytes);
        try mapped.put(gpa, f.id, try b.put(.operation, bytes));
    }
    try b.commit();
    const new_head = mapped.get(repo.op()).?;
    try op_heads.publish(repo.io, repo.heads_dir, new_head, &.{repo.op()});
    return repo.reopen(new_head, false);
}
