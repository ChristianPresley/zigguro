//! Preview (detached) operation tests: invisibility, adoption (fast path,
//! merged, conflicted), discard and GC, expiry, view diffs and undoing an
//! adoption.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const gc_mod = @import("../store/gc.zig");
const op_mod = @import("operation.zig");
const view_mod = @import("view.zig");
const op_heads = @import("op_heads.zig");
const repo_mod = @import("repo.zig");
const undo_mod = @import("undo.zig");
const preview = @import("preview.zig");
const adopt_mod = @import("adopt.zig");
const fx = @import("test_fixture.zig");
const ObjectId = id_mod.ObjectId;
const Repo = repo_mod.Repo;
const meta = fx.meta;
const Allocator = std.mem.Allocator;

/// The sorted names in `op_heads/`, for asserting it did not change.
fn snapshotHeads(gpa: Allocator, r: *const Repo) ![]ObjectId {
    return op_heads.list(gpa, r.io, r.heads_dir);
}

fn setBookmark(r: *Repo, name: []const u8, id: ObjectId) !*Repo {
    defer r.close();
    const tx = try r.startTransaction(meta(name));
    errdefer tx.discard();
    var t: ?ObjectId = id;
    try tx.mutRepo().setBookmark(name, fx.target(&t));
    return tx.commit();
}

/// A detached operation on `r` setting bookmark `name` to `id`.
fn previewBookmark(r: *Repo, name: []const u8, id: ObjectId) !preview.DetachedOp {
    const tx = try r.startTransaction(meta("preview"));
    var t: ?ObjectId = id;
    tx.mutRepo().setBookmark(name, fx.target(&t)) catch |e| {
        tx.discard();
        return e;
    };
    return preview.commitDetached(tx, .proposal);
}

/// The repo with one change `c` and returns it.
fn withChange(f: *fx.Fixture, r0: *Repo, c: *ObjectId) !*Repo {
    _ = f;
    const tx = try r0.startTransaction(meta("c"));
    errdefer tx.discard();
    c.* = try fx.change(tx.mutRepo(), &.{}, "c");
    return tx.commit();
}

fn rewrite(r: *Repo, old: ObjectId, description: []const u8) !struct { *Repo, ObjectId } {
    defer r.close();
    const tx = try r.startTransaction(meta(description));
    errdefer tx.discard();
    var ch = try op_mod.read(object.Change, r.store, tx.arena(), old);
    ch.description = description;
    const id = try tx.mutRepo().rewriteChange(old, ch);
    return .{ try tx.commit(), id };
}

test "preview: detached op invisible to Repo.load and op log heads" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    var c: ObjectId = undefined;
    const r0 = try f.initRepo();
    const r = try withChange(&f, r0, &c);
    r0.close();
    defer r.close();

    const before = try snapshotHeads(gpa, r);
    defer gpa.free(before);
    const d = try previewBookmark(r, "main", c);
    const after = try snapshotHeads(gpa, r);
    defer gpa.free(after);
    try t.expectEqualSlices(ObjectId, before, after);
    try t.expect(d.base_op.eql(r.op()));
    try t.expectEqual(preview.DetachedOp.Purpose.proposal, d.purpose);

    const loaded = try f.load(.head);
    defer loaded.close();
    try t.expect(loaded.op().eql(r.op()));
    try t.expect(loaded.view().bookmark("main").isAbsent());
    var log = try undo_mod.opLog(loaded, gpa, loaded.op(), 100);
    defer log.deinit();
    for (log.entries) |e| try t.expect(!e.id.eql(d.op));

    // Listed (as after a restart: everything comes from the marker and
    // the operation), and loadable read-only.
    const pending = try preview.list(loaded, gpa);
    defer gpa.free(pending);
    try t.expectEqual(@as(usize, 1), pending.len);
    try t.expectEqual(d, pending[0]);
    const at = try preview.loadDetached(gpa, f.io, f.tmp.dir, f.store, .{}, d.op);
    defer at.close();
    try t.expect(at.read_only);
    try t.expect(at.view().bookmark("main").asNormal().?.eql(c));
    try t.expectError(error.NotDetached, preview.loadDetached(gpa, f.io, f.tmp.dir, f.store, .{}, r.op()));
}

test "preview: adopt fast path (no intervening ops) publishes same op id" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    var c: ObjectId = undefined;
    const r0 = try f.initRepo();
    const r = try withChange(&f, r0, &c);
    r0.close();
    defer r.close();
    const d = try previewBookmark(r, "main", c);

    var res = try adopt_mod.adopt(r, d, meta("adopt"));
    defer res.deinit();
    try t.expect(res.adopted.eql(d.op));
    const heads = try snapshotHeads(gpa, r);
    defer gpa.free(heads);
    try t.expectEqualSlices(ObjectId, &.{d.op}, heads);
    const pending = try preview.list(r, gpa);
    defer gpa.free(pending);
    try t.expectEqual(@as(usize, 0), pending.len);
    try t.expectError(error.NotDetached, adopt_mod.adopt(r, d, meta("again")));

    const loaded = try f.load(.head);
    defer loaded.close();
    try t.expect(loaded.view().bookmark("main").asNormal().?.eql(c));
}

test "preview: adopt after concurrent op merges views" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    var c: ObjectId = undefined;
    const r0 = try f.initRepo();
    var r = try withChange(&f, r0, &c);
    r0.close();
    const d = try previewBookmark(r, "proposed", c);
    r = try setBookmark(r, "concurrent", c);
    defer r.close();
    const current = r.op();

    var res = try adopt_mod.adopt(r, d, meta("adopt"));
    defer res.deinit();
    const id = res.adopted;
    try t.expect(!id.eql(d.op));
    const loaded = try f.load(.head);
    defer loaded.close();
    try t.expect(loaded.op().eql(id));
    try t.expectEqualSlices(ObjectId, &.{ current, d.op }, loaded.operation.parents);
    var hex: [64]u8 = undefined;
    try t.expectEqualStrings(d.op.hex(&hex), loaded.operation.meta.tag(adopt_mod.adopted_tag).?);
    try t.expect(loaded.view().bookmark("proposed").asNormal().?.eql(c));
    try t.expect(loaded.view().bookmark("concurrent").asNormal().?.eql(c));
    const pending = try preview.list(loaded, gpa);
    defer gpa.free(pending);
    try t.expectEqual(@as(usize, 0), pending.len);
}

test "preview: divergent rewrite reported as conflicted" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    var c: ObjectId = undefined;
    const r0 = try f.initRepo();
    var r = try withChange(&f, r0, &c);
    r0.close();
    r = try setBookmark(r, "main", c);

    // The preview rewrites c and moves main to the rewrite.
    const d = blk: {
        const tx = try r.startTransaction(meta("proposal"));
        errdefer tx.discard();
        var ch = try op_mod.read(object.Change, r.store, tx.arena(), c);
        ch.description = "c (proposed)";
        const m = tx.mutRepo();
        const id = try m.rewriteChange(c, ch);
        var tt: ?ObjectId = id;
        try m.setBookmark("main", fx.target(&tt));
        break :blk try preview.commitDetached(tx, .proposal);
    };
    const d_view = try preview.loadDetached(gpa, f.io, f.tmp.dir, f.store, .{}, d.op);
    defer d_view.close();
    const proposed = d_view.view().heads[0];

    // Meanwhile the user rewrites c too, and moves main to it.
    r, const mine = try rewrite(r, c, "c (mine)");
    r = try setBookmark(r, "main", mine);
    defer r.close();
    const before = r.op();

    var res = try adopt_mod.adopt(r, d, meta("adopt"));
    defer res.deinit();
    const cf = res.conflicted;
    try t.expectEqual(@as(usize, 1), cf.divergent.len);
    try t.expect(cf.divergent[0].current.eql(mine));
    try t.expect(cf.divergent[0].detached.eql(proposed));
    const ch = try op_mod.read(object.Change, f.store, d_view.arena_state.allocator(), c);
    try t.expectEqual(ch.change_id, cf.divergent[0].change_id);
    try t.expectEqual(@as(usize, 1), cf.bookmarks.len);
    try t.expectEqualStrings("main", cf.bookmarks[0]);
    try t.expectEqual(@as(usize, 0), cf.workspaces.len);

    // Nothing changed; still pending.
    const heads = try snapshotHeads(gpa, r);
    defer gpa.free(heads);
    try t.expectEqualSlices(ObjectId, &.{before}, heads);
    _ = try preview.get(r, d.op);

    // Adopting anyway leaves both rewrites visible and main conflicted.
    var forced = try adopt_mod.adoptWith(r, d, meta("adopt anyway"), .{ .allow_conflicts = true });
    defer forced.deinit();
    const loaded = try f.load(.head);
    defer loaded.close();
    try t.expect(loaded.op().eql(forced.adopted));
    try t.expect(loaded.view().hasHead(mine));
    try t.expect(loaded.view().hasHead(proposed));
    try t.expect(loaded.view().bookmark("main").isConflicted());
}

test "preview: working-copy commits moved on both sides are conflicted" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    var c: ObjectId = undefined;
    const r0 = try f.initRepo();
    var r = try withChange(&f, r0, &c);
    r0.close();
    const d = blk: {
        const tx = try r.startTransaction(meta("proposal"));
        errdefer tx.discard();
        const m = tx.mutRepo();
        try m.setWcCommit("default", try fx.change(m, &.{c}, "proposed wc"));
        break :blk try preview.commitDetached(tx, .dry_run);
    };
    const prev = r;
    r = blk: {
        defer prev.close();
        const tx = try prev.startTransaction(meta("edit"));
        errdefer tx.discard();
        const m = tx.mutRepo();
        try m.setWcCommit("default", try fx.change(m, &.{c}, "my wc"));
        break :blk try tx.commit();
    };
    defer r.close();
    var res = try adopt_mod.adopt(r, d, meta("adopt"));
    defer res.deinit();
    try t.expectEqual(@as(usize, 1), res.conflicted.workspaces.len);
    try t.expectEqualStrings("default", res.conflicted.workspaces[0]);
    try t.expectEqual(@as(usize, 0), res.conflicted.divergent.len);
}

test "preview: discard then gc collects objects after grace" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    const r = try f.initRepo();
    defer r.close();
    var x: ObjectId = undefined;
    const d = blk: {
        const tx = try r.startTransaction(meta("proposal"));
        errdefer tx.discard();
        x = try fx.change(tx.mutRepo(), &.{}, "proposed");
        break :blk try preview.commitDetached(tx, .proposal);
    };
    const gc_opts: gc_mod.GcOptions = .{
        .grace_ns = 0,
        .rewrite_below = 1.01,
        .edges = .{ .extra_edges = op_mod.gcEdges },
    };
    _ = try gc_mod.gc(f.store, &.{r.gcRoots()}, gc_opts);
    try t.expect(f.store.contains(x));
    try t.expect(f.store.contains(d.op));

    // A pin keeps it alive without the marker.
    preview.discard(r, d.op);
    const pin = try preview.pinDetached(f.store, d);
    _ = try gc_mod.gc(f.store, &.{r.gcRoots()}, gc_opts);
    try t.expect(f.store.contains(x));
    pin.release();

    // Within the grace period nothing goes.
    _ = try gc_mod.gc(f.store, &.{r.gcRoots()}, .{ .grace_ns = std.time.ns_per_hour, .rewrite_below = 1.01, .edges = gc_opts.edges });
    try t.expect(f.store.contains(x));

    const report = try gc_mod.gc(f.store, &.{r.gcRoots()}, gc_opts);
    try t.expect(report.objects_removed > 0);
    try t.expect(!f.store.contains(x));
    try t.expect(!f.store.contains(d.op));
    try t.expect(f.store.contains(r.op()));
}

test "preview: expire drops markers older than the ttl" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    const r = try f.initRepo();
    defer r.close();
    const ttl = preview.default_ttl_ms;
    const old = try preview.commitDetached(try r.startTransaction(meta("old")), .checkpoint);
    // A day younger than `old`.
    var m = meta("new");
    m.start_ms = old.created_ms + std.time.ms_per_day;
    const new = try preview.commitDetached(try r.startTransaction(m), .landing);
    try t.expectEqual(m.start_ms, new.created_ms);

    try t.expectEqual(@as(usize, 0), try preview.expire(r, old.created_ms, ttl));
    try t.expectEqual(@as(usize, 1), try preview.expire(r, old.created_ms + ttl, ttl));
    const pending = try preview.list(r, gpa);
    defer gpa.free(pending);
    try t.expectEqual(@as(usize, 1), pending.len);
    try t.expect(pending[0].op.eql(new.op));
}

fn oid(n: u8) ObjectId {
    return .{ .bytes = @splat(n) };
}

test "preview: viewDiff golden" {
    const t = std.testing;
    const gpa = t.allocator;
    const lane = view_mod.LaneRecord{ .name = "fix", .workspace = "fix", .owner = "agent-1", .base = oid(0x11), .status = "active", .policy = "", .updated_ms = 1, .extra = &.{} };
    var lane2 = lane;
    lane2.status = "landed";
    const t1 = [_]?ObjectId{oid(0x11)};
    const t2 = [_]?ObjectId{oid(0x22)};
    const t3 = [_]?ObjectId{ oid(0x22), oid(0x11), oid(0x33) };
    const a: view_mod.View = .{
        .heads = &.{ oid(0x11), oid(0x22) },
        .bookmarks = &.{ .{ .name = "gone", .target = .{ .terms = &t1 } }, .{ .name = "main", .target = .{ .terms = &t1 } }, .{ .name = "same", .target = .{ .terms = &t2 } } },
        .remote_bookmarks = &.{.{ .remote = "origin", .name = "main", .target = .{ .terms = &t1 }, .tracked = true }},
        .tags = &.{},
        .git_refs = &.{},
        .git_head = .{ .terms = &t1 },
        .wc_commits = &.{ .{ .workspace = "default", .commit = oid(0x11) }, .{ .workspace = "old", .commit = oid(0x22) } },
        .lanes = &.{lane},
        .extra = &.{},
    };
    const b: view_mod.View = .{
        .heads = &.{ oid(0x22), oid(0x33) },
        .bookmarks = &.{ .{ .name = "main", .target = .{ .terms = &t3 } }, .{ .name = "new", .target = .{ .terms = &t2 } }, .{ .name = "same", .target = .{ .terms = &t2 } } },
        .remote_bookmarks = &.{.{ .remote = "origin", .name = "main", .target = .{ .terms = &t2 }, .tracked = true }},
        .tags = &.{.{ .name = "v1", .target = .{ .terms = &t2 } }},
        .git_refs = &.{},
        .git_head = .{ .terms = &t2 },
        .wc_commits = &.{.{ .workspace = "default", .commit = oid(0x33) }},
        .lanes = &.{lane2},
        .extra = &.{},
    };
    var d = try preview.viewDiff(gpa, &a, &b);
    defer d.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try d.format(&out.writer);
    try t.expectEqualStrings(
        \\+head 333333333333
        \\-head 111111111111
        \\bookmark gone: 111111111111 -> (none)
        \\bookmark main: 111111111111 -> {+222222222222 -111111111111 +333333333333}
        \\bookmark new: (none) -> 222222222222
        \\tag v1: (none) -> 222222222222
        \\remote_bookmark main@origin: 111111111111 (tracked) -> 222222222222 (tracked)
        \\git_head: 111111111111 -> 222222222222
        \\wc default: 111111111111 -> 333333333333
        \\wc old: 222222222222 -> (none)
        \\lane fix: changed
        \\
    , out.written());
    var same = try preview.viewDiff(gpa, &a, &a);
    defer same.deinit();
    try t.expect(same.isEmpty());
}

test "preview: undo of adopt restores pre-adopt view" {
    const t = std.testing;
    const gpa = t.allocator;
    var f = try fx.Fixture.init(gpa);
    defer f.deinit();
    var c: ObjectId = undefined;
    const r0 = try f.initRepo();
    var r = try withChange(&f, r0, &c);
    r0.close();
    const d = try previewBookmark(r, "proposed", c);
    r = try setBookmark(r, "concurrent", c);
    const pre_view = r.view_id;

    var res = try adopt_mod.adopt(r, d, meta("adopt"));
    defer res.deinit();
    r.close();
    const adopted = try f.load(.head);
    defer adopted.close();
    try t.expect(adopted.op().eql(res.adopted));

    const undone = try undo_mod.undo(adopted, res.adopted, meta("undo adopt"));
    defer undone.close();
    try t.expect(undone.view().bookmark("proposed").isAbsent());
    try t.expect(undone.view().bookmark("concurrent").asNormal().?.eql(c));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const pre = try op_mod.read(view_mod.View, f.store, arena_state.allocator(), pre_view);
    var diff = try preview.viewDiff(gpa, &pre, undone.view());
    defer diff.deinit();
    try t.expect(diff.isEmpty());
}
