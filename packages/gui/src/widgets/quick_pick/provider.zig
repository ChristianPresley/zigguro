//! QuickPick items, providers and the thread-safe result sink
//! (E04.F05.S04.T01).
//!
//! A provider owns one prefix ("" for the default, ">" for commands, "@"
//! for symbols...). It either hands over a static item list, which the
//! picker scores on the UI thread with its matcher (the fast path for up to
//! a few thousand items, such as commands), or answers queries on a worker:
//! `query` pushes scored items into a `ResultSink` as it finds them and
//! returns when done or when `cancel` turns true.

const std = @import("std");

/// One row of a QuickPick.
pub const QpItem = struct {
    /// Stable id (MRU and multi-select key).
    id: u64,
    label: []const u8,
    /// Muted text after the label.
    description: []const u8 = "",
    /// A second, muted line.
    detail: []const u8 = "",
    /// Shown as keycaps on the right ("Ctrl+Shift+P").
    keybinding: ?[]const u8 = null,
    /// Group label, shown on the first row of each run of a group.
    group: ?[]const u8 = null,
    /// Matched byte ranges of `label` (set by the matcher).
    highlights: []const [2]u32 = &.{},
    /// Higher ranks first (set by the matcher).
    score: i32 = 0,
    /// Initially checked in a multi-select picker.
    picked: bool = false,
};

/// Answers one prefix's queries.
pub const Provider = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable,

    /// The provider's operations and settings.
    pub const VTable = struct {
        /// The text that routes input to this provider ("" for the default).
        prefix: []const u8 = "",
        /// Shown in the empty input.
        placeholder: []const u8 = "",
        /// Static items, scored on the UI thread. Set this or `query`.
        items: ?*const fn (ptr: ?*anyopaque) []const QpItem = null,
        /// Runs on a worker for the query (prefix removed). Push results,
        /// return when finished or when `cancel` is set.
        query: ?*const fn (ptr: ?*anyopaque, q: []const u8, sink: *ResultSink, cancel: *const std.atomic.Value(bool)) void = null,
        /// The user accepted `items` (empty with free text), with Ctrl held
        /// when `alt`. Runs on the UI thread; the strings are valid only
        /// for the call.
        accept: *const fn (ptr: ?*anyopaque, items: []const QpItem, free_text: ?[]const u8, alt: bool) void,
    };

    /// The routing prefix.
    pub fn prefix(p: Provider) []const u8 {
        return p.vtable.prefix;
    }
};

/// Receives a query's results from a worker. Thread-safe.
pub const ResultSink = struct {
    gpa: std.mem.Allocator,
    /// For the mutex; null when everything runs on one thread.
    io: ?std.Io,
    mutex: std.Io.Mutex = .init,
    cancel: *const std.atomic.Value(bool),
    pending: Batch = .{},
    /// Called (without the lock) after each push and on `done`.
    notify: Notify,

    /// Wakes the UI side.
    pub const Notify = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque) void,
    };

    fn lock(s: *ResultSink) void {
        if (s.io) |io| s.mutex.lockUncancelable(io);
    }

    fn unlock(s: *ResultSink) void {
        if (s.io) |io| s.mutex.unlock(io);
    }

    /// Adds results (copied). Ignored once the query is cancelled.
    pub fn push(s: *ResultSink, items: []const QpItem) void {
        if (s.cancel.load(.acquire) or items.len == 0) return;
        s.lock();
        s.pending.append(s.gpa, items) catch {};
        s.unlock();
        s.notify.f(s.notify.ctx);
    }

    /// Marks the query finished.
    pub fn done(s: *ResultSink) void {
        s.lock();
        s.pending.finished = true;
        s.unlock();
        s.notify.f(s.notify.ctx);
    }

    /// UI side: takes what arrived since the last call.
    pub fn take(s: *ResultSink) Batch {
        s.lock();
        defer s.unlock();
        const b = s.pending;
        s.pending = .{ .finished = b.finished };
        return b;
    }

    /// Frees results nobody took.
    pub fn deinit(s: *ResultSink) void {
        s.pending.deinit(s.gpa);
    }
};

/// Results moved from a worker to the UI thread, with their strings.
pub const Batch = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    items: std.ArrayList(QpItem) = .empty,
    finished: bool = false,

    /// Copies `items` and their strings in.
    pub fn append(b: *Batch, gpa: std.mem.Allocator, items: []const QpItem) !void {
        if (b.arena == null) {
            const a = try gpa.create(std.heap.ArenaAllocator);
            a.* = .init(gpa);
            b.arena = a;
        }
        const a = b.arena.?.allocator();
        try b.items.ensureUnusedCapacity(gpa, items.len);
        for (items) |it| {
            var c = it;
            c.label = try a.dupe(u8, it.label);
            c.description = try a.dupe(u8, it.description);
            c.detail = try a.dupe(u8, it.detail);
            c.keybinding = if (it.keybinding) |k| try a.dupe(u8, k) else null;
            c.group = if (it.group) |g| try a.dupe(u8, g) else null;
            c.highlights = try a.dupe([2]u32, it.highlights);
            b.items.appendAssumeCapacity(c);
        }
    }

    /// Frees the items and their strings.
    pub fn deinit(b: *Batch, gpa: std.mem.Allocator) void {
        b.items.deinit(gpa);
        if (b.arena) |a| {
            a.deinit();
            gpa.destroy(a);
        }
        b.* = .{};
    }
};

test "sink copies, batches and stops after cancel" {
    const gpa = std.testing.allocator;
    var cancel: std.atomic.Value(bool) = .init(false);
    var wakes: u32 = 0;
    const W = struct {
        fn f(ctx: *anyopaque) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    var s: ResultSink = .{ .gpa = gpa, .io = std.testing.io, .cancel = &cancel, .notify = .{ .ctx = &wakes, .f = W.f } };
    defer s.deinit();
    var label = [_]u8{ 'a', 'b' };
    s.push(&.{.{ .id = 1, .label = &label, .highlights = &.{.{ 0, 1 }} }});
    label[0] = 'x';
    var b = s.take();
    defer b.deinit(gpa);
    try std.testing.expectEqualStrings("ab", b.items.items[0].label);
    try std.testing.expect(!b.finished);
    cancel.store(true, .release);
    s.push(&.{.{ .id = 2, .label = "c" }});
    s.done();
    var b2 = s.take();
    defer b2.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), b2.items.items.len);
    try std.testing.expect(b2.finished);
    try std.testing.expectEqual(@as(u32, 2), wakes);
}
