//! The workspace event bus: `WorkspaceEvent`s with the PathStore `Change`s
//! that caused them, fanned out to subscribed listeners.
//!
//! Listeners are called synchronously on the publishing task (the scanner's
//! writer or the watch pipeline), in subscription order. They must be cheap:
//! enqueue work, or (for UI listeners) post a `UiMsg` through the runtime.

const std = @import("std");
const RootId = @import("../ids.zig").RootId;
const FileId = @import("../ids.zig").FileId;
const Change = @import("../paths/path_store.zig").Change;

/// An event from the workspace.
pub const WorkspaceEvent = union(enum) {
    /// The path store published a new generation; the details are the changes.
    paths_changed: struct { generation: u64, added: u32 = 0, removed: u32 = 0, renamed: u32 = 0, modified: u32 = 0 },
    /// Scan progress for a root.
    scan_progress: struct { root: RootId, dirs: u32, files: u32, done: bool },
    /// An ignore file changed under `dir`.
    ignore_changed: struct { root: RootId, dir: FileId },
    /// A root must be (or was) rescanned.
    rescan: struct { root: RootId, reason: enum { overflow, watch_limit, root_replaced } },
    /// Indexer progress.
    index_progress: struct { indexed: u32, total: u32, bytes: u64, done: bool },
    /// Roots were added or removed.
    roots_changed: struct { count: u16 },

    /// Counts changes by kind into a `paths_changed` event.
    pub fn pathsChanged(generation: u64, changes: []const Change) WorkspaceEvent {
        var ev: WorkspaceEvent = .{ .paths_changed = .{ .generation = generation } };
        for (changes) |c| switch (c.what) {
            .added => ev.paths_changed.added += 1,
            .removed => ev.paths_changed.removed += 1,
            .renamed => ev.paths_changed.renamed += 1,
            .modified => ev.paths_changed.modified += 1,
        };
        return ev;
    }
};

/// A subscriber.
pub const EventListener = struct {
    /// Passed back to `onEvent`.
    ctx: *anyopaque,
    /// Called for every event; `changes` is empty except for `paths_changed`.
    onEvent: *const fn (ctx: *anyopaque, ev: *const WorkspaceEvent, changes: []const Change) void,
    /// Where the listener expects to run. `.ui` listeners are still called
    /// on the publishing task and must forward to the UI themselves.
    thread: enum { ui, worker } = .worker,
};

/// Handle returned by `subscribe`.
pub const ListenerId = enum(u32) { _ };

/// The listener list. Thread-safe.
pub const Bus = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    lock: std.Io.Mutex = .init,
    listeners: std.ArrayList(Slot) = .empty,
    next_id: u32 = 0,

    const Slot = struct { id: ListenerId, l: EventListener };

    /// An empty bus.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Bus {
        return .{ .gpa = gpa, .io = io };
    }

    /// Frees the bus.
    pub fn deinit(b: *Bus) void {
        b.listeners.deinit(b.gpa);
    }

    /// Adds a listener.
    pub fn subscribe(b: *Bus, l: EventListener) !ListenerId {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        const id: ListenerId = @enumFromInt(b.next_id);
        b.next_id += 1;
        try b.listeners.append(b.gpa, .{ .id = id, .l = l });
        return id;
    }

    /// Removes a listener.
    pub fn unsubscribe(b: *Bus, id: ListenerId) void {
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        for (b.listeners.items, 0..) |s, i| if (s.id == id) {
            _ = b.listeners.orderedRemove(i);
            return;
        };
    }

    /// Delivers `ev` to every listener (worker listeners first).
    pub fn publish(b: *Bus, ev: WorkspaceEvent, changes: []const Change) void {
        var copy: [32]Slot = undefined;
        b.lock.lockUncancelable(b.io);
        const n = @min(copy.len, b.listeners.items.len);
        @memcpy(copy[0..n], b.listeners.items[0..n]);
        b.lock.unlock(b.io);
        inline for (.{ .worker, .ui }) |which| {
            for (copy[0..n]) |s| if (s.l.thread == which) s.l.onEvent(s.l.ctx, &ev, changes);
        }
    }
};

test "events: bus delivers worker listeners before UI listeners" {
    var bus: Bus = .init(std.testing.allocator, std.testing.io);
    defer bus.deinit();
    const Rec = struct {
        log: std.ArrayList(u8) = .empty,
        fn on(ctx: *anyopaque, ev: *const WorkspaceEvent, _: []const Change) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.log.append(std.testing.allocator, if (ev.* == .rescan) 'r' else 'p') catch {};
        }
    };
    var ui: Rec = .{};
    defer ui.log.deinit(std.testing.allocator);
    var w: Rec = .{};
    defer w.log.deinit(std.testing.allocator);
    _ = try bus.subscribe(.{ .ctx = &ui, .onEvent = Rec.on, .thread = .ui });
    const wid = try bus.subscribe(.{ .ctx = &w, .onEvent = Rec.on });
    const changes = [_]Change{ .{ .id = .none, .what = .added }, .{ .id = .none, .what = .removed }, .{ .id = .none, .what = .added } };
    const ev = WorkspaceEvent.pathsChanged(3, &changes);
    try std.testing.expectEqual(@as(u32, 2), ev.paths_changed.added);
    bus.publish(ev, &changes);
    bus.unsubscribe(wid);
    bus.publish(.{ .rescan = .{ .root = .of(0), .reason = .overflow } }, &.{});
    try std.testing.expectEqualStrings("pr", ui.log.items);
    try std.testing.expectEqualStrings("p", w.log.items);
}
