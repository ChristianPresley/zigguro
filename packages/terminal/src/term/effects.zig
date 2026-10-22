//! Effects: everything the terminal asks its owner (the session and view on
//! the UI thread) to do, from ringing the bell to writing the clipboard.
//! Effects queue in a bounded list whose payloads live in an arena that is
//! reset when the owner drains the queue.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringTerm = @import("../vt/params.zig").StringTerm;
const ModeId = @import("modes.zig").ModeId;

/// OSC 52 selection targets (`c p q s 0-7`).
pub const ClipTargets = packed struct(u12) {
    c: bool = false,
    p: bool = false,
    q: bool = false,
    s: bool = false,
    cut: u8 = 0,
};

/// A clipboard request; `data` is decoded bytes, null for a read.
pub const ClipReq = struct {
    targets: ClipTargets,
    data: ?[]const u8,
    term: StringTerm,
};

/// A desktop notification.
pub const Notify = struct { title: []const u8, body: []const u8 };

/// Taskbar progress (OSC 9;4).
pub const Progress = struct {
    state: enum { remove, normal, err, indeterminate, paused },
    percent: u8,
};

/// A working-directory report.
pub const Cwd = struct {
    path: []const u8,
    host: []const u8,
    /// The host is neither empty, `localhost` nor this machine.
    remote: bool,
};

/// One effect. Slices point into the queue arena.
pub const Effect = union(enum) {
    bell,
    title_changed,
    icon_changed,
    cwd: Cwd,
    clipboard_write: ClipReq,
    /// Answer with `Terminal.answerClipboardRead`.
    clipboard_read: ClipReq,
    notify: Notify,
    progress: Progress,
    palette_changed,
    cursor_shape_changed,
    pointer_shape: []const u8,
    /// A mode changed (sync output, mouse tracking, screen switch, ...).
    mode: struct { id: ModeId, on: bool },
    user_var: struct { key: []const u8, value: []const u8 },
    /// Replies were dropped by the reply limiter (sent once per burst).
    replies_dropped,
};

/// Bounded effect queue.
pub const EffectQueue = struct {
    /// Maximum queued effects; later ones are dropped and counted.
    pub const cap = 1024;

    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Effect) = .empty,
    dropped: u32 = 0,

    /// An empty queue.
    pub fn init(gpa: Allocator) EffectQueue {
        return .{ .arena = .init(gpa) };
    }

    /// Frees everything.
    pub fn deinit(q: *EffectQueue) void {
        q.items.deinit(q.arena.child_allocator);
        q.arena.deinit();
    }

    /// Copies `s` into the arena.
    pub fn dupe(q: *EffectQueue, s: []const u8) Allocator.Error![]const u8 {
        return q.arena.allocator().dupe(u8, s);
    }

    /// Queues `e` (payloads must already be in the arena).
    pub fn push(q: *EffectQueue, e: Effect) void {
        if (q.items.items.len >= cap) {
            q.dropped += 1;
            return;
        }
        q.items.append(q.arena.child_allocator, e) catch {
            q.dropped += 1;
        };
    }

    /// The queued effects, oldest first; valid until `clear`.
    pub fn pending(q: *const EffectQueue) []const Effect {
        return q.items.items;
    }

    /// Empties the queue and frees payloads.
    pub fn clear(q: *EffectQueue) void {
        q.items.clearRetainingCapacity();
        _ = q.arena.reset(.retain_capacity);
    }
};

test "queue bounds and payloads" {
    var q: EffectQueue = .init(std.testing.allocator);
    defer q.deinit();
    q.push(.{ .pointer_shape = try q.dupe("text") });
    for (0..EffectQueue.cap + 5) |_| q.push(.bell);
    try std.testing.expectEqual(@as(usize, EffectQueue.cap), q.pending().len);
    try std.testing.expectEqual(@as(u32, 6), q.dropped);
    try std.testing.expectEqualStrings("text", q.pending()[0].pointer_shape);
    q.clear();
    try std.testing.expectEqual(@as(usize, 0), q.pending().len);
}
