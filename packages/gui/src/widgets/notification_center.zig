//! The notification model behind toasts (E04.F05.S04.T02): every toast is
//! kept (the last 200) for the notification center, with unread counts,
//! auto-dismiss deadlines and do-not-disturb.
//!
//! Auto-dismiss: info and success after 8 s, warning after 12 s; error
//! and approval toasts are sticky. Do-not-disturb records everything but
//! pops up only errors and approvals. At most `max_visible` toasts show,
//! newest first; the rest wait in the center.

const std = @import("std");
const actions = @import("../input/actions.zig");

/// How a notification is presented.
pub const Severity = enum(u8) { info, success, warning, error_, approval };

/// A button on a toast.
pub const ToastAction = struct {
    label: []const u8,
    action: actions.ActionId,
    arg: ?[]const u8 = null,
    primary: bool = false,
};

/// A toast's content. Strings are copied.
pub const Toast = struct {
    severity: Severity = .info,
    title: []const u8,
    /// Shown under the title (plain text until Markdown bodies, E04.F06).
    body_md: []const u8 = "",
    actions: []const ToastAction = &.{},
    /// Null: none; NaN: indeterminate; else 0..1.
    progress: ?f32 = null,
    /// Groups the center ("Agent: refactor-auth").
    source: []const u8 = "",
    /// Overrides the severity's auto-dismiss delay.
    timeout_ms: ?u32 = null,
    sticky: bool = false,
};

/// Names a notification.
pub const ToastId = enum(u32) { none = 0, _ };

/// One kept notification.
pub const Entry = struct {
    id: ToastId,
    toast: Toast,
    arena: std.heap.ArenaAllocator,
    created_ms: u64,
    read: bool = false,
    /// Shown as a toast.
    popup: bool,
    /// When the popup hides on its own, or null (sticky).
    dismiss_at: ?u64,
};

/// See the module doc.
pub const NotificationCenter = struct {
    gpa: std.mem.Allocator,
    /// Oldest first.
    entries: std.ArrayList(*Entry) = .empty,
    next_id: u32 = 1,
    dnd: bool = false,
    /// The center is open: toasts hide meanwhile.
    center_open: bool = false,
    /// Bumped on every change (views repaint on it).
    generation: u64 = 0,

    /// How many notifications are kept.
    pub const max_kept = 200;
    /// How many toasts show at once.
    pub const max_visible = 3;

    /// An empty center.
    pub fn init(gpa: std.mem.Allocator) NotificationCenter {
        return .{ .gpa = gpa };
    }

    /// Frees every notification.
    pub fn deinit(nc: *NotificationCenter) void {
        for (nc.entries.items) |e| nc.freeEntry(e);
        nc.entries.deinit(nc.gpa);
    }

    fn freeEntry(nc: *NotificationCenter, e: *Entry) void {
        e.arena.deinit();
        nc.gpa.destroy(e);
    }

    /// The default auto-dismiss delay, or null for sticky severities.
    pub fn defaultTimeout(s: Severity) ?u32 {
        return switch (s) {
            .info, .success => 8000,
            .warning => 12000,
            .error_, .approval => null,
        };
    }

    fn deadline(t: Toast, now_ms: u64) ?u64 {
        if (t.sticky) return null;
        const ms = t.timeout_ms orelse defaultTimeout(t.severity) orelse return null;
        return now_ms + ms;
    }

    fn copyToast(a: std.mem.Allocator, t: Toast) !Toast {
        var c = t;
        c.title = try a.dupe(u8, t.title);
        c.body_md = try a.dupe(u8, t.body_md);
        c.source = try a.dupe(u8, t.source);
        const acts = try a.alloc(ToastAction, t.actions.len);
        for (t.actions, acts) |s, *d| d.* = .{
            .label = try a.dupe(u8, s.label),
            .action = try a.dupe(u8, s.action),
            .arg = if (s.arg) |x| try a.dupe(u8, x) else null,
            .primary = s.primary,
        };
        c.actions = acts;
        return c;
    }

    /// Records `t`; it pops up unless do-not-disturb holds it back.
    pub fn post(nc: *NotificationCenter, t: Toast, now_ms: u64) !ToastId {
        const e = try nc.gpa.create(Entry);
        errdefer nc.gpa.destroy(e);
        e.* = .{ .id = @enumFromInt(nc.next_id), .toast = undefined, .arena = .init(nc.gpa), .created_ms = now_ms, .popup = true, .dismiss_at = deadline(t, now_ms) };
        errdefer e.arena.deinit();
        e.toast = try copyToast(e.arena.allocator(), t);
        e.popup = !nc.dnd or t.severity == .error_ or t.severity == .approval;
        try nc.entries.append(nc.gpa, e);
        nc.next_id +%= 1;
        if (nc.next_id == 0) nc.next_id = 1;
        if (nc.entries.items.len > max_kept) nc.freeEntry(nc.entries.orderedRemove(0));
        nc.generation +%= 1;
        return e.id;
    }

    /// The entry for `id`, if still kept.
    pub fn get(nc: *NotificationCenter, id: ToastId) ?*Entry {
        for (nc.entries.items) |e| if (e.id == id) return e;
        return null;
    }

    /// Replaces a notification's content (progress updates). Its
    /// auto-dismiss restarts from `now_ms`.
    pub fn update(nc: *NotificationCenter, id: ToastId, t: Toast, now_ms: u64) !void {
        const e = nc.get(id) orelse return;
        var fresh: std.heap.ArenaAllocator = .init(nc.gpa);
        errdefer fresh.deinit();
        const c = try copyToast(fresh.allocator(), t);
        e.arena.deinit();
        e.arena = fresh;
        e.toast = c;
        if (e.popup) e.dismiss_at = deadline(t, now_ms);
        nc.generation +%= 1;
    }

    /// Hides the toast; it stays in the center.
    pub fn dismiss(nc: *NotificationCenter, id: ToastId) void {
        const e = nc.get(id) orelse return;
        if (!e.popup) return;
        e.popup = false;
        nc.generation +%= 1;
    }

    /// Removes a notification from the center too.
    pub fn remove(nc: *NotificationCenter, id: ToastId) void {
        for (nc.entries.items, 0..) |e, i| if (e.id == id) {
            nc.freeEntry(nc.entries.orderedRemove(i));
            nc.generation +%= 1;
            return;
        };
    }

    /// Removes every notification.
    pub fn clear(nc: *NotificationCenter) void {
        for (nc.entries.items) |e| nc.freeEntry(e);
        nc.entries.clearRetainingCapacity();
        nc.generation +%= 1;
    }

    /// Notifications not yet seen in the center.
    pub fn unread(nc: *const NotificationCenter) u32 {
        var n: u32 = 0;
        for (nc.entries.items) |e| n += @intFromBool(!e.read);
        return n;
    }

    /// Marks everything read (the center was opened).
    pub fn markAllRead(nc: *NotificationCenter) void {
        for (nc.entries.items) |e| e.read = true;
        nc.generation +%= 1;
    }

    /// Suppresses popups except errors and approvals while on.
    pub fn setDoNotDisturb(nc: *NotificationCenter, on: bool) void {
        nc.dnd = on;
        if (on) for (nc.entries.items) |e| {
            if (e.toast.severity != .error_ and e.toast.severity != .approval) e.popup = false;
        };
        nc.generation +%= 1;
    }

    /// The toasts to show, newest first (at most `max_visible`; none while
    /// the center is open).
    pub fn visible(nc: *NotificationCenter, out: *[max_visible]*Entry) []*Entry {
        var n: usize = 0;
        if (nc.center_open) return out[0..0];
        var i = nc.entries.items.len;
        while (i > 0 and n < max_visible) {
            i -= 1;
            const e = nc.entries.items[i];
            if (!e.popup) continue;
            out[n] = e;
            n += 1;
        }
        return out[0..n];
    }

    /// Hides popups whose deadline passed, except those `hovered` says
    /// the pointer is over (they get `grace_ms` more). Returns whether
    /// anything changed.
    pub fn tick(nc: *NotificationCenter, now_ms: u64, hovered: anytype, grace_ms: u64) bool {
        var changed = false;
        for (nc.entries.items) |e| {
            const at = e.dismiss_at orelse continue;
            if (!e.popup or at > now_ms) continue;
            if (hovered.isHovered(e)) {
                e.dismiss_at = now_ms + grace_ms;
                continue;
            }
            e.popup = false;
            changed = true;
        }
        if (changed) nc.generation +%= 1;
        return changed;
    }

    /// The earliest auto-dismiss deadline of a showing toast.
    pub fn nextDeadline(nc: *const NotificationCenter) ?u64 {
        var best: ?u64 = null;
        for (nc.entries.items) |e| {
            if (!e.popup) continue;
            const at = e.dismiss_at orelse continue;
            if (best == null or at < best.?) best = at;
        }
        return best;
    }
};

const testing = std.testing;
const NoHover = struct {
    fn isHovered(_: NoHover, _: *Entry) bool {
        return false;
    }
};

test "notifications: auto dismiss by severity, errors are sticky" {
    var nc: NotificationCenter = .init(testing.allocator);
    defer nc.deinit();
    const a = try nc.post(.{ .title = "Saved" }, 0);
    const b = try nc.post(.{ .severity = .warning, .title = "Slow" }, 0);
    const c = try nc.post(.{ .severity = .error_, .title = "Failed" }, 0);
    try testing.expectEqual(@as(?u64, 8000), nc.nextDeadline());
    try testing.expect(nc.tick(8000, NoHover{}, 0));
    try testing.expect(!nc.get(a).?.popup);
    try testing.expect(nc.get(b).?.popup);
    _ = nc.tick(12000, NoHover{}, 0);
    try testing.expect(!nc.get(b).?.popup);
    _ = nc.tick(1_000_000, NoHover{}, 0);
    try testing.expect(nc.get(c).?.popup);
    try testing.expectEqual(@as(u32, 3), nc.unread());
    nc.markAllRead();
    try testing.expectEqual(@as(u32, 0), nc.unread());
}

test "notifications: at most three visible, newest first; do not disturb" {
    var nc: NotificationCenter = .init(testing.allocator);
    defer nc.deinit();
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        _ = try nc.post(.{ .title = try std.fmt.bufPrint(&buf, "t{d}", .{i}) }, 0);
    }
    var out: [NotificationCenter.max_visible]*Entry = undefined;
    const vis = nc.visible(&out);
    try testing.expectEqual(@as(usize, 3), vis.len);
    try testing.expectEqualStrings("t4", vis[0].toast.title);
    nc.setDoNotDisturb(true);
    try testing.expectEqual(@as(usize, 0), nc.visible(&out).len);
    _ = try nc.post(.{ .title = "quiet" }, 0);
    _ = try nc.post(.{ .severity = .approval, .title = "approve?" }, 0);
    _ = try nc.post(.{ .severity = .error_, .title = "broke" }, 0);
    try testing.expectEqual(@as(usize, 2), nc.visible(&out).len);
    try testing.expectEqual(@as(u32, 8), nc.unread());
}

test "notifications: update restarts the timer, keep the last 200" {
    var nc: NotificationCenter = .init(testing.allocator);
    defer nc.deinit();
    const id = try nc.post(.{ .title = "Indexing", .progress = 0.1, .actions = &.{.{ .label = "Cancel", .action = "index.cancel" }} }, 0);
    try nc.update(id, .{ .title = "Indexing", .progress = 0.5 }, 5000);
    try testing.expectEqual(@as(?u64, 13000), nc.get(id).?.dismiss_at);
    try testing.expectEqual(@as(?f32, 0.5), nc.get(id).?.toast.progress);
    for (0..250) |_| _ = try nc.post(.{ .title = "x" }, 0);
    try testing.expectEqual(@as(usize, NotificationCenter.max_kept), nc.entries.items.len);
    try testing.expect(nc.get(id) == null);
}
