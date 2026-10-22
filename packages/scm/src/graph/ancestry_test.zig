//! Ancestry tests: index answers against brute force over random DAGs.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const index = @import("index.zig");
const ancestry = @import("ancestry.zig");
const test_repo = @import("test_repo.zig");
const Repo = test_repo.Repo;
const ObjectId = id_mod.ObjectId;
const Pos = index.Pos;
const Bits = std.DynamicBitSetUnmanaged;

/// Ancestor sets (each including itself) for every position, from the
/// parents alone.
fn closure(gpa: std.mem.Allocator, v: *const index.View) ![]Bits {
    const sets = try gpa.alloc(Bits, v.count);
    for (sets, 0..) |*s, k| {
        s.* = try .initEmpty(gpa, v.count);
        s.set(k);
        var ps = v.parents(Pos.of(@intCast(k)));
        while (ps.next()) |p| s.setUnion(sets[p.int()]);
    }
    return sets;
}

fn freeClosure(gpa: std.mem.Allocator, sets: []Bits) void {
    for (sets) |*s| s.deinit(gpa);
    gpa.free(sets);
}

test "ancestry: isAncestor and mergeBases vs brute force (random DAGs 10k nodes)" {
    const t = std.testing;
    const gpa = t.allocator;
    const r = try Repo.init(gpa);
    defer r.deinit();
    var prng: std.Random.DefaultPrng = .init(11);
    const rng = prng.random();
    const ids = try test_repo.randomDag(r, rng, 10_000);
    defer gpa.free(ids);
    const ix = try r.openIndex(null);
    defer ix.close();
    try ix.ensureIndexed(ids);
    const v = ix.view;
    const sets = try closure(gpa, v);
    defer freeClosure(gpa, sets);

    var w: ancestry.Walker = .init(gpa);
    defer w.deinit();
    var hits: usize = 0;
    for (0..10_000) |_| {
        const b = rng.uintLessThan(u32, v.count);
        // Half the pairs close together, where answers are mixed.
        const a = if (rng.boolean()) rng.uintLessThan(u32, v.count) else b -| rng.uintLessThan(u32, 300);
        const want = sets[b].isSet(a);
        if (want) hits += 1;
        try t.expectEqual(want, try w.isAncestor(v, Pos.of(a), Pos.of(b)));
    }
    try t.expect(hits > 500);

    var common: Bits = try .initEmpty(gpa, v.count);
    defer common.deinit(gpa);
    var shadow: Bits = try .initEmpty(gpa, v.count);
    defer shadow.deinit(gpa);
    for (0..300) |_| {
        const a = rng.uintLessThan(u32, v.count);
        const b = a -| rng.uintLessThan(u32, 500);
        common.unsetAll();
        common.setUnion(sets[a]);
        common.setIntersection(sets[b]);
        // Best = common minus everything strictly below a common ancestor.
        shadow.unsetAll();
        var it = common.iterator(.{});
        while (it.next()) |c| {
            const was = shadow.isSet(c);
            shadow.setUnion(sets[c]);
            if (!was) shadow.unset(c);
        }
        var want: std.ArrayList(u32) = .empty;
        defer want.deinit(gpa);
        it = common.iterator(.{});
        while (it.next()) |c| if (!shadow.isSet(c)) try want.append(gpa, @intCast(c));

        const got = try w.mergeBases(v, gpa, Pos.of(a), Pos.of(b));
        defer gpa.free(got);
        const got_ints = try gpa.alloc(u32, got.len);
        defer gpa.free(got_ints);
        for (got, got_ints) |g, *x| x.* = g.int();
        std.mem.sort(u32, got_ints, {}, std.sort.asc(u32));
        try t.expectEqualSlices(u32, want.items, got_ints);
    }
}

test "ancestry: mergeBases criss-cross" {
    const t = std.testing;
    const gpa = t.allocator;
    const r = try Repo.init(gpa);
    defer r.deinit();
    //    R
    //   / \
    //  A   B
    //  |\ /|
    //  | X |
    //  |/ \|
    //  C   D
    //  |   |
    //  E   F
    const root = try r.commit(.{ .time_ms = 1, .description = "R" });
    const a = try r.commit(.{ .parents = &.{root}, .time_ms = 2, .description = "A" });
    const b = try r.commit(.{ .parents = &.{root}, .time_ms = 3, .description = "B" });
    const c = try r.commit(.{ .parents = &.{ a, b }, .time_ms = 4, .description = "C" });
    const d = try r.commit(.{ .parents = &.{ b, a }, .time_ms = 5, .description = "D" });
    const e = try r.commit(.{ .parents = &.{c}, .time_ms = 6, .description = "E" });
    const f = try r.commit(.{ .parents = &.{d}, .time_ms = 7, .description = "F" });
    try r.flush();
    const ix = try r.openIndex(null);
    defer ix.close();
    try ix.ensureIndexed(&.{ e, f });
    const P = struct {
        fn of(i: *index.CommitIndex, id: ObjectId) Pos {
            return i.pos(id).?;
        }
    }.of;

    const bases = try ix.mergeBases(gpa, P(ix, e), P(ix, f));
    defer gpa.free(bases);
    try t.expectEqual(@as(usize, 2), bases.len);
    // Newest first.
    try t.expectEqual(P(ix, b), bases[0]);
    try t.expectEqual(P(ix, a), bases[1]);

    const one = try ix.mergeBases(gpa, P(ix, a), P(ix, e));
    defer gpa.free(one);
    try t.expectEqualSlices(Pos, &.{P(ix, a)}, one);
    const same = try ix.mergeBases(gpa, P(ix, c), P(ix, c));
    defer gpa.free(same);
    try t.expectEqualSlices(Pos, &.{P(ix, c)}, same);
    const roots = try ix.mergeBases(gpa, P(ix, a), P(ix, b));
    defer gpa.free(roots);
    try t.expectEqualSlices(Pos, &.{P(ix, root)}, roots);

    try t.expect(try ix.isAncestor(P(ix, root), P(ix, f)));
    try t.expect(try ix.isAncestor(P(ix, a), P(ix, d)));
    try t.expect(!try ix.isAncestor(P(ix, c), P(ix, f)));
    try t.expect(!try ix.isAncestor(P(ix, f), P(ix, root)));

    // Children, with and without a visibility filter.
    const v = ix.acquire();
    defer v.release();
    var kids = try v.children(P(ix, a), null);
    try t.expectEqual(P(ix, c), kids.next().?);
    try t.expectEqual(P(ix, d), kids.next().?);
    try t.expectEqual(@as(?Pos, null), kids.next());
    var vis: ancestry.VisibleSet = .{ .bits = try .initEmpty(gpa, v.count) };
    defer vis.bits.deinit(gpa);
    vis.bits.set(P(ix, d).int());
    kids = try v.children(P(ix, a), &vis);
    try t.expectEqual(P(ix, d), kids.next().?);
    try t.expectEqual(@as(?Pos, null), kids.next());

    // Ancestors of E and F, newest first, each once.
    var walk = try ancestry.walkAncestors(gpa, v, &.{ P(ix, e), P(ix, f) }, .{});
    defer walk.deinit();
    var seen: std.ArrayList(Pos) = .empty;
    defer seen.deinit(gpa);
    var last: u64 = std.math.maxInt(u64);
    while (try walk.next()) |p| {
        try t.expect(v.correctedTime(p) <= last);
        last = v.correctedTime(p);
        try seen.append(gpa, p);
    }
    try t.expectEqual(@as(usize, 7), seen.items.len);
    var limited = try ancestry.walkAncestors(gpa, v, &.{P(ix, e)}, .{ .limit = 2 });
    defer limited.deinit();
    try t.expectEqual(P(ix, e), (try limited.next()).?);
    try t.expectEqual(P(ix, c), (try limited.next()).?);
    try t.expectEqual(@as(?Pos, null), try limited.next());
}
