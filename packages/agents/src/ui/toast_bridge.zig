//! The router's in-app side (E13.F01.S03.T01): a `ToastSink` that takes
//! notifications on the router's worker, queues copies, and on the UI
//! thread (`drain`, each frame or when woken) records them in zg_gui's
//! notification center, popping a toast when the router chose one. A
//! later notification for the same slot updates its entry. Toast buttons
//! run the action `agents.notification.activate` with the argument
//! "<key>\n<action id>"; `activateArg` splits it.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const notify = zg_agents.notify;
const Notification = notify.Notification;
const nc = zg_gui.w.notification_center;
const toast_w = zg_gui.w.toast_mod;

pub const activate_action = "agents.notification.activate";

const Item = struct {
    arena: std.heap.ArenaAllocator,
    n: Notification,
    slot: u32,
    show: bool,
};

pub const ToastBridge = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    queue: std.ArrayList(*Item) = .empty,
    /// The center entry for each router slot (UI thread only).
    ids: std.AutoHashMapUnmanaged(u32, nc.ToastId) = .empty,
    wake: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,

    pub fn init(gpa: Allocator, io: std.Io) ToastBridge {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(b: *ToastBridge) void {
        for (b.queue.items) |it| b.free(it);
        b.queue.deinit(b.gpa);
        b.ids.deinit(b.gpa);
    }

    pub fn sink(b: *ToastBridge) notify.ToastSink {
        return .{ .ctx = b, .deliver = deliver };
    }

    fn deliver(ctx: *anyopaque, n: *const Notification, slot: u32, show: bool) void {
        const b: *ToastBridge = @ptrCast(@alignCast(ctx));
        const it = b.gpa.create(Item) catch return;
        it.* = .{ .arena = .init(b.gpa), .n = undefined, .slot = slot, .show = show };
        it.n = copy(it.arena.allocator(), n.*) catch return b.free(it);
        b.mutex.lockUncancelable(b.io);
        const first = b.queue.items.len == 0;
        b.queue.append(b.gpa, it) catch {
            b.mutex.unlock(b.io);
            return b.free(it);
        };
        b.mutex.unlock(b.io);
        if (first) if (b.wake) |w| w.f(w.ctx);
    }

    /// UI thread: records what arrived since the last call.
    pub fn drain(b: *ToastBridge, app: *zg_gui.App) void {
        b.mutex.lockUncancelable(b.io);
        var batch = b.queue;
        b.queue = .empty;
        b.mutex.unlock(b.io);
        defer batch.deinit(b.gpa);
        for (batch.items) |it| {
            defer b.free(it);
            var arena: std.heap.ArenaAllocator = .init(b.gpa);
            defer arena.deinit();
            const t = toToast(arena.allocator(), &it.n) catch continue;
            if (b.ids.get(it.slot)) |id| {
                toast_w.updateToast(app, id, t);
                if (!it.show) toast_w.dismissToast(app, id);
                continue;
            }
            const id = toast_w.toast(app, t);
            if (id == .none) continue;
            // Recorded for the center; only toasts the router chose pop up.
            if (!it.show) toast_w.dismissToast(app, id);
            b.ids.put(b.gpa, it.slot, id) catch {};
        }
    }

    fn free(b: *ToastBridge, it: *Item) void {
        it.arena.deinit();
        b.gpa.destroy(it);
    }
};

fn copy(a: Allocator, n: Notification) Allocator.Error!Notification {
    var c = n;
    c.key = try a.dupe(u8, n.key);
    c.group = if (n.group) |g| try a.dupe(u8, g) else null;
    c.title = try a.dupe(u8, n.title);
    c.body = try a.dupe(u8, n.body);
    const acts = try a.alloc(notify.NotifyAction, n.actions.len);
    for (acts, n.actions) |*d, s| d.* = .{ .id = try a.dupe(u8, s.id), .label = try a.dupe(u8, s.label) };
    c.actions = acts;
    return c;
}

/// The zg_gui toast for `n` (strings in `a`).
pub fn toToast(a: Allocator, n: *const Notification) Allocator.Error!nc.Toast {
    const acts = try a.alloc(nc.ToastAction, n.actions.len);
    for (acts, n.actions, 0..) |*d, s, i| d.* = .{
        .label = s.label,
        .action = activate_action,
        .arg = try std.fmt.allocPrint(a, "{s}\n{s}", .{ n.key, s.id }),
        .primary = i == 0,
    };
    return .{
        .severity = switch (n.severity) {
            .info => .info,
            .success => .success,
            .warning => .warning,
            .error_ => .error_,
            .needs_input => .approval,
        },
        .title = n.title,
        .body_md = n.body,
        .actions = acts,
        .source = "Agents",
        .progress = if (n.progress) |p| if (p.total > 0) @as(f32, @floatFromInt(p.done)) / @as(f32, @floatFromInt(p.total)) else null else null,
    };
}

/// Splits a toast button's argument into the notification key and the
/// action id.
pub fn activateArg(arg: []const u8) ?struct { key: []const u8, action: []const u8 } {
    const nl = std.mem.lastIndexOfScalar(u8, arg, '\n') orelse return null;
    return .{ .key = arg[0..nl], .action = arg[nl + 1 ..] };
}

const testing = std.testing;

test "notifications reach the center; only chosen ones pop up" {
    const Empty = struct {
        pub fn build(_: *@This(), ui: *zg_gui.Ui) void {
            ui.text("agents", .{});
        }
    };
    var empty: Empty = .{};
    const t = try zg_gui.testing.TestApp.init(testing.allocator, .{ .root = .of(&empty) });
    defer t.deinit();
    var b: ToastBridge = .init(testing.allocator, testing.io);
    defer b.deinit();
    const s = b.sink();
    const acts = [_]notify.NotifyAction{ .{ .id = "open", .label = "Open" }, .{ .id = "deny", .label = "Deny" } };
    s.deliver(s.ctx, &.{ .key = "run:a", .severity = .needs_input, .title = "Lint needs input", .body = "Allow npm?", .actions = &acts }, 1, true);
    s.deliver(s.ctx, &.{ .key = "run:b", .severity = .success, .title = "Done: Build" }, 2, false);
    b.drain(&t.app);
    const center = &t.app.notifications;
    try testing.expectEqual(@as(usize, 2), center.entries.items.len);
    // The same slot updates its entry.
    s.deliver(s.ctx, &.{ .key = "run:a", .severity = .success, .title = "Done: Lint" }, 1, true);
    b.drain(&t.app);
    try testing.expectEqual(@as(usize, 2), center.entries.items.len);
    const arg = activateArg("run:a\ndeny").?;
    try testing.expectEqualStrings("run:a", arg.key);
    try testing.expectEqualStrings("deny", arg.action);
}
