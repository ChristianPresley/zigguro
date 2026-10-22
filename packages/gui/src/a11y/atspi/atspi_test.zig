//! The AT-SPI2 bridge (E04.F09.S01.T03). Bus tests run against a private
//! dbus-daemon with in-process fakes of `org.a11y.Bus` and the registry,
//! and are skipped when dbus-daemon isn't installed.

const std = @import("std");
const zg_platform = @import("zg_platform");
const ui_mod = @import("../../core/ui.zig");
const controls = @import("../../widgets/controls.zig");
const widget = @import("../../core/widget.zig");
const TestApp = @import("../../testing/test_app.zig").TestApp;
const snap = @import("../snapshot.zig");
const atspi = @import("root.zig");

const dbus = zg_platform.dbus;
const Bus = dbus.Bus;
const Incoming = dbus.conn.Incoming;
const Value = dbus.Value;
const Ui = ui_mod.Ui;
const roles = atspi.roles;
const states = atspi.states;
const objects = atspi.objects;
const testing = std.testing;

test "atspi: role and state mapping tables" {
    inline for (@typeInfo(widget.Role).@"enum".fields) |f| {
        const r = roles.of(@enumFromInt(f.value));
        try testing.expect(r != roles.atspi.invalid);
        try testing.expect(!std.mem.eql(u8, roles.name(r), "unknown"));
    }
    try testing.expectEqual(roles.atspi.push_button, roles.of(.button));
    try testing.expectEqual(roles.atspi.frame, roles.of(.window));
    try testing.expectEqual(roles.atspi.entry, roles.of(.textbox));
}

test "atspi: GetState bitset encoding" {
    const n: snap.Node = .{
        .id = 1,
        .parent = 0,
        .role = .checkbox,
        .node = .none,
        .state = .{ .focusable = true, .checkable = true, .checked = true },
    };
    const s = states.of(&n, false);
    // checked (4), enabled (8), focusable (11), sensitive (24), showing
    // (25), visible (30) in word 0; checkable (41) is bit 9 of word 1.
    const w0: u32 = (1 << 4) | (1 << 8) | (1 << 11) | (1 << 24) | (1 << 25) | (1 << 30);
    try testing.expectEqual(w0, s.words[0]);
    try testing.expectEqual(@as(u32, 1 << 9), s.words[1]);
    const off: snap.Node = .{ .id = 1, .parent = 0, .role = .button, .node = .none, .state = .{ .disabled = true, .offscreen = true } };
    try testing.expectEqual([2]u32{ 0, 0 }, states.of(&off, false).words);
}

test "atspi: signals encoded siiva{sv}" {
    var e: dbus.marshal.Encoder = .init(testing.allocator, 0);
    defer e.deinit();
    try dbus.marshal.encode(&e, atspi.events.sig, atspi.events.body("focused", 1, 0, atspi.events.zero()));
    const want = [_]u8{
        7, 0, 0, 0, 'f', 'o', 'c', 'u', 's', 'e', 'd', 0, // s
        1, 0, 0, 0, // i detail1
        0, 0, 0, 0, // i detail2
        1, 'i', 0, 0, // v: signature "i", pad
        0, 0, 0, 0, // int32 0
        0, 0, 0, 0, // a{sv}: empty
    };
    try testing.expectEqualSlices(u8, &want, e.buf.items);
}

test "atspi: GetStringAtOffset word granularity" {
    const t = "hello big world";
    const g = atspi.ifaces.Granularity;
    try testing.expectEqual([2]i32{ 6, 10 }, atspi.ifaces.stringAt(t, 7, g.word));
    // In the space after a word: that word.
    try testing.expectEqual([2]i32{ 6, 10 }, atspi.ifaces.stringAt(t, 9, g.word));
    try testing.expectEqual([2]i32{ 10, 15 }, atspi.ifaces.stringAt(t, 12, g.word));
    try testing.expectEqual([2]i32{ 0, 6 }, atspi.ifaces.stringAt(t, 0, g.word));
    try testing.expectEqual([2]i32{ 3, 4 }, atspi.ifaces.stringAt(t, 3, g.char));
    try testing.expectEqual([2]i32{ 0, 15 }, atspi.ifaces.stringAt(t, 3, g.line));
    // Characters, not bytes.
    try testing.expectEqual([2]i32{ 6, 8 }, atspi.ifaces.stringAt("héllo dé", 7, g.word));
    try testing.expectEqual([2]i32{ 0, 6 }, atspi.ifaces.stringAt("héllo dé", 1, g.word));
}

test "atspi: introspection lists the served interfaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const x = try atspi.introspect.xml(arena.allocator(), .{ .component = true, .action = true });
    try testing.expect(std.mem.indexOf(u8, x, "org.a11y.atspi.Accessible") != null);
    try testing.expect(std.mem.indexOf(u8, x, "org.a11y.atspi.Action") != null);
    try testing.expect(std.mem.indexOf(u8, x, "org.a11y.atspi.Text") == null);
    try testing.expect(std.mem.endsWith(u8, x, "</node>\n"));
}

// -- against a bus ---------------------------------------------------------------------

/// Fakes `org.a11y.Bus` (status and GetAddress) and the registry's socket.
const Fakes = struct {
    address: []const u8,
    enabled: bool,
    embedded: std.atomic.Value(u32) = .init(0),
    plug: [128]u8 = undefined,
    plug_len: usize = 0,

    fn handle(ctx: ?*anyopaque, bus: *Bus, in: *const Incoming) bool {
        const f: *Fakes = @ptrCast(@alignCast(ctx.?));
        const h = &in.msg.header;
        const member = h.member orelse return false;
        if (std.mem.eql(u8, member, "Get")) {
            bus.replyTo(in, "v", .{dbus.marshal.variantOf("b", f.enabled)}) catch {};
            return true;
        }
        if (std.mem.eql(u8, member, "GetAddress")) {
            bus.replyTo(in, "s", .{f.address}) catch {};
            return true;
        }
        if (std.mem.eql(u8, member, "Embed")) {
            const a = in.args() catch return false;
            const name = a[0].structure[0].asString().?;
            @memcpy(f.plug[0..name.len], name);
            f.plug_len = name.len;
            bus.replyTo(in, "(so)", .{.{ bus.unique_name, objects.root_path }}) catch {};
            _ = f.embedded.fetchAdd(1, .release);
            return true;
        }
        return false;
    }
};

fn requestName(bus: *Bus, name: []const u8) !void {
    var p = try bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", .{ name, @as(u32, 4) });
    defer p.deinit();
    var r = try p.wait(5 * std.time.ns_per_s);
    r.deinit();
}

const Form = struct {
    clicks: u32 = 0,
    on: bool = false,

    pub fn build(f: *Form, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .padding = .all(8) } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row }, .role = .toolbar, .label = "Tools" });
        if (controls.button(ui, .{ .label = "Run" }).clicked) {
            f.clicks += 1;
            ui.window().markViewDirty(ui.currentView());
        }
        ui.close();
        if (controls.checkbox(ui, "Wrap", &f.on).changed) ui.window().markViewDirty(ui.currentView());
    }
};

const Rig = struct {
    daemon: dbus.conn.TestDaemon,
    service: *Bus,
    client: *Bus,
    fakes: Fakes,
    t: *TestApp,
    b: *atspi.Bridge,
    arena: std.heap.ArenaAllocator,

    /// Null when dbus-daemon isn't installed.
    fn start(r: *Rig, view: *Form, enabled: bool) !bool {
        if (!try r.daemon.start()) return false;
        errdefer r.daemon.stop();
        const gpa = testing.allocator;
        const io = testing.io;
        r.fakes = .{ .address = r.daemon.address(), .enabled = enabled };
        r.service = try Bus.connectAddress(gpa, io, r.daemon.address(), .{});
        errdefer r.service.deinit();
        r.service.setMethodHandler(.{ .ctx = &r.fakes, .func = Fakes.handle });
        try requestName(r.service, "org.a11y.Bus");
        try requestName(r.service, "org.a11y.atspi.Registry");
        r.client = try Bus.connectAddress(gpa, io, r.daemon.address(), .{});
        errdefer r.client.deinit();
        r.arena = .init(gpa);
        r.t = try TestApp.init(gpa, .{ .root = .of(view) });
        errdefer r.t.deinit();
        _ = r.t.settle();
        r.b = try atspi.Bridge.init(gpa, io, .{ .session_address = r.daemon.address() });
        return true;
    }

    fn stop(r: *Rig) void {
        r.b.deinit();
        _ = r.t.settle();
        r.t.deinit();
        r.client.deinit();
        r.service.deinit();
        r.arena.deinit();
        r.daemon.stop();
    }

    /// Waits for `cond` (up to 5 s).
    fn until(r: *Rig, comptime cond: fn (*Rig) bool) !void {
        var i: usize = 0;
        while (!cond(r)) : (i += 1) {
            if (i > 500) return error.Timeout;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
    }

    fn embedded(r: *Rig) bool {
        return r.b.live() and r.fakes.embedded.load(.acquire) > 0;
    }

    /// Calls the bridge and returns the decoded reply (or error name).
    fn call(r: *Rig, path: []const u8, iface: []const u8, member: []const u8, comptime sig: []const u8, args: anytype) !Reply {
        const bus = r.b.a11y.load(.acquire).?;
        var p = try r.client.call(bus.unique_name, path, iface, member, sig, args);
        defer p.deinit();
        var rep = try p.wait(5 * std.time.ns_per_s);
        defer rep.deinit();
        const a = r.arena.allocator();
        if (rep.isError()) return .{ .err = try a.dupe(u8, rep.errorName() orelse "") };
        // Copy the body: the decoded values point into the reply.
        const bytes = try a.dupe(u8, rep.msg.body);
        var m = rep.msg;
        m.body = bytes;
        return .{ .values = try m.args(a, &.{}) };
    }

    const Reply = union(enum) { values: []Value, err: []const u8 };

    fn windowPath(r: *Rig, buf: *objects.PathBuf) ![]const u8 {
        const s = r.b.windows.items[0].tree.snapshot() orelse return error.NoSnapshot;
        defer s.release();
        return objects.pathOf(s.root().?.id, buf);
    }

    fn nodePath(r: *Rig, name: []const u8, buf: *objects.PathBuf) ![]const u8 {
        const s = r.b.windows.items[0].tree.snapshot() orelse return error.NoSnapshot;
        defer s.release();
        for (s.nodes) |*n| if (std.mem.eql(u8, n.name, name)) return objects.pathOf(n.id, buf);
        return error.NotFound;
    }
};

test "atspi: Embed handshake, then the tree is served by path" {
    var view: Form = .{};
    var r: Rig = undefined;
    if (!try r.start(&view, true)) return error.SkipZigTest;
    defer r.stop();
    try r.until(Rig.embedded);
    const bus = r.b.a11y.load(.acquire).?;
    // The plug named our connection and the application path.
    try testing.expectEqualStrings(bus.unique_name, r.fakes.plug[0..r.fakes.plug_len]);
    try r.b.addWindow(r.t.win, 5);
    _ = r.t.settle();

    // The application: one child, the window; its parent is the registry.
    const kids = (try r.call(objects.root_path, "org.a11y.atspi.Accessible", "GetChildren", "", .{})).values;
    try testing.expectEqual(@as(usize, 1), kids[0].array.items.len);
    var wb: objects.PathBuf = undefined;
    const wpath = try r.windowPath(&wb);
    try testing.expectEqualStrings(wpath, kids[0].array.items[0].structure[1].asString().?);
    const parent = (try r.call(objects.root_path, "org.freedesktop.DBus.Properties", "Get", "ss", .{ "org.a11y.atspi.Accessible", "Parent" })).values;
    try testing.expectEqualStrings(objects.root_path, parent[0].unwrap().structure[1].asString().?);
    const tk = (try r.call(objects.root_path, "org.freedesktop.DBus.Properties", "Get", "ss", .{ "org.a11y.atspi.Application", "ToolkitName" })).values;
    try testing.expectEqualStrings("zigguro", tk[0].asString().?);

    // GetChildren on the window matches the snapshot.
    const wk = (try r.call(wpath, "org.a11y.atspi.Accessible", "GetChildren", "", .{})).values;
    const s = r.b.windows.items[0].tree.snapshot().?;
    defer s.release();
    const want = s.children(s.root().?);
    try testing.expectEqual(want.len, wk[0].array.items.len);
    for (want, wk[0].array.items) |k, got| {
        var pb: objects.PathBuf = undefined;
        try testing.expectEqualStrings(objects.pathOf(s.nodes[k].id, &pb), got.structure[1].asString().?);
    }
    const role = (try r.call(wpath, "org.a11y.atspi.Accessible", "GetRole", "", .{})).values;
    try testing.expectEqual(roles.atspi.frame, role[0].u32);

    // Names, roles and states of a child.
    var bb: objects.PathBuf = undefined;
    const run = try r.nodePath("Run", &bb);
    const name = (try r.call(run, "org.freedesktop.DBus.Properties", "Get", "ss", .{ "org.a11y.atspi.Accessible", "Name" })).values;
    try testing.expectEqualStrings("Run", name[0].asString().?);
    const ifl = (try r.call(run, "org.a11y.atspi.Accessible", "GetInterfaces", "", .{})).values;
    try testing.expectEqual(@as(usize, 3), ifl[0].array.items.len);
    const st = (try r.call(run, "org.a11y.atspi.Accessible", "GetState", "", .{})).values;
    try testing.expect(st[0].array.items[0].u32 & (1 << 8) != 0);

    // A stale path.
    const gone = try r.call("/org/a11y/atspi/accessible/00000005deadbeef", "org.a11y.atspi.Accessible", "GetRole", "", .{});
    try testing.expectEqualStrings(atspi.ifaces.unknown_object, gone.err);
}

test "atspi: actions reach widgets and changes go out as signals" {
    var view: Form = .{};
    var r: Rig = undefined;
    if (!try r.start(&view, true)) return error.SkipZigTest;
    defer r.stop();
    try r.until(Rig.embedded);
    try r.b.addWindow(r.t.win, 5);
    _ = r.t.settle();

    var bb: objects.PathBuf = undefined;
    const run = try r.nodePath("Run", &bb);
    const names = (try r.call(run, "org.a11y.atspi.Action", "GetActions", "", .{})).values;
    try testing.expectEqualStrings("click", names[0].array.items[0].structure[0].asString().?);
    const ok = (try r.call(run, "org.a11y.atspi.Action", "DoAction", "i", .{@as(i32, 0)})).values;
    try testing.expect(ok[0].boolean);
    _ = r.t.settle();
    try testing.expectEqual(@as(u32, 1), view.clicks);

    const before = r.b.emitted.load(.acquire);
    var cb: objects.PathBuf = undefined;
    const wrap = try r.nodePath("Wrap", &cb);
    _ = try r.call(wrap, "org.a11y.atspi.Action", "DoAction", "i", .{@as(i32, 0)});
    _ = r.t.settle();
    try testing.expect(view.on);
    // StateChanged("checked") at least.
    try testing.expect(r.b.emitted.load(.acquire) > before);

    // Extents in window coordinates are the node's bounds.
    const ext = (try r.call(wrap, "org.a11y.atspi.Component", "GetExtents", "u", .{@as(u32, 1)})).values;
    try testing.expect(ext[0].structure[2].i32 > 0);
}

test "atspi: nothing is built while accessibility is off" {
    var view: Form = .{};
    var r: Rig = undefined;
    if (!try r.start(&view, false)) return error.SkipZigTest;
    defer r.stop();
    // Give the worker time to read the status.
    try testing.io.sleep(.fromMilliseconds(200), .awake);
    try testing.expect(!r.b.live());
    try r.b.addWindow(r.t.win, 5);
    _ = r.t.settle();
    try r.t.click(.{ .name_contains = "Run" });
    _ = r.t.settle();
    try testing.expectEqual(@as(u64, 0), r.b.windows.items[0].tree.stats.builds);
}
