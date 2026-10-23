//! Task events (E13.F03.S01.T01): what changed between two views, for
//! task triggers (F02), Mission Control (F01) and the board. Delivered
//! after the store's lock is released, on the thread that made the
//! change; UI listeners forward to the UI thread themselves.

const std = @import("std");
const task_mod = @import("task.zig");
const view_mod = @import("view.zig");
const deps = @import("deps.zig");

const Allocator = std.mem.Allocator;
const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const Status = task_mod.Status;
const TasksView = view_mod.TasksView;

pub const Kind = enum { created, status_changed, assigned, updated, deleted, unblocked, claimed, released };

pub const TaskEvent = struct {
    id: TaskId,
    kind: Kind,
    from: ?Status = null,
    to: ?Status = null,
};

pub const Listener = struct {
    ctx: *anyopaque,
    /// `view` is the view after the change (valid during the call).
    f: *const fn (ctx: *anyopaque, ev: TaskEvent, view: *const TasksView) void,
};

pub const ListenerId = u32;

pub const Listeners = struct {
    list: std.ArrayList(struct { id: ListenerId, l: Listener }) = .empty,
    plain: std.ArrayList(Listener) = .empty,
    next: ListenerId = 1,

    pub fn add(ls: *Listeners, gpa: Allocator, l: Listener) !ListenerId {
        const id = ls.next;
        try ls.list.append(gpa, .{ .id = id, .l = l });
        errdefer _ = ls.list.pop();
        try ls.plain.append(gpa, l);
        ls.next += 1;
        return id;
    }

    pub fn remove(ls: *Listeners, id: ListenerId) void {
        for (ls.list.items, 0..) |e, i| if (e.id == id) {
            _ = ls.list.orderedRemove(i);
            _ = ls.plain.orderedRemove(i);
            return;
        };
    }

    pub fn items(ls: *const Listeners) []const Listener {
        return ls.plain.items;
    }

    pub fn deinit(ls: *Listeners, gpa: Allocator) void {
        ls.list.deinit(gpa);
        ls.plain.deinit(gpa);
    }
};

/// Appends the events that turn `old` into `new`, by id order.
pub fn diff(gpa: Allocator, old: *const TasksView, new: *const TasksView, out: *std.ArrayList(TaskEvent)) !void {
    var finished: std.ArrayList(TaskId) = .empty;
    defer finished.deinit(gpa);
    for (new.tasks, 0..) |*t, i| {
        if (t.id == 0) continue;
        if (i > 0 and new.tasks[i - 1].id == t.id) continue; // duplicate file
        const p = old.get(t.id) orelse {
            try out.append(gpa, .{ .id = t.id, .kind = .created, .to = t.status });
            continue;
        };
        var any = false;
        if (p.status != t.status) {
            try out.append(gpa, .{ .id = t.id, .kind = .status_changed, .from = p.status, .to = t.status });
            if (t.status == .done and p.status != .done) try finished.append(gpa, t.id);
            any = true;
        }
        if (!optEql(p.assignee, t.assignee)) {
            try out.append(gpa, .{ .id = t.id, .kind = .assigned, .to = t.status });
            any = true;
        }
        if (!optEql(p.claimed_by, t.claimed_by)) {
            try out.append(gpa, .{ .id = t.id, .kind = if (t.claimed_by != null) .claimed else .released, .to = t.status });
            any = true;
        }
        if (!any and !sameOther(p, t)) try out.append(gpa, .{ .id = t.id, .kind = .updated, .to = t.status });
    }
    for (old.tasks, 0..) |*t, i| {
        if (t.id == 0) continue;
        if (i > 0 and old.tasks[i - 1].id == t.id) continue;
        if (new.get(t.id) == null) try out.append(gpa, .{ .id = t.id, .kind = .deleted, .from = t.status });
    }
    var unblocked: std.ArrayList(TaskId) = .empty;
    defer unblocked.deinit(gpa);
    for (finished.items) |id| try deps.unblocked(gpa, old, new, id, &unblocked);
    std.mem.sort(TaskId, unblocked.items, {}, std.sort.asc(TaskId));
    for (unblocked.items, 0..) |id, i| {
        if (i > 0 and unblocked.items[i - 1] == id) continue;
        try out.append(gpa, .{ .id = id, .kind = .unblocked, .to = new.get(id).?.status });
    }
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn sameOther(a: *const Task, b: *const Task) bool {
    if (!std.mem.eql(u8, a.title, b.title) or a.priority != b.priority) return false;
    if (!std.mem.eql(TaskId, a.depends_on, b.depends_on)) return false;
    if (a.labels.len != b.labels.len) return false;
    for (a.labels, b.labels) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    if ((a.due == null) != (b.due == null)) return false;
    if (a.due) |d| if (!d.eql(b.due.?)) return false;
    if (!optEql(a.rank, b.rank) or !optEql(a.github, b.github) or !optEql(a.problem, b.problem)) return false;
    return std.mem.eql(u8, a.path, b.path);
}
