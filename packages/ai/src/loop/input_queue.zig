//! User inputs waiting for an agent. Inputs are copied on submit (any
//! thread) and owned by the queue until the turn task takes them.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Mode = enum {
    /// Processed after the current turn ends.
    queue,
    /// Appended after the next tool results; like `queue` when no tools run.
    steer,
    /// Cancels the current turn, then queued.
    interrupt,
};

pub const Source = enum { ui, cli, subagent_parent, hook, schedule };

/// What a user (or a hook, schedule or parent agent) sends an agent.
pub const UserInput = struct {
    text: []const u8,
    mode: Mode = .queue,
    source: Source = .ui,
};

pub const InputId = u64;

/// An input owned by the queue.
pub const Owned = struct {
    id: InputId,
    text: []u8,
    mode: Mode,
    source: Source,

    pub fn free(o: Owned, gpa: Allocator) void {
        gpa.free(o.text);
    }
};

/// Bounded FIFO; the caller provides locking.
pub const InputQueue = struct {
    items: std.ArrayList(Owned) = .empty,
    next_id: InputId = 1,
    capacity: usize = 64,

    pub fn deinit(q: *InputQueue, gpa: Allocator) void {
        q.clear(gpa);
        q.items.deinit(gpa);
    }

    /// Copies `in`; `error.Busy` when full.
    pub fn push(q: *InputQueue, gpa: Allocator, in: UserInput) error{ Busy, OutOfMemory }!InputId {
        if (q.items.items.len >= q.capacity) return error.Busy;
        const text = try gpa.dupe(u8, in.text);
        errdefer gpa.free(text);
        const id = q.next_id;
        try q.items.append(gpa, .{ .id = id, .text = text, .mode = in.mode, .source = in.source });
        q.next_id += 1;
        return id;
    }

    pub fn pop(q: *InputQueue) ?Owned {
        if (q.items.items.len == 0) return null;
        return q.items.orderedRemove(0);
    }

    /// Moves every item of `from` to the end of `q`.
    pub fn takeAll(q: *InputQueue, gpa: Allocator, from: *InputQueue) Allocator.Error!void {
        try q.items.appendSlice(gpa, from.items.items);
        from.items.clearRetainingCapacity();
    }

    pub fn len(q: *const InputQueue) usize {
        return q.items.items.len;
    }

    pub fn clear(q: *InputQueue, gpa: Allocator) void {
        for (q.items.items) |o| o.free(gpa);
        q.items.clearRetainingCapacity();
    }
};

test "fifo and capacity" {
    const gpa = std.testing.allocator;
    var q: InputQueue = .{ .capacity = 2 };
    defer q.deinit(gpa);
    _ = try q.push(gpa, .{ .text = "a" });
    _ = try q.push(gpa, .{ .text = "b" });
    try std.testing.expectError(error.Busy, q.push(gpa, .{ .text = "c" }));
    const a = q.pop().?;
    defer a.free(gpa);
    try std.testing.expectEqualStrings("a", a.text);
    try std.testing.expectEqual(@as(usize, 1), q.len());
}
