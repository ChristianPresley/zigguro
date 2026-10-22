//! Tests for the conflict resolution proposer (`resolve.zig`).

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const store_mod = @import("../store/store.zig");
const chunker = @import("../store/chunker.zig");
const op_mod = @import("../oplog/operation.zig");
const repo_mod = @import("../oplog/repo.zig");
const preview = @import("../oplog/preview.zig");
const fx = @import("../oplog/test_fixture.zig");
const ports = @import("ports.zig");
const resolve = @import("resolve.zig");
const lt = @import("landing_test.zig");
const ObjectId = id_mod.ObjectId;
const Repo = repo_mod.Repo;
const Allocator = std.mem.Allocator;
const t = std.testing;

const Files = []const [2][]const u8;

/// A repo with commits base, left and right (children of base), a merge
/// of left and right whose tree terms are (left, base, right), and a
/// child of the merge as the working copy.
const Built = struct {
    repos: [3]*Repo,
    change: ObjectId,
    child: ObjectId,

    fn repo(b: *const Built) *Repo {
        return b.repos[2];
    }

    fn close(b: *Built) void {
        var i: usize = 3;
        while (i > 0) : (i -= 1) b.repos[i - 1].close();
    }
};

fn setup(f: *fx.Fixture, base: Files, left: Files, right: Files) !Built {
    const r0 = try f.initRepo();
    errdefer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    var m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{.{ "README", "r" }});
    const b = try lt.commit(m, &.{root}, "base", base);
    const l = try lt.commit(m, &.{b}, "left side", left);
    const r = try lt.commit(m, &.{b}, "right side", right);
    const r1 = try tx.commit();
    errdefer r1.close();

    tx = try r1.startTransaction(fx.meta("conflict"));
    m = tx.mutRepo();
    const a = tx.arena();
    const lc = try m.readChange(a, l);
    const bc = try m.readChange(a, b);
    const rc = try m.readChange(a, r);
    var c = lc;
    c.parents = try a.dupe(ObjectId, &.{ l, r });
    c.tree_terms = try a.dupe(ObjectId, &.{ lc.tree_terms[0], bc.tree_terms[0], rc.tree_terms[0] });
    c.description = "merge";
    c.change_id.bytes[0] ^= 0xff;
    const merged = try m.writeChange(c);
    const child = try lt.commit(m, &.{merged}, "child", &.{.{ "c", "c" }});
    try m.setWcCommit("default", child);
    const r2 = try tx.commit();
    return .{ .repos = .{ r0, r1, r2 }, .change = merged, .child = child };
}

/// A thread-safe model: every call answers `reply` (as JSON), after
/// `hook` has seen the prompt.
const TestModel = struct {
    reply: []const u8,
    hook: ?*const fn (m: *TestModel, prompt: []const u8) void = null,
    run: ?*resolve.Run = null,
    calls: std.atomic.Value(usize) = .init(0),
    inflight: std.atomic.Value(usize) = .init(0),
    max_inflight: std.atomic.Value(usize) = .init(0),

    fn port(m: *TestModel) ports.ModelPort {
        return .{ .ctx = m, .complete = complete };
    }

    fn complete(ctx: *anyopaque, req: *const ports.AiRequest, sink: *ports.AiSink) anyerror!void {
        const m: *TestModel = @ptrCast(@alignCast(ctx));
        _ = m.calls.fetchAdd(1, .monotonic);
        const now = m.inflight.fetchAdd(1, .acq_rel) + 1;
        defer _ = m.inflight.fetchSub(1, .acq_rel);
        _ = m.max_inflight.fetchMax(now, .acq_rel);
        if (req.json_schema == null) return error.NoSchema;
        if (m.hook) |h| h(m, req.messages[req.messages.len - 1].text);
        if (req.cancelled()) return sink.done(.cancelled, .{});
        sink.json(m.reply);
        sink.done(.end, .{});
    }
};

fn resolver(f: *fx.Fixture, m: *TestModel) resolve.Resolver {
    return .{ .gpa = t.allocator, .io = t.io, .store = f.store, .model = m.port() };
}

fn fileAt(store: *store_mod.Store, a: Allocator, tree: ObjectId, name: []const u8) !?[]const u8 {
    const tr = try op_mod.read(object.Tree, store, a, tree);
    const e = tr.find(name) orelse return null;
    var buf: [4096]u8 = undefined;
    var br = try chunker.blobReader(store, e.id, &buf);
    defer br.deinit();
    return try br.interface.readAlloc(a, @intCast(br.size));
}

test "resolve: binary → needs_human without model call" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(&f, &.{.{ "img", "a\x00b" }}, &.{.{ "img", "l\x00b" }}, &.{.{ "img", "r\x00b" }});
    defer b.close();
    var m: TestModel = .{ .reply = "{}" };
    var res = resolver(&f, &m);
    const run = try res.proposeForChange(b.change);
    defer run.deinit();
    try t.expectEqual(@as(usize, 1), run.set.regions.len);
    try t.expectEqual(resolve.RegionKind.binary, run.set.regions[0].kind);
    const p = run.proposal(0);
    try t.expectEqual(resolve.Status.needs_human, p.status);
    try t.expectEqualStrings("img", p.path);
    try t.expect(p.reason != null);
    try t.expectEqual(@as(usize, 0), m.calls.load(.monotonic));
}

test "resolve: marker in output rejected" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(&f, &.{.{ "m.txt", "a\nX\nb\n" }}, &.{.{ "m.txt", "a\nXL\nb\n" }}, &.{.{ "m.txt", "a\nXR\nb\n" }});
    defer b.close();

    var m: TestModel = .{ .reply = "{\"resolution\":\"<<<<<<< ours\\nXL\\n=======\\nXR\\n>>>>>>> theirs\\n\",\"rationale\":\"both\",\"addresses_sides\":[true,true]}" };
    var res = resolver(&f, &m);
    var run = try res.proposeForChange(b.change);
    try t.expectEqualStrings(resolve.reasons.markers, run.proposal(0).reason.?);
    // The context: surrounding lines, both sides' texts and descriptions.
    const ctx = run.jobs[0].ctx;
    try t.expectEqualStrings("a\n", ctx.before);
    try t.expectEqualStrings("b\n", ctx.after);
    try t.expectEqualStrings("X\n", ctx.base);
    try t.expectEqualStrings("left side", ctx.sides[0].description);
    try t.expectEqualStrings("XR\n", ctx.sides[1].text);
    try t.expectEqualStrings("txt", ctx.language.?);
    run.deinit();

    // Keeping both sides is fine.
    m = .{ .reply = "{\"resolution\":\"XL\\nXR\\n\",\"rationale\":\"both\",\"addresses_sides\":[true,true]}" };
    run = try res.proposeForChange(b.change);
    try t.expectEqual(resolve.Status.ok, run.proposal(0).status);
    try t.expectEqualStrings("XL\nXR\n", run.proposal(0).text);
    try t.expectEqualStrings("both", run.proposal(0).rationale);
    run.deinit();

    // Claiming side 2 while dropping its new identifier is not.
    m = .{ .reply = "{\"resolution\":\"XL\\n\",\"rationale\":\"both\",\"addresses_sides\":[true,true]}" };
    run = try res.proposeForChange(b.change);
    try t.expectEqualStrings(resolve.reasons.dropped, run.proposal(0).reason.?);
    run.deinit();

    // Unparseable replies need a human too.
    m = .{ .reply = "{\"resolution\":" };
    run = try res.proposeForChange(b.change);
    try t.expectEqualStrings(resolve.reasons.malformed, run.proposal(0).reason.?);
    run.deinit();
}

test "resolve: syntax regression rejected" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(
        &f,
        &.{.{ "f.zig", "fn f() u32 {\n    return 1;\n}\n" }},
        &.{.{ "f.zig", "fn f() u32 {\n    return 2;\n}\n" }},
        &.{.{ "f.zig", "fn f() u32 {\n    return 3;\n}\n" }},
    );
    defer b.close();
    var m: TestModel = .{ .reply = "{\"resolution\":\"    return 2 +;\\n\",\"rationale\":\"sum\",\"addresses_sides\":[]}" };
    var res = resolver(&f, &m);
    var run = try res.proposeForChange(b.change);
    try t.expectEqualStrings(resolve.reasons.syntax, run.proposal(0).reason.?);
    try t.expectEqualStrings("zig", run.jobs[0].ctx.language.?);
    run.deinit();

    m = .{ .reply = "{\"resolution\":\"    return 2 + 3;\\n\",\"rationale\":\"sum\",\"addresses_sides\":[]}" };
    run = try res.proposeForChange(b.change);
    try t.expectEqual(resolve.Status.ok, run.proposal(0).status);
    run.deinit();

    // Without validation the broken reply passes.
    m = .{ .reply = "{\"resolution\":\"    return 2 +;\\n\",\"rationale\":\"sum\",\"addresses_sides\":[]}" };
    res.options.validate_syntax = false;
    run = try res.proposeForChange(b.change);
    try t.expectEqual(resolve.Status.ok, run.proposal(0).status);
    run.deinit();
}

fn cancelSecond(m: *TestModel, prompt: []const u8) void {
    if (std.mem.indexOf(u8, prompt, "Y-left") != null) m.run.?.cancel(1);
}

test "resolve: parallel regions with cancellation" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(
        &f,
        &.{.{ "p.txt", "a\nX\nb\nY\nc\nZ\nd\n" }},
        &.{.{ "p.txt", "a\nX-left\nb\nY-left\nc\nZ-left\nd\n" }},
        &.{.{ "p.txt", "a\nX-right\nb\nY-right\nc\nZ-right\nd\n" }},
    );
    defer b.close();
    var m: TestModel = .{ .reply = "{\"resolution\":\"merged\\n\",\"rationale\":\"\",\"addresses_sides\":[]}", .hook = cancelSecond };
    var res = resolver(&f, &m);
    res.options.parallel = 2;
    const run = try res.prepare(b.change);
    defer run.deinit();
    m.run = run;
    try res.propose(run);
    try t.expectEqual(@as(usize, 3), run.jobs.len);
    for ([_]usize{ 0, 2 }) |i| {
        try t.expectEqual(resolve.Status.ok, run.proposal(i).status);
        try t.expectEqualStrings("merged\n", run.proposal(i).text);
    }
    try t.expectEqual(@as(u32, 1), run.proposal(1).region_idx);
    try t.expectEqualStrings(resolve.reasons.cancelled, run.proposal(1).reason.?);
    try t.expectEqual(@as(usize, 3), m.calls.load(.monotonic));
    try t.expect(m.max_inflight.load(.monotonic) <= 2);
    // Region 2's context reaches back over region 1 (as side 1).
    try t.expectEqualStrings("a\nX-left\nb\n", run.jobs[1].ctx.before);

    // Over the region limit, nothing is asked.
    res.options.max_regions = 1;
    m.hook = null;
    const few = try res.proposeForChange(b.change);
    defer few.deinit();
    try t.expectEqual(resolve.Status.ok, few.proposal(0).status);
    try t.expectEqualStrings(resolve.reasons.too_many, few.proposal(2).reason.?);
}

test "resolve: apply decisions produces resolved change and restacks" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var b = try setup(
        &f,
        &.{ .{ "a.txt", "1\nX\n2\nY\n3\n" }, .{ "gone", "g\n" }, .{ "other", "o\n" } },
        &.{ .{ "a.txt", "1\nXL\n2\nYL\n3\n" }, .{ "other", "o\n" } },
        &.{ .{ "a.txt", "1\nXR\n2\nYR\n3\n" }, .{ "gone", "g2\n" }, .{ "other", "o2\n" } },
    );
    defer b.close();
    const repo = b.repo();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const set = try resolve.conflicts(a, f.store, b.change);
    try t.expectEqual(@as(usize, 3), set.regions.len);
    try t.expectEqual(resolve.RegionKind.delete, set.regions[2].kind);

    const decisions = [_]resolve.RegionDecision{
        .{ .path = "a.txt", .region_idx = 0, .choice = .{ .accept = "XA\n" } },
        .{ .path = "a.txt", .region_idx = 1, .choice = .{ .side = 1 } },
        .{ .path = "gone", .region_idx = 0, .choice = .{ .side = 0 } },
    };
    const ap = try resolve.applyResolutions(repo, &set, &decisions, fx.meta("resolve"));
    const r3 = try repo.reopen(ap.preview.op, false);
    defer r3.close();
    const c = try op_mod.read(object.Change, f.store, a, ap.commit);
    try t.expectEqual(@as(usize, 1), c.tree_terms.len);
    try t.expectEqualSlices(ObjectId, &.{b.change}, c.predecessors);
    const tree = c.tree_terms[0];
    try t.expectEqualStrings("1\nXA\n2\nYR\n3\n", (try fileAt(f.store, a, tree, "a.txt")).?);
    try t.expectEqual(@as(?[]const u8, null), try fileAt(f.store, a, tree, "gone"));
    try t.expectEqualStrings("o2\n", (try fileAt(f.store, a, tree, "other")).?);
    // The child moved onto the resolved change.
    const child = try op_mod.read(object.Change, f.store, a, r3.view().wcCommit("default").?);
    try t.expect(child.parents[0].eql(ap.commit));
    // The preview is a resolve proposal for review.
    const p = ap.proposal("Resolve a.txt", .{ .actor = .{ .kind = .agent } }, "");
    try t.expectEqual(ports.ProposalKind.resolve, p.kind);
    try t.expect(p.changes[0].eql(ap.commit));
    preview.discard(repo, ap.preview.op);

    // Keeping a conflict leaves markers for that region only.
    var kept = decisions;
    kept[1].choice = .keep_conflict;
    kept[0].choice = .{ .edit = "XE\n" };
    const ap2 = try resolve.applyResolutions(repo, &set, &kept, fx.meta("resolve"));
    const c2 = try op_mod.read(object.Change, f.store, a, ap2.commit);
    const text = (try fileAt(f.store, a, c2.tree_terms[0], "a.txt")).?;
    try t.expect(std.mem.startsWith(u8, text, "1\nXE\n2\n<<<<<<<"));
    try t.expect(std.mem.indexOf(u8, text, "|||||||") != null);
    try t.expect(std.mem.indexOf(u8, text, ">>>>>>>") != null);
    try t.expect(std.mem.endsWith(u8, text, "\n3\n"));
    preview.discard(repo, ap2.preview.op);

    // Every region needs a decision, and whole-path ones cannot be kept.
    try t.expectError(error.MissingDecision, resolve.applyResolutions(repo, &set, decisions[0..2], fx.meta("resolve")));
    var bad = decisions;
    bad[2].choice = .keep_conflict;
    try t.expectError(error.CannotKeepConflict, resolve.applyResolutions(repo, &set, &bad, fx.meta("resolve")));
    bad[2] = .{ .path = "nope", .region_idx = 0, .choice = .{ .side = 0 } };
    try t.expectError(error.UnknownRegion, resolve.applyResolutions(repo, &set, &bad, fx.meta("resolve")));
}
