//! The Linux notification backend (E13.F01.S03.T02) over the freedesktop
//! `org.freedesktop.Notifications` D-Bus interface on the session bus:
//! `Notify` with actions, urgency and `desktop-entry`; `ActionInvoked`,
//! `ActivationToken` and `NotificationClosed` route clicks back (with the
//! Wayland activation token) to the router. Without a notification
//! daemon (`NameHasOwner` false) there is no backend and the router keeps
//! to in-app notifications. Calls run on the router's worker; signals on
//! the bus reader.

const std = @import("std");
const zg_platform = @import("zg_platform");
const n_mod = @import("notification.zig");

const Allocator = std.mem.Allocator;
const Bus = zg_platform.dbus.Bus;
const conn = zg_platform.dbus.conn;
const Value = zg_platform.dbus.Value;
const variantOf = zg_platform.dbus.marshal.variantOf;
const Notification = n_mod.Notification;

const log = std.log.scoped(.notify);

pub const service = "org.freedesktop.Notifications";
pub const object_path = "/org/freedesktop/Notifications";
pub const interface = "org.freedesktop.Notifications";
const call_timeout_ns = 5 * std.time.ns_per_s;

pub const ActivateFn = n_mod.ActivateFn;

const Shown = struct {
    key: []u8,
    /// Our id for the server's "default" action (the first action).
    default_action: []u8,
    token: ?[]u8 = null,
};

pub const Linux = struct {
    gpa: Allocator,
    io: std.Io,
    bus: *Bus,
    activate: ActivateFn,
    actions: bool,
    markup: bool,
    mutex: std.Io.Mutex = .init,
    shown: std.AutoHashMapUnmanaged(u32, Shown) = .empty,
    matches: [3]conn.MatchId = undefined,

    pub fn backend(l: *Linux) n_mod.OsBackend {
        return .{ .ctx = l, .vtable = &vtable };
    }

    const vtable: n_mod.OsBackend.VTable = .{ .show = show, .close = close, .deinit = deinitFn };

    fn show(ctx: *anyopaque, n: *const Notification, replaces: ?u64) anyerror!u64 {
        const l: *Linux = @ptrCast(@alignCast(ctx));
        var arena_state: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var acts: std.ArrayList([]const u8) = .empty;
        if (l.actions) for (n.actions, 0..) |act, i| {
            try acts.append(a, if (i == 0) "default" else act.id);
            try acts.append(a, act.label);
        };
        const body = if (l.markup) try escapeMarkup(a, n.body) else n.body;
        const urgency: u8 = switch (n.severity) {
            .needs_input, .error_ => 2,
            else => 1,
        };
        const hints = .{
            .{ "urgency", variantOf("y", urgency) },
            .{ "desktop-entry", variantOf("s", @as([]const u8, "zigguro")) },
        };
        const rid: u32 = if (replaces) |r| @truncate(r) else 0;
        var p = try l.bus.call(service, object_path, interface, "Notify", "susssasa{sv}i", .{
            @as([]const u8, "zigguro"), rid, @as([]const u8, "zigguro"), n.title, body, acts.items, hints, @as(i32, -1),
        });
        defer p.deinit();
        var r = try p.wait(call_timeout_ns);
        defer r.deinit();
        if (r.isError()) return error.NotifyFailed;
        const args = r.args(a) catch return error.NotifyFailed;
        if (args.len != 1 or args[0] != .u32) return error.NotifyFailed;
        const id = args[0].u32;
        try l.remember(id, n);
        return id;
    }

    fn remember(l: *Linux, id: u32, n: *const Notification) Allocator.Error!void {
        const key = try l.gpa.dupe(u8, n.key);
        errdefer l.gpa.free(key);
        const def = try l.gpa.dupe(u8, if (n.actions.len > 0) n.actions[0].id else "open");
        errdefer l.gpa.free(def);
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        const gop = try l.shown.getOrPut(l.gpa, id);
        if (gop.found_existing) freeShown(l.gpa, gop.value_ptr.*);
        gop.value_ptr.* = .{ .key = key, .default_action = def };
    }

    fn close(ctx: *anyopaque, id: u64) void {
        const l: *Linux = @ptrCast(@alignCast(ctx));
        var p = l.bus.call(service, object_path, interface, "CloseNotification", "u", .{@as(u32, @truncate(id))}) catch return;
        defer p.deinit();
        var r = p.wait(call_timeout_ns) catch return;
        r.deinit();
    }

    fn deinitFn(ctx: *anyopaque) void {
        const l: *Linux = @ptrCast(@alignCast(ctx));
        for (l.matches) |m| l.bus.removeMatch(m);
        var it = l.shown.valueIterator();
        while (it.next()) |s| freeShown(l.gpa, s.*);
        l.shown.deinit(l.gpa);
        l.gpa.destroy(l);
    }

    fn onActionInvoked(ctx: ?*anyopaque, in: *const conn.Incoming) void {
        const l: *Linux = @ptrCast(@alignCast(ctx.?));
        const a = in.args() catch return;
        if (a.len != 2 or a[0] != .u32) return;
        const action_key = a[1].asString() orelse return;
        var key_buf: [256]u8 = undefined;
        var act_buf: [64]u8 = undefined;
        var tok_buf: [256]u8 = undefined;
        const key, const action, const token = blk: {
            l.mutex.lockUncancelable(l.io);
            defer l.mutex.unlock(l.io);
            const s = l.shown.get(a[0].u32) orelse return;
            const act = if (std.mem.eql(u8, action_key, "default")) s.default_action else action_key;
            if (s.key.len > key_buf.len or act.len > act_buf.len) return;
            @memcpy(key_buf[0..s.key.len], s.key);
            @memcpy(act_buf[0..act.len], act);
            const tok: ?[]const u8 = if (s.token) |t| if (t.len <= tok_buf.len) blk2: {
                @memcpy(tok_buf[0..t.len], t);
                break :blk2 tok_buf[0..t.len];
            } else null else null;
            break :blk .{ key_buf[0..s.key.len], act_buf[0..act.len], tok };
        };
        l.activate.call(key, action, token);
    }

    /// Sent before `ActionInvoked`; kept for it.
    fn onActivationToken(ctx: ?*anyopaque, in: *const conn.Incoming) void {
        const l: *Linux = @ptrCast(@alignCast(ctx.?));
        const a = in.args() catch return;
        if (a.len != 2 or a[0] != .u32) return;
        const tok = a[1].asString() orelse return;
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        const s = l.shown.getPtr(a[0].u32) orelse return;
        const copy = l.gpa.dupe(u8, tok) catch return;
        if (s.token) |old| l.gpa.free(old);
        s.token = copy;
    }

    fn onClosed(ctx: ?*anyopaque, in: *const conn.Incoming) void {
        const l: *Linux = @ptrCast(@alignCast(ctx.?));
        const a = in.args() catch return;
        if (a.len < 1 or a[0] != .u32) return;
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        if (l.shown.fetchRemove(a[0].u32)) |kv| freeShown(l.gpa, kv.value);
    }
};

fn freeShown(gpa: Allocator, s: Shown) void {
    gpa.free(s.key);
    gpa.free(s.default_action);
    if (s.token) |t| gpa.free(t);
}

/// The backend on `bus`, or null when no notification daemon owns the
/// name (logged once). The router owns it (its `deinit` frees it).
pub fn linuxBackend(gpa: Allocator, io: std.Io, bus: *Bus, activate: ActivateFn) !?n_mod.OsBackend {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    {
        var p = try bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", .{@as([]const u8, service)});
        defer p.deinit();
        var r = try p.wait(call_timeout_ns);
        defer r.deinit();
        const args = r.args(a) catch return null;
        if (r.isError() or args.len != 1 or args[0] != .boolean or !args[0].boolean) {
            log.info("no notification daemon on the session bus; using in-app notifications only", .{});
            return null;
        }
    }
    var actions = false;
    var markup = false;
    {
        var p = try bus.call(service, object_path, interface, "GetCapabilities", "", .{});
        defer p.deinit();
        var r = try p.wait(call_timeout_ns);
        defer r.deinit();
        if (!r.isError()) {
            const args = r.args(a) catch &.{};
            if (args.len == 1 and args[0] == .array) for (args[0].array.items) |c| {
                const s = c.asString() orelse continue;
                if (std.mem.eql(u8, s, "actions")) actions = true;
                if (std.mem.eql(u8, s, "body-markup")) markup = true;
            };
        }
    }
    const l = try gpa.create(Linux);
    errdefer gpa.destroy(l);
    l.* = .{ .gpa = gpa, .io = io, .bus = bus, .activate = activate, .actions = actions, .markup = markup };
    const rules = [_]struct { []const u8, *const fn (?*anyopaque, *const conn.Incoming) void }{
        .{ "type='signal',interface='org.freedesktop.Notifications',member='ActionInvoked'", Linux.onActionInvoked },
        .{ "type='signal',interface='org.freedesktop.Notifications',member='ActivationToken'", Linux.onActivationToken },
        .{ "type='signal',interface='org.freedesktop.Notifications',member='NotificationClosed'", Linux.onClosed },
    };
    var added: usize = 0;
    errdefer for (l.matches[0..added]) |m| bus.removeMatch(m);
    for (rules, 0..) |rule, i| {
        l.matches[i] = try bus.addMatch(rule[0], .{ .ctx = l, .func = rule[1] });
        added += 1;
    }
    return l.backend();
}

/// `&`, `<` and `>` as entities, for servers that parse body markup.
pub fn escapeMarkup(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "&<>") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        else => try out.append(a, c),
    };
    return out.items;
}

test "escapeMarkup" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a &lt;b&gt; &amp; c", try escapeMarkup(arena.allocator(), "a <b> & c"));
    try std.testing.expectEqualStrings("plain", try escapeMarkup(arena.allocator(), "plain"));
}
