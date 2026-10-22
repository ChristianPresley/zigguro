//! Approving a description the reviewer edited (E09.F06.S01, the apply
//! step of #714): the proposal's preview is rewritten with the reviewer's
//! text and then adopted, in one adopt like an unedited approval.
//!
//! The preview's commit `target` is rewritten with the new description
//! (its descendants in the preview are restacked) as a new detached
//! operation on top of the proposal's preview. It is adopted against the
//! proposal's base, so the op log shows the preview, the edit and the
//! adoption. On `.conflicted` the edited preview is dropped and the
//! original stays, so the reviewer can decide again; once adopted, both
//! previews are gone.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const op_mod = @import("../oplog/operation.zig");
const repo_mod = @import("../oplog/repo.zig");
const preview = @import("../oplog/preview.zig");
const adopt_mod = @import("../oplog/adopt.zig");
const rebase = @import("../oplog/rebase.zig");
const ObjectId = id_mod.ObjectId;
const Repo = repo_mod.Repo;
const OpMeta = op_mod.OpMeta;
const DetachedOp = preview.DetachedOp;

/// Adopts preview `d` with commit `target` (in the preview's view)
/// described as `text`.
pub fn redescribe(repo: *Repo, d: DetachedOp, target: ObjectId, text: []const u8, meta: OpMeta) !adopt_mod.AdoptResult {
    _ = try preview.get(repo, d.op);
    const at = try repo.reopen(d.op, false);
    defer at.close();
    const tx = try at.startTransaction(meta);
    var tx_live = true;
    errdefer if (tx_live) tx.discard();
    const m = tx.mutRepo();
    var c = try m.readChange(tx.arena(), target);
    c.description = try tx.arena().dupe(u8, text);
    c.sig = null;
    // The edit rewrites the proposed commit (which rewrote the original).
    c.predecessors = &.{};
    _ = try m.rewriteChange(target, c);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    tx_live = false;
    var edited = try preview.commitDetached(tx, d.purpose);
    // Adopt against the proposal's base: the edit sits on the preview,
    // which the repo has not seen.
    edited.base_op = d.base_op;
    var res = adopt_mod.adopt(repo, edited, meta) catch |e| {
        preview.discard(repo, edited.op);
        return e;
    };
    switch (res) {
        .adopted => preview.discard(repo, d.op),
        .conflicted => preview.discard(repo, edited.op),
    }
    _ = &res;
    return res;
}

// ---------------------------------------------------------------- tests

const fx = @import("../oplog/test_fixture.zig");
const object = @import("../store/object.zig");
const lt = @import("landing_test.zig");
const t = std.testing;

test "describe: edited description adopted with descendants restacked" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    var m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{.{ "a", "1" }});
    const c1 = try lt.commit(m, &.{root}, "wip", &.{.{ "a", "2" }});
    const c2 = try lt.commit(m, &.{c1}, "top", &.{.{ "a", "3" }});
    try m.setWcCommit("default", c2);
    const r1 = try tx.commit();
    defer r1.close();

    // The AI proposes "Add two" for c1.
    tx = try r1.startTransaction(fx.meta("propose"));
    m = tx.mutRepo();
    var ch = try m.readChange(tx.arena(), c1);
    ch.description = "Add two";
    const proposed = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const d = try preview.commitDetached(tx, .proposal);

    // The reviewer edits it and approves.
    var res = try redescribe(r1, d, proposed, "Add two, edited", fx.meta("approve"));
    defer res.deinit();
    const head = res.adopted;
    const r2 = try r1.reopen(head, false);
    defer r2.close();
    const a = r2.arena_state.allocator();
    const wc = r2.view().wcCommit("default").?;
    const top = try op_mod.read(object.Change, f.store, a, wc);
    try t.expectEqualStrings("top", top.description);
    const mid = try op_mod.read(object.Change, f.store, a, top.parents[0]);
    try t.expectEqualStrings("Add two, edited", mid.description);
    try t.expectEqualSlices(ObjectId, &.{proposed}, mid.predecessors);
    try t.expect(mid.change_id.eql(ch.change_id));
    try t.expectEqual(@as(usize, 1), r2.view().heads.len);
    // Both previews are gone.
    try t.expectError(error.NotDetached, preview.get(r2, d.op));
    const left = try preview.list(r2, t.allocator);
    defer t.allocator.free(left);
    try t.expectEqual(@as(usize, 0), left.len);
}

test "describe: edit adopts over a concurrent unrelated operation" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    var m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{.{ "a", "1" }});
    const c1 = try lt.commit(m, &.{root}, "wip", &.{.{ "a", "2" }});
    try m.setWcCommit("default", c1);
    const r1 = try tx.commit();
    defer r1.close();

    tx = try r1.startTransaction(fx.meta("propose"));
    m = tx.mutRepo();
    var ch = try m.readChange(tx.arena(), c1);
    ch.description = "Add two";
    const proposed = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const d = try preview.commitDetached(tx, .proposal);

    // Meanwhile someone adds an unrelated commit and a bookmark.
    tx = try r1.startTransaction(fx.meta("side"));
    m = tx.mutRepo();
    const side = try lt.commit(m, &.{root}, "side", &.{.{ "b", "1" }});
    var sv: ?ObjectId = side;
    try m.setBookmark("side", fx.target(&sv));
    const r2 = try tx.commit();
    defer r2.close();

    var res = try redescribe(r2, d, proposed, "Edited", fx.meta("approve"));
    defer res.deinit();
    const r3 = try r2.reopen(res.adopted, false);
    defer r3.close();
    const a = r3.arena_state.allocator();
    const wc = try op_mod.read(object.Change, f.store, a, r3.view().wcCommit("default").?);
    try t.expectEqualStrings("Edited", wc.description);
    try t.expect(r3.view().bookmark("side").asNormal().?.eql(side));
}

test "describe: conflicting edit keeps the original preview" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    var m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{.{ "a", "1" }});
    const c1 = try lt.commit(m, &.{root}, "wip", &.{.{ "a", "2" }});
    try m.setWcCommit("default", c1);
    const r1 = try tx.commit();
    defer r1.close();

    tx = try r1.startTransaction(fx.meta("propose"));
    m = tx.mutRepo();
    var ch = try m.readChange(tx.arena(), c1);
    ch.description = "Add two";
    const proposed = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const d = try preview.commitDetached(tx, .proposal);

    // Meanwhile the user rewords the same commit.
    tx = try r1.startTransaction(fx.meta("reword"));
    m = tx.mutRepo();
    ch = try m.readChange(tx.arena(), c1);
    ch.description = "Mine";
    _ = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const r2 = try tx.commit();
    defer r2.close();

    var res = try redescribe(r2, d, proposed, "Edited", fx.meta("approve"));
    defer res.deinit();
    try t.expect(res == .conflicted);
    const left = try preview.list(r2, t.allocator);
    defer t.allocator.free(left);
    try t.expectEqual(@as(usize, 1), left.len);
    try t.expect(left[0].op.eql(d.op));
}
