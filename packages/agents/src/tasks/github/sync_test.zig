//! The sync engine against an in-memory GitHub, a real task store in a
//! temporary workspace and a fake review queue.

const std = @import("std");
const zg_ai = @import("zg_ai");
const TaskStore = @import("../store.zig");
const task_mod = @import("../task.zig");
const gh = @import("client.zig");
const sync = @import("sync.zig");
const state_mod = @import("state.zig");
const fake_github = @import("fake_github.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const FakeClock = zg_ai.ratelimit.FakeClock;
const TaskId = task_mod.TaskId;

const repo: gh.Repo = .{ .owner = "octo", .name = "demo" };
const token: []const u8 = "ghp_test";

const Review = struct {
    items: std.ArrayList(Item) = .empty,
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),

    const Item = struct { field: []const u8, local: []const u8, remote: []const u8, after: []const u8 };

    fn port(r: *Review) sync.ConflictPort {
        return .{ .ctx = r, .raise = raise };
    }

    fn raise(ctx: *anyopaque, c: sync.ConflictItem) anyerror!u64 {
        const r: *Review = @ptrCast(@alignCast(ctx));
        const a = r.arena.allocator();
        try r.items.append(a, .{ .field = try a.dupe(u8, c.field), .local = try a.dupe(u8, c.local), .remote = try a.dupe(u8, c.remote), .after = try a.dupe(u8, c.after) });
        return r.items.items.len;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    store: *TaskStore,
    gh: fake_github.FakeGitHub,
    clock: FakeClock,
    client: gh.GitHubClient,
    review: Review,
    engine: sync.SyncEngine,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fx, cfg: sync.SyncConfig) !void {
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.store = try TaskStore.open(gpa, io, f.tmp.dir, .{ .clock = .{ .nowRealMs = fixedNow } });
        f.gh = .init(gpa);
        f.clock = .init(1_792_756_800_000);
        f.client = .init(io, f.gh.transport(), .fixed(&token), .{ .clock = f.clock.clock() });
        f.review = .{};
        f.arena = .init(gpa);
        f.engine = .init(gpa, io, &f.client, f.store, f.store.state, cfg, .{ .conflicts = f.review.port() });
    }

    fn deinit(f: *Fx) void {
        f.store.close();
        f.gh.deinit();
        f.review.arena.deinit();
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn task(f: *Fx, id: TaskId) !task_mod.Task {
        const v = f.store.view();
        defer f.store.release(v);
        return (v.get(id) orelse return error.TaskNotFound).clone(f.arena.allocator());
    }

    fn file(f: *Fx, id: TaskId) ![]const u8 {
        const t = try f.task(id);
        return f.store.dir.readFileAlloc(io, t.path, f.arena.allocator(), .limited(1 << 20));
    }

    fn only(f: *Fx) !TaskId {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expectEqual(1, v.tasks.len);
        return v.tasks[0].id;
    }

    fn state(f: *Fx) !state_mod.SyncState {
        return state_mod.load(io, f.arena.allocator(), f.store.state);
    }
};

/// 2026-10-23 12:00:00 UTC.
fn fixedNow(_: ?*anyopaque) i64 {
    return 1_792_756_800_000;
}

test "import, round-trip and conflicts on a test repository" {
    var f: Fx = undefined;
    try f.init(.{ .repo = repo });
    defer f.deinit();

    _ = f.gh.add(.{ .title = "Crash on save", .labels = &.{"bug"}, .assignees = &.{"octo"} });
    f.gh.get(1).body = "Steps:\n1. save";
    _ = f.gh.add(.{ .title = "A pull request", .pull_request = true });
    _ = f.gh.add(.{ .title = "Old and closed", .closed = true, .state_reason = "completed" });

    const r1 = try f.engine.pull();
    try testing.expectEqual(1, r1.created);
    try testing.expectEqual(1, r1.skipped);
    const id = try f.only();
    var t = try f.task(id);
    try testing.expectEqualStrings("Crash on save", t.title);
    try testing.expectEqualStrings("octo/demo#1", t.github.?);
    try testing.expectEqualStrings("bug", t.labels[0]);
    try testing.expectEqualStrings("octo", t.assignee.?);
    try testing.expectEqual(task_mod.Status.backlog, t.status);
    try testing.expect(std.mem.indexOf(u8, try f.file(id), "# Crash on save\n\nSteps:\n1. save\n") != null);

    // Local edits go up.
    _ = try f.store.update(id, .{ .title = "Crash on save (Windows)", .labels = &.{ "bug", "windows" }, .status = .done }, .user);
    const r2 = try f.engine.push();
    try testing.expectEqual(1, r2.updated_remote);
    const remote = f.gh.get(1);
    try testing.expectEqualStrings("Crash on save (Windows)", remote.title);
    try testing.expect(remote.closed);
    try testing.expectEqualStrings("completed", remote.state_reason.?);
    try testing.expectEqual(2, remote.labels.len);
    // Nothing left to push: no requests.
    try testing.expectEqual(0, (try f.engine.push()).requests);

    // Remote edits come down.
    remote.body = "Steps:\n1. save\n2. crash";
    remote.closed = false;
    remote.state_reason = null;
    remote.assignees = &.{"hubot"};
    f.gh.touch(1);
    const r3 = try f.engine.pull();
    try testing.expectEqual(1, r3.updated_local);
    t = try f.task(id);
    try testing.expectEqual(task_mod.Status.ready, t.status);
    try testing.expectEqualStrings("hubot", t.assignee.?);
    try testing.expect(std.mem.indexOf(u8, try f.file(id), "2. crash") != null);
    try testing.expect(std.mem.indexOf(u8, try f.file(id), "# Crash on save (Windows)") != null);

    // Both sides change the title: nothing is overwritten, one review item.
    _ = try f.store.update(id, .{ .title = "Local title" }, .user);
    remote.title = "Remote title";
    f.gh.touch(1);
    const r4 = try f.engine.pull();
    try testing.expectEqual(1, r4.conflicts);
    try testing.expectEqualStrings("Local title", (try f.task(id)).title);
    try testing.expectEqualStrings("Remote title", f.gh.get(1).title);
    const r5 = try f.engine.push();
    try testing.expectEqual(1, r5.conflicts);
    try testing.expectEqual(0, r5.updated_remote);
    try testing.expectEqualStrings("Remote title", f.gh.get(1).title);
    try testing.expectEqual(1, f.review.items.items.len);
    try testing.expectEqual(1, (try f.engine.status(f.arena.allocator())).conflicts);
}

test "three_way_merge_cases" {
    var f: Fx = undefined;
    try f.init(.{ .repo = repo });
    defer f.deinit();
    _ = f.gh.add(.{ .title = "T", .labels = &.{ "a", "b" } });
    f.gh.get(1).body = "one";
    _ = try f.engine.pull();
    const id = try f.only();

    // Remote-only change: applied locally, nothing sent.
    f.gh.get(1).body = "two";
    f.gh.touch(1);
    var r = try f.engine.syncOnce();
    try testing.expectEqual(1, r.updated_local);
    try testing.expectEqual(0, r.updated_remote);
    try testing.expect(std.mem.indexOf(u8, try f.file(id), "two") != null);

    // Local-only change: sent, nothing applied locally.
    _ = try f.store.update(id, .{ .body = "# T\n\nthree\n" }, .user);
    r = try f.engine.syncOnce();
    try testing.expectEqual(1, r.updated_remote);
    try testing.expectEqualStrings("three", f.gh.get(1).body.?);

    // Both changed to the same value: no conflict.
    _ = try f.store.update(id, .{ .body = "# T\n\nfour\n" }, .user);
    f.gh.get(1).body = "four";
    f.gh.touch(1);
    r = try f.engine.syncOnce();
    try testing.expectEqual(0, r.conflicts);
    try testing.expectEqual(0, r.updated_remote);

    // Labels merge as sets: local adds c and drops a, GitHub adds d.
    _ = try f.store.update(id, .{ .labels = &.{ "b", "c" } }, .user);
    f.gh.get(1).labels = &.{ "a", "b", "d" };
    f.gh.touch(1);
    r = try f.engine.syncOnce();
    try testing.expectEqual(0, r.conflicts);
    const t = try f.task(id);
    try testing.expectEqual(3, t.labels.len);
    try testing.expectEqual(3, f.gh.get(1).labels.len);
    for ([_][]const u8{ "b", "c", "d" }) |l| try testing.expect(t.hasLabel(l));

    // Deleted on GitHub: the task stays and is unlinked.
    _ = try f.store.update(id, .{ .title = "T2" }, .user);
    f.gh.get(1).deleted = true;
    r = try f.engine.push();
    try testing.expectEqual(1, r.skipped);
    try testing.expect((try f.task(id)).github == null);
    try testing.expectEqual(0, (try f.state()).issues.len);
}

test "conflict_creates_review_item" {
    var f: Fx = undefined;
    try f.init(.{ .repo = repo });
    defer f.deinit();
    _ = f.gh.add(.{ .title = "T" });
    f.gh.get(1).body = "base";
    _ = try f.engine.pull();
    const id = try f.only();
    _ = try f.store.update(id, .{ .body = "# T\n\nmine\n" }, .user);
    f.gh.get(1).body = "theirs";
    f.gh.touch(1);

    const r = try f.engine.pull();
    try testing.expectEqual(1, r.conflicts);
    try testing.expectEqual(1, f.review.items.items.len);
    const item = f.review.items.items[0];
    try testing.expectEqualStrings("body", item.field);
    try testing.expectEqualStrings("mine", item.local);
    try testing.expectEqualStrings("theirs", item.remote);
    try testing.expect(std.mem.indexOf(u8, item.after, "theirs") != null);
    // The file still has the local text.
    try testing.expect(std.mem.indexOf(u8, try f.file(id), "mine") != null);
    // Raised once per remote value.
    f.gh.touch(1);
    _ = try f.engine.pull();
    try testing.expectEqual(1, f.review.items.items.len);
    // Accepting the review (the file takes GitHub's text) resolves it.
    _ = try f.store.update(id, .{ .body = "# T\n\ntheirs\n" }, .user);
    f.gh.touch(1);
    try testing.expectEqual(0, (try f.engine.syncOnce()).conflicts);
    try testing.expectEqual(0, (try f.state()).issues[0].conflicts.len);
}

test "publish_requires_explicit_action" {
    var f: Fx = undefined;
    try f.init(.{ .repo = repo, .labels_filter = &.{"zigguro"} });
    defer f.deinit();
    const made = try f.store.create(.{ .title = "Local only", .body = "Details", .labels = &.{"docs"}, .status = .cancelled }, .user);

    // Neither pull nor push creates issues.
    _ = try f.engine.syncOnce();
    try testing.expectEqual(0, f.gh.count(.POST));
    try testing.expect((try f.task(made.id)).github == null);

    const n = try f.engine.publish(made.id);
    try testing.expectEqual(1, n);
    try testing.expectEqual(1, f.gh.count(.POST));
    const issue = f.gh.get(1);
    try testing.expectEqualStrings("Local only", issue.title);
    try testing.expectEqualStrings("Details", issue.body.?);
    try testing.expect(issue.closed);
    try testing.expectEqualStrings("not_planned", issue.state_reason.?);
    const t = try f.task(made.id);
    try testing.expectEqualStrings("octo/demo#1", t.github.?);
    try testing.expect(t.hasLabel("zigguro") and t.hasLabel("docs"));
    try testing.expectError(error.AlreadyLinked, f.engine.publish(made.id));
    // In sync afterwards.
    const r = try f.engine.syncOnce();
    try testing.expectEqual(0, r.updated_local + r.updated_remote + r.conflicts);
}

test "state_roundtrip_atomic" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(0, (try state_mod.load(io, a, tmp.dir)).issues.len);
    const s: state_mod.SyncState = .{
        .repo = "octo/demo",
        .last_pull_iso = "2026-10-22T10:00:00Z",
        .list_since = "2026-10-22T09:59:00Z",
        .list_etag = "W/\"a\\\"b\"",
        .issues = &.{
            .{ .number = 7, .task_id = 42, .etag = "\"e\"", .base = .{ .title_hash = 1, .body_hash = std.math.maxInt(u64), .state = .cancelled, .labels = &.{ "bug", "P1" }, .assignee = "octo" }, .conflicts = &.{.{ .field = "title", .remote_hash = 9, .review = 3 }} },
            .{ .number = 8, .task_id = 43 },
        },
    };
    try state_mod.save(io, a, tmp.dir, s);
    try state_mod.save(io, a, tmp.dir, s);
    const back = try state_mod.load(io, a, tmp.dir);
    try testing.expectEqualStrings("octo/demo", back.repo);
    try testing.expectEqualStrings(s.list_etag.?, back.list_etag.?);
    try testing.expectEqual(2, back.issues.len);
    try testing.expectEqual(std.math.maxInt(u64), back.issues[0].base.body_hash);
    try testing.expectEqual(.cancelled, back.issues[0].base.state);
    try testing.expectEqualStrings("P1", back.issues[0].base.labels[1]);
    try testing.expectEqualStrings("title", back.issues[0].conflicts[0].field);
    try testing.expect(back.issues[1].base.assignee == null);
    // Only the state file is left (the temporary one was renamed).
    var it = tmp.dir.iterate();
    var names: usize = 0;
    while (try it.next(io)) |_| names += 1;
    try testing.expectEqual(1, names);
    // A broken file is an error, not an empty state.
    try tmp.dir.writeFile(io, .{ .sub_path = state_mod.file_name, .data = ".{ .version = 99 }" });
    try testing.expectError(error.InvalidState, state_mod.load(io, a, tmp.dir));
}

test "incremental_pull_uses_since" {
    var f: Fx = undefined;
    try f.init(.{ .repo = repo, .labels_filter = &.{"sync"} });
    defer f.deinit();
    f.gh.per_page = 2;
    for (0..5) |_| _ = f.gh.add(.{ .title = "Synced", .labels = &.{"sync"} });
    _ = f.gh.add(.{ .title = "Not for us" });

    const r1 = try f.engine.pull();
    try testing.expectEqual(5, r1.created);
    try testing.expectEqual(3, r1.requests);
    try testing.expect(std.mem.indexOf(u8, f.gh.seen.items[0].url, "since=") == null);
    try testing.expect(std.mem.indexOf(u8, f.gh.seen.items[0].url, "labels=sync") != null);
    const st = try f.state();
    try testing.expectEqualStrings(f.gh.get(5).updated_at, st.list_since.?);

    // The next pull asks for changes since then.
    f.gh.get(3).title = "Renamed";
    f.gh.touch(3);
    const before = f.gh.seen.items.len;
    const r2 = try f.engine.pull();
    try testing.expectEqual(1, r2.updated_local);
    try testing.expect(std.mem.indexOf(u8, f.gh.seen.items[before].url, "since=2026-10-22T10%3A00%3A05Z") != null);

    // Once nothing is new, a pull costs a single 304.
    _ = try f.engine.pull();
    const r4 = try f.engine.pull();
    try testing.expectEqual(1, r4.requests);
    try testing.expectEqual(0, r4.created + r4.updated_local);
    const s4 = try f.engine.status(f.arena.allocator());
    try testing.expectEqual(5, s4.linked);
    try testing.expectEqual(0, s4.pending_push);

    // Another repository's state is refused.
    var other = f.engine;
    other.cfg.repo = .{ .owner = "octo", .name = "elsewhere" };
    try testing.expectError(error.RepoChanged, other.pull());
}
