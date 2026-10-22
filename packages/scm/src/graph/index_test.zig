//! Commit index tests over scratch stores.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const index = @import("index.zig");
const seg = @import("index_segment.zig");
const test_repo = @import("test_repo.zig");
const Repo = test_repo.Repo;
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Pos = index.Pos;
const CommitIndex = index.CommitIndex;

const Summary = struct {
    change_id: ChangeId,
    parents: []ObjectId,
    preds: []ObjectId,
    level: u32,
    ctime: u64,
    time_ms: i64,
    flags: index.Flags,
};

/// Everything about `id` that does not depend on positions.
fn summarize(arena: std.mem.Allocator, ix: *const CommitIndex, id: ObjectId) !Summary {
    const p = ix.pos(id) orelse return error.NotIndexed;
    const e = ix.entry(p);
    var ps: std.ArrayList(ObjectId) = .empty;
    var it = e.parents;
    while (it.next()) |q| try ps.append(arena, ix.view.id(q));
    var pr: std.ArrayList(ObjectId) = .empty;
    var pit = e.predecessors;
    while (pit.next()) |q| try pr.append(arena, ix.view.id(q));
    return .{ .change_id = e.change_id, .parents = ps.items, .preds = pr.items, .level = e.level, .ctime = e.corrected_time, .time_ms = e.time_ms, .flags = e.flags };
}

/// Recomputes level and corrected time from the parents.
fn checkGenerations(ix: *const CommitIndex) !void {
    const v = ix.view;
    for (0..v.count) |k| {
        const p = Pos.of(@intCast(k));
        const e = v.entry(p);
        var level: u32 = 0;
        var ctime: u64 = @intCast(@max(e.time_ms, 0));
        var it = e.parents;
        while (it.next()) |q| {
            try std.testing.expect(q.int() < k);
            level = @max(level, v.level(q));
            ctime = @max(ctime, v.correctedTime(q) + 1);
        }
        try std.testing.expectEqual(level + 1, e.level);
        try std.testing.expectEqual(ctime, e.corrected_time);
    }
}

test "index: incremental equals rebuild" {
    const t = std.testing;
    const gpa = t.allocator;
    const r = try Repo.init(gpa);
    defer r.deinit();
    var prng: std.Random.DefaultPrng = .init(7);
    const ids = try test_repo.randomDag(r, prng.random(), 2000);
    defer gpa.free(ids);

    const inc = try r.openIndex(null);
    defer inc.close();
    var i: usize = 0;
    var updates: usize = 0;
    while (i < ids.len) : (i += 1 + prng.random().uintLessThan(usize, 60)) {
        try inc.ensureIndexed(&.{ids[i]});
        updates += 1;
        try t.expect(inc.view.segs.len <= 16);
    }
    try inc.ensureIndexed(ids);
    try t.expectEqual(@as(u32, 2000), inc.count());
    try t.expect(inc.verify());
    try checkGenerations(inc);
    // Logarithmic chain.
    try t.expect(inc.view.segs.len <= 12);

    const full = try r.openIndex("index-rebuild");
    defer full.close();
    try full.rebuild();
    try t.expectEqual(@as(u32, 2000), full.count());
    try t.expectEqual(@as(usize, 1), full.view.segs.len);
    try t.expect(full.verify());

    // A reopened index sees the same chain.
    const again = try CommitIndex.open(gpa, r.io, r.ix_dir, r.store, .{ .fsync = false });
    defer again.close();
    try t.expectEqual(inc.count(), again.count());
    try t.expect(!again.recovered);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (ids) |id| {
        const a = try summarize(arena, inc, id);
        const b = try summarize(arena, full, id);
        const c = try summarize(arena, again, id);
        try t.expectEqualDeep(a, b);
        try t.expectEqualDeep(a, c);
    }
    // Indexing again is a no-op.
    const before = inc.view.segs.len;
    try inc.ensureIndexed(ids);
    try t.expectEqual(before, inc.view.segs.len);
}

test "index: files are deterministic (golden)" {
    const t = std.testing;
    const gpa = t.allocator;
    var heads: [2][64]u8 = undefined;
    for (&heads) |*head| {
        const r = try Repo.init(gpa);
        defer r.deinit();
        var prng: std.Random.DefaultPrng = .init(42);
        const ids = try test_repo.randomDag(r, prng.random(), 300);
        defer gpa.free(ids);
        const ix = try r.openIndex(null);
        defer ix.close();
        try ix.ensureIndexed(ids[0..100]);
        try ix.ensureIndexed(ids);
        const n = try r.ix_dir.readFile(r.io, "HEAD", head);
        try t.expectEqual(@as(usize, 64), n.len);
    }
    try t.expectEqualStrings(&heads[0], &heads[1]);
    try t.expectEqualStrings(golden_head, &heads[0]);
}

/// HEAD after indexing `randomDag(seed 42, 300)` in two steps. Changes only
/// with the segment format, the object encoding or the DAG generator.
const golden_head = "0f41d75b217f662d05fe16ff7382171eed4fc665cfadcaab21b6f32cecd67e8a";

test "index: change-id divergence lookup" {
    const t = std.testing;
    const gpa = t.allocator;
    const r = try Repo.init(gpa);
    defer r.deinit();
    const cid: ChangeId = .{ .bytes = @splat(0x42) };
    const root = try r.commit(.{ .time_ms = 1, .description = "root" });
    const v1 = try r.commit(.{ .parents = &.{root}, .change_id = cid, .time_ms = 2, .description = "v1" });
    // Amended twice from v1 in two places: a divergent change.
    const v2a = try r.commit(.{ .parents = &.{root}, .preds = &.{v1}, .change_id = cid, .time_ms = 3, .description = "v2a" });
    const v2b = try r.commit(.{ .parents = &.{root}, .preds = &.{v1}, .change_id = cid, .time_ms = 4, .description = "v2b" });
    // A predecessor that was garbage-collected is skipped.
    const gone = id_mod.hashObject(.change, "gone");
    const other = try r.commit(.{ .parents = &.{root}, .preds = &.{gone}, .time_ms = 5, .description = "other" });
    try r.flush();

    const ix = try r.openIndex(null);
    defer ix.close();
    try ix.ensureIndexed(&.{ v2a, v2b, other });
    try t.expectEqual(@as(u32, 5), ix.count());
    const hits = try ix.byChangeId(gpa, cid);
    defer gpa.free(hits);
    try t.expectEqual(@as(usize, 3), hits.len);
    for (hits) |h| try t.expectEqual(cid, ix.view.changeId(h));
    try t.expectEqual(ix.pos(v1).?, hits[0]);
    var preds = ix.entry(ix.pos(v2b).?).predecessors;
    try t.expectEqual(ix.pos(v1).?, preds.next().?);
    try t.expectEqual(@as(?Pos, null), preds.next());
    try t.expectEqual(@as(u32, 0), ix.entry(ix.pos(other).?).predecessors.len());
    const none = try ix.byChangeId(gpa, .{ .bytes = @splat(1) });
    defer gpa.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
    // A missing parent is an error, not a silent gap.
    const orphan = try r.commit(.{ .parents = &.{gone}, .time_ms = 6, .description = "orphan" });
    try r.flush();
    try t.expectError(error.MissingParent, ix.ensureIndexed(&.{orphan}));
}

test "index: prefix resolution hex vs reverse-hex" {
    const t = std.testing;
    const gpa = t.allocator;
    const r = try Repo.init(gpa);
    defer r.deinit();
    var prng: std.Random.DefaultPrng = .init(3);
    const ids = try test_repo.randomDag(r, prng.random(), 500);
    defer gpa.free(ids);
    const ix = try r.openIndex(null);
    defer ix.close();
    // Two segments, so lookups span the chain.
    try ix.ensureIndexed(ids[0..200]);
    try ix.ensureIndexed(ids);

    for (ids[0..50]) |id| {
        const p = ix.pos(id).?;
        var hex: [64]u8 = undefined;
        _ = id.hex(&hex);
        const full = try ix.resolvePrefix(gpa, &hex);
        try t.expectEqual(index.PrefixResult{ .commit = p }, full);
        const n = ix.view.shortestUniqueCommit(p, 4);
        try t.expect(n >= 4);
        try t.expectEqual(index.PrefixResult{ .commit = p }, try ix.resolvePrefix(gpa, hex[0..n]));
        if (n > 4) {
            const amb = try ix.resolvePrefix(gpa, hex[0 .. n - 1]);
            defer amb.deinit(gpa);
            try t.expect(amb == .ambiguous_commits);
        }

        const cid = ix.view.changeId(p);
        var rev: [32]u8 = undefined;
        _ = cid.reverseHex(&rev);
        try t.expectEqual(index.PrefixResult{ .change = cid }, try ix.resolvePrefix(gpa, &rev));
        const m = ix.view.shortestUniqueChange(p, 4);
        try t.expectEqual(index.PrefixResult{ .change = cid }, try ix.resolvePrefix(gpa, rev[0..m]));
    }
    // One hex digit matches many commits; the candidates all match.
    const amb = try ix.resolvePrefix(gpa, "a");
    defer amb.deinit(gpa);
    try t.expectEqual(@as(usize, index.PrefixResult.max_candidates), amb.ambiguous_commits.len);
    for (amb.ambiguous_commits) |p| try t.expectEqual(@as(u8, 0xa), ix.view.id(p).bytes[0] >> 4);
    const ambc = try ix.resolvePrefix(gpa, "z");
    defer ambc.deinit(gpa);
    try t.expect(ambc == .ambiguous_changes);
    try t.expectEqual(index.PrefixResult.invalid, try ix.resolvePrefix(gpa, ""));
    try t.expectEqual(index.PrefixResult.invalid, try ix.resolvePrefix(gpa, "ak"));
    try t.expectEqual(index.PrefixResult.invalid, try ix.resolvePrefix(gpa, "G"));
    try t.expectEqual(index.PrefixResult.none, try ix.resolvePrefix(gpa, "0123456789abcdef0123"));
}

test "index: flags" {
    const t = std.testing;
    const gpa = t.allocator;
    const r = try Repo.init(gpa);
    defer r.deinit();
    const tree_a = id_mod.hashObject(.tree, "a");
    const tree_b = id_mod.hashObject(.tree, "b");
    const root = try r.commit(.{ .time_ms = 1 });
    const edit = try r.commit(.{ .parents = &.{root}, .tree_terms = &.{tree_a}, .time_ms = 2, .signed = true });
    const empty = try r.commit(.{ .parents = &.{edit}, .tree_terms = &.{tree_a}, .time_ms = 3, .provenance = tree_b });
    const side = try r.commit(.{ .parents = &.{root}, .tree_terms = &.{tree_b}, .time_ms = 4 });
    const conflicted = try r.commit(.{ .parents = &.{ empty, side }, .tree_terms = &.{ tree_a, root, tree_b }, .time_ms = 5 });
    try r.flush();
    const ix = try r.openIndex(null);
    defer ix.close();
    // Index `edit` first so `empty` must read its parent's tree back from
    // the store.
    try ix.ensureIndexed(&.{edit});
    try ix.ensureIndexed(&.{conflicted});
    const f = struct {
        fn of(i: *CommitIndex, id: ObjectId) index.Flags {
            return i.entry(i.pos(id).?).flags;
        }
    }.of;
    try t.expectEqual(index.Flags{ .empty = true }, f(ix, root));
    try t.expectEqual(index.Flags{ .signed = true }, f(ix, edit));
    try t.expectEqual(index.Flags{ .empty = true, .ai_touched = true }, f(ix, empty));
    try t.expectEqual(index.Flags{}, f(ix, side));
    try t.expectEqual(index.Flags{ .conflict = true, .merge = true }, f(ix, conflicted));
}

test "index: corrupt or missing files fall back to an empty index" {
    const t = std.testing;
    const gpa = t.allocator;
    const r = try Repo.init(gpa);
    defer r.deinit();
    var prng: std.Random.DefaultPrng = .init(9);
    const ids = try test_repo.randomDag(r, prng.random(), 100);
    defer gpa.free(ids);
    {
        const ix = try r.openIndex(null);
        defer ix.close();
        try ix.ensureIndexed(ids);
    }
    var head: [64]u8 = undefined;
    _ = try r.ix_dir.readFile(r.io, "HEAD", &head);
    var name: [68]u8 = undefined;
    @memcpy(name[0..64], &head);
    @memcpy(name[64..], ".zgx");

    // Truncated segment.
    const bytes = try r.ix_dir.readFileAlloc(r.io, &name, gpa, .unlimited);
    defer gpa.free(bytes);
    try r.ix_dir.writeFile(r.io, .{ .sub_path = &name, .data = bytes[0 .. bytes.len - 8] });
    {
        const ix = try r.openIndex(null);
        defer ix.close();
        try t.expect(ix.recovered);
        try t.expectEqual(@as(u32, 0), ix.count());
        try ix.ensureIndexed(ids);
        try t.expectEqual(@as(u32, 100), ix.count());
        try t.expect(ix.verify());
    }
    // A flipped byte passes open (headers only) and fails verify; rebuild
    // repairs it.
    _ = try r.ix_dir.readFile(r.io, "HEAD", &head);
    @memcpy(name[0..64], &head);
    const good = try r.ix_dir.readFileAlloc(r.io, &name, gpa, .unlimited);
    defer gpa.free(good);
    good[seg.header_len + 5] ^= 0xff;
    try r.ix_dir.writeFile(r.io, .{ .sub_path = &name, .data = good });
    {
        const ix = try r.openIndex(null);
        defer ix.close();
        try t.expect(!ix.verify());
        try ix.rebuild();
        try t.expect(ix.verify());
        try t.expectEqual(@as(u32, 100), ix.count());
        for (ids) |id| try t.expect(ix.pos(id) != null);
        _ = try ix.prune(0);
        const reopened = try r.openIndex(null);
        defer reopened.close();
        try t.expect(reopened.verify());
    }
    // HEAD gone.
    try r.ix_dir.deleteFile(r.io, "HEAD");
    const ix = try r.openIndex(null);
    defer ix.close();
    try t.expect(!ix.recovered);
    try t.expectEqual(@as(u32, 0), ix.count());
}
