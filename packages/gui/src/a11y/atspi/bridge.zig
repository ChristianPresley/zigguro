//! The AT-SPI2 bridge (E04.F09.S01.T03): exposes an app's windows to Orca
//! and other AT-SPI2 clients over D-Bus, through zg_platform's pure-Zig
//! D-Bus client.
//!
//! - **Activation.** A worker thread connects to the session bus, reads
//!   `org.a11y.Status.IsEnabled`/`ScreenReaderEnabled` at `/org/a11y/bus`
//!   and follows their `PropertiesChanged`. When either is on it asks
//!   `org.a11y.Bus.GetAddress` for the accessibility bus and connects to
//!   it. Trees stay inactive (and cost nothing) until then, and go
//!   inactive again when both turn off.
//! - **Registration.** On the accessibility bus the bridge answers every
//!   method call itself (`ifaces.zig`, by path lookup into the snapshots)
//!   and embeds its application object with the registry
//!   (`org.a11y.atspi.Socket.Embed`), again whenever the registry
//!   announces `Available`.
//! - **Events.** Each window's tree update becomes
//!   `org.a11y.atspi.Event.Object` signals (`events.zig`).
//! - **Threading.** Method calls run on the bus's reader thread under
//!   `lock`, against snapshots; actions are posted to the UI thread.
//!   `addWindow`/`removeWindow`/`deinit` run on the UI thread.

const std = @import("std");
const zg_platform = @import("zg_platform");
const tree_mod = @import("../tree.zig");
const snap = @import("../snapshot.zig");
const window_mod = @import("../../core/window.zig");
const objects = @import("objects.zig");
const ifaces = @import("ifaces.zig");
const events = @import("events.zig");
const app_mod = @import("../../core/app.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const dbus = zg_platform.dbus;
const Bus = dbus.Bus;
const Incoming = dbus.conn.Incoming;
const Value = dbus.Value;
const A11yTree = tree_mod.A11yTree;
const Update = tree_mod.Update;
const Window = window_mod.Window;
const Ref = objects.Ref;

const log = std.log.scoped(.atspi);

/// Where the bridge connects.
pub const Options = struct {
    /// The session bus address; null without a session bus (no
    /// accessibility then, unless `a11y_address` is set).
    session_address: ?[]const u8 = null,
    /// Connect straight to this accessibility bus, skipping the status
    /// check (tests).
    a11y_address: ?[]const u8 = null,
    app_name: []const u8 = "zigguro",
    version: []const u8 = "0",
};

/// One window: its tree and the bridge it reports to.
pub const Win = struct {
    tree: A11yTree,
    bridge: *Bridge,
    win: *Window,
    /// The last `Snapshot.active` sent (window activate events).
    was_active: bool = false,
};

const status_service = "org.a11y.Bus";
const status_path = "/org/a11y/bus";
const registry_service = "org.a11y.atspi.Registry";
const reply_timeout_ns = 3 * std.time.ns_per_s;

/// See the module doc.
pub const Bridge = struct {
    gpa: Allocator,
    io: Io,
    session_address: ?[]u8 = null,
    a11y_address: ?[]u8 = null,
    app_name: []u8,
    version: []u8,

    /// Guards `windows`, `parent` and `app_id` (UI thread and readers).
    lock: Io.Mutex = .init,
    windows: std.ArrayList(*Win) = .empty,
    /// The registry's socket that embeds the application.
    parent_name: std.ArrayList(u8) = .empty,
    parent_path: std.ArrayList(u8) = .empty,
    /// Set by the registry through `Application.Id`.
    app_id: i32 = 0,

    session: ?*Bus = null,
    /// Set once connected; read from any thread.
    a11y: std.atomic.Value(?*Bus) = .init(null),
    /// A client wants accessibility: either `status` flag.
    enabled: std.atomic.Value(bool) = .init(false),
    /// `IsEnabled`, `ScreenReaderEnabled`.
    status: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) },
    worker: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Wakes the worker (status changes, stop).
    kick: std.atomic.Value(u32) = .init(0),
    /// Signals sent (tests).
    emitted: std.atomic.Value(u64) = .init(0),

    /// Starts the bridge; it connects in the background.
    pub fn init(gpa: Allocator, io: Io, opts: Options) !*Bridge {
        const b = try gpa.create(Bridge);
        errdefer gpa.destroy(b);
        b.* = .{ .gpa = gpa, .io = io, .app_name = try gpa.dupe(u8, opts.app_name), .version = undefined };
        errdefer gpa.free(b.app_name);
        b.version = try gpa.dupe(u8, opts.version);
        errdefer gpa.free(b.version);
        if (opts.session_address) |a| b.session_address = try gpa.dupe(u8, a);
        if (opts.a11y_address) |a| b.a11y_address = try gpa.dupe(u8, a);
        b.worker = std.Thread.spawn(.{}, run, .{b}) catch null;
        return b;
    }

    /// Disconnects and frees the bridge and its trees (UI thread).
    pub fn deinit(b: *Bridge) void {
        b.stopping.store(true, .release);
        b.wake();
        if (b.worker) |t| t.join();
        if (b.a11y.swap(null, .acq_rel)) |bus| bus.deinit();
        if (b.session) |s| s.deinit();
        for (b.windows.items) |w| release(w);
        b.windows.deinit(b.gpa);
        b.parent_name.deinit(b.gpa);
        b.parent_path.deinit(b.gpa);
        if (b.session_address) |a| b.gpa.free(a);
        if (b.a11y_address) |a| b.gpa.free(a);
        b.gpa.free(b.app_name);
        b.gpa.free(b.version);
        b.gpa.destroy(b);
    }

    /// Exposes `win`, numbered `window_id` in node ids (UI thread).
    pub fn addWindow(b: *Bridge, win: *Window, window_id: u32) Allocator.Error!void {
        const w = try b.gpa.create(Win);
        w.* = .{ .tree = .init(b.gpa, window_id), .bridge = b, .win = win };
        w.tree.listener = .{ .ctx = w, .f = onUpdate };
        w.tree.attach(win);
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.windows.append(b.gpa, w) catch |err| {
            w.tree.deinit();
            b.gpa.destroy(w);
            return err;
        };
        if (b.live()) w.tree.activate(true);
    }

    /// Stops exposing `win` (UI thread, before the window closes).
    pub fn removeWindow(b: *Bridge, win: *Window) void {
        const w = blk: {
            b.lock.lockUncancelable(b.io);
            defer b.lock.unlock(b.io);
            for (b.windows.items, 0..) |w, i| if (w.win == win) {
                _ = b.windows.orderedRemove(i);
                break :blk w;
            };
            return;
        };
        if (b.a11y.load(.acquire)) |bus| if (w.tree.publisher.peek()) |s| if (s.root()) |r| {
            var pb: objects.PathBuf = undefined;
            events.emitDefunct(bus, objects.pathOf(r.id, &pb)) catch {};
        };
        release(w);
    }

    /// Frees `w` now, or after a wake the tree already posted to the UI
    /// thread (posted calls run in order).
    fn release(w: *Win) void {
        w.tree.detach();
        if (w.tree.posted.load(.acquire)) {
            if (w.win.app.post(.{ .ctx = w, .f = freeWin })) |_| return else |_| {}
        }
        freeWin(w, w.win.app);
    }

    fn freeWin(ctx: *anyopaque, _: *app_mod.App) void {
        const w: *Win = @ptrCast(@alignCast(ctx));
        const gpa = w.tree.gpa;
        w.tree.deinit();
        gpa.destroy(w);
    }

    /// Connected and wanted: trees build snapshots and events go out.
    pub fn live(b: *const Bridge) bool {
        return b.enabled.load(.acquire) and b.a11y.load(.acquire) != null;
    }

    fn setEnabled(b: *Bridge, on: bool) void {
        b.enabled.store(on, .release);
        b.applyActivation();
    }

    fn applyActivation(b: *Bridge) void {
        const on = b.live();
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        for (b.windows.items) |w| w.tree.activate(on);
    }

    fn wake(b: *Bridge) void {
        _ = b.kick.fetchAdd(1, .release);
        b.io.futexWake(u32, &b.kick.raw, 1);
    }

    // -- connecting (worker thread) -----------------------------------------------

    fn run(b: *Bridge) void {
        if (b.a11y_address) |addr| {
            b.enabled.store(true, .release);
            b.connectA11y(addr) catch |err| log.debug("accessibility bus: {t}", .{err});
            return;
        }
        const addr = b.session_address orelse return;
        const s = Bus.connectAddress(b.gpa, b.io, addr, .{ .negotiate_fd = false }) catch |err| {
            log.debug("session bus: {t}", .{err});
            return;
        };
        b.session = s;
        _ = s.addMatch("type='signal',sender='" ++ status_service ++ "',path='" ++ status_path ++ "',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'", .{ .ctx = b, .func = onStatus }) catch {};
        b.enabled.store(b.readStatus(s), .release);
        while (!b.stopping.load(.acquire)) {
            const seen = b.kick.load(.acquire);
            if (b.enabled.load(.acquire) and b.a11y.load(.acquire) == null) {
                b.connectViaStatus(s) catch |err| log.debug("accessibility bus: {t}", .{err});
            }
            b.applyActivation();
            if (b.stopping.load(.acquire)) break;
            b.io.futexWaitTimeout(u32, &b.kick.raw, seen, .none) catch {};
        }
    }

    /// `IsEnabled or ScreenReaderEnabled`, false when the service is
    /// missing.
    fn readStatus(b: *Bridge, s: *Bus) bool {
        inline for (.{ "IsEnabled", "ScreenReaderEnabled" }, 0..) |prop, i| {
            if (getProperty(b.gpa, s, status_service, status_path, "org.a11y.Status", prop)) |v| b.status[i].store(v, .release) else |_| {}
        }
        return b.status[0].load(.acquire) or b.status[1].load(.acquire);
    }

    fn getProperty(gpa: Allocator, s: *Bus, dest: []const u8, path: []const u8, iface: []const u8, prop: []const u8) !bool {
        var p = try s.call(dest, path, "org.freedesktop.DBus.Properties", "Get", "ss", .{ iface, prop });
        defer p.deinit();
        var r = try p.wait(reply_timeout_ns);
        defer r.deinit();
        if (r.isError()) return error.NoService;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = try r.args(arena.allocator());
        if (a.len != 1) return error.Malformed;
        return a[0].asBool() orelse error.Malformed;
    }

    fn connectViaStatus(b: *Bridge, s: *Bus) !void {
        var p = try s.call(status_service, status_path, "org.a11y.Bus", "GetAddress", "", .{});
        defer p.deinit();
        var r = try p.wait(reply_timeout_ns);
        defer r.deinit();
        if (r.isError()) return error.NoService;
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = try r.args(arena.allocator());
        const addr = (if (a.len == 1) a[0].asString() else null) orelse return error.Malformed;
        try b.connectA11y(addr);
    }

    fn connectA11y(b: *Bridge, addr: []const u8) !void {
        const bus = try Bus.connectAddress(b.gpa, b.io, addr, .{ .negotiate_fd = false });
        errdefer bus.deinit();
        bus.setMethodHandler(.{ .ctx = b, .func = onMethod });
        _ = try bus.addMatch("type='signal',interface='org.a11y.atspi.Socket',member='Available'", .{ .ctx = b, .func = onAvailable });
        b.a11y.store(bus, .release);
        b.embed(bus, true);
        b.applyActivation();
    }

    /// Embeds the application with the registry. `wait`: block for the
    /// reply (worker thread); else take it on the reader.
    fn embed(b: *Bridge, bus: *Bus, wait: bool) void {
        const plug: Ref = .{ .name = bus.unique_name, .path = objects.root_path };
        if (!wait) {
            bus.callAsync(registry_service, objects.root_path, "org.a11y.atspi.Socket", "Embed", "(so)", .{plug}, .{ .ctx = b, .func = onEmbedded }) catch {};
            return;
        }
        var p = bus.call(registry_service, objects.root_path, "org.a11y.atspi.Socket", "Embed", "(so)", .{plug}) catch return;
        defer p.deinit();
        var r = p.wait(reply_timeout_ns) catch return;
        defer r.deinit();
        b.takeParent(&r);
    }

    fn onEmbedded(ctx: ?*anyopaque, reply: dbus.conn.Error!*dbus.conn.Reply) void {
        const b: *Bridge = @ptrCast(@alignCast(ctx.?));
        const r = reply catch return;
        b.takeParent(r);
    }

    fn takeParent(b: *Bridge, r: *dbus.conn.Reply) void {
        if (r.isError()) return;
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = r.args(arena.allocator()) catch return;
        if (a.len != 1 or a[0] != .structure or a[0].structure.len != 2) return;
        const name = a[0].structure[0].asString() orelse return;
        const path = a[0].structure[1].asString() orelse return;
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        b.parent_name.clearRetainingCapacity();
        b.parent_path.clearRetainingCapacity();
        b.parent_name.appendSlice(b.gpa, name) catch return;
        b.parent_path.appendSlice(b.gpa, path) catch return;
    }

    /// The registry's socket, or the null reference (under `lock`).
    pub fn parentRef(b: *const Bridge) Ref {
        if (b.parent_path.items.len == 0) return .none;
        return .{ .name = b.parent_name.items, .path = b.parent_path.items };
    }

    fn onAvailable(ctx: ?*anyopaque, _: *const Incoming) void {
        const b: *Bridge = @ptrCast(@alignCast(ctx.?));
        // A restarted registry: embed again (no waiting on the reader).
        if (b.a11y.load(.acquire)) |bus| b.embed(bus, false);
    }

    fn onStatus(ctx: ?*anyopaque, in: *const Incoming) void {
        const b: *Bridge = @ptrCast(@alignCast(ctx.?));
        const a = in.args() catch return;
        if (a.len < 2 or a[1] != .dict) return;
        if (!std.mem.eql(u8, a[0].asString() orelse "", "org.a11y.Status")) return;
        const d = a[1].dict;
        if (d.get("IsEnabled")) |v| if (v.asBool()) |on| b.status[0].store(on, .release);
        if (d.get("ScreenReaderEnabled")) |v| if (v.asBool()) |on| b.status[1].store(on, .release);
        b.enabled.store(b.status[0].load(.acquire) or b.status[1].load(.acquire), .release);
        b.wake();
    }

    // -- serving (reader thread) ----------------------------------------------------

    fn onMethod(ctx: ?*anyopaque, bus: *Bus, in: *const Incoming) bool {
        const b: *Bridge = @ptrCast(@alignCast(ctx.?));
        b.lock.lockUncancelable(b.io);
        defer b.lock.unlock(b.io);
        return ifaces.dispatch(b, bus, in);
    }

    /// The window numbered `window_id` (under `lock`).
    pub fn window(b: *const Bridge, window_id: u32) ?*Win {
        for (b.windows.items) |w| if (w.tree.window_id == window_id) return w;
        return null;
    }

    // -- events (UI thread) -----------------------------------------------------------

    fn onUpdate(ctx: *anyopaque, u: *const Update) void {
        const w: *Win = @ptrCast(@alignCast(ctx));
        const b = w.bridge;
        if (!b.enabled.load(.acquire)) return;
        const bus = b.a11y.load(.acquire) orelse return;
        const n = events.emitUpdate(bus, u, &w.was_active) catch return;
        _ = b.emitted.fetchAdd(n, .monotonic);
    }
};
