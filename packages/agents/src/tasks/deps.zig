//! The dependency graph over `depends_on` (E13.F03.S01.T01): cycles
//! (Tarjan's strongly connected components, iterative) and the tasks a
//! change unblocked. Cycles are reported, never enforced.

const std = @import("std");
const task_mod = @import("task.zig");
const view_mod = @import("view.zig");

const Allocator = std.mem.Allocator;
const TaskId = task_mod.TaskId;
const TasksView = view_mod.TasksView;

/// Sorted ids of tasks on a cycle (a self-dependency counts).
pub fn cycles(a: Allocator, v: *const TasksView) ![]const TaskId {
    const n = v.tasks.len;
    if (n == 0) return &.{};
    const none = std.math.maxInt(u32);
    const index = try a.alloc(u32, n);
    defer a.free(index);
    const low = try a.alloc(u32, n);
    defer a.free(low);
    const on_stack = try a.alloc(bool, n);
    defer a.free(on_stack);
    @memset(index, none);
    @memset(on_stack, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a);
    // Call frames: node and the next edge to look at.
    const Frame = struct { node: u32, edge: u32 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(a);
    var out: std.ArrayList(TaskId) = .empty;
    var counter: u32 = 0;

    for (0..n) |root| {
        if (index[root] != none) continue;
        try frames.append(a, .{ .node = @intCast(root), .edge = 0 });
        index[root] = counter;
        low[root] = counter;
        counter += 1;
        try stack.append(a, @intCast(root));
        on_stack[root] = true;
        while (frames.items.len > 0) {
            const f = &frames.items[frames.items.len - 1];
            const t = &v.tasks[f.node];
            if (f.edge < t.depends_on.len) {
                const dep = t.depends_on[f.edge];
                f.edge += 1;
                const w: u32 = @intCast(v.indexOf(dep) orelse continue);
                if (index[w] == none) {
                    index[w] = counter;
                    low[w] = counter;
                    counter += 1;
                    try stack.append(a, w);
                    on_stack[w] = true;
                    try frames.append(a, .{ .node = w, .edge = 0 });
                } else if (on_stack[w]) {
                    low[f.node] = @min(low[f.node], index[w]);
                }
                continue;
            }
            // Done with this node.
            const node = f.node;
            _ = frames.pop();
            if (frames.items.len > 0) {
                const parent = frames.items[frames.items.len - 1].node;
                low[parent] = @min(low[parent], low[node]);
            }
            if (low[node] == index[node]) {
                // Pop the component.
                const start = std.mem.lastIndexOfScalar(u32, stack.items, node).?;
                const comp = stack.items[start..];
                const self_loop = comp.len == 1 and std.mem.indexOfScalar(TaskId, v.tasks[node].depends_on, v.tasks[node].id) != null;
                if (comp.len > 1 or self_loop) for (comp) |m| try out.append(a, v.tasks[m].id);
                for (comp) |m| on_stack[m] = false;
                stack.shrinkRetainingCapacity(start);
            }
        }
    }
    std.mem.sort(TaskId, out.items, {}, std.sort.asc(TaskId));
    return out.items;
}

/// Tasks depending on `done_id` whose dependencies are now all finished
/// in `after` but were not in `before`. Finished tasks are left out.
pub fn unblocked(gpa: Allocator, before: *const TasksView, after: *const TasksView, done_id: TaskId, out: *std.ArrayList(TaskId)) !void {
    for (after.tasks) |*t| {
        if (t.id == 0 or t.status.finished() or std.mem.indexOfScalar(TaskId, t.depends_on, done_id) == null) continue;
        if (after.isBlocked(t)) continue;
        const prev = before.get(t.id) orelse continue;
        if (before.isBlocked(prev)) try out.append(gpa, t.id);
    }
}
