//! Operation log tests: commit and load, concurrent view merges, undo,
//! restore, `--at-op` and op abandon with GC.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const gc_mod = @import("../store/gc.zig");
const op_mod = @import("operation.zig");
const view_mod = @import("view.zig");
const op_heads = @import("op_heads.zig");
const repo_mod = @import("repo.zig");
const undo_mod = @import("undo.zig");
const index_mod = @import("../graph/index.zig");
const fx = @import("test_fixture.zig");
const ObjectId = id_mod.ObjectId;
const Repo = repo_mod.Repo;
const meta = fx.meta;

/// Commits a transaction setting bookmark `name` to `id` (null deletes),
/// closing `r`.
fn setBookmark(r: *Repo, name: []const u8, id: ?ObjectId) !*Repo {
    defer r.close();
    const tx = try r.startTransaction(meta(name));
    errdefer tx.discard();
    var t: ?ObjectId = id;
    try tx.mutRepo().setBookmark(name, if (id == null) .absent else fx.target(&t));
    return tx.commit();
}

fn expectBookmark(r: *const Repo, name: []const u8, want: ?ObjectId) !void {
    const got = r.view().bookmark(name);
    try std.testing.expect(!got.isConflicted());
    try std.testing.expect(view_mod.optEql(want, got.asNormal()));
}

test "oplog: commit/load roundtrip" {
    const t = std.testing;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    const root = r0.op();
    const tx = try r0.startTransaction(meta("new change"));
    const m = tx.mutRepo();
    const c = try fx.change(m, &.{}, "c");
    var tgt: ?ObjectId = c;
    try m.setBookmark("main", fx.target(&tgt));
    try m.setWcCommit("default", c);
    try m.setLane(.{ .name = "lane-1", .workspace = "default", .owner = "agent", .base = c, .status = "active", .policy = "", .updated_ms = 5, .extra = &.{} });
    const r1 = try tx.commit();
    defer r1.close();
    r0.close();

    try t.expectEqualSlices(ObjectId, &.{root}, r1.operation.parents);
    try t.expectEqual(op_mod.ActorKind.human, r1.operation.meta.actor.kind);
    const heads = try op_heads.list(t.allocator, f.io, r1.heads_dir);
    defer t.allocator.free(heads);
    try t.expectEqualSlices(ObjectId, &.{r1.op()}, heads);

    const loaded = try f.load(.head);
    defer loaded.close();
    try t.expect(loaded.op().eql(r1.op()));
    try t.expect(!loaded.read_only);
    const v = loaded.view();
    try t.expectEqualSlices(ObjectId, &.{c}, v.heads);
    try expectBookmark(loaded, "main", c);
    try t.expect(v.wcCommit("default").?.eql(c));
    try t.expectEqualStrings("active", v.lane("lane-1").?.status);
    try t.expectEqualStrings("new change", loaded.operation.meta.description);
    try t.expect(loaded.operation.meta.end_ms >= loaded.operation.meta.start_ms);
    try t.expectError(error.AlreadyInitialized, f.initRepo());
}

test "oplog: conflicting bookmark moves give a conflicted target" {
    const t = std.testing;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    var tx = try r0.startTransaction(meta("base"));
    const c0 = try fx.change(tx.mutRepo(), &.{}, "c0");
    var t0: ?ObjectId = c0;
    try tx.mutRepo().setBookmark("main", fx.target(&t0));
    const base = try tx.commit();
    r0.close();
    defer base.close();

    // Two writers on the same operation, neither seeing the other.
    var ids: [2]ObjectId = undefined;
    for (&ids, [_][]const u8{ "c1", "c2" }) |*id, name| {
        const w = try base.startTransaction(meta(name));
        id.* = try fx.change(w.mutRepo(), &.{c0}, name);
        var tid: ?ObjectId = id.*;
        try w.mutRepo().setBookmark("main", fx.target(&tid));
        const r = try w.commit();
        r.close();
    }
    {
        const heads = try op_heads.list(t.allocator, f.io, base.heads_dir);
        defer t.allocator.free(heads);
        try t.expectEqual(@as(usize, 2), heads.len);
    }
    const merged = try f.load(.head);
    defer merged.close();
    try t.expectEqual(@as(usize, 2), merged.operation.parents.len);
    const main = merged.view().bookmark("main");
    try t.expect(main.isConflicted());
    try t.expectEqual(@as(usize, 3), main.terms.len);
    try t.expect(view_mod.optEql(main.terms[1], c0));
    var adds = [_]ObjectId{ main.terms[0].?, main.terms[2].? };
    std.mem.sort(ObjectId, &adds, {}, ObjectId.lessThan);
    std.mem.sort(ObjectId, &ids, {}, ObjectId.lessThan);
    try t.expectEqualSlices(ObjectId, &ids, &adds);
    // Both new commits are visible; their shared parent is not a head.
    try t.expectEqualSlices(ObjectId, &ids, merged.view().heads);

    // The merge was published: one head again, and loading is stable.
    const again = try f.load(.head);
    defer again.close();
    try t.expect(again.op().eql(merged.op()));

    // Resolving the conflict is an ordinary bookmark move.
    const resolved = try setBookmark(try f.load(.head), "main", ids[0]);
    defer resolved.close();
    try expectBookmark(resolved, "main", ids[0]);
}

test "oplog: merging the same bookmark move twice is not a conflict" {
    const t = std.testing;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(meta("c"));
    const c = try fx.change(tx.mutRepo(), &.{}, "c");
    const r1 = try tx.commit();
    defer r1.close();
    for (0..2) |_| {
        const w = try r1.startTransaction(meta("move"));
        var tid: ?ObjectId = c;
        try w.mutRepo().setBookmark("main", fx.target(&tid));
        try w.mutRepo().setBookmark("only-once", fx.target(&tid));
        const r = try w.commit();
        r.close();
    }
    const merged = try f.load(.head);
    defer merged.close();
    try expectBookmark(merged, "main", c);
}

test "oplog: undo middle op only reverts its effect" {
    const t = std.testing;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    var tx = try r0.startTransaction(meta("c"));
    const c = try fx.change(tx.mutRepo(), &.{}, "c");
    var r = try tx.commit();
    r0.close();
    r = try setBookmark(r, "a", c);
    const op_a = r.op();
    r = try setBookmark(r, "b", c);
    r = try setBookmark(r, "z", c);
    defer r.close();

    const u = try undo_mod.undo(r, op_a, meta("undo a"));
    defer u.close();
    try expectBookmark(u, "a", null);
    try expectBookmark(u, "b", c);
    try expectBookmark(u, "z", c);
    try t.expectEqualSlices(ObjectId, &.{c}, u.view().heads);
    try t.expectEqualSlices(ObjectId, &.{r.op()}, u.operation.parents);

    // Undo of undo redoes.
    const redo = try undo_mod.undo(u, u.op(), meta("redo"));
    defer redo.close();
    try expectBookmark(redo, "a", c);
    try expectBookmark(redo, "b", c);

    try t.expectError(error.CannotUndoRoot, undo_mod.undo(redo, (try rootOf(t.allocator, redo)), meta("x")));
}

fn rootOf(gpa: std.mem.Allocator, r: *Repo) !ObjectId {
    var g: repo_mod.OpGraph = .init(gpa, r.store);
    defer g.deinit();
    var x = r.op();
    while (true) {
        const n = try g.get(x);
        if (n.parents.len == 0) return x;
        x = n.parents[0];
    }
}

test "oplog: undo of a moved bookmark restores the old target" {
    var f = try fx.Fixture.init(std.testing.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    var tx = try r0.startTransaction(meta("c"));
    const c1 = try fx.change(tx.mutRepo(), &.{}, "c1");
    const c2 = try fx.change(tx.mutRepo(), &.{c1}, "c2");
    var r = try tx.commit();
    r0.close();
    r = try setBookmark(r, "main", c1);
    r = try setBookmark(r, "main", c2);
    const moved = r.op();
    r = try setBookmark(r, "other", c1);
    defer r.close();
    const u = try undo_mod.undo(r, moved, meta("undo move"));
    defer u.close();
    try expectBookmark(u, "main", c1);
    try expectBookmark(u, "other", c1);
}

test "oplog: restore" {
    const t = std.testing;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    var tx = try r0.startTransaction(meta("c"));
    const c = try fx.change(tx.mutRepo(), &.{}, "c");
    var r = try tx.commit();
    r0.close();
    r = try setBookmark(r, "a", c);
    const at_a = r.op();
    const view_a = r.view_id;
    r = try setBookmark(r, "b", c);
    r = try setBookmark(r, "a", null);
    defer r.close();

    const back = try undo_mod.restore(r, at_a, meta("restore"));
    defer back.close();
    try t.expect(back.view_id.eql(view_a));
    try expectBookmark(back, "a", c);
    try expectBookmark(back, "b", null);
    // History is kept: the restore follows the current operation.
    try t.expectEqualSlices(ObjectId, &.{r.op()}, back.operation.parents);
    var log = try undo_mod.opLog(back, t.allocator, back.op(), 100);
    defer log.deinit();
    try t.expectEqual(@as(usize, 6), log.entries.len);
    try t.expectEqualStrings("restore", log.entries[0].meta.description);
    try t.expectEqualStrings("init", log.entries[5].meta.description);
    for (1..@max(1, log.entries.len)) |i| try t.expect(log.entries[i - 1].meta.end_ms >= log.entries[i].meta.end_ms);
    var short = try undo_mod.opLog(back, t.allocator, back.op(), 2);
    defer short.deinit();
    try t.expectEqual(@as(usize, 2), short.entries.len);
}

test "oplog: at-op read-only" {
    const t = std.testing;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    var tx = try r0.startTransaction(meta("c"));
    const c = try fx.change(tx.mutRepo(), &.{}, "c");
    var r = try tx.commit();
    r0.close();
    r = try setBookmark(r, "a", c);
    const at_a = r.op();
    r = try setBookmark(r, "b", c);
    defer r.close();

    const old = try f.load(.{ .op = at_a });
    defer old.close();
    try t.expect(old.read_only);
    try expectBookmark(old, "a", c);
    try expectBookmark(old, "b", null);
    try t.expectError(error.ReadOnly, old.startTransaction(meta("nope")));

    var hex: [64]u8 = undefined;
    const byprefix = try f.load(.{ .op_prefix = at_a.hex(&hex)[0..12] });
    defer byprefix.close();
    try t.expect(byprefix.op().eql(at_a));
    try t.expectError(error.InvalidOpId, f.load(.{ .op_prefix = "xyz" }));
    try t.expectError(error.OpNotFound, f.load(.{ .op_prefix = "0000000000000000000000000000" }));

    // Loading at an old operation publishes nothing.
    const heads = try op_heads.list(t.allocator, f.io, r.heads_dir);
    defer t.allocator.free(heads);
    try t.expectEqualSlices(ObjectId, &.{r.op()}, heads);
}

test "oplog: abandon then gc" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    const r0 = try f.initRepo();
    const root = r0.op();
    var tx = try r0.startTransaction(meta("c"));
    const c = try fx.change(tx.mutRepo(), &.{}, "c");
    var r = try tx.commit();
    r0.close();
    const op1 = r.op();
    r = try setBookmark(r, "a", c);
    const op2 = r.op();
    const view2 = r.view_id;
    r = try setBookmark(r, "b", c);
    const op3 = r.op();
    const view3 = r.view_id;
    r = try setBookmark(r, "d", c);
    const view4 = r.view_id;
    try t.expectError(error.CannotAbandonHead, undo_mod.abandonAncestors(r, r.op()));
    try t.expectError(error.CannotAbandonRoot, undo_mod.abandonAncestors(r, root));

    const n = try undo_mod.abandonAncestors(r, op2);
    r.close();
    defer n.close();
    try t.expect(n.view_id.eql(view4));
    var log = try undo_mod.opLog(n, gpa, n.op(), 100);
    defer log.deinit();
    try t.expectEqual(@as(usize, 3), log.entries.len);
    try t.expect(log.entries[1].view.eql(view3));
    try t.expectEqualSlices(ObjectId, &.{root}, log.entries[1].parents);
    try t.expect(log.entries[2].id.eql(root));

    const report = try gc_mod.gc(f.store, &.{n.gcRoots()}, .{
        .grace_ns = 0,
        .rewrite_below = 1.01,
        .edges = .{ .extra_edges = op_mod.gcEdges, .extra_ctx = f.store },
    });
    try t.expect(report.objects_removed > 0);
    for ([_]ObjectId{ op1, op2, op3, view2 }) |gone| try t.expect(!f.store.contains(gone));
    for ([_]ObjectId{ root, view3, view4, c, n.op() }) |kept| try t.expect(f.store.contains(kept));

    const loaded = try f.load(.head);
    defer loaded.close();
    try t.expect(loaded.op().eql(n.op()));
    try expectBookmark(loaded, "a", c);
    try expectBookmark(loaded, "d", c);
}

test "oplog: rewritten changes leave the heads" {
    const t = std.testing;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(meta("c"));
    const c = try fx.change(tx.mutRepo(), &.{}, "c");
    const r1 = try tx.commit();
    defer r1.close();
    tx = try r1.startTransaction(meta("amend"));
    const m = tx.mutRepo();
    var amended = (try op_mod.read(@import("../store/object.zig").Change, f.store, tx.arena(), c));
    amended.description = "c amended";
    const c2 = try m.rewriteChange(c, amended);
    try t.expect(m.rewritten.get(c).?.eql(c2));
    const r2 = try tx.commit();
    defer r2.close();
    try t.expectEqualSlices(ObjectId, &.{c2}, r2.view().heads);
    const ch = try op_mod.read(@import("../store/object.zig").Change, f.store, r2.arena_state.allocator(), c2);
    try t.expectEqualSlices(ObjectId, &.{c}, ch.predecessors);
}

test "oplog: discarded transactions publish nothing" {
    const t = std.testing;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    const tx = try r0.startTransaction(meta("dropped"));
    _ = try fx.change(tx.mutRepo(), &.{}, "c");
    tx.discard();
    const loaded = try f.load(.head);
    defer loaded.close();
    try t.expect(loaded.op().eql(r0.op()));
    try t.expectEqual(@as(usize, 0), loaded.view().heads.len);
}

test "oplog: large views are stored as patches" {
    const t = std.testing;
    const gpa = t.allocator;
    const enc = @import("../store/encode.zig");
    const view_delta = @import("view_delta.zig");
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    var r = try f.initRepo();
    // ~200 bookmarks make the view far larger than 4 KiB.
    const c = blk: {
        const tx = try r.startTransaction(meta("many bookmarks"));
        errdefer tx.discard();
        const m = tx.mutRepo();
        const c = try fx.change(m, &.{}, "c");
        var tgt: ?ObjectId = c;
        for (0..200) |i| {
            var nb: [32]u8 = undefined;
            try m.setBookmark(try std.fmt.bufPrint(&nb, "feature/bookmark-{d}", .{i}), fx.target(&tgt));
        }
        const n = try tx.commit();
        r.close();
        r = n;
        break :blk c;
    };

    var depths: std.ArrayList(u8) = .empty;
    defer depths.deinit(gpa);
    var views: std.ArrayList(ObjectId) = .empty;
    defer views.deinit(gpa);
    for (0..40) |i| {
        var nb: [32]u8 = undefined;
        r = try setBookmark(r, try std.fmt.bufPrint(&nb, "op-{d}", .{i}), if (i % 3 == 0) null else c);
        const raw = try f.store.read(r.view_id);
        defer raw.release();
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const stored = try enc.decode(view_mod.View, arena_state.allocator(), raw.bytes);
        const d = view_delta.deltaOf(stored);
        try depths.append(gpa, if (d) |x| x.depth else 0);
        if (d) |x| try t.expect(raw.bytes.len < 1024 and x.patch.len < 512);
        try views.append(gpa, r.view_id);
    }
    // Up to max_depth patched views share one full base, then a new full
    // view starts the next run.
    try t.expectEqual(@as(u8, 1), depths.items[0]);
    try t.expectEqual(@as(u8, view_delta.max_depth), depths.items[view_delta.max_depth - 1]);
    try t.expectEqual(@as(u8, 0), depths.items[view_delta.max_depth]);
    try t.expectEqual(@as(u8, 1), depths.items[view_delta.max_depth + 1]);
    try expectBookmark(r, "feature/bookmark-199", c);
    try expectBookmark(r, "op-38", c);
    try expectBookmark(r, "op-39", null);

    // GC keeps every base a live patch needs; loading still works after.
    const head = r.op();
    defer r.close();
    _ = try gc_mod.gc(f.store, &.{r.gcRoots()}, .{
        .grace_ns = 0,
        .rewrite_below = 1.01,
        .edges = .{ .extra_edges = op_mod.gcEdges, .extra_ctx = f.store },
    });
    const loaded = try f.load(.head);
    defer loaded.close();
    try t.expect(loaded.op().eql(head));
    try expectBookmark(loaded, "feature/bookmark-0", c);
    try expectBookmark(loaded, "op-37", c);
    try t.expectError(error.DeltaViewNeedsStore, gc_mod.gc(f.store, &.{loaded.gcRoots()}, .{
        .grace_ns = 0,
        .edges = .{ .extra_edges = op_mod.gcEdges },
    }));
}

fn parentsOf(r: *Repo, id: ObjectId) ![]const ObjectId {
    const Change = @import("../store/object.zig").Change;
    return (try op_mod.read(Change, r.store, r.arena_state.allocator(), id)).parents;
}

test "oplog: rebaseDescendants follows rewrites and abandons" {
    const t = std.testing;
    const rebase = @import("rebase.zig");
    const Change = @import("../store/object.zig").Change;
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();

    // root ← a ← b ← c, plus a side branch a ← s; bookmarks on b and c,
    // the working copy on c, a tag on b.
    var tx = try r0.startTransaction(meta("stack"));
    var m = tx.mutRepo();
    const root = try fx.change(m, &.{}, "root");
    const a = try fx.change(m, &.{root}, "a");
    const b = try fx.change(m, &.{a}, "b");
    const c = try fx.change(m, &.{b}, "c");
    const s = try fx.change(m, &.{a}, "s");
    var tb: ?ObjectId = b;
    var tc: ?ObjectId = c;
    try m.setBookmark("mid", fx.target(&tb));
    try m.setBookmark("top", fx.target(&tc));
    try m.setTag("v1", fx.target(&tb));
    try m.setWcCommit("default", c);
    // Nothing rewritten yet: a no-op.
    try t.expectEqual(@as(usize, 0), (try m.rebaseDescendants(rebase.reparent, null)).rebased);
    const r1 = try tx.commit();
    defer r1.close();

    // Reword a: b, c and s follow.
    tx = try r1.startTransaction(meta("reword a"));
    m = tx.mutRepo();
    var ch = try m.readChange(tx.arena(), a);
    ch.description = "a reworded";
    const a2 = try m.rewriteChange(a, ch);
    const st = try m.rebaseDescendants(rebase.reparent, null);
    try t.expectEqual(@as(usize, 3), st.rebased);
    try t.expectEqual(@as(usize, 3), st.refs_moved);
    const r2 = try tx.commit();
    defer r2.close();
    const v2 = r2.view();
    try t.expectEqual(@as(usize, 2), v2.heads.len);
    const c2 = v2.bookmark("top").asNormal().?;
    const b2 = v2.bookmark("mid").asNormal().?;
    try t.expect(v2.wcCommit("default").?.eql(c2));
    try t.expect(v2.tag("v1").asNormal().?.eql(b));
    try t.expectEqualSlices(ObjectId, &.{b2}, try parentsOf(r2, c2));
    try t.expectEqualSlices(ObjectId, &.{a2}, try parentsOf(r2, b2));
    const c2_change = try op_mod.read(Change, f.store, r2.arena_state.allocator(), c2);
    try t.expectEqualSlices(ObjectId, &.{c}, c2_change.predecessors);
    try t.expectEqualStrings("c", c2_change.description);
    for (v2.heads) |h| {
        if (h.eql(c2)) continue;
        try t.expectEqualSlices(ObjectId, &.{a2}, try parentsOf(r2, h));
    }
    _ = s;

    // Abandon b2 with the index pruning the walk: c moves onto a2, and
    // so do the bookmark and the working copy; nothing else is rebased.
    var ix_dir = try f.tmp.dir.createDirPathOpen(f.io, "index", .{});
    defer ix_dir.close(f.io);
    const ix = try index_mod.CommitIndex.open(t.allocator, f.io, ix_dir, f.store, .{ .fsync = false });
    defer ix.close();
    try ix.ensureIndexed(v2.heads);
    tx = try r2.startTransaction(meta("abandon b"));
    m = tx.mutRepo();
    try m.abandon(b2, &.{a2});
    const st2 = try m.rebaseDescendants(rebase.reparent, ix);
    try t.expectEqual(@as(usize, 1), st2.rebased);
    // Only c2 sits above b2's level; the side head and b2 are pruned.
    try t.expectEqual(@as(usize, 1), st2.visited);
    const r3 = try tx.commit();
    defer r3.close();
    const v3 = r3.view();
    const c3 = v3.bookmark("top").asNormal().?;
    try t.expect(v3.bookmark("mid").asNormal().?.eql(a2));
    try t.expect(v3.wcCommit("default").?.eql(c3));
    try t.expectEqualSlices(ObjectId, &.{a2}, try parentsOf(r3, c3));
    try t.expectEqual(@as(usize, 2), v3.heads.len);
    try t.expect(v3.hasHead(c3));
}

test "oplog: rebaseDescendants chains rewrites within one transaction" {
    const t = std.testing;
    const rebase = @import("rebase.zig");
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    const tx = try r0.startTransaction(meta("all at once"));
    const m = tx.mutRepo();
    // A merge whose two parents are rewritten and abandoned in the same
    // transaction that wrote them, then a rewrite of the rewrite.
    const root = try fx.change(m, &.{}, "root");
    const x = try fx.change(m, &.{root}, "x");
    const y = try fx.change(m, &.{root}, "y");
    const merge = try fx.change(m, &.{ x, y }, "merge");
    var ch = try m.readChange(tx.arena(), x);
    ch.description = "x2";
    const x2 = try m.rewriteChange(x, ch);
    ch = try m.readChange(tx.arena(), x2);
    ch.description = "x3";
    const x3 = try m.rewriteChange(x2, ch);
    try m.abandon(y, &.{root});
    var tm: ?ObjectId = merge;
    try m.setBookmark("m", fx.target(&tm));
    var ty: ?ObjectId = y;
    try m.setBookmark("y", fx.target(&ty));
    const st = try m.rebaseDescendants(rebase.reparent, null);
    try t.expectEqual(@as(usize, 1), st.rebased);
    const r1 = try tx.commit();
    defer r1.close();
    const v = r1.view();
    const merge2 = v.bookmark("m").asNormal().?;
    try t.expectEqualSlices(ObjectId, &.{merge2}, v.heads);
    try t.expectEqualSlices(ObjectId, &.{ x3, root }, try parentsOf(r1, merge2));
    try t.expect(v.bookmark("y").asNormal().?.eql(root));
}
