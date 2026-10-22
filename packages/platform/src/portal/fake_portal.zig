//! A fake xdg-desktop-portal on a private bus, for tests: answers
//! FileChooser, OpenURI and Settings calls the way the real portal does,
//! with knobs for old-portal behaviour and response races.

const std = @import("std");
const linux = std.os.linux;
const conn = @import("../dbus/conn.zig");
const Bus = conn.Bus;
const Value = @import("../dbus/variant.zig").Value;
const request = @import("request.zig");

const Entry = struct { []const u8, Value };

/// The fake portal. Configure fields before `start`; read the recorded
/// fields after a call has been answered.
pub const FakePortal = struct {
    bus: *Bus = undefined,
    /// URIs a FileChooser response carries.
    uris: []const []const u8 = &.{},
    /// The response code to send.
    code: u32 = 0,
    /// Emit Response before the method reply (the race the client must handle).
    respond_before_reply: bool = true,
    /// Reply with a handle other than the predicted path, as portals
    /// before 0.9 did; the Response then goes to that handle.
    old_handle: bool = false,
    /// Whether Settings.ReadOne exists (portal version >= 2).
    has_read_one: bool = true,
    /// Settings values, by key, in the org.freedesktop.appearance namespace.
    settings: []const Entry = &.{},

    lock: std.Io.Mutex = .init,
    /// The last method called and its option count.
    last_method: [32]u8 = undefined,
    last_method_len: usize = 0,
    last_option_count: usize = 0,
    /// For OpenURI: the last URI, or whether OpenFile got a usable fd.
    last_uri: [256]u8 = undefined,
    last_uri_len: usize = 0,
    last_fd_ok: bool = false,
    calls: std.atomic.Value(u32) = .init(0),

    /// Connects to `address` and takes the portal's name.
    pub fn start(f: *FakePortal, gpa: std.mem.Allocator, io: std.Io, address: []const u8) !void {
        f.bus = try Bus.connectAddress(gpa, io, address, .{});
        errdefer f.bus.deinit();
        f.bus.setMethodHandler(.{ .ctx = f, .func = onCall });
        var p = try f.bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", .{ request.destination, @as(u32, 4) });
        defer p.deinit();
        var r = try p.wait(5 * std.time.ns_per_s);
        defer r.deinit();
        if (r.isError()) return error.NameTaken;
    }

    /// Disconnects.
    pub fn stop(f: *FakePortal) void {
        f.bus.deinit();
    }

    /// The last method name.
    pub fn lastMethod(f: *FakePortal) []const u8 {
        f.lock.lockUncancelable(f.bus.io);
        defer f.lock.unlock(f.bus.io);
        return f.last_method[0..f.last_method_len];
    }

    /// Waits until `n` calls have been answered.
    pub fn waitCalls(f: *FakePortal, n: u32) !void {
        var tries: usize = 0;
        while (f.calls.load(.acquire) < n) : (tries += 1) {
            if (tries > 500) return error.Timeout;
            try f.bus.io.sleep(.fromMilliseconds(10), .awake);
        }
    }

    /// Emits `SettingChanged` for an appearance key.
    pub fn changeSetting(f: *FakePortal, key: []const u8, value: Value) !void {
        try f.bus.emit(request.object_path, "org.freedesktop.portal.Settings", "SettingChanged", "ssv", .{ "org.freedesktop.appearance", key, value });
    }

    fn record(f: *FakePortal, method: []const u8, options: usize) void {
        f.lock.lockUncancelable(f.bus.io);
        defer f.lock.unlock(f.bus.io);
        const n = @min(method.len, f.last_method.len);
        @memcpy(f.last_method[0..n], method[0..n]);
        f.last_method_len = n;
        f.last_option_count = options;
    }

    fn onCall(ctx: ?*anyopaque, bus: *Bus, in: *const conn.Incoming) bool {
        const f: *FakePortal = @ptrCast(@alignCast(ctx.?));
        defer _ = f.calls.fetchAdd(1, .release);
        const h = in.msg.header;
        const iface = h.interface orelse return false;
        const member = h.member.?;
        const a = in.args() catch return false;
        if (std.mem.eql(u8, iface, "org.freedesktop.portal.Settings")) return f.settingsCall(bus, in, member, a);
        const is_chooser = std.mem.eql(u8, iface, "org.freedesktop.portal.FileChooser");
        const is_uri = std.mem.eql(u8, iface, "org.freedesktop.portal.OpenURI");
        if (!is_chooser and !is_uri) return false;
        if (a.len != 3 or a[2] != .dict) return false;
        f.record(member, a[2].dict.entries.len);
        if (is_uri) {
            f.lock.lockUncancelable(bus.io);
            if (a[1] == .string) {
                const n = @min(a[1].string.len, f.last_uri.len);
                @memcpy(f.last_uri[0..n], a[1].string[0..n]);
                f.last_uri_len = n;
            } else if (a[1] == .unix_fd) {
                f.last_fd_ok = linux.errno(linux.fcntl(a[1].unix_fd, linux.F.GETFD, 0)) == .SUCCESS;
            }
            f.lock.unlock(bus.io);
        }
        const token = (a[2].dict.get("handle_token") orelse return false).asString() orelse return false;
        var pbuf: [192]u8 = undefined;
        const predicted = request.predictPath(&pbuf, h.sender.?, token) catch return false;
        const handle = if (f.old_handle) "/org/freedesktop/portal/desktop/request/legacy/1" else predicted;

        var items: [8]Value = undefined;
        const n = @min(f.uris.len, items.len);
        for (f.uris[0..n], items[0..n]) |u, *it| it.* = .{ .string = u };
        const results = [_]Entry{.{ "uris", .{ .array = .{ .elem_sig = "s", .items = items[0..n] } } }};

        const early = f.respond_before_reply and !f.old_handle;
        if (early) bus.emit(handle, "org.freedesktop.portal.Request", "Response", "ua{sv}", .{ f.code, &results }) catch {};
        bus.replyTo(in, "o", .{handle}) catch {};
        if (!early) {
            // Give the client time to subscribe to the returned handle.
            bus.io.sleep(.fromMilliseconds(50), .awake) catch {};
            bus.emit(handle, "org.freedesktop.portal.Request", "Response", "ua{sv}", .{ f.code, &results }) catch {};
        }
        return true;
    }

    fn settingsCall(f: *FakePortal, bus: *Bus, in: *const conn.Incoming, member: []const u8, a: []const Value) bool {
        const read_one = std.mem.eql(u8, member, "ReadOne");
        if (!read_one and !std.mem.eql(u8, member, "Read")) return false;
        if (read_one and !f.has_read_one) return false;
        f.record(member, 0);
        if (a.len != 2) return false;
        const ns = a[0].asString() orelse return false;
        const key = a[1].asString() orelse return false;
        const value = for (f.settings) |e| {
            if (std.mem.eql(u8, e[0], key)) break e[1];
        } else null;
        if (!std.mem.eql(u8, ns, "org.freedesktop.appearance") or value == null) {
            bus.replyError(in, "org.freedesktop.portal.Error.NotFound", "no such setting") catch {};
            return true;
        }
        if (read_one) {
            bus.replyTo(in, "v", .{value.?}) catch {};
        } else {
            // Read wraps the value in one more variant.
            const inner = value.?;
            bus.replyTo(in, "v", .{Value{ .variant = &inner }}) catch {};
        }
        return true;
    }
};

const testing = std.testing;
const file_chooser = @import("file_chooser.zig");
const settings = @import("settings.zig");
const open_uri = @import("open_uri.zig");

const Harness = struct {
    daemon: conn.TestDaemon,
    portal: FakePortal,
    client: *Bus,

    fn start(h: *Harness, cfg: FakePortal) !bool {
        if (!try h.daemon.start()) return false;
        errdefer h.daemon.stop();
        h.portal = cfg;
        try h.portal.start(testing.allocator, testing.io, h.daemon.address());
        errdefer h.portal.stop();
        h.client = try Bus.connectAddress(testing.allocator, testing.io, h.daemon.address(), .{});
        return true;
    }

    fn stop(h: *Harness) void {
        h.client.deinit();
        h.portal.stop();
        h.daemon.stop();
    }
};

fn openAndWait(h: *Harness, req: @import("../api/dialog.zig").DialogRequest) !request.Response {
    const r = try request.Request.begin(testing.allocator, h.client, null);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const call = try file_chooser.buildCall(arena.allocator(), req, r.token());
    try h.client.callAsync(request.destination, request.object_path, file_chooser.interface, call.method, "ssa{sv}", .{ "", req.title, call.options }, r.replyHandler());
    return r.wait(5 * std.time.ns_per_s);
}

test "portal: Response before the call's reply is handled; uris become paths" {
    var h: Harness = undefined;
    if (!try h.start(.{ .uris = &.{ "file:///home/u/a%20b.zig", "file:///tmp/c" } })) return error.SkipZigTest;
    defer h.stop();
    var resp = try openAndWait(&h, .{ .request = 1, .kind = .open_files, .filters = &.{.{ .name = "Zig", .patterns = &.{"*.zig"} }} });
    defer resp.deinit();
    try testing.expectEqual(request.Code.success, resp.code);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(2, try file_chooser.paths(&resp, testing.allocator, &out));
    try testing.expectEqualStrings("/home/u/a b.zig\x00/tmp/c\x00", out.items);
    try testing.expectEqualStrings("OpenFile", h.portal.lastMethod());
    try testing.expectEqual(4, h.portal.last_option_count); // handle_token, modal, multiple, filters
}

test "portal: old portals answer on a different handle; cancel and save" {
    var h: Harness = undefined;
    if (!try h.start(.{ .old_handle = true, .code = 1 })) return error.SkipZigTest;
    defer h.stop();
    var resp = try openAndWait(&h, .{ .request = 2, .kind = .save_file, .default_path = "/tmp/x.txt" });
    defer resp.deinit();
    try testing.expectEqual(request.Code.cancelled, resp.code);
    try testing.expectEqualStrings("SaveFile", h.portal.lastMethod());
}

test "portal: missing portal gives unavailable through wait" {
    var d: conn.TestDaemon = undefined;
    if (!try d.start()) return error.SkipZigTest;
    defer d.stop();
    const client = try Bus.connectAddress(testing.allocator, testing.io, d.address(), .{});
    defer client.deinit();
    const r = try request.Request.begin(testing.allocator, client, null);
    defer r.deinit();
    try client.callAsync(request.destination, request.object_path, file_chooser.interface, "OpenFile", "ssa{sv}", .{ "", "t", &[_]Entry{} }, r.replyHandler());
    var resp = try r.wait(5 * std.time.ns_per_s);
    defer resp.deinit();
    try testing.expect(resp.unavailable);
    // Settings fall back to defaults.
    const app = settings.read(testing.allocator, client, 5 * std.time.ns_per_s);
    try testing.expectEqual(@import("../api/event.zig").ColorScheme.no_preference, app.scheme);
}

test "portal: Settings ReadOne vs Read fallback, and live changes" {
    var accent = [_]Value{ .{ .double = 0 }, .{ .double = 0.5 }, .{ .double = 1 } };
    const values = [_]Entry{
        .{ "color-scheme", .{ .u32 = 1 } },
        .{ "accent-color", .{ .structure = &accent } },
        .{ "contrast", .{ .u32 = 1 } },
    };
    inline for (.{ true, false }) |has_read_one| {
        var h: Harness = undefined;
        if (!try h.start(.{ .has_read_one = has_read_one, .settings = &values })) return error.SkipZigTest;
        defer h.stop();
        const app = settings.read(testing.allocator, h.client, 5 * std.time.ns_per_s);
        try testing.expectEqual(@import("../api/event.zig").ColorScheme.dark, app.scheme);
        try testing.expect(app.has_accent);
        try testing.expectEqual([3]u8{ 0, 128, 255 }, app.accent);
        try testing.expectEqual(@import("../api/event.zig").Contrast.high, app.contrast);
        try testing.expect(!app.reduced_motion);
        try testing.expectEqualStrings(if (has_read_one) "ReadOne" else "Read", h.portal.lastMethod());
    }

    var h: Harness = undefined;
    if (!try h.start(.{ .settings = &values })) return error.SkipZigTest;
    defer h.stop();
    const Seen = struct {
        app: std.atomic.Value(u32) = .init(0),
        fn on(ctx: ?*anyopaque, app: @import("../api/event.zig").Appearance) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.app.store(@intFromEnum(app.scheme) + 1, .release);
        }
    };
    var seen: Seen = .{};
    var w: settings.Watcher = .{ .bus = h.client, .current = .{}, .callback = .{ .ctx = &seen, .func = Seen.on } };
    try w.start();
    defer w.stop();
    // A round trip makes sure the match is installed before the signal.
    _ = settings.read(testing.allocator, h.client, 5 * std.time.ns_per_s);
    try h.portal.changeSetting("color-scheme", .{ .u32 = 2 });
    var tries: usize = 0;
    while (seen.app.load(.acquire) == 0 and tries < 500) : (tries += 1) try testing.io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectEqual(@intFromEnum(@import("../api/event.zig").ColorScheme.light) + 1, seen.app.load(.acquire));
}

test "portal: OpenURI for links, OpenFile with an fd for files; policy refuses others" {
    var h: Harness = undefined;
    if (!try h.start(.{})) return error.SkipZigTest;
    defer h.stop();
    const r1 = try open_uri.open(testing.allocator, h.client, "", "https://ziglang.org", .{}, null);
    var resp1 = try r1.wait(5 * std.time.ns_per_s);
    resp1.deinit();
    r1.deinit();
    try testing.expectEqualStrings("OpenURI", h.portal.lastMethod());
    try testing.expectEqualStrings("https://ziglang.org", h.portal.last_uri[0..h.portal.last_uri_len]);

    const r2 = try open_uri.open(testing.allocator, h.client, "", "file:///tmp", .{}, null);
    var resp2 = try r2.wait(5 * std.time.ns_per_s);
    resp2.deinit();
    r2.deinit();
    try testing.expectEqualStrings("OpenFile", h.portal.lastMethod());
    try testing.expect(h.portal.last_fd_ok);

    try testing.expectError(error.SchemeNotAllowed, open_uri.open(testing.allocator, h.client, "", "javascript:alert(1)", .{}, null));
    try testing.expectError(error.FileNotFound, open_uri.open(testing.allocator, h.client, "", "file:///nonexistent/zg", .{}, null));
}
