//! Rebasing descendants (E09.F03.S02.T01). After a transaction rewrites
//! or abandons commits, every visible commit that descends from one of
//! them is rebased so the graph stays connected:
//!
//! - a parent that was rewritten is replaced by its final rewrite
//!   (rewrites chain: a rebased commit is itself recorded as rewritten);
//! - a parent that was abandoned is replaced by its own parents, mapped
//!   the same way;
//! - commits whose parents did not change are left alone.
//!
//! Commits are visited in post-order from the visible heads, so parents
//! are always settled first. With a commit index, the walk stops at
//! commits no higher than the lowest rewritten or abandoned one, since
//! nothing at or below that level can descend from it.
//!
//! The `Engine` writes each rebased commit. `reparent` only swaps the
//! parents and keeps the tree, which is right when the rewrite left the
//! tree alone (describe, metadata); the F04 rewrite engine merges trees.
//!
//! Afterwards bookmarks and working copies on rewritten commits follow
//! the rewrite; on abandoned ones they move to the first remaining
//! parent (a bookmark on an abandoned root is deleted). Tags, git refs
//! and remote bookmarks record outside state and are not moved.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const index_mod = @import("../graph/index.zig");
const view_mod = @import("view.zig");
const mutable_mod = @import("mutable_repo.zig");
const ObjectId = id_mod.ObjectId;
const Change = object.Change;
const MutableRepo = mutable_mod.MutableRepo;
const RefTarget = view_mod.RefTarget;
const Allocator = std.mem.Allocator;

pub const Engine = struct {
    ctx: ?*anyopaque = null,
    /// Writes `c` (commit `old`) on `new_parents` with `m.rewriteChange`
    /// and returns the new commit.
    rebase: *const fn (ctx: ?*anyopaque, m: *MutableRepo, old: ObjectId, c: Change, new_parents: []const ObjectId) anyerror!ObjectId,
};

/// Keeps the tree, changes the parents, drops the signature.
pub const reparent: Engine = .{ .rebase = reparentFn };

fn reparentFn(_: ?*anyopaque, m: *MutableRepo, old: ObjectId, c: Change, new_parents: []const ObjectId) anyerror!ObjectId {
    var n = c;
    n.parents = try m.arena.dupe(ObjectId, new_parents);
    n.predecessors = &.{};
    n.sig = null;
    return m.rewriteChange(old, n);
}

pub const Stats = struct {
    /// Commits read during the walk.
    visited: usize = 0,
    rebased: usize = 0,
    /// Bookmarks and working copies moved or deleted.
    refs_moved: usize = 0,
};

const Walk = struct {
    m: *MutableRepo,
    arena: Allocator,
    /// Parents of every commit read.
    parents: std.AutoHashMapUnmanaged(ObjectId, []const ObjectId) = .empty,
    /// Memoized `mapped` results.
    memo: std.AutoHashMapUnmanaged(ObjectId, []const ObjectId) = .empty,

    fn parentsOf(w: *Walk, id: ObjectId) ![]const ObjectId {
        if (w.parents.get(id)) |p| return p;
        const c = try w.m.readChange(w.arena, id);
        try w.parents.put(w.arena, id, c.parents);
        return c.parents;
    }

    /// What `id` stands for after the rewrites: itself, its final
    /// rewrite, or (abandoned) its parents' mappings.
    fn mapped(w: *Walk, id: ObjectId, depth: u32) anyerror![]const ObjectId {
        if (depth > 10_000) return error.RewriteCycle;
        if (w.memo.get(id)) |r| return r;
        const r: []const ObjectId = if (w.m.rewritten.get(id)) |next|
            try w.mapped(next, depth + 1)
        else if (w.m.abandoned.contains(id)) blk: {
            var out: std.ArrayList(ObjectId) = .empty;
            for (try w.parentsOf(id)) |p| try appendUnique(&out, w.arena, try w.mapped(p, depth + 1));
            break :blk out.items;
        } else try w.arena.dupe(ObjectId, &.{id});
        try w.memo.put(w.arena, id, r);
        return r;
    }

    /// The parents `id` should have now.
    fn newParents(w: *Walk, id: ObjectId) ![]const ObjectId {
        var out: std.ArrayList(ObjectId) = .empty;
        for (try w.parentsOf(id)) |p| try appendUnique(&out, w.arena, try w.mapped(p, 0));
        return out.items;
    }
};

fn appendUnique(out: *std.ArrayList(ObjectId), arena: Allocator, ids: []const ObjectId) !void {
    outer: for (ids) |id| {
        for (out.items) |o| if (o.eql(id)) continue :outer;
        try out.append(arena, id);
    }
}

fn sameIds(a: []const ObjectId, b: []const ObjectId) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

fn levelOf(ix: *index_mod.CommitIndex, id: ObjectId) ?u32 {
    const p = ix.pos(id) orelse return null;
    return ix.entry(p).level;
}

pub fn rebaseDescendants(m: *MutableRepo, engine: Engine, ix: ?*index_mod.CommitIndex) !Stats {
    var stats: Stats = .{};
    if (m.rewritten.count() == 0 and m.abandoned.count() == 0) return stats;
    var arena_state: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena_state.deinit();
    var w: Walk = .{ .m = m, .arena = arena_state.allocator() };

    // Commits at or below this level cannot descend from a rewrite.
    var floor: u32 = 0;
    if (ix) |x| {
        floor = std.math.maxInt(u32);
        for ([_][]const ObjectId{ m.rewritten.keys(), m.abandoned.keys() }) |ids| {
            for (ids) |id| floor = @min(floor, levelOf(x, id) orelse 0);
        }
    }

    // Post-order DFS from the heads with an explicit stack.
    const Frame = struct { id: ObjectId, expanded: bool };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(m.gpa);
    var seen: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
    defer seen.deinit(m.gpa);
    var order: std.ArrayList(ObjectId) = .empty;
    defer order.deinit(m.gpa);
    for (m.view.heads.keys()) |h| try stack.append(m.gpa, .{ .id = h, .expanded = false });
    while (stack.pop()) |f| {
        if (f.expanded) {
            try order.append(m.gpa, f.id);
            continue;
        }
        if ((try seen.getOrPut(m.gpa, f.id)).found_existing) continue;
        if (ix) |x| if (levelOf(x, f.id)) |l| if (l <= floor) continue;
        stats.visited += 1;
        try stack.append(m.gpa, .{ .id = f.id, .expanded = true });
        for (try w.parentsOf(f.id)) |p| {
            if (!seen.contains(p)) try stack.append(m.gpa, .{ .id = p, .expanded = false });
        }
    }

    for (order.items) |id| {
        // Rewritten and abandoned commits are resolved through `mapped`.
        if (m.rewritten.contains(id) or m.abandoned.contains(id)) continue;
        const old_parents = try w.parentsOf(id);
        const new_parents = try w.newParents(id);
        if (sameIds(old_parents, new_parents)) continue;
        const c = try m.readChange(w.arena, id);
        const new = try engine.rebase(engine.ctx, m, id, c, new_parents);
        // An engine may write through `writeChange`; record it either way.
        try m.rewritten.put(m.gpa, id, new);
        _ = m.view.heads.swapRemove(id);
        stats.rebased += 1;
    }

    // Bookmarks follow; tags, git refs and remote bookmarks do not.
    var deleted: std.ArrayList([]const u8) = .empty;
    for (m.view.bookmarks.keys(), m.view.bookmarks.values()) |name, *t| {
        const moved = (try moveTarget(&w, t.*)) orelse continue;
        if (moved.isAbsent()) try deleted.append(w.arena, name) else t.* = moved;
        stats.refs_moved += 1;
    }
    for (deleted.items) |name| _ = m.view.bookmarks.orderedRemove(name);
    for (m.view.wc_commits.values()) |*c| {
        if (!m.rewritten.contains(c.*) and !m.abandoned.contains(c.*)) continue;
        const to = try w.mapped(c.*, 0);
        // A working copy on an abandoned root keeps pointing at it.
        if (to.len == 0) continue;
        c.* = to[0];
        stats.refs_moved += 1;
    }
    return stats;
}

/// `t` with rewritten or abandoned terms replaced, or null when
/// unchanged. Absent terms in the result delete the ref.
fn moveTarget(w: *Walk, t: RefTarget) !?RefTarget {
    var changed = false;
    for (t.terms) |term| {
        const id = term orelse continue;
        if (w.m.rewritten.contains(id) or w.m.abandoned.contains(id)) changed = true;
    }
    if (!changed) return null;
    const terms = try w.m.arena.dupe(?ObjectId, t.terms);
    for (terms) |*term| {
        const id = term.* orelse continue;
        if (!w.m.rewritten.contains(id) and !w.m.abandoned.contains(id)) continue;
        const to = try w.mapped(id, 0);
        term.* = if (to.len == 0) null else to[0];
    }
    return .{ .terms = terms };
}
