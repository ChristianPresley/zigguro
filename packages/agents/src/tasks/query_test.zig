//! The query language over a fixed board.

const std = @import("std");
const task_mod = @import("task.zig");
const view_mod = @import("view.zig");
const query = @import("query.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Task = task_mod.Task;
const Date = task_mod.Date;

fn date(y: i32, m: u4, d: u5) Date {
    return .{ .y = y, .m = m, .d = d };
}

const board = [_]Task{
    .{ .id = 1, .path = "T-0001.md", .title = "Write the docs", .status = .ready, .priority = 1, .assignee = "alice", .labels = &.{ "docs", "agent" }, .due = date(2026, 11, 1), .created = "2026-10-05" },
    .{ .id = 2, .path = "T-0002.md", .title = "Fix the parser", .status = .in_progress, .priority = 0, .assignee = "agent:coder", .labels = &.{"bug"}, .due = date(2026, 10, 20), .created = "2026-10-01", .claimed_by = "run-1" },
    .{ .id = 3, .path = "T-0003.md", .title = "Review layout", .status = .review, .priority = 2, .assignee = "bob", .labels = &.{"ui"} },
    .{ .id = 4, .path = "T-0004.md", .title = "Ship release", .status = .done, .priority = 1, .labels = &.{"release"}, .due = date(2026, 10, 1) },
    .{ .id = 5, .path = "T-0005.md", .title = "Plan sprint", .status = .backlog, .priority = 3, .due = date(2026, 10, 23) },
    .{ .id = 6, .path = "T-0006.md", .title = "Blocked thing", .status = .ready, .priority = 2, .assignee = "alice", .labels = &.{"docs"}, .depends_on = &.{3} },
    .{ .id = 7, .path = "T-0007.md", .title = "Cancelled idea", .status = .cancelled, .priority = 3, .due = date(2026, 9, 1) },
    .{ .id = 8, .path = "T-0008.md", .title = "Agent research notes", .status = .ready, .priority = 2, .assignee = "agent:researcher", .labels = &.{"research"}, .depends_on = &.{4} },
};

const Case = struct { []const u8, []const u32 };

const cases = [_]Case{
    .{ "", &.{ 1, 2, 3, 4, 5, 6, 7, 8 } },
    .{ "status:ready", &.{ 1, 6, 8 } },
    .{ "status:ready,review", &.{ 1, 3, 6, 8 } },
    .{ "STATUS:In-Progress", &.{2} },
    .{ "-status:done", &.{ 1, 2, 3, 5, 6, 7, 8 } },
    .{ "label:docs", &.{ 1, 6 } },
    .{ "label:DOCS", &.{ 1, 6 } },
    .{ "-label:docs", &.{ 2, 3, 4, 5, 7, 8 } },
    .{ "assignee:alice", &.{ 1, 6 } },
    .{ "assignee:ALICE", &.{ 1, 6 } },
    .{ "assignee:agent:*", &.{ 2, 8 } },
    .{ "assignee:*", &.{ 1, 2, 3, 6, 8 } },
    .{ "-assignee:*", &.{ 4, 5, 7 } },
    .{ "priority:P1", &.{ 1, 4 } },
    .{ "priority:>=P1", &.{ 1, 2, 4 } },
    .{ "priority:>P1", &.{2} },
    .{ "priority:<=P2", &.{ 3, 5, 6, 7, 8 } },
    .{ "priority:<p2", &.{ 5, 7 } },
    .{ "due:<2026-11-01", &.{ 2, 4, 5, 7 } },
    .{ "due:<=2026-11-01", &.{ 1, 2, 4, 5, 7 } },
    .{ "due:2026-10-20", &.{2} },
    .{ "due:today", &.{5} },
    .{ "due:>today", &.{1} },
    .{ "due:overdue", &.{2} },
    .{ "blocked:true", &.{6} },
    .{ "blocked:false", &.{ 1, 2, 3, 4, 5, 7, 8 } },
    .{ "claimed:yes", &.{2} },
    .{ "claimed:false", &.{ 1, 3, 4, 5, 6, 7, 8 } },
    .{ "text:docs", &.{1} },
    .{ "text:\"the docs\"", &.{1} },
    .{ "\"fix the\"", &.{2} },
    .{ "parser", &.{2} },
    .{ "-parser", &.{ 1, 3, 4, 5, 6, 7, 8 } },
    .{ "id:T-0003", &.{3} },
    .{ "id:3", &.{3} },
    .{ "status:ready label:docs", &.{ 1, 6 } },
    .{ "status:ready -blocked:true assignee:agent:*", &.{8} },
    .{ "status:ready sort:priority", &.{ 1, 6, 8 } },
    .{ "sort:-priority", &.{ 5, 7, 3, 6, 8, 1, 4, 2 } },
    .{ "sort:due", &.{ 7, 4, 2, 5, 1, 3, 6, 8 } },
    .{ "sort:title", &.{ 8, 6, 7, 2, 5, 3, 4, 1 } },
    .{ "sort:created", &.{ 3, 4, 5, 6, 7, 8, 2, 1 } },
    .{ "  status:ready\tsort:-id  ", &.{ 8, 6, 1 } },
};

fn ids(v: *const view_mod.TasksView, idx: []const u32) ![]u32 {
    const out = try gpa.alloc(u32, idx.len);
    for (out, idx) |*o, i| o.* = v.tasks[i].id;
    return out;
}

test "query table" {
    const v = try view_mod.TasksView.build(gpa, &board, 1);
    defer v.destroy();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    for (cases) |c| {
        const q = query.parseQuery(arena.allocator(), c[0]) catch |e| {
            std.debug.print("query {s}: {t}\n", .{ c[0], e });
            return e;
        };
        out.clearRetainingCapacity();
        try query.evalQueryAt(v, &q, date(2026, 10, 23), &out, gpa);
        const got = try ids(v, out.items);
        defer gpa.free(got);
        testing.expectEqualSlices(u32, c[1], got) catch |e| {
            std.debug.print("query {s}\n", .{c[0]});
            return e;
        };
    }
}

test "invalid queries" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const bad = [_][]const u8{ "status:someday", "status:", "priority:P9", "priority:high", "due:tomorrow", "blocked:maybe", "sort:size", "foo:bar", "text:\"open", "id:x" };
    for (bad) |b| testing.expectError(error.InvalidQuery, query.parseQuery(arena.allocator(), b)) catch |e| {
        std.debug.print("query {s}\n", .{b});
        return e;
    };
}

test "date terms need today; blocked needs a view" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t = &board[4];
    try testing.expect(!query.matches(&try query.parseQuery(a, "due:today"), t, null, null));
    try testing.expect(query.matches(&try query.parseQuery(a, "due:today"), t, null, date(2026, 10, 23)));
    try testing.expect(query.matches(&try query.parseQuery(a, "-blocked:true"), &board[5], null, null));
    try testing.expectEqual(std.math.Order.lt, query.cmpDate(date(2025, 12, 31), date(2026, 1, 1)));
}
