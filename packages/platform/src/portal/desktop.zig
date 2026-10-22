//! The portals the Linux backends use (E01.F04, E01.F05): file dialogs,
//! opening URIs and the appearance settings, on one session bus. The bus
//! connects and the settings are read on a short-lived thread, so start-up
//! never waits for the portal (it may be D-Bus activated). Answers arrive
//! on the bus reader thread; they are queued, `notify` wakes the backend,
//! and the backend `take`s them on its own thread.

const std = @import("std");
const Bus = @import("../dbus/conn.zig").Bus;
const request = @import("request.zig");
const file_chooser = @import("file_chooser.zig");
const open_uri = @import("open_uri.zig");
const settings = @import("settings.zig");
const dialog = @import("../api/dialog.zig");
const Appearance = @import("../api/event.zig").Appearance;

const log = std.log.scoped(.portal);

/// Something for the backend to turn into an event.
pub const Answer = union(enum) {
    /// A file dialog's answer: NUL-separated paths, owned by the taker
    /// (allocated with the desktop's allocator).
    dialog: struct { request: u32, paths: []u8, cancelled: bool },
    /// The appearance read at start-up, or after a `SettingChanged`.
    appearance: Appearance,
};

/// Wakes the thread that calls `take`. Runs on the bus reader thread or
/// the start-up thread.
pub const Notify = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

/// What `init` needs.
pub const Options = struct {
    /// The bus address; null means no session bus (no portal).
    address: ?[]const u8 = null,
    /// How long start-up waits for each settings read.
    timeout_ns: u64 = 2 * std.time.ns_per_s,
};

/// The address of the session bus in `env`: `DBUS_SESSION_BUS_ADDRESS`,
/// else `unix:path=$XDG_RUNTIME_DIR/bus`. Written to `buf`.
pub fn sessionAddress(buf: []u8, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("DBUS_SESSION_BUS_ADDRESS")) |a| return if (a.len <= buf.len) blk: {
        @memcpy(buf[0..a.len], a);
        break :blk buf[0..a.len];
    } else null;
    const dir = env.get("XDG_RUNTIME_DIR") orelse return null;
    return std.fmt.bufPrint(buf, "unix:path={s}/bus", .{dir}) catch null;
}

/// One dialog or URI call in flight.
const Job = struct {
    d: *Desktop,
    request: u32,
    req: *request.Request = undefined,
    /// The callback has finished with the job.
    done: std.atomic.Value(bool) = .init(false),
};

/// The portal client. Pin it in memory (the threads point at it).
pub const Desktop = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    notify: Notify,
    timeout_ns: u64,
    address: ?[]u8 = null,
    /// Connects and reads the settings; joined before the bus is used.
    starter: ?std.Thread = null,
    start_lock: std.Io.Mutex = .init,
    /// Set by the start-up thread; read only after joining it.
    bus: ?*Bus = null,
    watcher: settings.Watcher = undefined,
    watching: bool = false,
    /// Set once a call found no portal on the bus: later calls fail at
    /// once with `error.Unsupported`, so callers use their own UI.
    missing: std.atomic.Value(bool) = .init(false),
    lock: std.Io.Mutex = .init,
    answers: std.ArrayList(Answer) = .empty,
    jobs: std.ArrayList(*Job) = .empty,

    /// Starts connecting in the background. Without an address (or when
    /// the thread cannot start) every call returns `error.Unsupported`.
    pub fn init(d: *Desktop, gpa: std.mem.Allocator, io: std.Io, notify: Notify, opts: Options) void {
        d.* = .{ .gpa = gpa, .io = io, .notify = notify, .timeout_ns = opts.timeout_ns };
        const a = opts.address orelse return;
        d.address = gpa.dupe(u8, a) catch return;
        d.starter = std.Thread.spawn(.{}, start, .{d}) catch null;
    }

    fn start(d: *Desktop) void {
        const bus = Bus.connectAddress(d.gpa, d.io, d.address.?, .{}) catch |err| {
            log.info("no session bus ({t}): native dialogs and URI opening are unavailable", .{err});
            return;
        };
        d.bus = bus;
        const app = settings.read(d.gpa, bus, d.timeout_ns);
        d.watcher = .{ .bus = bus, .current = app, .callback = .{ .ctx = d, .func = onAppearance } };
        if (d.watcher.start()) |_| {
            d.watching = true;
        } else |err| log.warn("following appearance settings: {t}", .{err});
        d.push(.{ .appearance = app });
    }

    /// The bus, once the start-up thread is done; null without one.
    fn ready(d: *Desktop) ?*Bus {
        d.start_lock.lockUncancelable(d.io);
        defer d.start_lock.unlock(d.io);
        if (d.starter) |t| {
            t.join();
            d.starter = null;
        }
        return d.bus;
    }

    /// Closes the bus (which fails calls still in flight) and frees
    /// everything. Answers not yet taken are dropped.
    pub fn deinit(d: *Desktop) void {
        if (d.ready()) |bus| {
            if (d.watching) d.watcher.stop();
            bus.deinit();
        }
        for (d.jobs.items) |j| {
            j.req.free();
            d.gpa.destroy(j);
        }
        d.jobs.deinit(d.gpa);
        for (d.answers.items) |a| switch (a) {
            .dialog => |r| d.gpa.free(r.paths),
            .appearance => {},
        };
        d.answers.deinit(d.gpa);
        if (d.address) |a| d.gpa.free(a);
    }

    /// The next answer, if any. The caller owns a dialog's paths.
    pub fn take(d: *Desktop) ?Answer {
        d.lock.lockUncancelable(d.io);
        defer d.lock.unlock(d.io);
        if (d.answers.items.len == 0) return null;
        return d.answers.orderedRemove(0);
    }

    /// Opens a FileChooser dialog; its answer comes back as
    /// `Answer.dialog`. `parent` is a portal window handle or "".
    pub fn openDialog(d: *Desktop, req: dialog.DialogRequest, parent: []const u8) error{ Unsupported, OutOfMemory, SystemResources }!void {
        const bus = d.usable() orelse return error.Unsupported;
        return d.begin(req.request, onDialog, struct {
            fn call(gpa: std.mem.Allocator, b: *Bus, cb: request.Callback, ctx: anytype) anyerror!*request.Request {
                return file_chooser.open(gpa, b, ctx.req, ctx.parent, cb);
            }
        }.call, bus, .{ .req = req, .parent = parent });
    }

    /// Asks the portal to open `uri` (http, https, mailto or file).
    pub fn openUri(d: *Desktop, uri: []const u8, parent: []const u8) error{ Unsupported, OutOfMemory, SystemResources }!void {
        const bus = d.usable() orelse return error.Unsupported;
        if (open_uri.scheme(uri)) |s| {
            const policy: open_uri.SchemePolicy = .{};
            if (!policy.allow(policy.ctx, s)) return error.Unsupported;
        } else return error.Unsupported;
        return d.begin(0, onUri, struct {
            fn call(gpa: std.mem.Allocator, b: *Bus, cb: request.Callback, ctx: anytype) anyerror!*request.Request {
                return open_uri.open(gpa, b, ctx.parent, ctx.uri, .{}, cb);
            }
        }.call, bus, .{ .uri = uri, .parent = parent });
    }

    fn usable(d: *Desktop) ?*Bus {
        const bus = d.ready() orelse return null;
        if (d.missing.load(.acquire)) return null;
        d.reap();
        return bus;
    }

    fn begin(d: *Desktop, id: u32, comptime cb: fn (?*anyopaque, *request.Response) void, comptime call: anytype, bus: *Bus, ctx: anytype) error{ Unsupported, OutOfMemory, SystemResources }!void {
        const job = try d.gpa.create(Job);
        job.* = .{ .d = d, .request = id };
        d.lock.lockUncancelable(d.io);
        defer d.lock.unlock(d.io);
        d.jobs.ensureUnusedCapacity(d.gpa, 1) catch {
            d.gpa.destroy(job);
            return error.OutOfMemory;
        };
        job.req = call(d.gpa, bus, .{ .ctx = job, .func = cb }, ctx) catch |err| {
            d.gpa.destroy(job);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.InvalidUri or err == error.SchemeNotAllowed or err == error.FileNotFound) return error.Unsupported;
            log.warn("portal call: {t}", .{err});
            return error.SystemResources;
        };
        d.jobs.appendAssumeCapacity(job);
    }

    /// Frees the jobs whose callback and reply have both run.
    fn reap(d: *Desktop) void {
        d.lock.lockUncancelable(d.io);
        defer d.lock.unlock(d.io);
        var i: usize = 0;
        while (i < d.jobs.items.len) {
            const j = d.jobs.items[i];
            if (j.done.load(.acquire) and j.req.settled()) {
                j.req.deinit();
                d.gpa.destroy(j);
                _ = d.jobs.swapRemove(i);
            } else i += 1;
        }
    }

    fn push(d: *Desktop, a: Answer) void {
        {
            d.lock.lockUncancelable(d.io);
            defer d.lock.unlock(d.io);
            d.answers.append(d.gpa, a) catch {
                log.warn("portal answer dropped: out of memory", .{});
                if (a == .dialog) d.gpa.free(a.dialog.paths);
                return;
            };
        }
        d.notify.func(d.notify.ctx);
    }

    fn noteMissing(d: *Desktop, resp: *const request.Response) void {
        if (resp.unavailable and !d.missing.swap(true, .acq_rel)) log.warn("no xdg-desktop-portal: native dialogs and URI opening are unavailable", .{});
    }

    fn onDialog(ctx: ?*anyopaque, resp: *request.Response) void {
        const job: *Job = @ptrCast(@alignCast(ctx.?));
        const d = job.d;
        defer job.done.store(true, .release);
        defer resp.deinit();
        d.noteMissing(resp);
        var paths: std.ArrayList(u8) = .empty;
        defer paths.deinit(d.gpa);
        var cancelled = resp.code != .success;
        if (!cancelled) _ = file_chooser.paths(resp, d.gpa, &paths) catch {
            cancelled = true;
        };
        const owned: []u8 = if (cancelled) &.{} else paths.toOwnedSlice(d.gpa) catch blk: {
            cancelled = true;
            break :blk &.{};
        };
        d.push(.{ .dialog = .{ .request = job.request, .paths = owned, .cancelled = cancelled } });
    }

    fn onUri(ctx: ?*anyopaque, resp: *request.Response) void {
        const job: *Job = @ptrCast(@alignCast(ctx.?));
        defer job.done.store(true, .release);
        defer resp.deinit();
        job.d.noteMissing(resp);
        if (resp.code == .other and !resp.unavailable) log.warn("the portal could not open a URI", .{});
    }

    fn onAppearance(ctx: ?*anyopaque, app: Appearance) void {
        const d: *Desktop = @ptrCast(@alignCast(ctx.?));
        d.push(.{ .appearance = app });
    }
};

const testing = std.testing;
const conn = @import("../dbus/conn.zig");
const FakePortal = @import("fake_portal.zig").FakePortal;

const Woken = struct {
    n: std.atomic.Value(u32) = .init(0),
    fn on(ctx: *anyopaque) void {
        const w: *Woken = @ptrCast(@alignCast(ctx));
        _ = w.n.fetchAdd(1, .release);
    }
};

fn takeWait(d: *Desktop) !Answer {
    var tries: usize = 0;
    while (tries < 500) : (tries += 1) {
        if (d.take()) |a| return a;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.Timeout;
}

test "desktop: appearance at start, dialogs, URIs, and a missing portal" {
    var daemon: conn.TestDaemon = undefined;
    if (!try daemon.start()) return error.SkipZigTest;
    defer daemon.stop();
    var portal: FakePortal = .{
        .uris = &.{"file:///tmp/a%20b"},
        .settings = &.{.{ "color-scheme", .{ .u32 = 1 } }},
    };
    try portal.start(testing.allocator, testing.io, daemon.address());
    defer portal.stop();

    var woken: Woken = .{};
    var d: Desktop = undefined;
    d.init(testing.allocator, testing.io, .{ .ctx = &woken, .func = Woken.on }, .{ .address = daemon.address() });
    defer d.deinit();
    const first = try takeWait(&d);
    try testing.expectEqual(@import("../api/event.zig").ColorScheme.dark, first.appearance.scheme);

    try d.openDialog(.{ .request = 7, .kind = .open_file }, "x11:2a");
    const ans = try takeWait(&d);
    defer testing.allocator.free(ans.dialog.paths);
    try testing.expectEqual(7, ans.dialog.request);
    try testing.expect(!ans.dialog.cancelled);
    try testing.expectEqualStrings("/tmp/a b\x00", ans.dialog.paths);
    try testing.expect(woken.n.load(.acquire) >= 2);

    try d.openUri("https://ziglang.org", "");
    var tries: usize = 0;
    while (!std.mem.eql(u8, portal.lastMethod(), "OpenURI") and tries < 500) : (tries += 1) try testing.io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectEqualStrings("OpenURI", portal.lastMethod());
    try testing.expectError(error.Unsupported, d.openUri("javascript:x", ""));

    // A live change.
    try portal.changeSetting("color-scheme", .{ .u32 = 2 });
    const changed = try takeWait(&d);
    try testing.expectEqual(@import("../api/event.zig").ColorScheme.light, changed.appearance.scheme);
}

test "desktop: no portal on the bus cancels once, then refuses" {
    var daemon: conn.TestDaemon = undefined;
    if (!try daemon.start()) return error.SkipZigTest;
    defer daemon.stop();
    var woken: Woken = .{};
    var d: Desktop = undefined;
    d.init(testing.allocator, testing.io, .{ .ctx = &woken, .func = Woken.on }, .{ .address = daemon.address(), .timeout_ns = std.time.ns_per_s });
    defer d.deinit();
    // Defaults when the settings cannot be read.
    try testing.expectEqual(@import("../api/event.zig").ColorScheme.no_preference, (try takeWait(&d)).appearance.scheme);
    try d.openDialog(.{ .request = 1, .kind = .open_file }, "");
    const ans = try takeWait(&d);
    try testing.expect(ans.dialog.cancelled);
    try testing.expectEqual(0, ans.dialog.paths.len);
    try testing.expectError(error.Unsupported, d.openDialog(.{ .request = 2, .kind = .open_file }, ""));

    // Without an address nothing connects.
    var none: Desktop = undefined;
    none.init(testing.allocator, testing.io, .{ .ctx = &woken, .func = Woken.on }, .{});
    defer none.deinit();
    try testing.expectError(error.Unsupported, none.openUri("https://ziglang.org", ""));
}

test "session bus address from the environment" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    var buf: [128]u8 = undefined;
    try testing.expectEqual(null, sessionAddress(&buf, &env));
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    try testing.expectEqualStrings("unix:path=/run/user/1000/bus", sessionAddress(&buf, &env).?);
    try env.put("DBUS_SESSION_BUS_ADDRESS", "unix:abstract=x");
    try testing.expectEqualStrings("unix:abstract=x", sessionAddress(&buf, &env).?);
}
