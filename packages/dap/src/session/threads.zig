//! A session's threads (E07.F06.S02.T01): which are stopped and why, and
//! which one has the focus. Applies `stopped`, `continued` and `thread`
//! events and `threads` responses; the session guards it with its lock.
//!
//! Focus rules: a `stopped` event focuses its thread unless it carries
//! `preserveFocusHint`, or no thread has the focus yet. When the focused
//! thread exits the focus moves to the first stopped thread, else to none.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Why a thread stopped. Strings are the table's.
pub const StopReason = struct {
    reason: []const u8,
    description: ?[]const u8 = null,
    text: ?[]const u8 = null,
    hit_breakpoint_ids: []const i64 = &.{},
    preserve_focus: bool = false,
};

pub const ThreadState = struct {
    id: i64,
    name: []const u8,
    stopped: bool = false,
    stop_reason: ?StopReason = null,
};

/// A `stopped` event body, already decoded.
pub const Stopped = struct {
    reason: []const u8,
    description: ?[]const u8 = null,
    text: ?[]const u8 = null,
    thread_id: ?i64 = null,
    all_threads_stopped: bool = false,
    preserve_focus: bool = false,
    hit_breakpoint_ids: []const i64 = &.{},
};

/// A thread of a `threads` response.
pub const NamedThread = struct { id: i64, name: []const u8 };

pub const Table = struct {
    /// Names and stop reasons; reset with the table.
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(ThreadState) = .empty,
    current: ?i64 = null,
    /// The last stop covered every thread (threads listed later are
    /// stopped too).
    all_stopped: bool = false,
    last_reason: ?StopReason = null,

    pub fn init(gpa: Allocator) Table {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(t: *Table) void {
        t.arena.deinit();
        t.* = undefined;
    }

    pub fn clear(t: *Table) void {
        _ = t.arena.reset(.retain_capacity);
        t.list = .empty;
        t.current = null;
        t.all_stopped = false;
        t.last_reason = null;
    }

    pub fn find(t: *Table, id: i64) ?*ThreadState {
        for (t.list.items) |*th| if (th.id == id) return th;
        return null;
    }

    fn ensure(t: *Table, id: i64) Allocator.Error!*ThreadState {
        if (t.find(id)) |th| return th;
        const a = t.arena.allocator();
        try t.list.append(a, .{ .id = id, .name = try std.fmt.allocPrint(a, "Thread {d}", .{id}) });
        return &t.list.items[t.list.items.len - 1];
    }

    pub fn anyStopped(t: *const Table) bool {
        for (t.list.items) |th| if (th.stopped) return true;
        return false;
    }

    /// Applies a `stopped` event.
    pub fn applyStopped(t: *Table, ev: Stopped) Allocator.Error!void {
        const a = t.arena.allocator();
        const reason: StopReason = .{
            .reason = try a.dupe(u8, ev.reason),
            .description = if (ev.description) |s| try a.dupe(u8, s) else null,
            .text = if (ev.text) |s| try a.dupe(u8, s) else null,
            .hit_breakpoint_ids = try a.dupe(i64, ev.hit_breakpoint_ids),
            .preserve_focus = ev.preserve_focus,
        };
        t.last_reason = reason;
        t.all_stopped = ev.all_threads_stopped;
        if (ev.thread_id) |id| {
            const th = try t.ensure(id);
            th.stopped = true;
            th.stop_reason = reason;
        }
        if (ev.all_threads_stopped) for (t.list.items) |*th| {
            th.stopped = true;
            if (th.stop_reason == null or ev.thread_id == null or th.id != ev.thread_id.?) th.stop_reason = reason;
        };
        if (ev.thread_id) |id| {
            if (!ev.preserve_focus or t.current == null) t.current = id;
        } else if (t.current == null) {
            for (t.list.items) |th| if (th.stopped) {
                t.current = th.id;
                break;
            };
        }
    }

    /// Applies a `continued` event or an optimistic resume. `all` is
    /// `allThreadsContinued` (true when absent).
    pub fn applyContinued(t: *Table, thread_id: ?i64, all: bool) void {
        if (all or thread_id == null) {
            for (t.list.items) |*th| {
                th.stopped = false;
                th.stop_reason = null;
            }
            t.all_stopped = false;
        } else if (t.find(thread_id.?)) |th| {
            th.stopped = false;
            th.stop_reason = null;
        }
    }

    /// Applies a `thread` event.
    pub fn applyThreadEvent(t: *Table, id: i64, reason: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, reason, "exited")) {
            for (t.list.items, 0..) |th, i| if (th.id == id) {
                _ = t.list.orderedRemove(i);
                break;
            };
            if (t.current == id) {
                t.current = null;
                for (t.list.items) |th| if (th.stopped) {
                    t.current = th.id;
                    break;
                };
            }
            return;
        }
        const th = try t.ensure(id);
        if (t.all_stopped and th.stop_reason == null) {
            th.stopped = true;
            th.stop_reason = t.last_reason;
        }
    }

    /// Replaces the list with a `threads` response, keeping what is known
    /// of each thread's state.
    pub fn applyThreads(t: *Table, threads: []const NamedThread) Allocator.Error!void {
        const a = t.arena.allocator();
        var next: std.ArrayList(ThreadState) = try .initCapacity(a, threads.len);
        for (threads) |nt| {
            var st: ThreadState = .{ .id = nt.id, .name = try a.dupe(u8, nt.name) };
            if (t.find(nt.id)) |old| {
                st.stopped = old.stopped;
                st.stop_reason = old.stop_reason;
            } else if (t.all_stopped) {
                st.stopped = true;
                st.stop_reason = t.last_reason;
            }
            next.appendAssumeCapacity(st);
        }
        t.list = next;
        if (t.current) |c| if (t.find(c) == null) {
            t.current = null;
            for (t.list.items) |th| if (th.stopped) {
                t.current = th.id;
                break;
            };
        };
    }

    /// A copy of the thread states for undoing an optimistic resume.
    pub fn snapshot(t: *const Table, gpa: Allocator) Allocator.Error![]ThreadState {
        return gpa.dupe(ThreadState, t.list.items);
    }

    /// Puts back the stop states of `snap` (threads still present).
    pub fn restore(t: *Table, snap: []const ThreadState, all_stopped: bool) void {
        for (snap) |old| if (t.find(old.id)) |th| {
            th.stopped = old.stopped;
            th.stop_reason = old.stop_reason;
        };
        t.all_stopped = all_stopped;
    }
};
