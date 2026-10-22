//! Dynamic notes for the model (E10.F07.S02.T01): todo changes, newly
//! applicable rules, files changed on disk, budget warnings and mode
//! changes. They are queued from any thread and drained by the assembler
//! into the newest user message as `<system-reminder>` text blocks, after
//! that message's tool results, so the cached prefix is never disturbed.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Why a reminder was queued.
pub const ReminderKind = enum { todo, rule_loaded, file_changed, budget, mode, other };

/// One queued reminder (text owned by the queue until drained).
pub const Reminder = struct { kind: ReminderKind, text: []const u8 };

/// A thread-safe queue of reminders.
pub const ReminderQueue = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    items: std.ArrayList(Reminder) = .empty,

    pub fn init(gpa: Allocator, io: Io) ReminderQueue {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(q: *ReminderQueue) void {
        for (q.items.items) |r| q.gpa.free(r.text);
        q.items.deinit(q.gpa);
    }

    /// Queues a copy of `text`. A later `todo` or `mode` reminder replaces
    /// a queued one of the same kind (only the latest state matters). Drops
    /// the reminder when out of memory.
    pub fn push(q: *ReminderQueue, kind: ReminderKind, text: []const u8) void {
        const copy = q.gpa.dupe(u8, text) catch return;
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        if (kind == .todo or kind == .mode) for (q.items.items) |*r| if (r.kind == kind) {
            q.gpa.free(r.text);
            r.text = copy;
            return;
        };
        q.items.append(q.gpa, .{ .kind = kind, .text = copy }) catch q.gpa.free(copy);
    }

    /// Number of queued reminders.
    pub fn len(q: *ReminderQueue) usize {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        return q.items.items.len;
    }

    /// Moves every reminder into `arena` (as wrapped text) and empties the queue.
    pub fn drain(q: *ReminderQueue, arena: Allocator) Allocator.Error![]const []const u8 {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        const out = try arena.alloc([]const u8, q.items.items.len);
        for (q.items.items, out) |r, *o| o.* = try wrap(arena, r.text);
        for (q.items.items) |r| q.gpa.free(r.text);
        q.items.clearRetainingCapacity();
        return out;
    }
};

/// `<system-reminder>\n<text>\n</system-reminder>`.
pub fn wrap(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "<system-reminder>\n{s}\n</system-reminder>", .{std.mem.trim(u8, text, "\n")});
}

test "queue replaces state reminders and drains in order" {
    var q: ReminderQueue = .init(std.testing.allocator, std.testing.io);
    defer q.deinit();
    q.push(.todo, "1 of 3 done");
    q.push(.file_changed, "a.zig changed");
    q.push(.todo, "2 of 3 done");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const out = try q.drain(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("<system-reminder>\n2 of 3 done\n</system-reminder>", out[0]);
    try std.testing.expectEqual(@as(usize, 0), q.len());
}
