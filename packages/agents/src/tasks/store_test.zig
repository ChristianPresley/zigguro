//! The task store over the fixture files in a temporary workspace.

const std = @import("std");
const runs = @import("../runs/root.zig");
const TaskStore = @import("store.zig");
const task_mod = @import("task.zig");
const ids = @import("ids.zig");
const events = @import("events.zig");
const query = @import("query.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const Status = task_mod.Status;

const fixture_names = [_][]const u8{
    "T-0001-write-the-docs.md", "T-0002-obsidian.md",    "T-0003-crlf.md",          "T-0004-bom.md",
    "T-0005-duplicate-a.md",    "T-0005-duplicate-b.md", "T-0006-unknown-props.md", "T-0007-malformed.md",
    "T-0008-missing-id.md",     "T-0009-bad-status.md",  "T-0010-cycle-a.md",       "T-0011-cycle-b.md",
    "T-0012-self.md",           "T-0013-depends.md",     "T-0014-claimed.md",       "T-0015-github.md",
    "T-0016-heading-title.md",  "T-0017-no-title.md",    "T-0018-comma-labels.md",  "T-0019-bad-priority.md",
    "empty.md",
};

fn fixture(comptime name: []const u8) []const u8 {
    return @embedFile("testdata/fixtures/" ++ name);
}

const Fx = struct {
    tmp: testing.TmpDir,
    store: *TaskStore,
    changes: FakeChanges = .{},
    docs: FakeDocs = .{},

    fn init(f: *Fx, o: TaskStore.Options) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .store = undefined };
        try f.tmp.dir.createDirPath(io, ".zigguro/tasks");
        inline for (fixture_names) |n| try f.tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/tasks/" ++ n, .data = fixture(n) });
        var oo = o;
        oo.changes = .{ .ctx = &f.changes, .propose = FakeChanges.propose };
        oo.clock = .{ .nowRealMs = fixedNow };
        f.store = try TaskStore.open(gpa, io, f.tmp.dir, oo);
    }

    fn deinit(f: *Fx) void {
        f.store.close();
        f.changes.deinit();
        f.tmp.cleanup();
    }

    fn read(f: *Fx, name: []const u8) ![]u8 {
        var buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, ".zigguro/tasks/{s}", .{name});
        return f.tmp.dir.readFileAlloc(io, p, gpa, .limited(1 << 20));
    }
};

/// 2026-10-23 12:00:00 UTC.
fn fixedNow(_: ?*anyopaque) i64 {
    return 1_792_756_800_000;
}

const FakeChanges = struct {
    reqs: std.ArrayList(struct { path: []u8, after: ?[]u8, summary: []u8 }) = .empty,

    fn propose(ctx: *anyopaque, r: TaskStore.ChangeRequest) anyerror!u64 {
        const c: *FakeChanges = @ptrCast(@alignCast(ctx));
        try c.reqs.append(gpa, .{ .path = try gpa.dupe(u8, r.path), .after = if (r.after) |x| try gpa.dupe(u8, x) else null, .summary = try gpa.dupe(u8, r.summary) });
        return 100 + c.reqs.items.len;
    }

    fn deinit(c: *FakeChanges) void {
        for (c.reqs.items) |r| {
            gpa.free(r.path);
            if (r.after) |x| gpa.free(x);
            gpa.free(r.summary);
        }
        c.reqs.deinit(gpa);
    }
};

const FakeDocs = struct {
    open_path: ?[]const u8 = null,
    applied: u32 = 0,
    fn apply(ctx: *anyopaque, path: []const u8, _: []const u8) anyerror!bool {
        const d: *FakeDocs = @ptrCast(@alignCast(ctx));
        if (d.open_path) |p| if (std.mem.eql(u8, p, path)) {
            d.applied += 1;
            return true;
        };
        return false;
    }
};

test "parse_fixtures" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const v = f.store.view();
    defer f.store.release(v);
    try testing.expectEqual(fixture_names.len, v.tasks.len);
    const Want = struct { u32, []const u8, Status, u2, ?[]const u8 };
    const wants = [_]Want{
        .{ 1, "Write the docs", .ready, 1, null },
        .{ 2, "Obsidian authored", .in_progress, 0, null },
        .{ 3, "CRLF task", .review, 3, null },
        .{ 4, "BOM task", .done, 2, null },
        .{ 6, "Unknown properties", .ready, 2, null },
        .{ 9, "Bad status", .backlog, 2, "unknown status" },
        .{ 14, "Claimed by a run", .in_progress, 2, null },
        .{ 16, "Title from the heading", .backlog, 2, null },
        .{ 17, "T-0017-no-title", .backlog, 2, null },
        .{ 18, "Comma labels", .backlog, 2, null },
        .{ 19, "Bad priority", .backlog, 2, "priority must be P0 to P3" },
    };
    for (wants) |w| {
        const t = v.get(w[0]) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(w[1], t.title);
        try testing.expectEqual(w[2], t.status);
        try testing.expectEqual(w[3], t.priority);
        if (w[4]) |p| try testing.expectEqualStrings(p, t.problem.?) else try testing.expect(t.problem == null);
    }
    const t1 = v.get(1).?;
    try testing.expectEqualStrings("alice", t1.assignee.?);
    try testing.expectEqual(@as(usize, 2), t1.labels.len);
    try testing.expectEqual(@as(u5, 1), t1.due.?.d);
    try testing.expectEqualStrings("2026-10-20T09:00:00Z", t1.created.?);
    try testing.expectEqualStrings("needs review", v.get(2).?.labels[1]);
    try testing.expectEqualSlices(u32, &.{ 1, 4 }, v.get(13).?.depends_on);
    try testing.expectEqualStrings("01JABCDEFGHJKMNPQRSTVWXYZ0", v.get(14).?.claimed_by.?);
    try testing.expectEqualStrings("ChristianPresley/zigguro#42", v.get(15).?.github.?);
    try testing.expectEqualStrings("a0", v.get(15).?.rank.?);
    try testing.expectEqualStrings("ui", v.get(18).?.labels[1]);
    try testing.expectEqual(@as(u5, 30), v.get(18).?.due.?.d);
    // Bad files are listed, never dropped.
    var bad: u32 = 0;
    for (v.tasks) |t| if (t.id == 0) {
        bad += 1;
        try testing.expect(t.problem != null);
    };
    try testing.expectEqual(@as(u32, 3), bad); // malformed, missing id, empty
    try testing.expectEqualSlices(u32, &.{5}, v.duplicates);
    try testing.expectEqualSlices(u32, &.{ 10, 11, 12 }, v.cycles);
    // Ready: T-0001, T-0006, T-0012, T-0013, T-0015 and the file without an id.
    try testing.expectEqual(@as(usize, 6), v.byStatus(.ready).len);
}

test "round trip: re-setting a property keeps every file byte-identical" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const v = f.store.view();
    defer f.store.release(v);
    for (v.tasks) |t| {
        if (t.id == 0 or t.problem != null or v.isDuplicate(t.id)) continue;
        const before = try f.read(t.path);
        defer gpa.free(before);
        // Only files that spell the status the way it is written back.
        const loc = std.mem.indexOf(u8, before, "status: ") orelse continue;
        const word = before[loc + 8 ..][0..@tagName(t.status).len];
        if (!std.mem.eql(u8, word, @tagName(t.status))) continue;
        _ = try f.store.update(t.id, .{ .status = t.status }, .user);
        const after = try f.read(t.path);
        defer gpa.free(after);
        try testing.expectEqualStrings(before, after);
    }
    // And an empty patch never writes.
    _ = try f.store.update(2, .{}, .user);
    const b = try f.read("T-0002-obsidian.md");
    defer gpa.free(b);
    try testing.expectEqualStrings(fixture("T-0002-obsidian.md"), b);
}

test "patch_byte_preserving" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    _ = try f.store.update(2, .{ .status = .review }, .user);
    _ = try f.store.update(3, .{ .status = .done }, .user);
    const b2 = try f.read("T-0002-obsidian.md");
    defer gpa.free(b2);
    const want2 = try std.mem.replaceOwned(u8, gpa, fixture("T-0002-obsidian.md"), "status: In Progress   # set from the board", "status: review   # set from the board");
    defer gpa.free(want2);
    try testing.expectEqualStrings(want2, b2);
    const b3 = try f.read("T-0003-crlf.md");
    defer gpa.free(b3);
    try testing.expectEqualStrings("---\r\nid: T-0003\r\nstatus: done\r\npriority: P3\r\n---\r\n# CRLF task\r\n\r\nLine one.\r\n", b3);
    // Lists, removal and the body.
    _ = try f.store.update(1, .{ .labels = &.{ "docs", "agent", "v1" }, .assignee = @as(?[]const u8, null), .body = "# Write the docs\n\nNew body.\n" }, .user);
    const b1 = try f.read("T-0001-write-the-docs.md");
    defer gpa.free(b1);
    try testing.expectEqualStrings("---\nid: T-0001\ntitle: Write the docs\nstatus: ready\npriority: P1\nlabels: [docs, agent, v1]\ndue: 2026-11-01\ncreated: 2026-10-20T09:00:00Z\n---\n# Write the docs\n\nNew body.\n", b1);
    const v = f.store.view();
    defer f.store.release(v);
    try testing.expectEqual(Status.review, v.get(2).?.status);
    try testing.expect(v.get(1).?.assignee == null);
    try testing.expectError(error.TaskNotFound, f.store.update(999, .{ .status = .done }, .user));
}

test "agent_patch_makes_changeset vs whitelisted_field_autoapplies" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const agent: TaskStore.WriteVia = .{ .agent = .{ .run = .zero } };
    // Status and claim are applied directly.
    try testing.expectEqual(TaskStore.Outcome.applied, try f.store.update(6, .{ .status = .in_progress, .claimed_by = @as(?[]const u8, "run-1") }, agent));
    try testing.expectEqual(@as(usize, 0), f.changes.reqs.items.len);
    {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expectEqualStrings("run-1", v.get(6).?.claimed_by.?);
    }
    // Anything else waits for review, and the file is unchanged.
    const out = try f.store.update(6, .{ .title = "Renamed by an agent", .status = .review }, agent);
    try testing.expectEqual(@as(u64, 101), out.changeset);
    try testing.expectEqualStrings(".zigguro/tasks/T-0006-unknown-props.md", f.changes.reqs.items[0].path);
    try testing.expect(std.mem.indexOf(u8, f.changes.reqs.items[0].after.?, "title: Renamed by an agent") != null);
    try testing.expectEqualStrings("Update task T-0006 (status, title)", f.changes.reqs.items[0].summary);
    const v = f.store.view();
    defer f.store.release(v);
    try testing.expectEqualStrings("Unknown properties", v.get(6).?.title);
    // Agent-created tasks are proposed too.
    const c = try f.store.create(.{ .title = "From an agent" }, agent);
    try testing.expectEqual(@as(u64, 102), c.outcome.changeset);
    try testing.expectEqualStrings(".zigguro/tasks/T-0020-from-an-agent.md", f.changes.reqs.items[1].path);
}

test "create, editor writes, delete to trash" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const c = try f.store.create(.{ .title = "New task", .status = .ready, .priority = 1, .labels = &.{"docs"}, .depends_on = &.{1}, .body = "Details." }, .user);
    try testing.expectEqual(@as(u32, 20), c.id);
    const b = try f.read("T-0020-new-task.md");
    defer gpa.free(b);
    try testing.expectEqualStrings("---\nid: T-0020\ntitle: New task\nstatus: ready\npriority: P1\nlabels:\n  - docs\ndepends_on:\n  - T-0001\ncreated: 2026-10-23T12:00:00Z\n---\n# New task\n\nDetails.", b);
    try testing.expectEqual(@as(u32, 21), ids.loadNext(io, f.store.state));
    try testing.expectError(error.InvalidTask, f.store.create(.{ .title = "  " }, .user));
    // A file open in the editor gets the change there.
    f.store.o.documents = .{ .ctx = &f.docs, .apply = FakeDocs.apply };
    f.docs.open_path = ".zigguro/tasks/T-0020-new-task.md";
    _ = try f.store.update(20, .{ .status = .done }, .user);
    try testing.expectEqual(@as(u32, 1), f.docs.applied);
    {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expectEqual(Status.done, v.get(20).?.status);
    }
    const unchanged = try f.read("T-0020-new-task.md");
    defer gpa.free(unchanged);
    try testing.expectEqualStrings(b, unchanged);
    // Delete moves the file to the trash.
    _ = try f.store.delete(20, .user);
    {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expect(v.get(20) == null);
    }
    const trashed = try f.tmp.dir.readFileAlloc(io, ".zigguro/tasks/.trash/T-0020-new-task.md", gpa, .limited(1 << 16));
    gpa.free(trashed);
    // Deleted ids are not reused.
    const c2 = try f.store.create(.{ .title = "Next" }, .user);
    try testing.expectEqual(@as(u32, 21), c2.id);
}

const Recorder = struct {
    evs: std.ArrayList(events.TaskEvent) = .empty,
    fn on(ctx: *anyopaque, ev: events.TaskEvent, _: *const @import("view.zig").TasksView) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.evs.append(gpa, ev) catch {};
    }
};

test "events: status, claims, external edits, unblocked" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    var rec: Recorder = .{};
    defer rec.evs.deinit(gpa);
    const lid = try f.store.subscribe(.{ .ctx = &rec, .f = Recorder.on });
    _ = try f.store.update(14, .{ .claimed_by = @as(?[]const u8, null), .status = .ready }, .user);
    try testing.expectEqual(@as(usize, 2), rec.evs.items.len);
    try testing.expectEqual(events.Kind.status_changed, rec.evs.items[0].kind);
    try testing.expectEqual(@as(?Status, .in_progress), rec.evs.items[0].from);
    try testing.expectEqual(events.Kind.released, rec.evs.items[1].kind);
    rec.evs.clearRetainingCapacity();
    // T-0013 waits for T-0001 (ready) and T-0004 (done): finishing
    // T-0001, edited outside the app, unblocks it.
    const p = ".zigguro/tasks/T-0001-write-the-docs.md";
    const old = try f.read("T-0001-write-the-docs.md");
    defer gpa.free(old);
    const new = try std.mem.replaceOwned(u8, gpa, old, "status: ready", "status: done");
    defer gpa.free(new);
    try f.tmp.dir.writeFile(io, .{ .sub_path = p, .data = new });
    try f.store.fileChanged(".zigguro\\tasks\\T-0001-write-the-docs.md");
    try testing.expectEqual(@as(usize, 2), rec.evs.items.len);
    try testing.expectEqual(events.TaskEvent{ .id = 1, .kind = .status_changed, .from = .ready, .to = .done }, rec.evs.items[0]);
    try testing.expectEqual(events.TaskEvent{ .id = 13, .kind = .unblocked, .to = .ready }, rec.evs.items[1]);
    // Files elsewhere are ignored; a removed file is a deletion.
    try f.store.fileChanged("docs/T-0001.md");
    try f.tmp.dir.deleteFile(io, ".zigguro/tasks/T-0016-heading-title.md");
    try f.store.fileChanged(".zigguro/tasks/T-0016-heading-title.md");
    try testing.expectEqual(events.Kind.deleted, rec.evs.items[rec.evs.items.len - 1].kind);
    f.store.unsubscribe(lid);
    _ = try f.store.create(.{ .title = "Quiet" }, .user);
    try testing.expectEqual(@as(usize, 3), rec.evs.items.len);
}

test "queries over the store" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const v = f.store.view();
    defer f.store.release(v);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const q = try query.parseQuery(arena.allocator(), "status:ready -blocked:true sort:priority");
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    try query.evalQueryAt(v, &q, f.store.today(), &out, gpa);
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(gpa);
    for (out.items) |i| try got.append(gpa, v.tasks[i].id);
    // T-0001 (P1) first; T-0012 depends on itself and T-0013 on T-0001.
    try testing.expectEqualSlices(u32, &.{ 1, 6, 15, 0 }, got.items);
}

test "tagging_on_create: tasks keep their project" {
    var f: Fx = undefined;
    try f.init(.{});
    defer f.deinit();
    const c = try f.store.create(.{ .title = "Outline", .project = "book" }, .user);
    const b = try f.read("T-0020-outline.md");
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "\nproject: book\n") != null);
    {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expectEqualStrings("book", v.get(c.id).?.project.?);
    }
    _ = try f.store.update(c.id, .{ .project = @as(?[]const u8, null) }, .user);
    const v = f.store.view();
    defer f.store.release(v);
    try testing.expect(v.get(c.id).?.project == null);
}
