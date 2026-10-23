//! The Linux backend against a fake notification server on a private
//! dbus-daemon (skipped when dbus-daemon is not installed).

const std = @import("std");
const zg_platform = @import("zg_platform");
const n_mod = @import("notification.zig");
const os_linux = @import("os_linux.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const Bus = zg_platform.dbus.Bus;
const conn = zg_platform.dbus.conn;
const TestDaemon = conn.TestDaemon;

/// Answers GetCapabilities and Notify like a notification daemon and
/// records the last Notify call.
const FakeServer = struct {
    bus: *Bus = undefined,
    caps: []const []const u8 = &.{ "actions", "body", "body-markup" },
    mutex: std.Io.Mutex = .init,
    sig: [32]u8 = undefined,
    sig_len: usize = 0,
    replaces: u32 = 0,
    summary: [64]u8 = undefined,
    summary_len: usize = 0,
    body: [64]u8 = undefined,
    body_len: usize = 0,
    actions: [8][16]u8 = undefined,
    action_lens: [8]usize = undefined,
    n_actions: usize = 0,
    urgency: u8 = 0,
    desktop_entry_ok: bool = false,
    expire: i32 = 0,
    next_id: u32 = 40,
    notifies: std.atomic.Value(u32) = .init(0),

    fn start(f: *FakeServer, address: []const u8) !void {
        f.bus = try Bus.connectAddress(gpa, io, address, .{});
        errdefer f.bus.deinit();
        f.bus.setMethodHandler(.{ .ctx = f, .func = onCall });
        var p = try f.bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", .{ @as([]const u8, os_linux.service), @as(u32, 4) });
        defer p.deinit();
        var r = try p.wait(5 * std.time.ns_per_s);
        defer r.deinit();
        if (r.isError()) return error.NameTaken;
    }

    fn onCall(ctx: ?*anyopaque, bus: *Bus, in: *const conn.Incoming) bool {
        const f: *FakeServer = @ptrCast(@alignCast(ctx.?));
        const member = in.msg.header.member orelse return false;
        if (std.mem.eql(u8, member, "GetCapabilities")) {
            bus.replyTo(in, "as", .{f.caps}) catch {};
            return true;
        }
        if (!std.mem.eql(u8, member, "Notify")) return false;
        const a = in.args() catch return false;
        f.mutex.lockUncancelable(io);
        const sig = in.msg.header.signature;
        f.sig_len = @min(sig.len, f.sig.len);
        @memcpy(f.sig[0..f.sig_len], sig[0..f.sig_len]);
        f.replaces = a[1].u32;
        copyInto(&f.summary, &f.summary_len, a[3].asString().?);
        copyInto(&f.body, &f.body_len, a[4].asString().?);
        f.n_actions = 0;
        for (a[5].array.items) |item| {
            copyInto(&f.actions[f.n_actions], &f.action_lens[f.n_actions], item.asString().?);
            f.n_actions += 1;
        }
        for (a[6].dict.entries) |e| {
            const k = e.key.asString().?;
            if (std.mem.eql(u8, k, "urgency")) f.urgency = e.value.unwrap().byte;
            if (std.mem.eql(u8, k, "desktop-entry")) f.desktop_entry_ok = std.mem.eql(u8, e.value.asString().?, "zigguro");
        }
        f.expire = a[7].i32;
        const id = if (f.replaces != 0) f.replaces else blk: {
            f.next_id += 1;
            break :blk f.next_id;
        };
        f.mutex.unlock(io);
        bus.replyTo(in, "u", .{id}) catch {};
        _ = f.notifies.fetchAdd(1, .release);
        return true;
    }

    fn action(f: *FakeServer, i: usize) []const u8 {
        return f.actions[i][0..f.action_lens[i]];
    }
};

fn copyInto(buf: anytype, len: *usize, s: []const u8) void {
    len.* = @min(s.len, buf.len);
    @memcpy(buf[0..len.*], s[0..len.*]);
}

const Activations = struct {
    mutex: std.Io.Mutex = .init,
    count: u32 = 0,
    key: [32]u8 = undefined,
    key_len: usize = 0,
    action: [16]u8 = undefined,
    action_len: usize = 0,
    token: [64]u8 = undefined,
    token_len: ?usize = null,

    fn fnOf(a: *Activations) n_mod.ActivateFn {
        return .{ .ctx = a, .f = on };
    }

    fn on(ctx: *anyopaque, key: []const u8, action: []const u8, token: ?[]const u8) void {
        const a: *Activations = @ptrCast(@alignCast(ctx));
        a.mutex.lockUncancelable(io);
        defer a.mutex.unlock(io);
        copyInto(&a.key, &a.key_len, key);
        copyInto(&a.action, &a.action_len, action);
        if (token) |t| {
            var l: usize = 0;
            copyInto(&a.token, &l, t);
            a.token_len = l;
        } else a.token_len = null;
        a.count += 1;
    }

    fn waitCount(a: *Activations, n: u32) !void {
        var i: u32 = 0;
        while (i < 500) : (i += 1) {
            a.mutex.lockUncancelable(io);
            const c = a.count;
            a.mutex.unlock(io);
            if (c >= n) return;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }
};

const Fx = struct {
    d: TestDaemon = undefined,
    server: FakeServer = .{},
    client: *Bus = undefined,
    acts: Activations = .{},
    backend: ?n_mod.OsBackend = null,

    /// False when dbus-daemon is missing.
    fn init(f: *Fx, with_server: bool, caps: ?[]const []const u8) !bool {
        f.* = .{};
        if (!try f.d.start()) return false;
        errdefer f.d.stop();
        if (caps) |c| f.server.caps = c;
        if (with_server) try f.server.start(f.d.address());
        f.client = try Bus.connectAddress(gpa, io, f.d.address(), .{});
        f.backend = try os_linux.linuxBackend(gpa, io, f.client, f.acts.fnOf());
        return true;
    }

    fn deinit(f: *Fx, with_server: bool) void {
        if (f.backend) |b| b.deinit();
        f.client.deinit();
        if (with_server) f.server.bus.deinit();
        f.d.stop();
    }
};

const acts = [_]n_mod.NotifyAction{ .{ .id = "open", .label = "Open" }, .{ .id = "deny", .label = "Deny" } };
const ask: n_mod.Notification = .{ .key = "run:7", .severity = .needs_input, .title = "Lint needs input", .body = "Allow <npm> & co?", .actions = &acts };

test "linux_notify_marshalling" {
    var f: Fx = undefined;
    if (!try f.init(true, null)) return error.SkipZigTest;
    defer f.deinit(true);
    const b = f.backend.?;
    const id = try b.show(&ask, null);
    try testing.expectEqual(@as(u64, 41), id);
    try testing.expectEqualStrings("susssasa{sv}i", f.server.sig[0..f.server.sig_len]);
    try testing.expectEqual(@as(u32, 0), f.server.replaces);
    try testing.expectEqualStrings("Lint needs input", f.server.summary[0..f.server.summary_len]);
    // The server parses markup: escaped.
    try testing.expectEqualStrings("Allow &lt;npm&gt; &amp; co?", f.server.body[0..f.server.body_len]);
    try testing.expectEqual(@as(usize, 4), f.server.n_actions);
    try testing.expectEqualStrings("default", f.server.action(0));
    try testing.expectEqualStrings("Open", f.server.action(1));
    try testing.expectEqualStrings("deny", f.server.action(2));
    try testing.expectEqual(@as(u8, 2), f.server.urgency);
    try testing.expect(f.server.desktop_entry_ok);
    try testing.expectEqual(@as(i32, -1), f.server.expire);
    _ = try b.show(&.{ .key = "run:8", .severity = .success, .title = "Done" }, null);
    try testing.expectEqual(@as(u8, 1), f.server.urgency);
}

test "linux_replaces_id_for_same_key" {
    var f: Fx = undefined;
    if (!try f.init(true, null)) return error.SkipZigTest;
    defer f.deinit(true);
    const b = f.backend.?;
    const id = try b.show(&ask, null);
    const id2 = try b.show(&.{ .key = "run:7", .severity = .success, .title = "Done: Lint" }, id);
    try testing.expectEqual(id, id2);
    try testing.expectEqual(@as(u32, @intCast(id)), f.server.replaces);
}

test "linux_action_invoked_routes_to_run" {
    var f: Fx = undefined;
    if (!try f.init(true, null)) return error.SkipZigTest;
    defer f.deinit(true);
    const id: u32 = @intCast(try f.backend.?.show(&ask, null));
    try f.server.bus.emit(os_linux.object_path, os_linux.interface, "ActionInvoked", "us", .{ id, @as([]const u8, "deny") });
    try f.acts.waitCount(1);
    try testing.expectEqualStrings("run:7", f.acts.key[0..f.acts.key_len]);
    try testing.expectEqualStrings("deny", f.acts.action[0..f.acts.action_len]);
    // The body ("default") is the first action.
    try f.server.bus.emit(os_linux.object_path, os_linux.interface, "ActionInvoked", "us", .{ id, @as([]const u8, "default") });
    try f.acts.waitCount(2);
    try testing.expectEqualStrings("open", f.acts.action[0..f.acts.action_len]);
}

test "linux_activation_token_forwarded" {
    var f: Fx = undefined;
    if (!try f.init(true, null)) return error.SkipZigTest;
    defer f.deinit(true);
    const id: u32 = @intCast(try f.backend.?.show(&ask, null));
    try f.server.bus.emit(os_linux.object_path, os_linux.interface, "ActivationToken", "us", .{ id, @as([]const u8, "xdg-token-123") });
    try f.server.bus.emit(os_linux.object_path, os_linux.interface, "ActionInvoked", "us", .{ id, @as([]const u8, "default") });
    try f.acts.waitCount(1);
    try testing.expectEqualStrings("xdg-token-123", f.acts.token[0..f.acts.token_len.?]);
    // Closed: later clicks for that id are ignored.
    try f.server.bus.emit(os_linux.object_path, os_linux.interface, "NotificationClosed", "uu", .{ id, @as(u32, 2) });
    try f.server.bus.emit(os_linux.object_path, os_linux.interface, "ActionInvoked", "us", .{ id, @as([]const u8, "default") });
    try io.sleep(.fromMilliseconds(100), .awake);
    try testing.expectEqual(@as(u32, 1), f.acts.count);
}

test "linux_no_actions_capability_omits_actions" {
    var f: Fx = undefined;
    if (!try f.init(true, &.{"body"})) return error.SkipZigTest;
    defer f.deinit(true);
    _ = try f.backend.?.show(&ask, null);
    try testing.expectEqual(@as(usize, 0), f.server.n_actions);
    // No body-markup: the text goes as is.
    try testing.expectEqualStrings("Allow <npm> & co?", f.server.body[0..f.server.body_len]);
}

test "linux_no_daemon_falls_back" {
    var f: Fx = undefined;
    if (!try f.init(false, null)) return error.SkipZigTest;
    defer f.deinit(false);
    try testing.expect(f.backend == null);
}
