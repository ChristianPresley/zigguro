//! The `depends_on` graph of a task: every label must name a task, and
//! no task may depend on itself through any chain. Checked before a run
//! starts, so a bad graph fails at once with the cycle or the missing
//! label in the message. Running the graph is `TaskRunner`'s job.

const std = @import("std");
const Task = @import("Task.zig");
const TaskList = @import("TaskList.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ UnknownTask, Cycle, OutOfMemory };

/// Checks the graph below `root`. On `UnknownTask` or `Cycle`, `message`
/// says which (`dependency cycle: a -> b -> a`), allocated in `arena`.
pub fn check(arena: Allocator, list: *const TaskList, root: []const u8, message: *[]const u8) Error!void {
    var state: std.StringHashMapUnmanaged(Mark) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try visit(arena, list, root, null, &state, &stack, message);
}

const Mark = enum { open, done };

fn visit(
    arena: Allocator,
    list: *const TaskList,
    label: []const u8,
    parent: ?[]const u8,
    state: *std.StringHashMapUnmanaged(Mark),
    stack: *std.ArrayList([]const u8),
    message: *[]const u8,
) Error!void {
    if (state.get(label)) |m| switch (m) {
        .done => return,
        .open => {
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(arena, "dependency cycle: ");
            const from = for (stack.items, 0..) |l, i| {
                if (std.mem.eql(u8, l, label)) break i;
            } else 0;
            for (stack.items[from..]) |l| try text.print(arena, "{s} -> ", .{l});
            try text.appendSlice(arena, label);
            message.* = text.items;
            return error.Cycle;
        },
    };
    const t = list.byLabel(label) orelse {
        message.* = if (parent) |p|
            try std.fmt.allocPrint(arena, "task '{s}' depends on '{s}', which is not a task", .{ p, label })
        else
            try std.fmt.allocPrint(arena, "no task is called '{s}'", .{label});
        return error.UnknownTask;
    };
    try state.put(arena, label, .open);
    try stack.append(arena, label);
    for (t.depends_on) |d| try visit(arena, list, d, label, state, stack, message);
    _ = stack.pop();
    try state.put(arena, label, .done);
}

/// The tasks below `root` (itself included), each once, dependencies
/// first. The graph must have passed `check`.
pub fn order(arena: Allocator, list: *const TaskList, root: []const u8) Allocator.Error![]const *const Task {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(*const Task) = .empty;
    try post(arena, list, root, &seen, &out);
    return out.items;
}

fn post(arena: Allocator, list: *const TaskList, label: []const u8, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(*const Task)) Allocator.Error!void {
    if ((try seen.getOrPut(arena, label)).found_existing) return;
    const t = list.byLabel(label) orelse return;
    for (t.depends_on) |d| try post(arena, list, d, seen, out);
    try out.append(arena, t);
}
