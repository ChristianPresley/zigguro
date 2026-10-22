//! Adopting a detached (preview) operation onto the repo as it is now.
//!
//! - Fast path: nothing happened since the preview was made (the current
//!   operation is its base). The detached operation itself becomes the
//!   op head, so its ID does not change.
//! - Otherwise the detached view is merged into the current one with the
//!   concurrent-op-heads merge (`merge_views.zig`): base = the preview's
//!   base view, left = the current view, right = the detached view. The
//!   result is a new operation with parents `[current, detached]`, tagged
//!   `adopted=<detached-hex>`.
//!
//! When the merge would need a decision, adopt returns `.conflicted` and
//! changes nothing, so E12 can ask the user (then `Options.allow_conflicts`
//! adopts anyway, as concurrent writers would). A decision is needed when:
//! a change was rewritten on both sides (it would become divergent), a
//! bookmark moved differently on both sides, or a workspace's working-copy
//! commit changed differently on both sides.
//!
//! The marker goes once the operation is adopted. The caller (ScmService)
//! checks out the working copy if `@` changed.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const store_mod = @import("../store/store.zig");
const index_mod = @import("../graph/index.zig");
const op_mod = @import("operation.zig");
const view_mod = @import("view.zig");
const op_heads = @import("op_heads.zig");
const merge_views = @import("merge_views.zig");
const repo_mod = @import("repo.zig");
const preview = @import("preview.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Store = store_mod.Store;
const Operation = op_mod.Operation;
const OpMeta = op_mod.OpMeta;
const View = view_mod.View;
const Repo = repo_mod.Repo;
const DetachedOp = preview.DetachedOp;
const Allocator = std.mem.Allocator;

/// The tag naming the detached operation an adopt operation merged.
pub const adopted_tag = "adopted";

/// A change rewritten both in the preview and, since, in the repo.
pub const Divergent = struct {
    change_id: ChangeId,
    current: ObjectId,
    detached: ObjectId,
};

/// What adopting would leave for the user to decide. Sorted.
pub const ViewConflicts = struct {
    arena_state: std.heap.ArenaAllocator,
    divergent: []const Divergent = &.{},
    /// Bookmarks that would become conflicted.
    bookmarks: []const []const u8 = &.{},
    /// Workspaces whose working-copy commit both sides changed.
    workspaces: []const []const u8 = &.{},

    pub fn deinit(c: *ViewConflicts) void {
        c.arena_state.deinit();
    }

    pub fn isEmpty(c: *const ViewConflicts) bool {
        return c.divergent.len == 0 and c.bookmarks.len == 0 and c.workspaces.len == 0;
    }
};

pub const AdoptResult = union(enum) {
    /// The new op head.
    adopted: ObjectId,
    conflicted: ViewConflicts,

    pub fn deinit(r: *AdoptResult) void {
        switch (r.*) {
            .adopted => {},
            .conflicted => |*c| c.deinit(),
        }
    }
};

pub const Options = struct {
    /// Adopt even when the merge needs a decision: bookmarks stay
    /// conflicted, both rewrites stay visible (divergent), and the
    /// preview's working-copy commits win.
    allow_conflicts: bool = false,
};

pub fn adopt(repo: *Repo, d: DetachedOp, meta: OpMeta) !AdoptResult {
    return adoptWith(repo, d, meta, .{});
}

pub fn adoptWith(repo: *Repo, d: DetachedOp, meta: OpMeta, opts: Options) !AdoptResult {
    if (repo.read_only) return error.ReadOnly;
    _ = try preview.get(repo, d.op);
    const gpa = repo.gpa;

    if (repo.op().eql(d.base_op)) {
        try op_heads.publish(repo.io, repo.heads_dir, d.op, &.{d.base_op});
        preview.removeMarker(repo.io, repo.repo_dir, d.op);
        return .{ .adopted = d.op };
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base_op = try op_mod.read(Operation, repo.store, a, d.base_op);
    const detached_op = try op_mod.read(Operation, repo.store, a, d.op);
    const base = try op_mod.read(View, repo.store, a, base_op.view);
    const right = try op_mod.read(View, repo.store, a, detached_op.view);
    const left = repo.view().*;
    const merged = try merge_views.mergeViews(gpa, a, base, left, right);

    if (!opts.allow_conflicts) {
        var c = try findConflicts(repo, base, left, right, merged);
        if (!c.isEmpty()) return .{ .conflicted = c };
        c.deinit();
    }

    var hex: [64]u8 = undefined;
    const t = try repo.startTransaction(meta);
    defer t.discard();
    t.meta = try t.meta.withTag(t.arena(), adopted_tag, try t.arena().dupe(u8, d.op.hex(&hex)));
    try t.addParent(d.op);
    try t.setView(merged);
    const id = try t.writeOp();
    try t.publishHead(id);
    preview.removeMarker(repo.io, repo.repo_dir, d.op);
    return .{ .adopted = id };
}

fn findConflicts(repo: *Repo, base: View, left: View, right: View, merged: View) !ViewConflicts {
    var c: ViewConflicts = .{ .arena_state = .init(repo.gpa) };
    errdefer c.deinit();
    const a = c.arena_state.allocator();

    // Bookmarks conflicted by the merge (both lists sorted by name).
    var names: std.ArrayList([]const u8) = .empty;
    for (merged.bookmarks) |m| {
        if (m.target.isConflicted() and !left.bookmark(m.name).isConflicted()) try names.append(a, m.name);
    }
    c.bookmarks = names.items;

    // Working-copy commits both sides moved.
    var wss: std.ArrayList([]const u8) = .empty;
    for (right.wc_commits) |w| {
        const b = base.wcCommit(w.workspace);
        const l = left.wcCommit(w.workspace);
        if (view_mod.optEql(b, w.commit) or view_mod.optEql(b, l) or view_mod.optEql(l, w.commit)) continue;
        try wss.append(a, w.workspace);
    }
    for (base.wc_commits) |w| {
        // Forgotten in the preview, moved in the repo.
        if (right.wcCommit(w.workspace) != null) continue;
        const l = left.wcCommit(w.workspace) orelse continue;
        if (!l.eql(w.commit)) try wss.append(a, w.workspace);
    }
    std.mem.sort([]const u8, wss.items, {}, lessStr);
    c.workspaces = wss.items;

    c.divergent = try findDivergent(repo, a, base, left, right);
    return c;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// Commits new on both sides (not reachable from the base view's heads)
/// that share a change ID.
fn findDivergent(repo: *Repo, out_arena: Allocator, base: View, left: View, right: View) ![]const Divergent {
    const gpa = repo.gpa;
    // Divergence needs new commits on both sides, so new heads on both.
    const added = struct {
        fn any(b: View, side: View) bool {
            for (side.heads) |h| if (!b.hasHead(h)) return true;
            return false;
        }
    }.any;
    if (!added(base, left) or !added(base, right)) return &.{};
    var old: OldSet = try .init(repo, base, &.{ left.heads, right.heads });
    defer old.deinit();
    var mine: std.AutoArrayHashMapUnmanaged(ObjectId, ChangeId) = .empty;
    defer mine.deinit(gpa);
    var theirs: std.AutoArrayHashMapUnmanaged(ObjectId, ChangeId) = .empty;
    defer theirs.deinit(gpa);
    try old.newCommits(left, &mine);
    try old.newCommits(right, &theirs);

    var by_change: std.AutoHashMapUnmanaged(ChangeId, std.ArrayList(ObjectId)) = .empty;
    defer {
        var it = by_change.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        by_change.deinit(gpa);
    }
    for (mine.keys(), mine.values()) |id, cid| {
        const gop = try by_change.getOrPut(gpa, cid);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, id);
    }
    var out: std.ArrayList(Divergent) = .empty;
    for (theirs.keys(), theirs.values()) |id, cid| {
        const l = by_change.get(cid) orelse continue;
        for (l.items) |cur| {
            if (!cur.eql(id)) try out.append(out_arena, .{ .change_id = cid, .current = cur, .detached = id });
        }
    }
    std.mem.sort(Divergent, out.items, {}, struct {
        fn lt(_: void, x: Divergent, y: Divergent) bool {
            const o = std.mem.order(u8, &x.change_id.bytes, &y.change_id.bytes);
            if (o != .eq) return o == .lt;
            if (!x.current.eql(y.current)) return ObjectId.lessThan({}, x.current, y.current);
            return ObjectId.lessThan({}, x.detached, y.detached);
        }
    }.lt);
    return out.items;
}

/// Answers "is this commit reachable from the base view's heads?". With a
/// commit index that is an ancestry query per base head; without one, the
/// whole base history is walked once (tests and small repos).
const OldSet = struct {
    repo: *Repo,
    base: View,
    arena_state: std.heap.ArenaAllocator,
    ix: ?*index_mod.CommitIndex,
    base_pos: []const index_mod.Pos = &.{},
    /// Without an index: every commit reachable from the base heads.
    all: std.AutoHashMapUnmanaged(ObjectId, void) = .empty,

    fn init(repo: *Repo, base: View, others: []const []const ObjectId) !OldSet {
        const gpa = repo.gpa;
        var s: OldSet = .{ .repo = repo, .base = base, .arena_state = .init(gpa), .ix = repo.opts.index };
        errdefer s.deinit();
        const a = s.arena_state.allocator();
        if (s.ix) |ix| {
            try ix.ensureIndexed(base.heads);
            for (others) |hs| try ix.ensureIndexed(hs);
            var ps: std.ArrayList(index_mod.Pos) = .empty;
            for (base.heads) |h| if (ix.pos(h)) |p| try ps.append(a, p);
            s.base_pos = ps.items;
            return s;
        }
        var stack: std.ArrayList(ObjectId) = .empty;
        defer stack.deinit(gpa);
        try stack.appendSlice(gpa, base.heads);
        while (stack.pop()) |x| {
            if ((try s.all.getOrPut(gpa, x)).found_existing) continue;
            const ch = try op_mod.read(object.Change, repo.store, a, x);
            try stack.appendSlice(gpa, ch.parents);
        }
        return s;
    }

    fn deinit(s: *OldSet) void {
        s.all.deinit(s.repo.gpa);
        s.arena_state.deinit();
    }

    fn contains(s: *OldSet, id: ObjectId) !bool {
        if (s.base.hasHead(id)) return true;
        const ix = s.ix orelse return s.all.contains(id);
        const p = ix.pos(id) orelse return false;
        for (s.base_pos) |b| if (try ix.isAncestor(p, b)) return true;
        return false;
    }

    /// Adds the commits reachable from `side`'s heads but not from the
    /// base heads, with their change IDs.
    fn newCommits(s: *OldSet, side: View, out: *std.AutoArrayHashMapUnmanaged(ObjectId, ChangeId)) !void {
        const gpa = s.repo.gpa;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var seen: std.AutoHashMapUnmanaged(ObjectId, void) = .empty;
        defer seen.deinit(gpa);
        var stack: std.ArrayList(ObjectId) = .empty;
        defer stack.deinit(gpa);
        for (side.heads) |h| if (!s.base.hasHead(h)) try stack.append(gpa, h);
        while (stack.pop()) |x| {
            if ((try seen.getOrPut(gpa, x)).found_existing) continue;
            if (try s.contains(x)) continue;
            const ch = try op_mod.read(object.Change, s.repo.store, a, x);
            try out.put(gpa, x, ch.change_id);
            try stack.appendSlice(gpa, ch.parents);
        }
    }
};
