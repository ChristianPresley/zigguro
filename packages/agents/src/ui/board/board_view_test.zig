//! The task board in a headless window over a real store with 30 tasks
//! in a temporary workspace.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const board_view = @import("board_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const tasks = zg_agents.tasks;
const TaskBoard = board_view.TaskBoard;

const statuses = [_][]const u8{ "backlog", "ready", "in_progress", "review", "done" };

const Starts = struct {
    started: ?tasks.TaskId = null,
    fn start(ctx: *anyopaque, id: tasks.TaskId) void {
        const s: *Starts = @ptrCast(@alignCast(ctx));
        s.started = id;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    store: *tasks.TaskStore,
    b: *TaskBoard,
    t: *TestApp,
    starts: Starts = .{},

    fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .store = undefined, .b = undefined, .t = undefined };
        try f.tmp.dir.createDirPath(io, ".zigguro/tasks");
        var name: [64]u8 = undefined;
        var body: [512]u8 = undefined;
        for (1..31) |i| {
            const n = try std.fmt.bufPrint(&name, ".zigguro/tasks/T-{d:0>4}-task-{d}.md", .{ i, i });
            const st = if (i == 2) "ready" else statuses[i % statuses.len];
            const data = try std.fmt.bufPrint(&body, "---\nid: T-{d:0>4}\ntitle: Task number {d}\nstatus: {s}\npriority: P{d}\n{s}{s}{s}---\n# Task number {d}\n\nBody of {d}.\n", .{
                i,                                                                                          i,                                                           st,                                           i % 4,
                if (i % 3 == 0) "assignee: agent:coder\n" else if (i % 5 == 0) "assignee: alice\n" else "", if (i % 4 == 0) "labels: [docs, ui, perf, extra]\n" else "", if (i == 2) "depends_on: [T-0001]\n" else "", i,
                i,
            });
            try f.tmp.dir.writeFile(io, .{ .sub_path = n, .data = data });
        }
        f.store = try tasks.TaskStore.open(gpa, io, f.tmp.dir, .{ .clock = .{ .nowRealMs = fixedNow } });
        f.b = try TaskBoard.init(gpa, .{ .store = f.store, .start_agent = .{ .ctx = &f.starts, .f = Starts.start }, .agents = &.{ "coder", "writer" } });
        f.t = try TestApp.init(gpa, .{ .root = .of(f.b), .size = .{ .w = 1800, .h = 1200 } });
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.b.deinit();
        f.store.close();
        f.tmp.cleanup();
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn sem(f: *Fx) ![]u8 {
        return f.t.semanticsSnapshot(gpa);
    }

    fn read(f: *Fx, id: u32) ![]u8 {
        var buf: [64]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, ".zigguro/tasks/T-{d:0>4}-task-{d}.md", .{ id, id });
        return f.tmp.dir.readFileAlloc(io, p, gpa, .limited(1 << 16));
    }

    fn focusBoard(f: *Fx) !void {
        const n = f.t.find(.{ .name = "Task board" }) orelse return error.NotFound;
        f.t.win.setFocus(n, true);
    }

    fn statusOf(f: *Fx, id: u32) tasks.Status {
        const v = f.store.view();
        defer f.store.release(v);
        return v.get(id).?.status;
    }
};

/// 2026-10-23 12:00:00 UTC.
fn fixedNow(_: ?*anyopaque) i64 {
    return 1_792_756_800_000;
}

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing {s} in\n{s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

test "board, list and table with 30 tasks" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "list \"Backlog, 6 tasks\"");
        try expectHas(s, "list \"Ready, 7 tasks\"");
        try expectHas(s, "list \"Done, 6 tasks\"");
        // A card says what it is; blocked and agent assignments show.
        try expectHas(s, "T-0002 Task number 2, Ready, P2, blocked");
        try expectHas(s, "T-0003 Task number 3, Review, P3, assigned to agent:coder");
    }
    f.b.setMode(.list);
    f.settle();
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "group \"Ready (7)\"");
    }
    f.b.setMode(.table);
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "task-table" }) != null);
    try testing.expectEqual(@as(u64, 30), f.b.table.t.source.rowCount());
    // The filter applies to every mode.
    f.b.query_field.setText("assignee:agent:*") catch {};
    f.b.setQuery("assignee:agent:*");
    f.settle();
    try testing.expectEqual(@as(u64, 10), f.b.table.t.source.rowCount());
    f.b.setQuery("status:");
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "task-query-error" }) != null);
}

test "keyboard: navigate, move across and reorder, open the editor" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.focusBoard();
    // The cursor starts on the first backlog card: by priority, then id.
    try testing.expectEqual(@as(?tasks.TaskId, 20), f.b.cursor);
    f.t.press(.arrow_right, .{});
    f.settle();
    try testing.expectEqual(@as(?tasks.TaskId, 16), f.b.cursor);
    const id = f.b.cursor.?;
    const before = try f.read(id);
    defer gpa.free(before);
    f.t.press(.arrow_right, .{ .alt = true });
    f.settle();
    try testing.expectEqual(tasks.Status.in_progress, f.statusOf(id));
    // Only the status line changed.
    const after = try f.read(id);
    defer gpa.free(after);
    const want = try std.mem.replaceOwned(u8, gpa, before, "status: ready", "status: in_progress");
    defer gpa.free(want);
    try testing.expectEqualStrings(want, after);
    // Reorder down: the card gets a rank.
    f.t.press(.arrow_down, .{ .alt = true });
    f.settle();
    {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expect(v.get(id).?.rank != null);
    }
    f.t.press(.enter, .{});
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "task-editor" }) != null);
    // S starts an agent on the cursor's task.
    f.t.press(.key_s, .{});
    f.settle();
    try testing.expectEqual(@as(?tasks.TaskId, id), f.starts.started);
}

test "drag and keyboard moves write the same bytes" {
    // Keyboard: Alt+Left takes T-0004 from Done to Blocked.
    var kb_bytes: []u8 = undefined;
    {
        var f: Fx = undefined;
        try f.init();
        defer f.deinit();
        try f.focusBoard();
        f.b.cursor = 4;
        f.t.press(.arrow_left, .{ .alt = true });
        f.settle();
        try testing.expectEqual(tasks.Status.blocked, f.statusOf(4));
        kb_bytes = try f.read(4);
    }
    defer gpa.free(kb_bytes);
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    // Drag T-0004 onto the empty Blocked column.
    const col = try f.t.rectOf(.{ .role = .list, .name_contains = "Blocked" });
    try f.t.drag(.{ .role = .listitem, .name_contains = "T-0004 " }, .{ .x = col.x + col.w / 2, .y = col.y + 60 });
    f.settle();
    try testing.expectEqual(tasks.Status.blocked, f.statusOf(4));
    const drag_bytes = try f.read(4);
    defer gpa.free(drag_bytes);
    try testing.expectEqualStrings(kb_bytes, drag_bytes);
}

test "moving blocked work asks first; delete and undo" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.focusBoard();
    // T-0002 waits for T-0001 (ready).
    f.b.cursor = 2;
    f.t.press(.arrow_right, .{ .alt = true });
    f.settle();
    try testing.expectEqual(tasks.Status.ready, f.statusOf(2));
    try testing.expect(f.b.confirm != null);
    try f.t.click(.{ .role = .button, .name = "Move anyway" });
    f.settle();
    try testing.expectEqual(tasks.Status.in_progress, f.statusOf(2));
    // Delete to the trash and back.
    f.b.cursor = 7;
    try f.focusBoard();
    f.t.press(.delete, .{});
    f.settle();
    {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expect(v.get(7) == null);
    }
    try f.t.click(.{ .role = .button, .name = "Undo" });
    f.settle();
    {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expect(v.get(7) != null);
    }
}

test "new task, assign and the editor form" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.focusBoard();
    f.t.press(.key_n, .{});
    f.settle();
    f.b.new_field.setText("Brand new") catch {};
    f.b.create(f.b.new_field.slice());
    f.settle();
    try testing.expectEqual(@as(?tasks.TaskId, 31), f.b.cursor);
    f.b.startAssign();
    f.settle();
    try f.t.click(.{ .role = .button, .name = "agent:writer" });
    f.settle();
    {
        const v = f.store.view();
        defer f.store.release(v);
        try testing.expectEqualStrings("agent:writer", v.get(31).?.assignee.?);
    }
    f.b.openEditor(31);
    f.settle();
    const e = f.b.editor.?;
    e.labels.setText("docs, ui") catch {};
    e.due.setText("2026-11-02") catch {};
    e.depends.setText("T-0001, tasknumber10") catch {};
    f.settle();
    // Typing a title searches; picking one replaces the word.
    try testing.expect(f.t.find(.{ .role = .button, .name = "T-0010 Task number 10" }) != null);
    e.addDependency(10);
    try testing.expectEqualStrings("T-0001, T-0010", e.depends.slice());
    e.priority = 0;
    f.settle();
    try f.t.click(.{ .role = .button, .name = "Save" });
    f.settle();
    const v = f.store.view();
    defer f.store.release(v);
    const t = v.get(31).?;
    try testing.expectEqual(@as(u2, 0), t.priority);
    try testing.expectEqualSlices(u32, &.{ 1, 10 }, t.depends_on);
    try testing.expectEqual(@as(u5, 2), t.due.?.d);
    try testing.expectEqualStrings("ui", t.labels[1]);
    e.due.setText("tomorrow") catch {};
    e.save();
    try testing.expect(e.problem != null);
}
