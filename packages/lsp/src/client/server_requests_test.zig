const std = @import("std");
const Client = @import("Client.zig");
const host_mod = @import("host.zig");
const protocol = @import("../gen/protocol.zig");
const client_test = @import("client_test.zig");
const Harness = client_test.Harness;
const Ready = client_test.Ready;
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A host that records every call. Any call it does not expect fails the
/// test, so nothing (telemetry in particular) leaves the client unseen.
const FakeHost = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    log: std.ArrayList(u8) = .empty,
    /// `showMessageRequest` answers: an index, or null to hold the reply.
    choices: []const ?usize = &.{},
    calls: usize = 0,
    held: ?host_mod.ReplyCb = null,
    watchers: usize = 0,
    cleared: bool = false,
    refreshed: std.EnumSet(host_mod.RefreshFeature) = .initEmpty(),

    fn host(h: *FakeHost) host_mod.ClientHost {
        return .{
            .ctx = h,
            .showMessage = showMessage,
            .showMessageRequest = showMessageRequest,
            .showDocument = showDocument,
            .logMessage = logMessage,
            .getConfiguration = getConfiguration,
        };
    }

    fn of(ctx: ?*anyopaque) *FakeHost {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn note(h: *FakeHost, comptime fmt: []const u8, args: anytype) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.log.print(testing.allocator, fmt ++ "\n", args) catch @panic("oom");
    }

    fn deinit(h: *FakeHost) void {
        h.log.deinit(testing.allocator);
    }

    fn showMessage(ctx: ?*anyopaque, server: host_mod.ServerId, kind: protocol.MessageType, text: []const u8) void {
        of(ctx).note("toast {d} {t} {s}", .{ server, kind, text });
    }

    fn logMessage(ctx: ?*anyopaque, server: host_mod.ServerId, kind: protocol.MessageType, text: []const u8) void {
        of(ctx).note("log {d} {t} {s}", .{ server, kind, text });
    }

    fn showMessageRequest(ctx: ?*anyopaque, _: host_mod.ServerId, _: protocol.MessageType, text: []const u8, actions: []const []const u8, reply: host_mod.ReplyCb) void {
        const h = of(ctx);
        h.note("ask {s} {d}", .{ text, actions.len });
        const i = h.calls;
        h.calls += 1;
        if (h.choices[i]) |c| reply.call(c) else h.held = reply;
    }

    fn showDocument(ctx: ?*anyopaque, uri: []const u8, external: bool, take_focus: bool, _: ?protocol.Range, reply: host_mod.BoolCb) void {
        of(ctx).note("open {s} {} {}", .{ uri, external, take_focus });
        reply.call(true);
    }

    fn getConfiguration(_: ?*anyopaque, section: ?[]const u8, scope_uri: ?[]const u8, arena: Allocator) std.json.Value {
        const s = section orelse return .null;
        if (scope_uri) |u| return .{ .string = std.fmt.allocPrint(arena, "{s}:{s}", .{ u, s }) catch @panic("oom") };
        if (!std.mem.eql(u8, s, "zls")) return .null;
        var o: std.json.ObjectMap = .empty;
        o.put(arena, "enable_snippets", .{ .bool = true }) catch @panic("oom");
        return .{ .object = o };
    }

    fn watchBridge(h: *FakeHost) host_mod.WatchBridge {
        return .{ .ctx = h, .set = setWatch, .clear = clearWatch };
    }

    fn setWatch(ctx: ?*anyopaque, server: host_mod.ServerId, id: []const u8, w: []const protocol.FileSystemWatcher) void {
        const h = of(ctx);
        h.note("watch {d} {s} {s}", .{ server, id, w[0].globPattern.pattern });
        h.watchers = w.len;
    }

    fn clearWatch(ctx: ?*anyopaque, server: host_mod.ServerId, id: []const u8) void {
        const h = of(ctx);
        h.note("unwatch {d} {s}", .{ server, id });
        h.cleared = true;
    }

    fn refreshListener(h: *FakeHost) host_mod.RefreshListener {
        return .{ .ctx = h, .func = onRefresh };
    }

    fn onRefresh(ctx: ?*anyopaque, e: host_mod.RefreshEvent) void {
        const h = of(ctx);
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        h.refreshed.insert(e.feature);
    }
};

fn readyHandlers(ready: *Ready) []const Client.NamedNotificationHandler {
    const S = struct {
        var list: [1]Client.NamedNotificationHandler = undefined;
    };
    S.list[0] = .{ .method = "test/ready", .handler = .{ .ctx = ready, .func = Ready.onReady } };
    return &S.list;
}

test "server_requests: register/unregister, push-mode configuration" {
    var ready: Ready = .{ .io = testing.io };
    var fh: FakeHost = .{ .io = testing.io };
    defer fh.deinit();
    var h: Harness = undefined;
    try h.init("server_registration.script", .{
        .notification_handlers = readyHandlers(&ready),
        .services = .{ .server = 4, .host = fh.host(), .watch = fh.watchBridge() },
    });
    defer h.deinit();
    errdefer h.dumpStderr();
    ready.io = h.rt.io;
    try h.client.start();
    try h.client.waitInitialized(.fromSeconds(10));

    try ready.waitStep(1);
    try testing.expectEqual(@as(usize, 2), fh.watchers);
    // Push mode: the server pulls the settings, answered from the host in
    // request order.
    try testing.expect(try h.client.settingsChanged());

    try ready.waitStep(2);
    try testing.expect(fh.cleared);
    try testing.expect(!try h.client.settingsChanged());
    try testing.expectEqualStrings("watch 4 w1 **/*.zig\nunwatch 4 w1\n", fh.log.items);

    h.client.shutdown();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}

test "server_requests: workspaceFolders change -> notification or restart" {
    var ready: Ready = .{ .io = testing.io };
    var h: Harness = undefined;
    const w: []const protocol.WorkspaceFolder = &.{.{ .uri = "file:///w", .name = "w" }};
    const x: []const protocol.WorkspaceFolder = &.{.{ .uri = "file:///x", .name = "x" }};
    try h.init("server_folders.script", .{ .workspace_folders = w, .notification_handlers = readyHandlers(&ready) });
    defer h.deinit();
    errdefer h.dumpStderr();
    ready.io = h.rt.io;
    try h.client.start();
    try h.client.waitInitialized(.fromSeconds(10));
    try ready.waitStep(1);
    try testing.expectEqual(Client.FolderChange.notified, try h.client.setWorkspaceFolders(x));
    try testing.expectEqual(Client.FolderChange.unchanged, try h.client.setWorkspaceFolders(x));
    try ready.waitStep(2);
    h.client.shutdown();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());

    // A server without changeNotifications needs a restart (no traffic).
    var h2: Harness = undefined;
    try h2.init("handshake.script", .{ .root_uri = "file:///w", .workspace_folders = w });
    defer h2.deinit();
    try h2.client.start();
    try h2.client.waitInitialized(.fromSeconds(10));
    try testing.expectEqual(Client.FolderChange.restart_required, try h2.client.setWorkspaceFolders(x));
    h2.client.shutdown();
}

test "server_requests: window, deferred replies and timeout, refresh, unknown, telemetry" {
    var ready: Ready = .{ .io = testing.io };
    var fh: FakeHost = .{ .io = testing.io, .choices = &.{ 1, null } };
    defer fh.deinit();
    var h: Harness = undefined;
    try h.init("server_window.script", .{
        .trace_bodies = true,
        .notification_handlers = readyHandlers(&ready),
        .services = .{
            .server = 2,
            .host = fh.host(),
            .refresh = fh.refreshListener(),
            .reply_timeout = .fromMilliseconds(100),
        },
    });
    defer h.deinit();
    errdefer h.dumpStderr();
    ready.io = h.rt.io;
    try h.client.start();
    try h.client.waitInitialized(.fromSeconds(10));
    try ready.waitStep(1);

    // The second error within 5 s goes to the log; telemetry goes nowhere.
    try testing.expectEqualStrings(
        \\toast 2 Error e1
        \\log 2 Error e2
        \\toast 2 Info i1
        \\log 2 Log l1
        \\ask pick 2
        \\ask ignored 1
        \\open file:///w/a.zig false false
        \\
    , fh.log.items);
    try testing.expectEqual(std.EnumSet(host_mod.RefreshFeature).initFull(), fh.refreshed);
    // A late answer after the timeout is ignored.
    fh.held.?.call(0);

    h.client.shutdown();
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try h.exitStatus());
}
