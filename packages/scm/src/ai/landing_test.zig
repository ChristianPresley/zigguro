//! Lane landing queue tests with a fake review port, check runner and
//! workspace materializer.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const op_mod = @import("../oplog/operation.zig");
const view_mod = @import("../oplog/view.zig");
const repo_mod = @import("../oplog/repo.zig");
const undo_mod = @import("../oplog/undo.zig");
const mutable_mod = @import("../oplog/mutable_repo.zig");
const tree_merge = @import("../merge/tree_merge.zig");
const fx = @import("../oplog/test_fixture.zig");
const ports = @import("ports.zig");
const landing = @import("landing.zig");
const FakeReview = @import("testing/fake_review.zig").FakeReview;
const ObjectId = id_mod.ObjectId;
const Repo = repo_mod.Repo;
const LandingQueue = landing.LandingQueue;
const meta = fx.meta;
const t = std.testing;
const gpa = t.allocator;

/// Writes a change with the given files on `parents`.
fn commit(m: *mutable_mod.MutableRepo, parents: []const ObjectId, description: []const u8, files: []const [2][]const u8) !ObjectId {
    var tm = tree_merge.TreeMerger.init(gpa, m.batch.store, m.batch);
    defer tm.deinit();
    const tree = try tree_merge.testTree(&tm, files);
    const sig: object.Signature = .{ .name = "t", .email = "t@example.com", .time_ms = 1_700_000_000_000, .tz_offset_min = 0 };
    var cid: id_mod.ChangeId = undefined;
    const h = std.hash.Wyhash.hash(9, description);
    std.mem.writeInt(u64, cid.bytes[0..8], h, .little);
    std.mem.writeInt(u64, cid.bytes[8..16], std.hash.int(h), .little);
    return m.writeChange(.{
        .parents = try m.arena.dupe(ObjectId, parents),
        .tree_terms = try m.arena.dupe(ObjectId, &.{tree}),
        .change_id = cid,
        .predecessors = &.{},
        .author = sig,
        .committer = sig,
        .description = try m.arena.dupe(u8, description),
        .provenance = null,
        .extra = &.{},
        .sig = null,
    });
}

fn filesOf(r: *Repo, commit_id: ObjectId) ![]const u8 {
    // "name=content;" for every file, in tree order (flat trees only).
    const a = r.arena_state.allocator();
    const c = try op_mod.read(object.Change, r.store, a, commit_id);
    const tree = try op_mod.read(object.Tree, r.store, a, c.tree().?);
    var out: std.ArrayList(u8) = .empty;
    for (tree.entries) |e| {
        const blob = try r.store.read(e.id);
        defer blob.release();
        try out.print(a, "{s}={s};", .{ e.name, blob.bytes });
    }
    return out.items;
}

const Checks = struct {
    fail: ?[]const u8 = null,
    runs: usize = 0,
    roots: usize = 0,

    fn port(c: *Checks) ports.CheckPort {
        return .{ .ctx = c, .run = run };
    }
    fn checkout(c: *Checks) landing.CheckoutPort {
        return .{ .ctx = c, .materialize = materialize, .release = release };
    }
    fn run(ctx: *anyopaque, root: []const u8, spec: *const ports.CheckSpec, sink: *ports.CheckSink) anyerror!ports.CheckResult {
        const c: *Checks = @ptrCast(@alignCast(ctx));
        c.runs += 1;
        try t.expectEqualStrings("/ws/landing", root);
        sink.log(spec.name, "running\n");
        if (c.fail) |log| {
            sink.log(spec.name, log);
            return .{ .passed = false, .exit_code = 1, .log_tail = log };
        }
        return .{ .passed = true, .exit_code = 0 };
    }
    fn materialize(ctx: *anyopaque, _: ObjectId) anyerror![]const u8 {
        const c: *Checks = @ptrCast(@alignCast(ctx));
        c.roots += 1;
        return "/ws/landing";
    }
    fn release(ctx: *anyopaque, _: []const u8) void {
        const c: *Checks = @ptrCast(@alignCast(ctx));
        c.roots -= 1;
    }
};

const Notes = struct {
    titles: std.ArrayList([]u8) = .empty,
    fn deinit(n: *Notes) void {
        for (n.titles.items) |x| gpa.free(x);
        n.titles.deinit(gpa);
    }
    fn port(n: *Notes) ports.NotificationPort {
        return .{ .ctx = n, .notify = notify };
    }
    fn notify(ctx: *anyopaque, note: *const ports.Notification) void {
        const n: *Notes = @ptrCast(@alignCast(ctx));
        n.titles.append(gpa, std.fmt.allocPrint(gpa, "{s}: {s}", .{ note.owner, note.title }) catch return) catch {};
    }
};

const Setup = struct {
    f: fx.Fixture,
    repo: *Repo,
    root: ObjectId,
    /// Lane l1: adds b.txt (c1), then c.txt (c2, its working copy).
    c1: ObjectId,
    c2: ObjectId,

    fn init() !Setup {
        var f = try fx.Fixture.init(gpa);
        errdefer f.deinit();
        const r0 = try f.initRepo();
        defer r0.close();
        const tx = try r0.startTransaction(meta("setup"));
        errdefer tx.discard();
        const m = tx.mutRepo();
        const root = try commit(m, &.{}, "root", &.{.{ "a.txt", "1" }});
        const c1 = try commit(m, &.{root}, "add b", &.{ .{ "a.txt", "1" }, .{ "b.txt", "1" } });
        const c2 = try commit(m, &.{c1}, "add c", &.{ .{ "a.txt", "1" }, .{ "b.txt", "1" }, .{ "c.txt", "1" } });
        var main: ?ObjectId = root;
        try m.setBookmark("main", fx.target(&main));
        try addLane(m, "l1", "ws1", root, c2, "");
        return .{ .f = f, .repo = try tx.commit(), .root = root, .c1 = c1, .c2 = c2 };
    }

    fn deinit(s: *Setup) void {
        s.repo.close();
        s.f.deinit();
    }

    /// Commits `edit` in a transaction on the latest operation.
    fn change(s: *Setup, comptime edit: fn (m: *mutable_mod.MutableRepo, s: *Setup) anyerror!void) !void {
        const fresh = try s.f.load(.head);
        s.repo.close();
        s.repo = fresh;
        const tx = try s.repo.startTransaction(meta("concurrent"));
        errdefer tx.discard();
        try edit(tx.mutRepo(), s);
        const r = try tx.commit();
        s.repo.close();
        s.repo = r;
    }
};

fn addLane(m: *mutable_mod.MutableRepo, name: []const u8, ws: []const u8, base: ObjectId, wc: ObjectId, policy: []const u8) !void {
    try m.setWcCommit(ws, wc);
    try m.setLane(.{ .name = name, .workspace = ws, .owner = "agent-7", .base = base, .status = "active", .policy = policy, .updated_ms = 1, .extra = &.{} });
}

fn trunkOf(r: *const Repo) ObjectId {
    return r.view().bookmark("main").asNormal().?;
}

fn laneStatus(r: *const Repo, name: []const u8) []const u8 {
    return r.view().lane(name).?.status;
}

fn states(q: *LandingQueue) ![]landing.LandingState {
    var out: std.ArrayList(landing.LandingState) = .empty;
    for (q.events().items.items) |e| {
        if (out.items.len > 0 and out.items[out.items.len - 1] == e.state) continue;
        try out.append(q.stream.arena_state.allocator(), e.state);
    }
    return out.items;
}

const check_specs = [_]ports.CheckSpec{.{ .name = "test", .command = &.{ "zig", "build", "test" } }};

test "landing: happy path (fake review + checks)" {
    var s = try Setup.init();
    defer s.deinit();
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var checks: Checks = .{};
    var notes: Notes = .{};
    defer notes.deinit();
    var q = LandingQueue.init(gpa, s.repo, .{ .review = review.port(), .checks = checks.port(), .checkout = checks.checkout(), .notify = notes.port() });
    defer q.deinit();

    const tk = try q.submit("l1", .{ .checks = &check_specs });
    try t.expectEqual(landing.LandingState.in_review, tk.state);
    try t.expectEqualStrings("awaiting_review", laneStatus(q.current(), "l1"));
    const item = review.item(tk.review).?;
    try t.expectEqual(ports.ProposalKind.land, item.kind);
    try t.expectEqualStrings("l1", item.lane);
    try t.expectEqual(@as(usize, 2), item.changes.len);
    // Nothing visible moved yet.
    try t.expect(trunkOf(q.current()).eql(s.root));

    try q.onReviewDecision(tk.review, .{ .verdict = .approve, .reviewer = "chris" });
    const r = q.current();
    try t.expectEqual(landing.LandingState.landed, q.ticket(tk.id).?.state);
    // trunk did not move: the stack lands as is.
    try t.expect(trunkOf(r).eql(s.c2));
    try t.expectEqualStrings("landed", laneStatus(r, "l1"));
    try t.expectEqual(@as(usize, 1), checks.runs);
    try t.expectEqual(@as(usize, 0), checks.roots);
    try t.expectEqualSlices(landing.LandingState, &.{ .submitted, .in_review, .approved, .rebasing, .checking, .landed }, try states(&q));
    var saw_log = false;
    for (q.events().items.items) |e| saw_log = saw_log or std.mem.eql(u8, e.log, "running\n");
    try t.expect(saw_log);
    try t.expectEqualStrings("agent-7: Lane landed", notes.titles.items[0]);
    const st = landing.laneState(r.arena_state.allocator(), r.view().lane("l1").?).?;
    try t.expectEqual(landing.LandingState.landed, st.state);
}

test "landing: trunk moved → rebased" {
    var s = try Setup.init();
    defer s.deinit();
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var q = LandingQueue.init(gpa, s.repo, .{ .review = review.port() });
    defer q.deinit();
    const tk = try q.submit("l1", .{});

    // Someone lands d.txt on main meanwhile.
    try s.change(struct {
        fn edit(m: *mutable_mod.MutableRepo, st: *Setup) !void {
            const d = try commit(m, &.{st.root}, "add d", &.{ .{ "a.txt", "1" }, .{ "d.txt", "1" } });
            var tgt: ?ObjectId = d;
            try m.setBookmark("main", fx.target(&tgt));
        }
    }.edit);
    const d = trunkOf(s.repo);

    try q.onReviewDecision(tk.review, .{ .verdict = .approve, .reviewer = "chris" });
    const r = q.current();
    try t.expectEqual(landing.LandingState.landed, q.ticket(tk.id).?.state);
    const top = trunkOf(r);
    try t.expect(!top.eql(s.c2));
    try t.expectEqualStrings("a.txt=1;b.txt=1;c.txt=1;d.txt=1;", try filesOf(r, top));
    const a = r.arena_state.allocator();
    const c2n = try op_mod.read(object.Change, r.store, a, top);
    const c1n = try op_mod.read(object.Change, r.store, a, c2n.parents[0]);
    try t.expect(c1n.parents[0].eql(d));
    try t.expectEqualStrings("add b", c1n.description);
    // The lane's working copy followed its commit.
    try t.expect(r.view().wcCommit("ws1").?.eql(top));
    try t.expect(r.view().lane("l1").?.base.?.eql(top));
}

test "landing: conflict returns lane" {
    var s = try Setup.init();
    defer s.deinit();
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var notes: Notes = .{};
    defer notes.deinit();
    var q = LandingQueue.init(gpa, s.repo, .{ .review = review.port(), .notify = notes.port() });
    defer q.deinit();
    const tk = try q.submit("l1", .{});
    try s.change(struct {
        fn edit(m: *mutable_mod.MutableRepo, st: *Setup) !void {
            const x = try commit(m, &.{st.root}, "other b", &.{ .{ "a.txt", "1" }, .{ "b.txt", "2" } });
            var tgt: ?ObjectId = x;
            try m.setBookmark("main", fx.target(&tgt));
        }
    }.edit);
    const before = trunkOf(s.repo);
    try q.onReviewDecision(tk.review, .{ .verdict = .approve, .reviewer = "chris" });
    const r = q.current();
    try t.expectEqual(landing.LandingState.returned_conflict, q.ticket(tk.id).?.state);
    try t.expect(trunkOf(r).eql(before));
    try t.expectEqualStrings("active", laneStatus(r, "l1"));
    try t.expect(r.view().wcCommit("ws1").?.eql(s.c2));
    const st = landing.laneState(r.arena_state.allocator(), r.view().lane("l1").?).?;
    try t.expectEqualStrings("b.txt", st.reason);
    try t.expectEqualStrings("agent-7: Lane needs a rebase: conflicts with trunk", notes.titles.items[0]);
}

test "landing: checks fail returns lane with logs" {
    var s = try Setup.init();
    defer s.deinit();
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var checks: Checks = .{ .fail = "error: boom\n" };
    var q = LandingQueue.init(gpa, s.repo, .{ .review = review.port(), .checks = checks.port(), .checkout = checks.checkout() });
    defer q.deinit();
    const tk = try q.submit("l1", .{ .checks = &check_specs });
    try q.onReviewDecision(tk.review, .{ .verdict = .approve, .reviewer = "chris" });
    const r = q.current();
    try t.expectEqual(landing.LandingState.returned_checks_failed, q.ticket(tk.id).?.state);
    try t.expect(trunkOf(r).eql(s.root));
    try t.expectEqualStrings("active", laneStatus(r, "l1"));
    const st = landing.laneState(r.arena_state.allocator(), r.view().lane("l1").?).?;
    try t.expect(std.mem.indexOf(u8, st.reason, "error: boom") != null);
    var logged = false;
    for (q.events().items.items) |e| logged = logged or std.mem.eql(u8, e.log, "error: boom\n");
    try t.expect(logged);
    // The rebased commits stay invisible.
    try t.expectEqual(@as(usize, 1), r.view().heads.len);
}

test "landing: two lanes sequential" {
    var s = try Setup.init();
    defer s.deinit();
    try s.change(struct {
        fn edit(m: *mutable_mod.MutableRepo, st: *Setup) !void {
            const e = try commit(m, &.{st.root}, "add e", &.{ .{ "a.txt", "1" }, .{ "e.txt", "1" } });
            try addLane(m, "l2", "ws2", st.root, e, "");
        }
    }.edit);
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var q = LandingQueue.init(gpa, s.repo, .{ .review = review.port() });
    defer q.deinit();
    const t1 = try q.submit("l1", .{});
    const t2 = try q.submit("l2", .{});
    try t.expectError(error.AlreadySubmitted, q.submit("l1", .{}));
    review.decide(t1.review, .approved);
    review.decide(t2.review, .approved);
    try q.poll();
    const r = q.current();
    try t.expectEqual(landing.LandingState.landed, q.ticket(t1.id).?.state);
    try t.expectEqual(landing.LandingState.landed, q.ticket(t2.id).?.state);
    // l2 landed on top of l1.
    try t.expectEqualStrings("a.txt=1;b.txt=1;c.txt=1;e.txt=1;", try filesOf(r, trunkOf(r)));
    const top = try op_mod.read(object.Change, r.store, r.arena_state.allocator(), trunkOf(r));
    try t.expect(top.parents[0].eql(s.c2));
}

test "landing: undo after land restores bookmark and lane status" {
    var s = try Setup.init();
    defer s.deinit();
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var q = LandingQueue.init(gpa, s.repo, .{ .review = review.port() });
    defer q.deinit();
    const tk = try q.submit("l1", .{});
    try q.onReviewDecision(tk.review, .{ .verdict = .approve, .reviewer = "chris" });
    const landed_op = q.current().op();
    try t.expect(trunkOf(q.current()).eql(s.c2));
    const r = try undo_mod.undo(q.current(), landed_op, meta("undo land"));
    defer r.close();
    try t.expect(trunkOf(r).eql(s.root));
    try t.expectEqualStrings("landing", laneStatus(r, "l1"));
}

test "landing: restart mid-queue resumes" {
    var s = try Setup.init();
    defer s.deinit();
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var review_id: ports.ReviewId = 0;
    {
        var q = LandingQueue.init(gpa, s.repo, .{ .review = review.port() });
        defer q.deinit();
        review_id = (try q.submit("l1", .{ .strategy = .squash })).review;
        // The process stops here.
    }
    review.decide(review_id, .approved);
    var q2 = LandingQueue.init(gpa, s.repo, .{ .review = review.port() });
    defer q2.deinit();
    try q2.resumeAll();
    const r = q2.current();
    try t.expectEqualStrings("landed", laneStatus(r, "l1"));
    // Squashed: one change on root with both descriptions.
    const top = try op_mod.read(object.Change, r.store, r.arena_state.allocator(), trunkOf(r));
    try t.expect(top.parents[0].eql(s.root));
    try t.expectEqualStrings("add b\n\nadd c", top.description);
    try t.expectEqual(@as(usize, 2), top.predecessors.len);
    try t.expectEqualStrings("a.txt=1;b.txt=1;c.txt=1;", try filesOf(r, trunkOf(r)));
    // A new ticket gets a fresh number.
    try t.expect(q2.next_id > 1);
}

test "landing: rejection and the no-review policy" {
    var s = try Setup.init();
    defer s.deinit();
    try s.change(struct {
        fn edit(m: *mutable_mod.MutableRepo, st: *Setup) !void {
            const e = try commit(m, &.{st.root}, "add e", &.{ .{ "a.txt", "1" }, .{ "e.txt", "1" } });
            try addLane(m, "trusted", "ws3", st.root, e, "may_land_without_review");
        }
    }.edit);
    var review = FakeReview.init(gpa, .pending);
    defer review.deinit();
    var q = LandingQueue.init(gpa, s.repo, .{ .review = review.port() });
    defer q.deinit();
    const tk = try q.submit("l1", .{});
    try q.onReviewDecision(tk.review, .{ .verdict = .reject, .reviewer = "chris", .note = "split it" });
    try t.expectEqual(landing.LandingState.rejected, q.ticket(tk.id).?.state);
    try t.expectEqualStrings("active", laneStatus(q.current(), "l1"));
    try t.expect(trunkOf(q.current()).eql(s.root));

    const tr = try q.submit("trusted", .{});
    try t.expectEqual(landing.LandingState.landed, tr.state);
    try t.expectEqual(@as(usize, 1), review.items.items.len);
}
