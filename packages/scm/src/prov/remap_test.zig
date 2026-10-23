//! Tests for attribution through rewrites (`remap.zig`).

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const fx = @import("../oplog/test_fixture.zig");
const op_mod = @import("../oplog/operation.zig");
const lt = @import("../ai/landing_test.zig");
const record = @import("record.zig");
const attribution = @import("attribution.zig");
const manifest = @import("manifest.zig");
const remap = @import("remap.zig");
const ObjectId = id_mod.ObjectId;
const Change = object.Change;
const Seg = attribution.Seg;
const t = std.testing;

const agent = record.Actor.agent("claude", "anthropic/claude-x", "s-1");
const bob = record.Actor.human("Bob", "bob@example.com");

const Env = struct {
    f: fx.Fixture,
    arena_state: std.heap.ArenaAllocator,
    repo: *@import("../oplog/repo.zig").Repo,

    fn init() !Env {
        var f = try fx.Fixture.init(t.allocator);
        errdefer f.deinit();
        const r = try f.initRepo();
        return .{ .f = f, .arena_state = .init(t.allocator), .repo = r };
    }

    fn deinit(e: *Env) void {
        e.repo.close();
        e.arena_state.deinit();
        e.f.deinit();
    }

    fn arena(e: *Env) std.mem.Allocator {
        return e.arena_state.allocator();
    }

    /// Commits made in one transaction: `specs[i]` = (parent index or
    /// null, file text of "f.txt").
    fn commits(e: *Env, specs: []const struct { ?usize, []const u8 }) ![]Change {
        const tx = try e.repo.startTransaction(fx.meta("setup"));
        const m = tx.mutRepo();
        const ids = try e.arena().alloc(ObjectId, specs.len);
        for (specs, 0..) |sp, i| {
            const parents: []const ObjectId = if (sp[0]) |p| &.{ids[p]} else &.{};
            const desc = try std.fmt.allocPrint(e.arena(), "c{d}-{d}", .{ i, e.repo.op().bytes[0] });
            ids[i] = try lt.commit(m, parents, desc, &.{.{ "f.txt", sp[1] }});
        }
        const r1 = try tx.commit();
        e.repo.close();
        e.repo = r1;
        const out = try e.arena().alloc(Change, specs.len);
        for (out, ids) |*c, id| c.* = try op_mod.read(Change, e.f.store, e.arena(), id);
        return out;
    }

    fn record_(e: *Env, actor: record.Actor) !ObjectId {
        var b = e.f.store.batch();
        var ctx: remap.RemapContext = .{ .gpa = t.allocator, .store = e.f.store, .batch = &b };
        const id = try remap.writeRecord(&ctx, .{ .actor = actor, .created_ms = 1 });
        try b.commit();
        return id;
    }

    /// A manifest attributing f.txt (`text`) by `segs`.
    fn manifestOf(e: *Env, text: []const u8, segs: []const Seg) !ObjectId {
        var bld: attribution.Builder = .init(t.allocator);
        defer bld.deinit();
        for (segs) |s| try bld.push(s);
        const m = try bld.toMap(e.arena());
        const fa = try manifest.encodeFile(e.arena(), "f.txt", id_mod.hashObject(.blob, text), m);
        var b = e.f.store.batch();
        const id = try manifest.write(&b, t.allocator, .{ .files = &.{fa} });
        try b.commit();
        return id;
    }

    fn remapRewrite(e: *Env, old: Change, new: Change, kind: remap.RewriteKind, actor: record.Actor) !?attribution.AttributionMap {
        var b = e.f.store.batch();
        var ctx: remap.RemapContext = .{ .gpa = t.allocator, .store = e.f.store, .batch = &b };
        var n = new;
        try remap.remapForRewrite(&ctx, e.arena(), old, &n, kind, actor);
        try b.commit();
        return e.mapOf(n.provenance);
    }

    fn mapOf(e: *Env, id: ?ObjectId) !?attribution.AttributionMap {
        const m = try manifest.read(e.f.store, e.arena(), id orelse return null);
        const fa = m.find("f.txt") orelse return null;
        return try fa.map(e.arena());
    }

    fn actorOf(e: *Env, id: ObjectId) !record.Actor {
        const r = try e.f.store.read(id);
        defer r.release();
        return (try @import("../store/encode.zig").decode(record.ProvenanceRecord, e.arena(), try e.arena().dupe(u8, r.bytes))).actor;
    }
};

const inh = attribution.inherited;

test "remap: pure rebase keeps runs" {
    var e = try Env.init();
    defer e.deinit();
    const a_rec = try e.record_(agent);
    const cs = try e.commits(&.{
        .{ null, "a\nb\nc\n" },
        .{ 0, "a\nX1\nX2\nb\nc\n" },
        .{ null, "top\na\nb\nc\n" },
        .{ 2, "top\na\nX1\nX2\nb\nc\n" },
    });
    var old = cs[1];
    old.provenance = try e.manifestOf("a\nX1\nX2\nb\nc\n", &.{ .{ .len = 1, .prov = inh }, .{ .len = 2, .prov = a_rec }, .{ .len = 2, .prov = inh } });
    const m = (try e.remapRewrite(old, cs[3], .rebase, bob)).?;
    try t.expectEqual(@as(u32, 6), m.lineCount());
    try t.expect(m.at(0).?.prov.eql(inh));
    try t.expect(m.at(1).?.prov.eql(inh));
    try t.expect(m.at(2).?.prov.eql(a_rec));
    try t.expect(m.at(3).?.prov.eql(a_rec));
    try t.expect(m.at(4).?.prov.eql(inh));

    // No provenance and nothing written: none after the rewrite either.
    try t.expect((try e.remapRewrite(cs[1], cs[3], .describe, bob)) == null);
}

test "remap: moved block keeps provenance" {
    var e = try Env.init();
    defer e.deinit();
    const a_rec = try e.record_(agent);
    const old_text = "a\nagent_line_1\nagent_line_2\nb\nc\nd\n";
    const cs = try e.commits(&.{
        .{ null, "a\nb\nc\nd\n" },
        .{ 0, old_text },
        .{ 0, "a\nb\nc\nd\nagent_line_1\nagent_line_2\nbob was here\n" },
    });
    var old = cs[1];
    old.provenance = try e.manifestOf(old_text, &.{ .{ .len = 1, .prov = inh }, .{ .len = 2, .prov = a_rec }, .{ .len = 3, .prov = inh } });
    const m = (try e.remapRewrite(old, cs[2], .edit, bob)).?;
    try t.expect(m.at(3).?.prov.eql(inh));
    try t.expect(m.at(4).?.prov.eql(a_rec));
    try t.expect(m.at(5).?.prov.eql(a_rec));
    try t.expect((try e.actorOf(m.at(6).?.prov)).eql(bob));
}

fn count(m: attribution.AttributionMap, prov: ObjectId) u32 {
    var n: u32 = 0;
    for (m.runs) |r| {
        if (r.prov.eql(prov)) n += r.len;
    }
    return n;
}

test "remap: squash and split preserve totals" {
    var e = try Env.init();
    defer e.deinit();
    const a_rec = try e.record_(agent);
    const b_rec = try e.record_(bob);
    const c_text = "base\nagent_1\nagent_2\nagent_3\n";
    const d_text = "base\nagent_1\nagent_2\nagent_3\nbob_1\nbob_2\n";
    const cs = try e.commits(&.{
        .{ null, "base\n" },
        .{ 0, c_text },
        .{ 1, d_text },
        // The squash of C and D, on base.
        .{ 0, d_text },
        // C split in two: the first two agent lines, then the third.
        .{ 0, "base\nagent_1\nagent_2\n" },
        .{ 4, c_text },
    });
    var c = cs[1];
    c.provenance = try e.manifestOf(c_text, &.{ .{ .len = 1, .prov = inh }, .{ .len = 3, .prov = a_rec } });
    var d = cs[2];
    d.provenance = try e.manifestOf(d_text, &.{ .{ .len = 4, .prov = inh }, .{ .len = 2, .prov = b_rec } });

    var b = e.f.store.batch();
    var ctx: remap.RemapContext = .{ .gpa = t.allocator, .store = e.f.store, .batch = &b };
    const sq = try remap.remapFrom(&ctx, e.arena(), &.{ c, d }, cs[3], null);
    const s1 = try remap.remapFrom(&ctx, e.arena(), &.{c}, cs[4], null);
    const s2 = try remap.remapFrom(&ctx, e.arena(), &.{c}, cs[5], null);
    try b.commit();
    const msq = (try e.mapOf(sq)).?;
    try t.expectEqual(@as(u32, 3), count(msq, a_rec));
    try t.expectEqual(@as(u32, 2), count(msq, b_rec));
    const m1 = (try e.mapOf(s1)).?;
    const m2 = (try e.mapOf(s2)).?;
    try t.expectEqual(@as(u32, 2), count(m1, a_rec));
    try t.expectEqual(@as(u32, 1), count(m2, a_rec));
    try t.expect(m2.at(3).?.prov.eql(a_rec));
}

test "remap: conflict resolution attribution" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ids: [3]ObjectId = undefined;
    for (&ids, 0..) |*x, i| {
        x.* = .zero;
        x.bytes[0] = @intCast(i + 1);
    }
    const side1: attribution.AttributionMap = .{ .runs = &.{ .{ .start_line = 0, .len = 1, .prov = inh }, .{ .start_line = 1, .len = 1, .prov = ids[0] } } };
    const side2: attribution.AttributionMap = .{ .runs = &.{ .{ .start_line = 0, .len = 1, .prov = inh }, .{ .start_line = 1, .len = 1, .prov = ids[1], .mixed = true } } };
    const m = try remap.attributionForMerge(t.allocator, a, "a\nB\n", &.{ .{ .text = "a\nS1\n", .map = side1 }, .{ .text = "a\nS2\n", .map = side2 } }, "a\nS1\nS2\nresolver wrote\n", ids[2]);
    try t.expect(m.at(0).?.prov.eql(inh));
    try t.expect(m.at(1).?.prov.eql(ids[0]));
    try t.expect(m.at(2).?.prov.eql(ids[1]));
    try t.expect(m.at(2).?.mixed);
    try t.expect(m.at(3).?.prov.eql(ids[2]));
}

test "remap: deterministic" {
    var e = try Env.init();
    defer e.deinit();
    const a_rec = try e.record_(agent);
    const cs = try e.commits(&.{
        .{ null, "a\n" },
        .{ 0, "a\nagent\n" },
        .{ 0, "a\nagent\nbob\n" },
    });
    var old = cs[1];
    old.provenance = try e.manifestOf("a\nagent\n", &.{ .{ .len = 1, .prov = inh }, .{ .len = 1, .prov = a_rec } });
    var ids: [2]?ObjectId = undefined;
    for (&ids) |*x| {
        var b = e.f.store.batch();
        var ctx: remap.RemapContext = .{ .gpa = t.allocator, .store = e.f.store, .batch = &b };
        var n = cs[2];
        try remap.remapForRewrite(&ctx, e.arena(), old, &n, .edit, bob);
        try b.commit();
        x.* = n.provenance;
    }
    try t.expect(ids[0].?.eql(ids[1].?));
}

test "remap: property, rebases keep every agent line's record" {
    var e = try Env.init();
    defer e.deinit();
    const a_rec = try e.record_(agent);
    var prng: std.Random.DefaultPrng = .init(42);
    const rnd = prng.random();
    const Line = struct { text: []const u8, agent: bool };
    var lines: std.ArrayList(Line) = .empty;
    for (0..20) |i| try lines.append(e.arena(), .{ .text = try std.fmt.allocPrint(e.arena(), "parent line {d}\n", .{i}), .agent = false });
    for (0..6) |i| try lines.insert(e.arena(), rnd.uintLessThan(usize, lines.items.len + 1), .{ .text = try std.fmt.allocPrint(e.arena(), "agent line {d}\n", .{i}), .agent = true });

    var next: usize = 100;
    var old: ?Change = null;
    for (0..12) |round| {
        // The new parent gains lines; the change keeps its own.
        for (0..rnd.uintLessThan(usize, 4)) |_| {
            try lines.insert(e.arena(), rnd.uintLessThan(usize, lines.items.len + 1), .{ .text = try std.fmt.allocPrint(e.arena(), "parent line {d}\n", .{next}), .agent = false });
            next += 1;
        }
        var parent_text: std.ArrayList(u8) = .empty;
        var change_text: std.ArrayList(u8) = .empty;
        var segs: std.ArrayList(Seg) = .empty;
        for (lines.items) |l| {
            if (!l.agent) try parent_text.appendSlice(e.arena(), l.text);
            try change_text.appendSlice(e.arena(), l.text);
            try segs.append(e.arena(), .{ .len = 1, .prov = if (l.agent) a_rec else inh });
        }
        const cs = try e.commits(&.{ .{ null, parent_text.items }, .{ 0, change_text.items } });
        if (round == 0) {
            old = cs[1];
            old.?.provenance = try e.manifestOf(change_text.items, segs.items);
            continue;
        }
        var b = e.f.store.batch();
        var ctx: remap.RemapContext = .{ .gpa = t.allocator, .store = e.f.store, .batch = &b };
        var n = cs[1];
        try remap.remapForRewrite(&ctx, e.arena(), old.?, &n, .rebase, bob);
        try b.commit();
        const m = (try e.mapOf(n.provenance)).?;
        try t.expectEqual(@as(u32, @intCast(lines.items.len)), m.lineCount());
        for (lines.items, 0..) |l, i| try t.expect(m.at(@intCast(i)).?.prov.eql(if (l.agent) a_rec else inh));
        old = n;
    }
}
