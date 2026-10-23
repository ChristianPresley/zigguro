//! An immutable snapshot of the task board (E13.F03.S01.T01): tasks
//! sorted by id with per-status indexes, duplicate ids and dependency
//! cycles. Readers hold a reference (`TaskStore.view`/`release`) while the
//! store builds the next one.

const std = @import("std");
const task_mod = @import("task.zig");
const deps = @import("deps.zig");

const Allocator = std.mem.Allocator;
const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const Status = task_mod.Status;

pub const status_count = @typeInfo(Status).@"enum".fields.len;

pub const TasksView = struct {
    version: u64,
    /// By id; files without a valid id last, by path.
    tasks: []const Task,
    by_status: [status_count][]const u32,
    /// Ids used by more than one file.
    duplicates: []const TaskId,
    /// Ids on a dependency cycle, sorted.
    cycles: []const TaskId,
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(1),

    /// Copies `tasks` (any order) into a new view.
    pub fn build(gpa: Allocator, tasks: []const Task, version: u64) !*TasksView {
        const v = try gpa.create(TasksView);
        errdefer gpa.destroy(v);
        v.* = .{ .version = version, .tasks = &.{}, .by_status = @splat(&.{}), .duplicates = &.{}, .cycles = &.{}, .arena = .init(gpa) };
        errdefer v.arena.deinit();
        const a = v.arena.allocator();
        const list = try a.alloc(Task, tasks.len);
        for (list, tasks) |*d, *s| d.* = try s.clone(a);
        std.mem.sort(Task, list, {}, lessTask);
        v.tasks = list;
        var counts: [status_count]u32 = @splat(0);
        for (list) |t| counts[@intFromEnum(t.status)] += 1;
        var idx: [status_count][]u32 = undefined;
        for (&idx, counts) |*x, c| x.* = try a.alloc(u32, c);
        var fill: [status_count]u32 = @splat(0);
        for (list, 0..) |t, i| {
            const s = @intFromEnum(t.status);
            idx[s][fill[s]] = @intCast(i);
            fill[s] += 1;
        }
        for (&v.by_status, idx) |*d, x| d.* = x;
        var dups: std.ArrayList(TaskId) = .empty;
        var i: usize = 1;
        while (i < list.len) : (i += 1) {
            if (list[i].id != 0 and list[i].id == list[i - 1].id and (dups.items.len == 0 or dups.items[dups.items.len - 1] != list[i].id))
                try dups.append(a, list[i].id);
        }
        v.duplicates = dups.items;
        v.cycles = try deps.cycles(a, v);
        return v;
    }

    pub fn destroy(v: *TasksView) void {
        const gpa = v.arena.child_allocator;
        v.arena.deinit();
        gpa.destroy(v);
    }

    /// The first file with this id.
    pub fn get(v: *const TasksView, id: TaskId) ?*const Task {
        const i = v.indexOf(id) orelse return null;
        return &v.tasks[i];
    }

    pub fn indexOf(v: *const TasksView, id: TaskId) ?usize {
        if (id == 0) return null;
        const i = std.sort.lowerBound(Task, v.tasks, id, orderId);
        if (i < v.tasks.len and v.tasks[i].id == id) return i;
        return null;
    }

    pub fn byStatus(v: *const TasksView, s: Status) []const u32 {
        return v.by_status[@intFromEnum(s)];
    }

    /// Dependencies of `id` that are not done or cancelled (missing ones
    /// included).
    pub fn blockedBy(v: *const TasksView, id: TaskId, out: *std.ArrayList(TaskId), gpa: Allocator) !void {
        const t = v.get(id) orelse return;
        for (t.depends_on) |d| {
            const dt = v.get(d);
            if (dt == null or !dt.?.status.finished()) try out.append(gpa, d);
        }
    }

    pub fn isBlocked(v: *const TasksView, t: *const Task) bool {
        for (t.depends_on) |d| {
            const dt = v.get(d) orelse return true;
            if (!dt.status.finished()) return true;
        }
        return false;
    }

    /// Ready, every dependency finished, not claimed.
    pub fn readyToClaim(v: *const TasksView, id: TaskId) bool {
        const t = v.get(id) orelse return false;
        return t.status == .ready and t.claimed_by == null and !v.isBlocked(t);
    }

    pub fn inCycle(v: *const TasksView, id: TaskId) bool {
        return std.sort.binarySearch(TaskId, v.cycles, id, orderU32) != null;
    }

    pub fn isDuplicate(v: *const TasksView, id: TaskId) bool {
        return std.mem.indexOfScalar(TaskId, v.duplicates, id) != null;
    }

    /// The largest id in use.
    pub fn maxId(v: *const TasksView) TaskId {
        var m: TaskId = 0;
        for (v.tasks) |t| m = @max(m, t.id);
        return m;
    }
};

fn lessTask(_: void, a: Task, b: Task) bool {
    // Id 0 sorts last.
    const ka: u64 = if (a.id == 0) std.math.maxInt(u64) else a.id;
    const kb: u64 = if (b.id == 0) std.math.maxInt(u64) else b.id;
    if (ka != kb) return ka < kb;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn orderId(id: TaskId, t: Task) std.math.Order {
    if (t.id == 0) return .lt;
    return std.math.order(id, t.id);
}

fn orderU32(a: TaskId, b: TaskId) std.math.Order {
    return std.math.order(a, b);
}
