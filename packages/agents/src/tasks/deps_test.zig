//! Dependency cycles, unblocking and duplicate ids.

const std = @import("std");
const task_mod = @import("task.zig");
const view_mod = @import("view.zig");
const deps = @import("deps.zig");
const events = @import("events.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Task = task_mod.Task;
const TasksView = view_mod.TasksView;

fn t(comptime id: u32, comptime status: task_mod.Status, comptime on: []const u32) Task {
    return .{ .id = id, .path = std.fmt.comptimePrint("T-{d:0>4}.md", .{id}), .title = "t", .status = status, .depends_on = on };
}

test "cycles: rings, self loops, chains and missing ids" {
    const tasks = [_]Task{
        t(1, .ready, &.{2}), t(2, .ready, &.{3}), t(3, .ready, &.{1}), // ring
        t(4, .ready, &.{4}), // self
        t(5, .ready, &.{ 1, 6 }), t(6, .ready, &.{}), // into the ring, not on it
        t(7, .ready, &.{99}), // missing
        t(8, .ready, &.{9}), t(9, .ready, &.{ 8, 10 }), t(10, .ready, &.{9}), // two rings sharing 9
    };
    const v = try TasksView.build(gpa, &tasks, 1);
    defer v.destroy();
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 8, 9, 10 }, v.cycles);
    try testing.expect(v.inCycle(4) and !v.inCycle(5));
    // Missing dependencies block.
    try testing.expect(v.isBlocked(v.get(7).?));
    var blk: std.ArrayList(u32) = .empty;
    defer blk.deinit(gpa);
    try v.blockedBy(5, &blk, gpa);
    try testing.expectEqualSlices(u32, &.{ 1, 6 }, blk.items);
}

test "cycles: a long chain does not recurse" {
    var tasks: [5000]Task = undefined;
    var dep: [5000][1]u32 = undefined;
    for (&tasks, &dep, 0..) |*x, *d, i| {
        d[0] = @intCast(i + 2);
        x.* = .{ .id = @intCast(i + 1), .path = "T.md", .title = "t", .status = .ready, .depends_on = if (i + 1 < tasks.len) d else &.{} };
    }
    const v = try TasksView.build(gpa, &tasks, 1);
    defer v.destroy();
    try testing.expectEqual(@as(usize, 0), v.cycles.len);
}

test "unblocked: only tasks whose last open dependency finished" {
    const before = [_]Task{ t(1, .in_progress, &.{}), t(2, .ready, &.{}), t(3, .ready, &.{1}), t(4, .ready, &.{ 1, 2 }), t(5, .done, &.{1}) };
    const after = [_]Task{ t(1, .done, &.{}), t(2, .ready, &.{}), t(3, .ready, &.{1}), t(4, .ready, &.{ 1, 2 }), t(5, .done, &.{1}) };
    const a = try TasksView.build(gpa, &before, 1);
    defer a.destroy();
    const b = try TasksView.build(gpa, &after, 2);
    defer b.destroy();
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    try deps.unblocked(gpa, a, b, 1, &out);
    // 4 still waits for 2; 5 is finished already.
    try testing.expectEqualSlices(u32, &.{3}, out.items);
}

test "duplicate ids are reported once and diff ignores the copy" {
    const tasks = [_]Task{
        .{ .id = 2, .path = "b.md", .title = "B", .status = .ready },
        .{ .id = 2, .path = "a.md", .title = "A", .status = .ready },
        .{ .id = 2, .path = "c.md", .title = "C", .status = .ready },
        .{ .id = 0, .path = "x.md", .title = "x", .problem = "missing or invalid id" },
        .{ .id = 1, .path = "one.md", .title = "1" },
    };
    const v = try TasksView.build(gpa, &tasks, 1);
    defer v.destroy();
    try testing.expectEqualSlices(u32, &.{2}, v.duplicates);
    try testing.expectEqualStrings("a.md", v.get(2).?.path);
    try testing.expectEqual(@as(u32, 0), v.tasks[v.tasks.len - 1].id);
    try testing.expectEqual(@as(u32, 2), v.maxId());
    var evs: std.ArrayList(events.TaskEvent) = .empty;
    defer evs.deinit(gpa);
    const empty = try TasksView.build(gpa, &.{}, 0);
    defer empty.destroy();
    try events.diff(gpa, empty, v, &evs);
    try testing.expectEqual(@as(usize, 2), evs.items.len);
}
