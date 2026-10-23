//! Claims across threads and processes, leases, the reaper, the task
//! tools, hooks and the dispatcher.

const std = @import("std");
const builtin = @import("builtin");
const runs = @import("../runs/root.zig");
const lease = @import("lease.zig");
const ClaimManager = @import("claim.zig");
const TaskStore = @import("store.zig");
const tools = @import("tools.zig");
const hooks = @import("hooks.zig");
const dispatch = @import("dispatch.zig");
const query = @import("query.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const RunId = runs.RunId;

fn rid(n: u128) RunId {
    return .fromInt((n + 1) << 64 | n);
}

// ---- the lock layer ----

const Shared = struct {
    locks: lease.Locks,
    holders: std.atomic.Value(u32) = .init(0),
    wins: std.atomic.Value(u32) = .init(0),
    violations: std.atomic.Value(u32) = .init(0),
};

fn hammer(s: *Shared, me: u128, rounds: u32) void {
    const run = rid(me);
    var i: u32 = 0;
    while (i < rounds) : (i += 1) {
        const r = s.locks.acquire("T-0001.lock", .{ .run = run, .until_s = 2_000_000_000 }, 1_000) catch continue;
        if (r != .ok) continue;
        if (s.holders.fetchAdd(1, .acq_rel) != 0) _ = s.violations.fetchAdd(1, .monotonic);
        _ = s.wins.fetchAdd(1, .monotonic);
        _ = s.holders.fetchSub(1, .acq_rel);
        _ = s.locks.release("T-0001.lock", run) catch {};
    }
}

test "exclusive_create_single_winner_threads" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var s: Shared = .{ .locks = .{ .io = io, .dir = tmp.dir } };
    var threads: [32]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, hammer, .{ &s, @as(u128, i), 1000 });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 0), s.violations.load(.monotonic));
    try testing.expect(s.wins.load(.monotonic) > 0);
    // No temporary files are left behind.
    var it = tmp.dir.iterate();
    while (try it.next(io)) |e| {
        std.debug.print("left: {s}\n", .{e.name});
        return error.TestUnexpectedResult;
    }
}

test "exclusive_create_single_winner_processes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const linux = std.os.linux;
    var pids: [4]linux.pid_t = undefined;
    for (&pids, 0..) |*p, k| {
        const r = linux.fork();
        if (r == 0) {
            // The child: its own Io, the same directory.
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            const cio = threaded.io();
            childLoop(cio, tmp.dir, @intCast(k));
            linux.exit_group(0);
        }
        p.* = @intCast(r);
    }
    for (pids) |p| {
        var status: u32 = 0;
        _ = linux.waitpid(p, &status, 0);
    }
    // Every child wrote its win count; none saw another holder.
    var total: u32 = 0;
    for (0..pids.len) |k| {
        var nb: [32]u8 = undefined;
        var buf: [32]u8 = undefined;
        const got = try tmp.dir.readFile(io, try std.fmt.bufPrint(&nb, "wins-{d}", .{k}), &buf);
        total += try std.fmt.parseInt(u32, got, 10);
    }
    try testing.expect(total > 0);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "violation", .{}));
}

fn childLoop(cio: std.Io, dir: std.Io.Dir, k: u32) void {
    const locks: lease.Locks = .{ .io = cio, .dir = dir };
    const run = rid(100 + k);
    var wins: u32 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const r = locks.acquire("T-0001.lock", .{ .run = run, .until_s = 2_000_000_000 }, 1_000) catch continue;
        if (r != .ok) continue;
        // The witness can only be created by the one holder.
        const w = dir.createFile(cio, "witness", .{ .exclusive = true }) catch {
            dir.writeFile(cio, .{ .sub_path = "violation", .data = "x" }) catch {};
            _ = locks.release("T-0001.lock", run) catch {};
            continue;
        };
        w.close(cio);
        wins += 1;
        dir.deleteFile(cio, "witness") catch {};
        _ = locks.release("T-0001.lock", run) catch {};
    }
    var nb: [32]u8 = undefined;
    var vb: [16]u8 = undefined;
    dir.writeFile(cio, .{ .sub_path = std.fmt.bufPrint(&nb, "wins-{d}", .{k}) catch unreachable, .data = std.fmt.bufPrint(&vb, "{d}", .{wins}) catch unreachable }) catch {};
}

test "stale_lease_steal_cas" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const l: lease.Locks = .{ .io = io, .dir = tmp.dir, .grace_s = 30 };
    try testing.expectEqual(lease.Acquire.ok, try l.acquire("T-0002.lock", .{ .run = rid(1), .until_s = 1_000 }, 100));
    // Live (and within the grace period): taken.
    const t1 = try l.acquire("T-0002.lock", .{ .run = rid(2), .until_s = 2_000 }, 1_020);
    try testing.expect(t1 == .taken and t1.taken.run.eql(rid(1)));
    // Past the grace: stolen.
    try testing.expectEqual(lease.Acquire.ok, try l.acquire("T-0002.lock", .{ .run = rid(2), .until_s = 2_000 }, 1_031));
    var buf: [512]u8 = undefined;
    try testing.expect((try l.read("T-0002.lock", &buf)).?.run.eql(rid(2)));
    // Only the holder renews or releases.
    try testing.expect(!try l.renew("T-0002.lock", .{ .run = rid(1), .until_s = 9_000 }));
    try testing.expect(try l.renew("T-0002.lock", .{ .run = rid(2), .until_s = 9_000 }));
    try testing.expectEqual(@as(i64, 9_000), (try l.read("T-0002.lock", &buf)).?.until_s);
    try testing.expect(!try l.release("T-0002.lock", rid(1)));
    try testing.expect(try l.release("T-0002.lock", rid(2)));
    // An unreadable lock counts as held until it is old.
    try tmp.dir.writeFile(io, .{ .sub_path = "T-0003.lock", .data = "" });
    const t3 = try l.acquire("T-0003.lock", .{ .run = rid(3), .until_s = 2_000 }, @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)));
    try testing.expect(t3 == .taken and t3.taken.run.eql(.zero));
}

// ---- the manager over a store ----

const Clock = struct {
    ms: i64 = 1_792_756_800_000, // 2026-10-23 12:00:00 UTC
    fn now(ctx: ?*anyopaque) i64 {
        const c: *Clock = @ptrCast(@alignCast(ctx.?));
        return c.ms;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    clock: Clock = .{},
    store: *TaskStore,
    claims: *ClaimManager,

    fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .store = undefined, .claims = undefined };
        try f.tmp.dir.createDirPath(io, ".zigguro/tasks");
        const files = [_][2][]const u8{
            .{ "T-0001-a.md", "---\nid: T-0001\ntitle: Low\nstatus: ready\npriority: P3\n---\n" },
            .{ "T-0002-b.md", "---\nid: T-0002\ntitle: Urgent\nstatus: ready\npriority: P0\nlabels: [code]\nassignee: agent:coder\n---\n# Urgent\n\nFix it. See [[Design notes]].\n" },
            .{ "T-0003-c.md", "---\nid: T-0003\ntitle: Waits\nstatus: ready\npriority: P0\ndepends_on: [T-0001]\n---\n" },
            .{ "T-0004-d.md", "---\nid: T-0004\ntitle: Later\nstatus: backlog\n---\n" },
            .{ "T-0005-e.md", "---\nid: T-0005\ntitle: Due soon\nstatus: ready\npriority: P0\ndue: 2026-10-25\n---\n" },
        };
        for (files) |x| {
            var b: [64]u8 = undefined;
            try f.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&b, ".zigguro/tasks/{s}", .{x[0]}), .data = x[1] });
        }
        f.store = try TaskStore.open(gpa, io, f.tmp.dir, .{ .clock = .{ .ctx = &f.clock, .nowRealMs = Clock.now } });
        f.claims = try ClaimManager.init(gpa, f.store, .{ .lease_s = 900 });
    }

    fn deinit(f: *Fx) void {
        f.claims.deinit();
        f.store.close();
        f.tmp.cleanup();
    }

    fn task(f: *Fx, id: u32) struct { status: @import("task.zig").Status, claimed: bool } {
        const v = f.store.view();
        defer f.store.release(v);
        const t = v.get(id).?;
        return .{ .status = t.status, .claimed = t.claimed_by != null };
    }

    fn file(f: *Fx, name: []const u8) ![]u8 {
        var b: [64]u8 = undefined;
        return f.tmp.dir.readFileAlloc(io, try std.fmt.bufPrint(&b, ".zigguro/tasks/{s}", .{name}), gpa, .limited(1 << 16));
    }
};

test "claims: preconditions, blocked deps and taken tasks" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const r1 = try f.claims.claim(1, rid(1), 900);
    try testing.expect(r1 == .ok);
    try testing.expectEqual(@import("task.zig").Status.in_progress, f.task(1).status);
    try testing.expect(f.task(1).claimed);
    // Not ready any more.
    try testing.expect((try f.claims.claim(1, rid(2), 900)) == .not_ready);
    // blocked_deps_refused
    const r3 = try f.claims.claim(3, rid(2), 900);
    try testing.expectEqualSlices(u32, &.{1}, r3.blocked);
    try testing.expect((try f.claims.claim(4, rid(2), 900)) == .not_ready);
    try testing.expect((try f.claims.claimWith(4, rid(2), 900, .{ .allow_backlog = true })) == .ok);
    try testing.expect((try f.claims.claim(99, rid(2), 900)) == .not_found);
    // Release: done.
    try f.claims.release(1, rid(1), .done, null);
    try testing.expectEqual(@import("task.zig").Status.done, f.task(1).status);
    try testing.expect(!f.task(1).claimed);
    try testing.expectError(error.NotClaimed, f.claims.release(4, rid(9), .done, null));
    // Claims never reach git.
    const gi = try f.tmp.dir.readFileAlloc(io, ".zigguro/tasks/.claims/.gitignore", gpa, .limited(64));
    defer gpa.free(gi);
    try testing.expectEqualStrings("*\n", gi);
}

test "claim_next_priority_order" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const q = try query.parseQuery(arena.allocator(), "status:ready");
    // P0 with a due date first, then P0 without; T-0003 is blocked.
    try testing.expectEqual(@as(?u32, 5), try f.claims.claimNext(rid(1), &q, 900));
    try testing.expectEqual(@as(?u32, 2), try f.claims.claimNext(rid(2), &q, 900));
    try testing.expectEqual(@as(?u32, 1), try f.claims.claimNext(rid(3), &q, 900));
    try testing.expectEqual(@as(?u32, null), try f.claims.claimNext(rid(4), &q, 900));
}

const Live = struct {
    run: RunId,
    fn isActive(ctx: *anyopaque, r: RunId) bool {
        const l: *Live = @ptrCast(@alignCast(ctx));
        return l.run.eql(r);
    }
};

test "reaper_releases_and_logs; live runs are renewed" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try testing.expect((try f.claims.claim(1, rid(1), 900)) == .ok);
    try testing.expect((try f.claims.claim(2, rid(2), 900)) == .ok);
    var live: Live = .{ .run = rid(2) };
    const port: ClaimManager.ActivePort = .{ .ctx = &live, .isActive = Live.isActive };
    // After 5 minutes the live run's lease is renewed.
    f.clock.ms += 301_000;
    const m1 = try f.claims.maintain(port);
    try testing.expectEqual(@as(u32, 1), m1.renewed);
    try testing.expectEqual(@as(u32, 0), m1.reaped);
    // Within lease + 60 s the crashed run's task is ready again.
    f.clock.ms += 900_000 - 301_000 + 31_000;
    const m2 = try f.claims.maintain(port);
    try testing.expectEqual(@as(u32, 1), m2.reaped);
    try testing.expectEqual(@import("task.zig").Status.ready, f.task(1).status);
    try testing.expect(!f.task(1).claimed);
    try testing.expectEqual(@import("task.zig").Status.in_progress, f.task(2).status);
    const b = try f.file("T-0001-a.md");
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "## Agent log\n\n- 2026-10-23 12:15Z claim by run ") != null);
    try testing.expect(std.mem.endsWith(u8, b, " expired\n"));
}

const FakeHooks = struct {
    block: ?[]const u8 = null,
    seen: ?hooks.Event = null,
    fn run(ctx: *anyopaque, _: std.mem.Allocator, ev: hooks.Event, _: hooks.Input) anyerror!?[]const u8 {
        const h: *FakeHooks = @ptrCast(@alignCast(ctx));
        h.seen = ev;
        return h.block;
    }
};

const FakeChanges = struct {
    n: u64 = 0,
    fn propose(ctx: *anyopaque, _: TaskStore.ChangeRequest) anyerror!u64 {
        const c: *FakeChanges = @ptrCast(@alignCast(ctx));
        c.n += 1;
        return 500 + c.n;
    }
};

fn textOf(json: []const u8) []const u8 {
    const k = std.mem.indexOf(u8, json, "\"text\":\"").? + 8;
    return json[k..std.mem.indexOfPos(u8, json, k, "\"}").?];
}

test "tools: list, get, claim, progress, complete with hooks; create and update propose" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var changes: FakeChanges = .{};
    f.store.o.changes = .{ .ctx = &changes, .propose = FakeChanges.propose };
    var hk: FakeHooks = .{};
    var src: tools.Source = .{ .store = f.store, .claims = f.claims, .run = rid(7), .agent = "coder", .hooks = .{ .ctx = &hk, .run = FakeHooks.run } };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const r = try tools.run(&src, a, "task_list", "{\"query\":\"status:ready sort:priority\"}");
        try testing.expect(!r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.json, "\\\"total\\\":4") != null);
    }
    {
        const r = try tools.run(&src, a, "task_get", "{\"id\":\"T-0002\"}");
        try testing.expect(std.mem.indexOf(u8, r.json, "Fix it.") != null);
        const bad_in = try tools.run(&src, a, "task_get", "{\"id\":\"T-0002\",\"extra\":1}");
        try testing.expect(bad_in.is_error);
    }
    {
        const r = try tools.run(&src, a, "task_claim", "{\"id\":\"T-0003\"}");
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.json, "waits for unfinished tasks: T-0001") != null);
    }
    try testing.expect(!(try tools.run(&src, a, "task_claim", "{\"id\":\"T-0002\"}")).is_error);
    try testing.expect(!(try tools.run(&src, a, "task_progress", "{\"id\":\"T-0002\",\"note\":\"halfway\"}")).is_error);
    // hook_exit2_blocks_completion
    hk.block = "tests are failing";
    {
        const r = try tools.run(&src, a, "task_complete", "{\"id\":\"T-0002\",\"summary\":\"Fixed\",\"outcome\":\"review\"}");
        try testing.expect(r.is_error);
        try testing.expect(std.mem.indexOf(u8, r.json, "blocked by a TaskCompleted hook: tests are failing") != null);
        try testing.expectEqual(@import("task.zig").Status.in_progress, f.task(2).status);
    }
    hk.block = null;
    try testing.expect(!(try tools.run(&src, a, "task_complete", "{\"id\":\"T-0002\",\"summary\":\"Fixed\",\"outcome\":\"review\"}")).is_error);
    try testing.expectEqual(@import("task.zig").Status.review, f.task(2).status);
    const b = try f.file("T-0002-b.md");
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, b, ": halfway\n- ") != null);
    try testing.expect(std.mem.indexOf(u8, b, " finished (review): Fixed\n") != null);
    // Another run's task cannot be completed.
    try testing.expect((try tools.run(&src, a, "task_complete", "{\"id\":\"T-0001\",\"summary\":\"x\",\"outcome\":\"done\"}")).is_error);
    // Create and update go to review.
    {
        const r = try tools.run(&src, a, "task_create", "{\"title\":\"Follow-up\",\"labels\":[\"docs\"],\"priority\":\"P1\"}");
        try testing.expectEqual(@as(?u64, 501), r.changeset);
        try testing.expectEqual(hooks.Event.created, hk.seen.?);
        const u = try tools.run(&src, a, "task_update", "{\"id\":\"T-0001\",\"title\":\"Renamed\"}");
        try testing.expectEqual(@as(?u64, 502), u.changeset);
        hk.block = "no new tasks today";
        const blocked = try tools.run(&src, a, "task_create", "{\"title\":\"Another\"}");
        try testing.expect(blocked.is_error and blocked.changeset == null);
    }
    // Without a run, claims are refused.
    var anon: tools.Source = .{ .store = f.store, .claims = f.claims };
    try testing.expect((try tools.run(&anon, a, "task_claim_next", "{}")).is_error);
}

test "tools_schemas_strict" {
    for (tools.tool_list) |t| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, t.input_schema_json, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        try testing.expectEqualStrings("object", o.get("type").?.string);
        try testing.expect(o.get("additionalProperties").?.bool == false);
        const reads = std.mem.eql(u8, t.name, "task_list") or std.mem.eql(u8, t.name, "task_get");
        try testing.expectEqual(reads, t.read_only);
        try testing.expect(!(t.read_only and t.mutates));
    }
}

const Started = struct {
    id: ?RunId = null,
    title: [128]u8 = undefined,
    title_len: usize = 0,
    fail: bool = false,
    fn start(ctx: *anyopaque, id: RunId, spec: runs.RunSpec) anyerror!void {
        const s: *Started = @ptrCast(@alignCast(ctx));
        if (s.fail) return error.UnknownProfile;
        s.id = id;
        @memcpy(s.title[0..spec.title.len], spec.title);
        s.title_len = spec.title.len;
    }
    fn fixedId() RunId {
        return rid(42);
    }
};

test "dispatcher_builds_runspec_golden" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var st: Started = .{};
    var d: dispatch.Dispatcher = .{ .gpa = gpa, .io = io, .store = f.store, .claims = f.claims, .starter = .{ .ctx = &st, .start = Started.start }, .next_id = Started.fixedId };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = f.store.view();
    const spec = try d.specFor(arena.allocator(), v.get(2).?, "\n# Urgent\n\nFix it. See [[Design notes]].\n", .{});
    f.store.release(v);
    try testing.expectEqualStrings("T-0002 \u{00B7} Urgent", spec.title);
    try testing.expectEqualStrings(
        \\Work on task T-0002: Urgent
        \\
        \\# Urgent
        \\
        \\Fix it. See [[Design notes]].
        \\
        \\The task file is .zigguro/tasks/T-0002-b.md.
        \\Linked notes: [[Design notes]]
        \\Use task_progress for notes along the way. When finished call task_complete with outcome "review" (or "done" when nothing needs checking); if you cannot finish, call task_release with the reason.
    , spec.prompt);
    try testing.expectEqualStrings("coder", spec.agent_def.?);
    try testing.expectEqual(runs.Isolation.lane, spec.isolation);
    try testing.expectEqual(runs.RunKind.task, spec.kind);
    try testing.expectEqualStrings("T-0002", spec.origin.task.id);
    // Start: claimed for the run, then started.
    const id = try d.startForTask(2, .{});
    try testing.expect(id.eql(rid(42)) and st.id.?.eql(rid(42)));
    try testing.expectEqual(@import("task.zig").Status.in_progress, f.task(2).status);
    try testing.expectError(error.TaskNotReady, d.startForTask(2, .{}));
    try testing.expectError(error.TaskBlocked, d.startForTask(3, .{}));
    // A run that cannot start gives the task back.
    st.fail = true;
    try testing.expectError(error.UnknownProfile, d.startForTask(4, .{}));
    try testing.expectEqual(@import("task.zig").Status.ready, f.task(4).status);
}
