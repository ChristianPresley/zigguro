//! The X11 backend (E01.F05.S02.T01, first part): top-level windows with
//! ICCCM/EWMH basics (WM_DELETE_WINDOW, WM_CLASS, _NET_WM_NAME, _NET_WM_PID,
//! WM_NORMAL_HINTS, _NET_WM_STATE requests), core-protocol keyboard and
//! pointer input, `Xft.dpi` scaling, Expose repaint, and frame pacing from
//! a refresh-rate timer. Frames reach the window through the CPU presenter
//! in `present.zig` (MIT-SHM or PutImage).
//!
//! Threads: `Conn` reads on one thread only, so this backend has no
//! platform thread. The UI thread dispatches X events inside `pollEvents`
//! and `waitEvents`. Any thread may `submit`, `wake` or present; requests
//! go through the connection's lock. One mutex guards the windows and the
//! staged events.
//!
//! Selections (E01.F05.S03.T01) live in `selection.zig`: CLIPBOARD and
//! PRIMARY with TARGETS, MULTIPLE, TIMESTAMP and INCR, on a hidden window.
//! Large answers become large payloads (`Platform.release`).
//!
//! Keyboard (E01.F05.S02.T02): with XKB the server's keymap becomes the
//! shared `xkb.Keymap` (`keymap_from_server.zig`), modifier and group
//! state follow StateNotify, detectable autorepeat marks repeats, and
//! keys go through the Wayland seat's keyboard logic for text, compose
//! and chords. Without XKB, the core keymap in `keymap.zig`.
//!
//! Pointer (E01.F05.S02.T02): with XInput 2.2+, `xinput2.zig` events
//! replace core pointer events: subpixel positions, smooth scrolling from
//! scroll valuators (emulated wheel buttons are dropped) and touch.
//! Without XI2, core events and wheel buttons.
//!
//! Not yet here (later E01.F05 tasks): RandR monitors, _NET_WM_SYNC_REQUEST and _NET_WM_PING, cursors,
//! XDND (#253).

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const types = @import("../api/types.zig");
const keys_api = @import("../api/keys.zig");
const event_api = @import("../api/event.zig");
const window_api = @import("../api/window.zig");
const surface = @import("../api/surface.zig");
const clipboard = @import("../api/clipboard.zig");
const native_api = @import("../api/native.zig");
const platform_api = @import("../api/platform.zig");
const PayloadArena = @import("../queue/payload_arena.zig").PayloadArena;
const Wake = @import("../queue/wake.zig").Wake;

const conn_mod = @import("conn.zig");
const Conn = conn_mod.Conn;
const proto = @import("proto.zig");
const dpi = @import("dpi.zig");
const Keymap = @import("keymap.zig").Keymap;
const modsFromState = @import("keymap.zig").modsFromState;
const present_mod = @import("present.zig");
const Presenter = present_mod.Presenter;
const dri3 = @import("dri3.zig");
const selection = @import("selection.zig");
const xkb_ext = @import("xkb.zig");
const xinput2 = @import("xinput2.zig");
const seat_mod = @import("../wayland/seat.zig");
const compose = @import("../xkb/compose.zig");

const Event = event_api.Event;
const Command = window_api.Command;
const WindowId = types.WindowId;
const PxSize = types.PxSize;
const Platform = platform_api.Platform;
const Error = platform_api.Error;

const log = std.log.scoped(.x11);

/// Options for `X11Backend.init`.
pub const InitOptions = struct {
    /// The environment (`DISPLAY`, `XAUTHORITY`, `ZG_SCALE`,
    /// `ZG_X11_PRESENT`).
    environ_map: ?*const std.process.Environ.Map = null,
    /// Overrides `DISPLAY`.
    display: ?[]const u8 = null,
    /// Forces a presenter path; null picks MIT-SHM when available.
    present: ?present_mod.Path = null,
    /// Frame interval while frames are requested.
    refresh_ns: u32 = 16_666_667,
};

const atom_names = [_][]const u8{
    "WM_PROTOCOLS",
    "WM_DELETE_WINDOW",
    "WM_CHANGE_STATE",
    "UTF8_STRING",
    "_NET_WM_NAME",
    "_NET_WM_PID",
    "_NET_WM_STATE",
    "_NET_WM_STATE_MAXIMIZED_VERT",
    "_NET_WM_STATE_MAXIMIZED_HORZ",
    "_NET_WM_STATE_FULLSCREEN",
    "_NET_WM_WINDOW_TYPE",
    "_NET_WM_WINDOW_TYPE_NORMAL",
    "_NET_ACTIVE_WINDOW",
};
const Atoms = @import("atoms.zig").AtomTable(&atom_names);

/// Events a top-level window listens for.
const window_events = proto.EventMask.key_press | proto.EventMask.key_release |
    proto.EventMask.button_press | proto.EventMask.button_release |
    proto.EventMask.enter_window | proto.EventMask.leave_window |
    proto.EventMask.pointer_motion | proto.EventMask.exposure |
    proto.EventMask.visibility_change | proto.EventMask.structure_notify |
    proto.EventMask.focus_change | proto.EventMask.property_change;

/// Multi-click timing.
const double_click_ns: u64 = 400 * std.time.ns_per_ms;
const double_click_px: f32 = 4;

/// One window and its presenter, allocated together so pointers stay put.
const Window = struct {
    id: WindowId,
    xid: u32,
    gc: u32,
    size: PxSize,
    serial: u32 = 0,
    presenter: Presenter,
    frame_requested: bool = false,
    last_frame_ns: u64 = 0,
    occluded: bool = false,
    focused: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    last_click_ns: u64 = 0,
    last_click_pos: [2]f32 = .{ -100, -100 },
    last_click_button: u8 = 0,
    clicks: u8 = 0,
};

/// Where the seat's keyboard logic puts events. Mutex held.
const Sink = struct {
    b: *X11Backend,

    /// Stages an event.
    pub fn stage(s: Sink, ev: Event) !void {
        s.b.stage(ev);
    }

    /// Copies key text into the payload arena.
    pub fn text(s: Sink, t: []const u8) types.PayloadSlice {
        return s.b.arena.put(t) catch .empty;
    }
};

/// The X11 backend.
pub const X11Backend = struct {
    gpa: Allocator,
    io: Io,
    opts: InitOptions,
    conn: *Conn,
    atoms: Atoms,
    /// The core keymap, when the server has no XKB.
    keymap: Keymap = .{},
    /// The XKB event base, or null without XKB.
    xkb_event: ?u8 = null,
    /// Keyboard state and logic (XKB path). Guarded by the mutex.
    seat: seat_mod.Seat = .{},
    compose_table: ?compose.ComposeTable = null,
    /// Loads compose rules off the UI thread at startup.
    compose_thread: ?std.Thread = null,
    /// XInput2's major opcode, or null without XI 2.2.
    xi_opcode: ?u8 = null,
    /// Scroll valuators. Guarded by the mutex.
    scrolling: xinput2.Scrolling = .{},
    /// The last pointer position, to tell scroll-only motion apart.
    ptr_pos: [2]f32 = .{ -1, -1 },
    scale: f32 = 1.0,
    path: present_mod.Path,
    /// The MIT-SHM event base, for ShmCompletion.
    shm_event: ?u8 = null,
    /// DRI3/Present support (dmabuf import), or null.
    gpu: ?dri3.Dri3 = null,

    mutex: Io.Mutex = .init,
    windows: std.ArrayList(*Window) = .empty,
    next_win: u32 = 1,
    staged: std.ArrayList(Event) = .empty,
    /// Selections. Guarded by the mutex.
    sel: selection.Selections = undefined,
    /// The newest server timestamp seen in an event (0 = CurrentTime).
    last_time: u32 = 0,
    /// Payloads over the arena's limit, by id. Guarded by the mutex.
    large: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    next_large: u32 = 0,

    arena: PayloadArena,
    ui_wake: Wake,
    wake_pending: std.atomic.Value(bool) = .init(false),
    /// Set when the connection failed.
    dead: bool = false,
    hooks: native_api.NativeHooks,

    /// Connects, reads the keyboard mapping and scale, and picks the
    /// presenter path.
    pub fn init(gpa: Allocator, io: Io, opts: InitOptions) !*X11Backend {
        var empty_env: std.process.Environ.Map = .init(gpa);
        defer empty_env.deinit();
        const env = opts.environ_map orelse &empty_env;
        const conn = try Conn.connect(gpa, io, env, .{ .display = opts.display });
        errdefer conn.deinit();
        var arena = try PayloadArena.init(gpa);
        errdefer arena.deinit(gpa);
        var ui_wake = try Wake.init(io);
        errdefer ui_wake.deinit();

        const b = try gpa.create(X11Backend);
        errdefer gpa.destroy(b);
        b.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .conn = conn,
            .atoms = try conn.internAtoms(&atom_names),
            .path = .put_image,
            .arena = arena,
            .ui_wake = ui_wake,
            .hooks = .{
                .ptr = b,
                .win32SetMessageHook = noHook,
                .win32CreateMessageWindow = noMsgWindow,
                .win32DestroyMessageWindow = noDestroy,
                .windowHandle = windowHandle,
            },
        };
        b.xkb_event = xkb_ext.enable(conn);
        if (b.xkb_event != null) {
            b.loadXkbKeymap() catch |err| {
                log.warn("XKB keymap unavailable ({t}); using the core keymap", .{err});
                b.xkb_event = null;
            };
        }
        if (b.xkb_event == null) try b.loadKeymap();
        errdefer b.keymap.deinit(gpa);
        errdefer b.seat.deinit(gpa);
        b.enableXi2();
        errdefer b.scrolling.deinit(gpa);
        b.sel = try .init(gpa, conn);
        errdefer b.sel.deinit();
        b.scale = dpi.envScale(opts.environ_map) orelse b.readXftScale();
        const shm_ok = b.shmUsable();
        b.path = b.pickPath(env, shm_ok);
        // ZG_X11_PRESENT=shm|putimage (or a forced path) keeps E02 on CPU
        // buffers.
        const cpu_forced = opts.present != null or env.get("ZG_X11_PRESENT") != null and !std.mem.eql(u8, env.get("ZG_X11_PRESENT").?, "dri3");
        if (!cpu_forced) b.gpu = b.probeGpu();
        errdefer if (b.gpu) |*g| g.deinit(gpa);
        if (b.xkb_event != null) b.startCompose(env);
        log.info("X11 display ready: {d}x{d}, scale {d}, presenting with {t}{s}", .{ conn.screen().width_px, conn.screen().height_px, b.scale, b.path, if (b.gpu != null) " and DRI3/Present" else "" });
        return b;
    }

    fn loadKeymap(b: *X11Backend) !void {
        const s = &b.conn.setup;
        const count: u8 = s.max_keycode - s.min_keycode + 1;
        const r = try b.conn.reply(try b.conn.request(proto.GetKeyboardMapping, .{ .first_keycode = s.min_keycode, .count = count }, &.{}));
        const km = try Keymap.init(b.gpa, s.min_keycode, r.keysyms_per_keycode, r.keysyms);
        b.keymap.deinit(b.gpa);
        b.keymap = km;
    }

    /// Fetches the server's XKB keymap and state into the seat.
    fn loadXkbKeymap(b: *X11Backend) !void {
        const km = try xkb_ext.fetchKeymap(b.gpa, b.conn);
        b.seat.setKeymap(b.gpa, km);
        const st = (try b.conn.reply(try b.conn.request(xkb_ext.GetState, .{}, &.{}))).state;
        b.seat.modifiers(0, st.base, st.latched, st.locked, st.group);
    }

    /// Turns on XInput 2.2+ pointer and touch events, when the server
    /// has them, and reads the scroll valuators.
    fn enableXi2(b: *X11Backend) void {
        const info = b.conn.extension("XInputExtension") orelse return;
        const v = b.conn.reply(b.conn.request(xinput2.QueryVersion, .{}, &.{}) catch return) catch return;
        if (!v.atLeast(2, 2)) return;
        b.loadScrollValuators() catch |err| {
            log.warn("XIQueryDevice failed: {t}", .{err});
            return;
        };
        _ = b.conn.request(xinput2.SelectEvents, .{ .window = b.conn.screen().root, .device_id = xinput2.Device.all, .mask = 1 << xinput2.EventType.hierarchy_changed }, &.{}) catch return;
        b.xi_opcode = info.major_opcode;
    }

    fn loadScrollValuators(b: *X11Backend) !void {
        const r = try b.conn.reply(try b.conn.request(xinput2.QueryDevice, .{}, &.{}));
        try b.scrolling.load(b.gpa, r.bytes);
    }

    /// Starts loading compose rules (XCOMPOSEFILE, ~/.XCompose, the
    /// locale's file) on a helper thread; keys compose once it is done.
    fn startCompose(b: *X11Backend, env: *const std.process.Environ.Map) void {
        var copy: std.process.Environ.Map = .init(b.gpa);
        for ([_][]const u8{ "XCOMPOSEFILE", "HOME", "LC_ALL", "LC_CTYPE", "LANG" }) |k| if (env.get(k)) |v| {
            copy.put(k, v) catch {
                copy.deinit();
                return;
            };
        };
        b.compose_thread = std.Thread.spawn(.{}, loadCompose, .{ b, copy }) catch |err| {
            log.warn("compose loader thread: {t}", .{err});
            copy.deinit();
            return;
        };
    }

    fn loadCompose(b: *X11Backend, env_in: std.process.Environ.Map) void {
        var env = env_in;
        defer env.deinit();
        const t = compose.ComposeTable.loadDefault(b.gpa, b.io, &env) catch |err| {
            log.warn("loading compose rules: {t}", .{err});
            return;
        };
        b.lock();
        defer b.unlock();
        b.compose_table = t;
        b.seat.compose = .init(&b.compose_table.?);
    }

    fn readXftScale(b: *X11Backend) f32 {
        const ck = b.conn.request(proto.GetProperty, .{ .window = b.conn.screen().root, .property = proto.Atom.resource_manager, .type = proto.Atom.string }, &.{}) catch return 1.0;
        const r = b.conn.reply(ck) catch return 1.0;
        const d = dpi.parseXftDpi(r.value) orelse return 1.0;
        return dpi.scaleForDpi(d);
    }

    fn pickPath(b: *X11Backend, env: *const std.process.Environ.Map, shm_ok: bool) present_mod.Path {
        if (b.opts.present) |p| return if (p == .shm and !shm_ok) .put_image else p;
        if (env.get("ZG_X11_PRESENT")) |v| {
            if (std.mem.eql(u8, v, "putimage")) return .put_image;
        }
        return if (shm_ok) .shm else .put_image;
    }

    fn probeGpu(b: *X11Backend) ?dri3.Dri3 {
        const p = (dri3.Probe.send(b.conn, b.conn.screen().root) catch return null) orelse return null;
        return p.finish(b.gpa, b.conn) catch null;
    }

    fn shmUsable(b: *X11Backend) bool {
        const info = b.conn.extension("MIT-SHM") orelse return false;
        const v = b.conn.reply(b.conn.request(proto.ShmQueryVersion, .{}, &.{}) catch return false) catch return false;
        if (v.major < 1 or (v.major == 1 and v.minor < 2)) return false;
        b.shm_event = info.first_event;
        return true;
    }

    /// The type-erased interface.
    pub fn platform(b: *X11Backend) Platform {
        return Platform.fromImpl(X11Backend, b);
    }

    fn lock(b: *X11Backend) void {
        b.mutex.lockUncancelable(b.io);
    }
    fn unlock(b: *X11Backend) void {
        b.mutex.unlock(b.io);
    }

    fn nowNs(b: *X11Backend) u64 {
        return @intCast(@max(0, Io.Clock.awake.now(b.io).nanoseconds));
    }

    fn find(b: *X11Backend, id: WindowId) ?*Window {
        for (b.windows.items) |w| if (w.id == id) return w;
        return null;
    }

    fn byXid(b: *X11Backend, xid: u32) ?*Window {
        for (b.windows.items) |w| if (w.xid == xid) return w;
        return null;
    }

    fn stage(b: *X11Backend, ev: Event) void {
        b.staged.append(b.gpa, ev) catch log.warn("event dropped: out of memory", .{});
    }

    // ---- Platform.VTable ----

    /// See `Platform.VTable.createWindow`. The window maps at once; its
    /// background stays untouched (no flash) until the first present.
    pub fn createWindow(b: *X11Backend, opts: window_api.WindowOptions) Error!WindowId {
        const c = b.conn;
        const s = c.screen();
        const w = b.gpa.create(Window) catch return error.OutOfMemory;
        errdefer b.gpa.destroy(w);
        const xid = c.newXid() catch return error.SystemResources;
        const gc = c.newXid() catch return error.SystemResources;
        const size: PxSize = .{ .w = std.math.clamp(opts.size.w, 1, 16384), .h = std.math.clamp(opts.size.h, 1, 16384) };
        b.lock();
        defer b.unlock();
        const id: WindowId = @enumFromInt(b.next_win);
        b.next_win += 1;
        w.* = .{ .id = id, .xid = xid, .gc = gc, .size = size, .presenter = .init(b.gpa, b.io, c, b.path, xid, gc, s.root_depth, id) };
        w.presenter.bind();
        if (b.gpu) |*g| w.presenter.gpu = g;
        b.createX(w, opts) catch return error.SystemResources;
        b.windows.append(b.gpa, w) catch {
            _ = c.request(proto.DestroyWindow, .{ .window = xid }, &.{}) catch {};
            return error.OutOfMemory;
        };
        b.stage(.{ .window_configure = .{ .win = id, .size = size, .scale = .{ .factor = b.scale }, .state = .{}, .serial = 0, .screen_origin_px = null } });
        return id;
    }

    fn createX(b: *X11Backend, w: *Window, opts: window_api.WindowOptions) !void {
        const c = b.conn;
        const s = c.screen();
        _ = try c.request(proto.CreateWindow, .{
            .data = s.root_depth,
            .wid = w.xid,
            .parent = s.root,
            .x = 0,
            .y = 0,
            .width = @intCast(w.size.w),
            .height = @intCast(w.size.h),
            .visual = s.root_visual,
            .values = .{
                .values = .{
                    .background_pixmap = 0,
                    .border_pixel = 0,
                    .bit_gravity = 1, // NorthWest: keep pixels on resize
                    .event_mask = window_events,
                    .colormap = s.default_colormap,
                },
            },
        }, &.{});
        _ = try c.request(proto.CreateGC, .{ .cid = w.gc, .drawable = w.xid, .values = .{ .values = .{ .graphics_exposures = 0 } } }, &.{});
        if (b.gpu != null) _ = try c.request(dri3.PresentSelectInput, .{ .eid = try c.newXid(), .window = w.xid, .event_mask = dri3.EventMask.complete | dri3.EventMask.idle }, &.{});
        if (b.xi_opcode != null) _ = try c.request(xinput2.SelectEvents, .{ .window = w.xid, .device_id = xinput2.Device.all_master, .mask = xinput2.windowMask(true) }, &.{});
        const a = &b.atoms;
        try b.setAtoms(w.xid, a.get("WM_PROTOCOLS"), &.{a.get("WM_DELETE_WINDOW")});
        try b.setAtoms(w.xid, a.get("_NET_WM_WINDOW_TYPE"), &.{a.get("_NET_WM_WINDOW_TYPE_NORMAL")});
        try b.setTitle(w.xid, opts.title);
        // WM_CLASS must match the desktop file's StartupWMClass (E17).
        try b.setProp(w.xid, proto.Atom.wm_class, proto.Atom.string, 8, "zigguro\x00Zigguro\x00");
        var pid: [4]u8 = undefined;
        std.mem.writeInt(u32, &pid, @intCast(linux.getpid()), .little);
        try b.setProp(w.xid, a.get("_NET_WM_PID"), proto.Atom.cardinal, 32, &pid);
        if (opts.min_size) |m| try b.setMinSize(w.xid, m);
        _ = try c.request(proto.MapWindow, .{ .window = w.xid }, &.{});
        try c.flush();
    }

    fn setProp(b: *X11Backend, xid: u32, prop: u32, ty: u32, format: u8, bytes: []const u8) !void {
        _ = try b.conn.request(proto.ChangeProperty, .{ .window = xid, .property = prop, .type = ty, .format = format, .length = @intCast(bytes.len / (format / 8)), .bytes = bytes }, &.{});
    }

    fn setAtoms(b: *X11Backend, xid: u32, prop: u32, atoms: []const u32) !void {
        var buf: [16]u8 = undefined;
        for (atoms, 0..) |x, i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], x, .little);
        try b.setProp(xid, prop, proto.Atom.atom, 32, buf[0 .. atoms.len * 4]);
    }

    fn setTitle(b: *X11Backend, xid: u32, title: []const u8) !void {
        try b.setProp(xid, b.atoms.get("_NET_WM_NAME"), b.atoms.get("UTF8_STRING"), 8, title);
        try b.setProp(xid, proto.Atom.wm_name, proto.Atom.string, 8, title);
    }

    fn setMinSize(b: *X11Backend, xid: u32, m: PxSize) !void {
        // WM_SIZE_HINTS: 18 longs; PMinSize (16) with min at longs 5 and 6.
        var hints: [18 * 4]u8 = @splat(0);
        std.mem.writeInt(u32, hints[0..4], 16, .little);
        std.mem.writeInt(u32, hints[20..24], m.w, .little);
        std.mem.writeInt(u32, hints[24..28], m.h, .little);
        try b.setProp(xid, proto.Atom.wm_normal_hints, proto.Atom.wm_size_hints, 32, &hints);
    }

    /// See `Platform.VTable.destroyWindow`.
    pub fn destroyWindow(b: *X11Backend, win: WindowId) void {
        b.lock();
        defer b.unlock();
        for (b.windows.items, 0..) |w, i| if (w.id == win) {
            _ = b.windows.swapRemove(i);
            b.destroyX(w);
            return;
        };
    }

    fn destroyX(b: *X11Backend, w: *Window) void {
        w.presenter.deinit();
        _ = b.conn.request(proto.FreeGC, .{ .gc = w.gc }, &.{}) catch {};
        _ = b.conn.request(proto.DestroyWindow, .{ .window = w.xid }, &.{}) catch {};
        b.conn.flush() catch {};
        b.gpa.destroy(w);
    }

    /// See `Platform.VTable.submit`. Commands apply at once (the
    /// connection is thread-safe); frame requests wake `waitEvents`.
    pub fn submit(b: *X11Backend, cmd: Command) Error!void {
        b.lock();
        defer b.unlock();
        b.run(cmd) catch |err| return switch (err) {
            error.InvalidWindow, error.Unsupported, error.OutOfMemory => |e| e,
            else => error.SystemResources,
        };
        b.conn.flush() catch return error.SystemResources;
    }

    fn lookup(b: *X11Backend, id: WindowId) error{InvalidWindow}!*Window {
        return b.find(id) orelse error.InvalidWindow;
    }

    fn run(b: *X11Backend, cmd: Command) !void {
        switch (cmd) {
            .set_title => |t| try b.setTitle((try b.lookup(t.win)).xid, t.title),
            // Cursors, the IME and hit-testing come with later E01.F05
            // tasks; the window must exist.
            .set_cursor => |t| _ = try b.lookup(t.win),
            .set_ime_state => |t| _ = try b.lookup(t.win),
            .set_hit_test => |t| _ = try b.lookup(t.win),
            .set_min_size => |t| try b.setMinSize((try b.lookup(t.win)).xid, t.size),
            .request_state => |t| {
                const w = try b.lookup(t.win);
                const a = &b.atoms;
                switch (t.op) {
                    .show => try b.sendRoot(w.xid, a.get("_NET_ACTIVE_WINDOW"), .{ 1, 0, 0, 0, 0 }),
                    .maximize, .unmaximize => try b.sendRoot(w.xid, a.get("_NET_WM_STATE"), .{ @intFromBool(t.op == .maximize), a.get("_NET_WM_STATE_MAXIMIZED_VERT"), a.get("_NET_WM_STATE_MAXIMIZED_HORZ"), 1, 0 }),
                    .fullscreen, .unfullscreen => try b.sendRoot(w.xid, a.get("_NET_WM_STATE"), .{ @intFromBool(t.op == .fullscreen), a.get("_NET_WM_STATE_FULLSCREEN"), 0, 1, 0 }),
                    .minimize => try b.sendRoot(w.xid, a.get("WM_CHANGE_STATE"), .{ 3, 0, 0, 0, 0 }), // IconicState
                }
            },
            .request_frame => |win| {
                const w = try b.lookup(win);
                w.frame_requested = true;
                b.ui_wake.signal();
            },
            .clipboard_write => |t| try b.sel.own(t.which, t.items, b.last_time),
            .clipboard_read => |t| {
                try b.sel.read(t.which, t.mime, t.request, b.last_time, b.nowNs());
                b.drainSelections();
                // Wake `waitEvents` for a local answer or the new deadline.
                b.ui_wake.signal();
            },
            .begin_move, .begin_resize, .show_window_menu, .start_drag, .set_drop_effect, .activate, .request_attention, .open_dialog, .open_uri => return error.Unsupported,
        }
    }

    /// Sends an EWMH client message about `xid` to the root window.
    fn sendRoot(b: *X11Backend, xid: u32, msg_type: u32, data: [5]u32) !void {
        var ev: [32]u8 = @splat(0);
        ev[0] = proto.EventCode.client_message;
        ev[1] = 32;
        std.mem.writeInt(u32, ev[4..8], xid, .little);
        std.mem.writeInt(u32, ev[8..12], msg_type, .little);
        for (data, 0..) |d, i| std.mem.writeInt(u32, ev[12 + i * 4 ..][0..4], d, .little);
        _ = try b.conn.request(proto.SendEvent, .{
            .destination = b.conn.screen().root,
            .event_mask = proto.EventMask.substructure_notify | proto.EventMask.substructure_redirect,
            .event = ev,
        }, &.{});
    }

    /// See `Platform.VTable.surfaceTarget`: E02 imports its images into
    /// the window's presenter (DRI3) or renders into its CPU buffers.
    pub fn surfaceTarget(b: *X11Backend, win: WindowId) Error!surface.SurfaceTarget {
        return .{ .external = try b.cpuPresenter(win) };
    }

    /// See `Platform.VTable.cpuPresenter`.
    pub fn cpuPresenter(b: *X11Backend, win: WindowId) Error!*surface.Presenter {
        b.lock();
        defer b.unlock();
        const w = b.find(win) orelse return error.InvalidWindow;
        return &w.presenter.presenter;
    }

    /// See `Platform.VTable.native`.
    pub fn native(b: *X11Backend) *const native_api.NativeHooks {
        return &b.hooks;
    }

    /// See `Platform.VTable.payload`.
    pub fn payload(b: *X11Backend, s: types.PayloadSlice) []const u8 {
        if (!s.large) return b.arena.get(s);
        b.lock();
        defer b.unlock();
        return b.large.get(s.off) orelse &.{};
    }

    /// See `Platform.VTable.release`.
    pub fn release(b: *X11Backend, s: types.PayloadSlice) void {
        if (!s.large) return;
        b.lock();
        defer b.unlock();
        if (b.large.fetchRemove(s.off)) |kv| b.gpa.free(kv.value);
    }

    /// `bytes` as a payload: inline in the arena, else a large payload
    /// that takes ownership of `bytes`. Mutex held. `bytes` is freed on
    /// the inline path and on error.
    fn putOwned(b: *X11Backend, bytes: []u8) types.PayloadSlice {
        if (b.arena.put(bytes)) |s| {
            b.gpa.free(bytes);
            return s;
        } else |_| {}
        const id = b.next_large;
        b.large.put(b.gpa, id, bytes) catch {
            b.gpa.free(bytes);
            return .empty;
        };
        b.next_large = (b.next_large + 1) & std.math.maxInt(u30);
        return .{ .off = @intCast(id), .large = true, .len = @intCast(bytes.len) };
    }

    /// Turns finished selection reads and owner changes into events.
    /// Mutex held.
    fn drainSelections(b: *X11Backend) void {
        for (b.sel.done.items) |d| {
            const data: types.PayloadSlice = if (d.ok and d.data.len > 0) b.putOwned(d.data) else blk: {
                b.gpa.free(d.data);
                break :blk .empty;
            };
            b.stage(.{ .clipboard_data = .{ .request = d.request, .data = data, .mime = d.mime } });
        }
        b.sel.done.clearRetainingCapacity();
        for (&b.sel.changed, 0..) |*c, i| if (c.*) {
            c.* = false;
            b.stage(.{ .clipboard_changed = @enumFromInt(i) });
        };
    }

    /// See `Platform.VTable.monitors`: the screen, until RandR monitors.
    pub fn monitors(b: *X11Backend, out: []types.MonitorInfo) usize {
        const s = b.conn.screen();
        if (out.len > 0) {
            const r: types.PxRect = .{ .x = 0, .y = 0, .w = s.width_px, .h = s.height_px };
            out[0] = .{ .id = 0, .rect_px = r, .work_px = r, .scale = .{ .factor = b.scale }, .refresh_mhz = @intCast(@divTrunc(std.time.ns_per_s * 1000, @as(u64, b.opts.refresh_ns))), .primary = true };
            const name = "X11 screen";
            @memcpy(out[0].name_buf[0..name.len], name);
            out[0].name_len = name.len;
        }
        return 1;
    }

    /// See `Platform.VTable.pollEvents`. Reads the X socket first.
    pub fn pollEvents(b: *X11Backend, out: []Event) usize {
        if (out.len == 0) return 0;
        _ = b.arena.flip();
        b.dispatch();
        var n: usize = 0;
        if (b.wake_pending.swap(false, .acquire)) {
            out[0] = .wake;
            n = 1;
        }
        b.lock();
        defer b.unlock();
        b.sel.expire(b.nowNs());
        b.drainSelections();
        b.dueFrames(b.nowNs());
        const take = @min(out.len - n, b.staged.items.len);
        for (b.staged.items[0..take], 0..) |e, i| {
            out[n + i] = e;
            b.arena.retire(&e);
        }
        b.staged.replaceRangeAssumeCapacity(0, take, &.{});
        return n + take;
    }

    /// Stages `frame` for windows whose request is due. Mutex held.
    fn dueFrames(b: *X11Backend, now: u64) void {
        for (b.windows.items) |w| {
            if (!w.frame_requested) continue;
            if (now < w.last_frame_ns + b.opts.refresh_ns) continue;
            w.frame_requested = false;
            w.last_frame_ns = now;
            b.stage(.{ .frame = .{ .win = w.id, .target_ns = now + b.opts.refresh_ns, .refresh_ns = b.opts.refresh_ns } });
        }
    }

    /// The earliest due frame, if any is requested. Mutex held.
    fn nextFrameNs(b: *X11Backend) ?u64 {
        var next: ?u64 = null;
        for (b.windows.items) |w| if (w.frame_requested) {
            const t = w.last_frame_ns + b.opts.refresh_ns;
            next = if (next) |x| @min(x, t) else t;
        };
        return next;
    }

    /// See `Platform.VTable.waitEvents`.
    pub fn waitEvents(b: *X11Backend, deadline_ns: ?u64) void {
        while (true) {
            b.dispatch();
            const now = b.nowNs();
            var until = deadline_ns;
            {
                b.lock();
                defer b.unlock();
                b.sel.expire(now);
                b.drainSelections();
                if (b.staged.items.len > 0) return;
                if (b.nextFrameNs()) |t| until = if (until) |d| @min(d, t) else t;
                if (b.sel.nextDeadline()) |t| until = if (until) |d| @min(d, t) else t;
            }
            if (b.wake_pending.load(.acquire)) return;
            if (until) |u| if (now >= u) return;
            b.conn.flush() catch {};
            var fds = [_]linux.pollfd{
                .{ .fd = b.conn.pollFd(), .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = b.ui_wake.handle().fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const nfds: usize = if (b.dead) 1 else 2;
            const timeout_ms: i32 = if (until) |u| @intCast(@min((u - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(i32))) else -1;
            const rc = linux.poll(if (b.dead) fds[1..].ptr else &fds, nfds, timeout_ms);
            if (linux.errno(rc) != .SUCCESS) return;
            if (fds[1].revents != 0) b.ui_wake.consume();
            // Loop: dispatch, then return once something is staged or due.
        }
    }

    /// See `Platform.VTable.wake`.
    pub fn wake(b: *X11Backend) void {
        b.wake_pending.store(true, .release);
        b.ui_wake.signal();
    }

    /// See `Platform.VTable.deinit`.
    pub fn deinit(b: *X11Backend) void {
        b.lock();
        for (b.windows.items) |w| b.destroyX(w);
        b.windows.deinit(b.gpa);
        b.unlock();
        b.staged.deinit(b.gpa);
        b.sel.deinit();
        var it = b.large.valueIterator();
        while (it.next()) |v| b.gpa.free(v.*);
        b.large.deinit(b.gpa);
        if (b.compose_thread) |t| t.join();
        b.keymap.deinit(b.gpa);
        b.seat.deinit(b.gpa);
        b.scrolling.deinit(b.gpa);
        if (b.compose_table) |*t| t.deinit(b.gpa);
        if (b.gpu) |*g| g.deinit(b.gpa);
        b.conn.deinit();
        b.arena.deinit(b.gpa);
        b.ui_wake.deinit();
        b.gpa.destroy(b);
    }

    // ---- event dispatch (UI thread) ----

    /// Translates every X event the socket has.
    fn dispatch(b: *X11Backend) void {
        if (b.dead) return;
        while (true) {
            const ev = b.conn.pollEvent() catch |err| {
                log.err("X connection lost: {t}", .{err});
                b.dead = true;
                b.lock();
                for (b.windows.items) |w| b.stage(.{ .window_close_requested = w.id });
                b.unlock();
                return;
            } orelse return;
            b.lock();
            defer b.unlock();
            b.translate(ev);
        }
    }

    fn translate(b: *X11Backend, ev: []const u8) void {
        const code = ev[0] & 0x7f;
        switch (code) {
            proto.EventCode.key_press...proto.EventCode.leave_notify => b.last_time = u32At(ev, 4),
            proto.EventCode.property_notify => b.last_time = u32At(ev, 12),
            else => {},
        }
        if (b.sel.handleEvent(ev, b.nowNs())) return b.drainSelections();
        if (b.shm_event) |base| if (code == base) {
            const drawable = u32At(ev, 4);
            if (b.byXid(drawable)) |w| _ = w.presenter.onShmCompletion(u32At(ev, 12));
            return;
        };
        if (b.gpu) |g| if (code == proto.generic_event and ev[1] == g.present_opcode) return b.onPresentEvent(ev);
        if (b.xkb_event) |base| if (code == base) return b.onXkbEvent(ev);
        if (b.xi_opcode) |op| if (code == proto.generic_event and ev[1] == op) return b.onXiEvent(ev);
        // With XI2 the server sends XI2 pointer events instead of core
        // ones; ignore any core stragglers.
        if (b.xi_opcode != null) switch (code) {
            proto.EventCode.button_press, proto.EventCode.button_release, proto.EventCode.motion_notify, proto.EventCode.enter_notify, proto.EventCode.leave_notify => return,
            else => {},
        };
        switch (code) {
            proto.EventCode.key_press, proto.EventCode.key_release => b.onKey(ev, code == proto.EventCode.key_press),
            proto.EventCode.button_press, proto.EventCode.button_release => b.onButton(ev, code == proto.EventCode.button_press),
            proto.EventCode.motion_notify => {
                const w = b.byXid(u32At(ev, 12)) orelse return;
                b.stage(.{ .pointer_move = .{ .win = w.id, .pos_px = eventPos(ev), .mods = modsFromState(u16At(ev, 28)), .time_ns = b.nowNs() } });
            },
            proto.EventCode.enter_notify, proto.EventCode.leave_notify => {
                const w = b.byXid(u32At(ev, 12)) orelse return;
                b.stage(.{ .pointer_enter_leave = .{ .win = w.id, .entered = code == proto.EventCode.enter_notify } });
            },
            proto.EventCode.focus_in, proto.EventCode.focus_out => {
                const w = b.byXid(u32At(ev, 4)) orelse return;
                // NotifyPointer (5) and beyond are pointer-root noise.
                if (ev[1] >= 5) return;
                const focused = code == proto.EventCode.focus_in;
                if (w.focused == focused) return;
                w.focused = focused;
                if (b.xkb_event != null) {
                    // The seat stages the focus change; leaving releases
                    // held keys and resets compose.
                    const sink: Sink = .{ .b = b };
                    if (focused) {
                        b.seat.kbEnter(sink, w.id, 0, &.{}) catch {};
                    } else if (b.seat.kb_focus == w.id) {
                        _ = b.seat.kbLeave(sink, b.nowNs()) catch {};
                    } else b.stage(.{ .window_focus = .{ .win = w.id, .focused = false } });
                    return;
                }
                b.stage(.{ .window_focus = .{ .win = w.id, .focused = focused } });
            },
            proto.EventCode.expose => {
                const w = b.byXid(u32At(ev, 4)) orelse return;
                const r: types.PxRect = .{ .x = u16At(ev, 8), .y = u16At(ev, 10), .w = u16At(ev, 12), .h = u16At(ev, 14) };
                // Repaint from the newest buffer; before the first present
                // the window needs a frame anyway.
                if (!w.presenter.repaint(r)) w.frame_requested = true;
            },
            proto.EventCode.visibility_notify => {
                const w = b.byXid(u32At(ev, 4)) orelse return;
                b.setOccluded(w, ev[8] == 2); // FullyObscured
            },
            proto.EventCode.unmap_notify => if (b.byXid(u32At(ev, 8))) |w| b.setOccluded(w, true),
            proto.EventCode.map_notify => if (b.byXid(u32At(ev, 8))) |w| b.setOccluded(w, false),
            proto.EventCode.configure_notify => {
                const w = b.byXid(u32At(ev, 8)) orelse return;
                const size: PxSize = .{ .w = u16At(ev, 20), .h = u16At(ev, 22) };
                if (size.w == 0 or size.h == 0 or (size.w == w.size.w and size.h == w.size.h)) return;
                w.size = size;
                w.serial +%= 1;
                b.stage(.{ .window_configure = .{ .win = w.id, .size = size, .scale = .{ .factor = b.scale }, .state = .{ .maximized = w.maximized, .fullscreen = w.fullscreen, .activated = w.focused }, .serial = w.serial, .screen_origin_px = .{ .x = @as(i16, @bitCast(u16At(ev, 16))), .y = @as(i16, @bitCast(u16At(ev, 18))) } } });
            },
            proto.EventCode.client_message => {
                const w = b.byXid(u32At(ev, 4)) orelse return;
                if (u32At(ev, 8) == b.atoms.get("WM_PROTOCOLS") and u32At(ev, 12) == b.atoms.get("WM_DELETE_WINDOW")) {
                    b.stage(.{ .window_close_requested = w.id });
                }
            },
            proto.EventCode.mapping_notify => if (ev[4] == 1 and b.xkb_event == null) {
                // MappingKeyboard: refetch. The reply may queue more events;
                // the dispatch loop picks them up.
                b.loadKeymap() catch |err| log.warn("keyboard mapping refresh failed: {t}", .{err});
            },
            else => {},
        }
    }

    /// A Present event: IdleNotify releases a pixmap, CompleteNotify
    /// becomes `Event.present_feedback` (UST is µs on CLOCK_MONOTONIC,
    /// our clock). Mutex held.
    fn onPresentEvent(b: *X11Backend, ev: []const u8) void {
        switch (dri3.decodeEvent(ev) orelse return) {
            .idle => |i| if (b.byXid(i.window)) |w| {
                _ = w.presenter.onIdle(i.pixmap);
            },
            .complete => |c| {
                if (!c.is_pixmap) return;
                const w = b.byXid(c.window) orelse return;
                const F = event_api.PresentFlags;
                const flags: u8 = switch (c.mode) {
                    .skip => F.discarded,
                    .flip => F.vsync | F.zero_copy,
                    else => F.vsync,
                };
                b.stage(.{ .present_feedback = .{ .win = w.id, .presented_ns = if (c.mode == .skip) 0 else c.ust *| std.time.ns_per_us, .seq = c.msc, .flags = flags } });
            },
            .other => {},
        }
    }

    fn setOccluded(b: *X11Backend, w: *Window, occluded: bool) void {
        if (w.occluded == occluded) return;
        w.occluded = occluded;
        b.stage(.{ .window_occluded = .{ .win = w.id, .occluded = occluded } });
    }

    /// An XKB event: state changes feed the seat; map changes refetch the
    /// keymap (the replies may queue more events; the dispatch loop picks
    /// them up). Mutex held.
    fn onXkbEvent(b: *X11Backend, ev: []const u8) void {
        switch (xkb_ext.decodeEvent(ev)) {
            .state => |s| b.seat.modifiers(0, s.base, s.latched, s.locked, s.group),
            .keymap_changed => b.loadXkbKeymap() catch |err| log.warn("XKB keymap refresh failed: {t}", .{err}),
            .other => {},
        }
    }

    fn onKey(b: *X11Backend, ev: []const u8, pressed: bool) void {
        const w = b.byXid(u32At(ev, 12)) orelse return;
        const keycode = ev[1];
        if (b.xkb_event != null) {
            if (keycode < 8) return;
            const evdev: u32 = keycode - 8;
            const sink: Sink = .{ .b = b };
            const now = b.nowNs();
            // Events can reach a window before its FocusIn.
            b.seat.kb_focus = w.id;
            if (pressed and (b.seat.serverRepeat(sink, evdev, now) catch false)) return;
            _ = b.seat.key(sink, 0, evdev, pressed, now) catch {};
            return;
        }
        const state = u16At(ev, 28);
        const r = b.keymap.resolve(keycode, state);
        var text: types.PayloadSlice = .empty;
        if (pressed and r.codepoint != 0) {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(r.codepoint, &buf) catch 0;
            text = b.arena.put(buf[0..n]) catch .empty;
        }
        b.stage(.{ .key = .{ .win = w.id, .ev = .{
            .key = r.key,
            .keysym = r.keysym,
            .codepoint = r.codepoint,
            .mods = modsFromState(state),
            .action = if (pressed) .press else .release,
            .text = text,
            .native_scancode = if (keycode >= 8) keycode - 8 else 0,
            .time_ns = b.nowNs(),
        } } });
    }

    /// An XInput2 event. Mutex held.
    fn onXiEvent(b: *X11Backend, ev: []const u8) void {
        if (ev.len < 12) return;
        switch (u16At(ev, 8)) {
            xinput2.EventType.hierarchy_changed, xinput2.EventType.device_changed => {
                // Replies may queue more events; the dispatch loop picks
                // them up.
                b.loadScrollValuators() catch |err| log.warn("XIQueryDevice failed: {t}", .{err});
                b.scrolling.reset();
            },
            xinput2.EventType.enter, xinput2.EventType.leave => {
                const cr = xinput2.decodeCrossing(ev) orelse return;
                const w = b.byXid(cr.window) orelse return;
                b.stage(.{ .pointer_enter_leave = .{ .win = w.id, .entered = cr.entered } });
                if (cr.entered) {
                    // As on Wayland, entering also reports the position.
                    b.scrolling.reset();
                    b.ptr_pos = cr.pos;
                    b.stage(.{ .pointer_move = .{ .win = w.id, .pos_px = cr.pos, .mods = .{}, .time_ns = b.nowNs() } });
                }
            },
            else => {
                const e = xinput2.decodeDeviceEvent(ev) orelse return;
                const w = b.byXid(e.window) orelse return;
                const mods = modsFromState(e.mods);
                switch (e.evtype) {
                    xinput2.EventType.motion => {
                        // Emulated motion comes from touches we already get.
                        if (e.flags & xinput2.pointer_emulated != 0) return;
                        const d = b.scrolling.delta(&e);
                        if (d[0] != 0 or d[1] != 0) {
                            const whole = @floor(d[0]) == d[0] and @floor(d[1]) == d[1];
                            b.stage(.{ .scroll = .{ .win = w.id, .dx = @floatCast(d[0]), .dy = @floatCast(d[1]), .unit = .lines, .source = if (whole) .wheel else .continuous, .phase = .none } });
                        }
                        if (e.pos[0] == b.ptr_pos[0] and e.pos[1] == b.ptr_pos[1]) return;
                        b.ptr_pos = e.pos;
                        b.stage(.{ .pointer_move = .{ .win = w.id, .pos_px = e.pos, .mods = mods, .time_ns = b.nowNs() } });
                    },
                    xinput2.EventType.button_press, xinput2.EventType.button_release => {
                        // Wheel buttons emulated from scroll valuators: the
                        // valuators already scrolled.
                        if (e.flags & xinput2.pointer_emulated != 0) return;
                        b.pointerButton(w, @intCast(@min(e.detail, 255)), e.evtype == xinput2.EventType.button_press, e.pos, mods);
                    },
                    xinput2.EventType.touch_begin, xinput2.EventType.touch_update, xinput2.EventType.touch_end => {
                        const phase: types.Phase = switch (e.evtype) {
                            xinput2.EventType.touch_begin => .begin,
                            xinput2.EventType.touch_update => .update,
                            else => .end,
                        };
                        b.stage(.{ .touch = .{ .win = w.id, .id = @bitCast(e.detail), .phase = phase, .pos_px = e.pos } });
                    },
                    else => {},
                }
            },
        }
    }

    fn onButton(b: *X11Backend, ev: []const u8, pressed: bool) void {
        const w = b.byXid(u32At(ev, 12)) orelse return;
        b.pointerButton(w, ev[1], pressed, eventPos(ev), modsFromState(u16At(ev, 28)));
    }

    /// A button press or release; 4–7 are wheel notches. Mutex held.
    fn pointerButton(b: *X11Backend, w: *Window, detail: u8, pressed: bool, pos: [2]f32, mods: keys_api.Mods) void {
        const now = b.nowNs();
        switch (detail) {
            4, 5, 6, 7 => {
                if (!pressed) return;
                const d: f32 = if (detail == 4 or detail == 6) -1 else 1;
                const vertical = detail <= 5;
                b.stage(.{ .scroll = .{ .win = w.id, .dx = if (vertical) 0 else d, .dy = if (vertical) d else 0, .unit = .lines, .source = .wheel, .phase = .none } });
                return;
            },
            else => {},
        }
        const button: types.Button = switch (detail) {
            1 => .left,
            2 => .middle,
            3 => .right,
            8 => .back,
            9 => .forward,
            else => @enumFromInt(detail),
        };
        if (pressed) {
            const near = @abs(pos[0] - w.last_click_pos[0]) <= double_click_px and @abs(pos[1] - w.last_click_pos[1]) <= double_click_px;
            if (detail == w.last_click_button and near and now - w.last_click_ns <= double_click_ns and w.clicks < 3) w.clicks += 1 else w.clicks = 1;
            w.last_click_ns = now;
            w.last_click_pos = pos;
            w.last_click_button = detail;
        }
        b.stage(.{ .pointer_button = .{ .win = w.id, .button = button, .pressed = pressed, .pos_px = pos, .mods = mods, .clicks = if (pressed) w.clicks else 0, .time_ns = now } });
    }

    // ---- native hooks ----

    fn noHook(_: *anyopaque, _: WindowId, _: []const u32, _: ?native_api.Win32MsgHook, _: *anyopaque) error{Unsupported}!void {
        return error.Unsupported;
    }

    fn noMsgWindow(_: *anyopaque, _: native_api.Win32MsgHook, _: *anyopaque) error{ Unsupported, SystemResources }!*anyopaque {
        return error.Unsupported;
    }

    fn noDestroy(_: *anyopaque, _: *anyopaque) void {}

    fn windowHandle(ctx: *anyopaque, win: WindowId) native_api.NativeWindow {
        const b: *X11Backend = @ptrCast(@alignCast(ctx));
        b.lock();
        defer b.unlock();
        return if (b.find(win)) |w| .{ .x11 = w.xid } else .headless;
    }

    // ---- test access ----

    /// The X window id of `win`, for tests that inspect the server.
    pub fn xidOf(b: *X11Backend, win: WindowId) ?u32 {
        b.lock();
        defer b.unlock();
        return if (b.find(win)) |w| w.xid else null;
    }
};

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}
fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// The event-window position of a key, button or motion event.
fn eventPos(ev: []const u8) [2]f32 {
    return .{ @floatFromInt(@as(i16, @bitCast(u16At(ev, 24)))), @floatFromInt(@as(i16, @bitCast(u16At(ev, 26)))) };
}

// ---- tests (on a private Xvfb; skipped without one) ----

const testing = std.testing;
const conformance = @import("../testing/conformance.zig");

/// A private Xvfb; an absent Xvfb skips. `-noreset` keeps the server up
/// between clients (by default it regenerates when the last one leaves,
/// and a client connecting then fails its handshake).
pub const XvfbForTest = struct {
    child: std.process.Child,
    name_buf: [16]u8,
    name_len: usize,
    sock_buf: [32]u8,
    sock_len: usize,

    /// Starts Xvfb on a display number derived from `seed` and the pid.
    pub fn start(seed: u32) !XvfbForTest {
        var x: XvfbForTest = undefined;
        const n = 450 + (seed * 37 + @as(u32, @intCast(linux.getpid()))) % 400;
        x.name_len = (try std.fmt.bufPrint(&x.name_buf, ":{d}", .{n})).len;
        x.sock_len = (try std.fmt.bufPrint(&x.sock_buf, "/tmp/.X11-unix/X{d}", .{n})).len;
        x.child = try std.process.spawn(testing.io, .{
            .argv = &.{ "Xvfb", x.display(), "-nolisten", "tcp", "-noreset", "-screen", "0", "640x480x24" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        errdefer x.child.kill(testing.io);
        var tries: usize = 0;
        while (tries < 300) : (tries += 1) {
            if (Io.Dir.cwd().access(testing.io, x.sock_buf[0..x.sock_len], .{})) |_| return x else |_| {}
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.XvfbDidNotStart;
    }

    /// The `DISPLAY` value.
    pub fn display(x: *const XvfbForTest) []const u8 {
        return x.name_buf[0..x.name_len];
    }

    /// Stops Xvfb.
    pub fn stop(x: *XvfbForTest) void {
        x.child.kill(testing.io);
    }
};

const Harness = struct {
    io: Io,
    display: []const u8,
    path: present_mod.Path = .shm,
    current: ?*X11Backend = null,

    /// A fresh backend on the harness display.
    pub fn create(h: *Harness) !Platform {
        const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = h.display, .present = h.path });
        h.current = b;
        return b.platform();
    }

    /// Sends WM_DELETE_WINDOW from a second client, as a window manager would.
    pub fn requestClose(h: *Harness, win: WindowId) !void {
        const b = h.current.?;
        const xid = b.xidOf(win) orelse return error.InvalidWindow;
        var ev: [32]u8 = @splat(0);
        ev[0] = proto.EventCode.client_message;
        ev[1] = 32;
        std.mem.writeInt(u32, ev[4..8], xid, .little);
        std.mem.writeInt(u32, ev[8..12], b.atoms.get("WM_PROTOCOLS"), .little);
        std.mem.writeInt(u32, ev[12..16], b.atoms.get("WM_DELETE_WINDOW"), .little);
        var env: std.process.Environ.Map = .init(testing.allocator);
        defer env.deinit();
        const other = try Conn.connect(testing.allocator, testing.io, &env, .{ .display = h.display });
        defer other.deinit();
        try other.checked(proto.SendEvent, .{ .destination = xid, .event_mask = 0, .event = ev }, &.{});
    }
};

test "Xvfb conformance (MIT-SHM and PutImage)" {
    var x = XvfbForTest.start(1) catch return error.SkipZigTest;
    defer x.stop();
    for ([_]present_mod.Path{ .shm, .put_image }) |path| {
        var h: Harness = .{ .io = testing.io, .display = x.display(), .path = path };
        try conformance.runConformance(Harness, &h);
    }
}

/// Waits for an event matching `kind` for `win`.
fn waitFor(p: Platform, comptime kind: Event.Tag, win: WindowId) !Event {
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 2 * std.time.ns_per_s;
    var evs: [64]Event = undefined;
    while (true) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == kind and e.window() == win) return e;
        if (@as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) >= deadline) return error.Timeout;
        p.waitEvents(deadline);
    }
}

test "Xvfb: presented pixels read back with GetImage on both paths" {
    var x = XvfbForTest.start(2) catch return error.SkipZigTest;
    defer x.stop();
    for ([_]present_mod.Path{ .shm, .put_image }) |path| {
        const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display(), .present = path });
        defer b.deinit();
        try testing.expectEqual(path, b.path);
        const p = b.platform();
        const win = try p.createWindow(.{ .title = "zg present", .size = .{ .w = 64, .h = 48 } });
        _ = try waitFor(p, .window_configure, win);
        try p.submit(.{ .request_frame = win });
        _ = try waitFor(p, .frame, win);

        const pr = try p.cpuPresenter(win);
        const buf = try pr.allocCpuBuffer(64, 48, present_mod.fourcc_argb8888);
        var y: usize = 0;
        while (y < 48) : (y += 1) {
            const row = buf.pixels[y * buf.stride ..][0 .. 64 * 4];
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                // Left half orange, right half teal (B, G, R, A in memory).
                const c: [4]u8 = if (i < 32) .{ 0x10, 0x80, 0xf0, 0xff } else .{ 0x90, 0x90, 0x10, 0xff };
                @memcpy(row[i * 4 ..][0..4], &c);
            }
        }
        try pr.present(buf.handle, &.{}, .none, null);
        // A round trip on our connection: the server has drawn by then.
        try b.conn.sync();
        const img = try b.conn.reply(try b.conn.request(proto.GetImage, .{ .drawable = b.xidOf(win).?, .x = 0, .y = 0, .width = 64, .height = 48 }, &.{}));
        try testing.expectEqual(@as(usize, 64 * 48 * 4), img.pixels.len);
        try testing.expectEqualSlices(u8, &.{ 0x10, 0x80, 0xf0 }, img.pixels[0..3]);
        try testing.expectEqualSlices(u8, &.{ 0x90, 0x90, 0x10 }, img.pixels[(47 * 64 + 63) * 4 ..][0..3]);
        p.destroyWindow(win);
    }
}

test "Xvfb: a newer present releases the older buffer" {
    var x = XvfbForTest.start(3) catch return error.SkipZigTest;
    defer x.stop();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg release", .size = .{ .w = 16, .h = 16 } });
    const pr = try p.cpuPresenter(win);
    const a = try pr.allocCpuBuffer(16, 16, present_mod.fourcc_argb8888);
    const c = try pr.allocCpuBuffer(16, 16, present_mod.fourcc_argb8888);
    try pr.present(a.handle, &.{}, .none, null);
    try pr.present(c.handle, &.{.{ .x = 0, .y = 0, .w = 4, .h = 4 }}, .none, null);
    var got: [4]surface.BufferHandle = undefined;
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 2 * std.time.ns_per_s;
    var n: usize = 0;
    while (n == 0) {
        var evs: [16]Event = undefined;
        _ = p.pollEvents(&evs);
        n = pr.pollReleased(&got);
        if (n != 0) break;
        const now: u64 = @intCast(Io.Clock.awake.now(testing.io).nanoseconds);
        if (now >= deadline) return error.Timeout;
        // Completions are not events: poll in short steps.
        p.waitEvents(@min(deadline, now + 5 * std.time.ns_per_ms));
    }
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(a.handle, got[0]);
}

/// Polls `want` until a `kind` event arrives, letting `other` dispatch
/// (it answers selection requests) in between.
fn waitBoth(want: Platform, other: Platform, comptime kind: Event.Tag) !@FieldType(Event, @tagName(kind)) {
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 5 * std.time.ns_per_s;
    var evs: [64]Event = undefined;
    while (true) {
        const n = want.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == kind) return @field(e, @tagName(kind));
        _ = other.pollEvents(&evs);
        const now: u64 = @intCast(Io.Clock.awake.now(testing.io).nanoseconds);
        if (now >= deadline) return error.Timeout;
        want.waitEvents(now + 2 * std.time.ns_per_ms);
    }
}

test "Xvfb: selections between two clients (text, 10 MB INCR, PRIMARY, changes)" {
    var x = XvfbForTest.start(4) catch return error.SkipZigTest;
    defer x.stop();
    const a = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer a.deinit();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    const pa = a.platform();
    const pb = b.platform();

    try pa.submit(.{ .clipboard_write = .{ .which = .clipboard, .items = &.{.{ .mime = .text_utf8, .data = "hello" }} } });
    try testing.expect(b.sel.xfixes_event != null);
    if (b.sel.xfixes_event != null) try testing.expectEqual(clipboard.Selection.clipboard, try waitBoth(pb, pa, .clipboard_changed));
    try pb.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 1 } });
    const small = try waitBoth(pb, pa, .clipboard_data);
    try testing.expectEqual(@as(u32, 1), small.request);
    try testing.expectEqualStrings("hello", pb.payload(small.data));

    // The owner answers itself from its copy.
    try pa.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 2 } });
    try testing.expectEqualStrings("hello", pa.payload((try waitBoth(pa, pb, .clipboard_data)).data));

    // Not offered: an empty answer.
    try pb.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .png, .request = 3 } });
    try testing.expectEqual(@as(u32, 0), (try waitBoth(pb, pa, .clipboard_data)).data.len);

    const big = try testing.allocator.alloc(u8, 10 * 1024 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    try pa.submit(.{ .clipboard_write = .{ .which = .clipboard, .items = &.{.{ .mime = .html, .data = big }} } });
    try pb.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .html, .request = 4 } });
    const lg = try waitBoth(pb, pa, .clipboard_data);
    try testing.expect(lg.data.large);
    try testing.expectEqualSlices(u8, big, pb.payload(lg.data));
    pb.release(lg.data);

    try pa.submit(.{ .clipboard_write = .{ .which = .primary, .items = &.{.{ .mime = .text_utf8, .data = "sel" }} } });
    try pb.submit(.{ .clipboard_read = .{ .which = .primary, .mime = .text_utf8, .request = 5 } });
    try testing.expectEqualStrings("sel", pb.payload((try waitBoth(pb, pa, .clipboard_data)).data));

    // B takes the clipboard: A loses it and reads from B.
    try pb.submit(.{ .clipboard_write = .{ .which = .clipboard, .items = &.{.{ .mime = .text_utf8, .data = "from b" }} } });
    if (a.sel.xfixes_event != null) _ = try waitBoth(pa, pb, .clipboard_changed);
    // SelectionClear may trail the XFIXES notice.
    var spins: usize = 0;
    while (a.sel.owned[0]) : (spins += 1) {
        if (spins > 2000) return error.Timeout;
        var evs: [16]Event = undefined;
        _ = pa.pollEvents(&evs);
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try pa.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 6 } });
    try testing.expectEqualStrings("from b", pa.payload((try waitBoth(pa, pb, .clipboard_data)).data));
}

/// Waits on raw connection `r` for SelectionNotify, letting `owner`
/// dispatch; returns its property.
fn rawNotify(r: *Conn, owner: Platform) !u32 {
    var evs: [16]Event = undefined;
    var tries: usize = 0;
    while (tries < 2000) : (tries += 1) {
        _ = owner.pollEvents(&evs);
        try r.flush();
        while (try r.pollEvent()) |ev| if (ev[0] & 0x7f == proto.EventCode.selection_notify) return u32At(ev, 20);
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

test "Xvfb: TARGETS lists the required atoms; MULTIPLE converts pairs and marks failures" {
    var x = XvfbForTest.start(5) catch return error.SkipZigTest;
    defer x.stop();
    const a = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer a.deinit();
    const pa = a.platform();
    try pa.submit(.{ .clipboard_write = .{ .which = .clipboard, .items = &.{.{ .mime = .text_utf8, .data = "multi" }} } });

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const r = try Conn.connect(testing.allocator, testing.io, &env, .{ .display = x.display() });
    defer r.deinit();
    const at = try r.internAtoms(&.{ "CLIPBOARD", "TARGETS", "MULTIPLE", "TIMESTAMP", "UTF8_STRING", "ATOM_PAIR", "image/png", "_T", "_P1", "_P2", "_M" });
    const rw = try r.newXid();
    _ = try r.request(proto.CreateWindow, .{ .data = 0, .wid = rw, .parent = r.screen().root, .x = 0, .y = 0, .width = 1, .height = 1, .class = .input_only, .visual = 0 }, &.{});

    _ = try r.request(proto.ConvertSelection, .{ .requestor = rw, .selection = at.get("CLIPBOARD"), .target = at.get("TARGETS"), .property = at.get("_T"), .time = 0 }, &.{});
    try testing.expectEqual(at.get("_T"), try rawNotify(r, pa));
    const tp = try r.reply(try r.request(proto.GetProperty, .{ .window = rw, .property = at.get("_T") }, &.{}));
    try testing.expectEqual(proto.Atom.atom, tp.type);
    var have: usize = 0;
    var i: usize = 0;
    while (i < tp.value.len) : (i += 4) {
        const v = u32At(tp.value, i);
        for ([_]u32{ at.get("TARGETS"), at.get("MULTIPLE"), at.get("TIMESTAMP"), at.get("UTF8_STRING") }) |want| {
            if (v == want) have += 1;
        }
    }
    try testing.expectEqual(@as(usize, 4), have);

    var pairs: [16]u8 = undefined;
    for ([_]u32{ at.get("UTF8_STRING"), at.get("_P1"), at.get("image/png"), at.get("_P2") }, 0..) |v, k| std.mem.writeInt(u32, pairs[k * 4 ..][0..4], v, .little);
    _ = try r.request(proto.ChangeProperty, .{ .window = rw, .property = at.get("_M"), .type = at.get("ATOM_PAIR"), .format = 32, .length = 4, .bytes = &pairs }, &.{});
    _ = try r.request(proto.ConvertSelection, .{ .requestor = rw, .selection = at.get("CLIPBOARD"), .target = at.get("MULTIPLE"), .property = at.get("_M"), .time = 0 }, &.{});
    try testing.expectEqual(at.get("_M"), try rawNotify(r, pa));
    const mp = try r.reply(try r.request(proto.GetProperty, .{ .window = rw, .property = at.get("_M") }, &.{}));
    try testing.expectEqual(@as(usize, 16), mp.value.len);
    try testing.expectEqual(at.get("_P1"), u32At(mp.value, 4));
    try testing.expectEqual(@as(u32, 0), u32At(mp.value, 12));
    const p1 = try r.reply(try r.request(proto.GetProperty, .{ .window = rw, .property = at.get("_P1") }, &.{}));
    try testing.expectEqualStrings("multi", p1.value);
}

/// XTEST FakeInput: a key or button event as if from the device.
const XTestFakeInput = struct {
    /// The extension that owns this request.
    pub const extension = "XTEST";
    /// The minor opcode.
    pub const minor = 2;
    /// 2 KeyPress, 3 KeyRelease.
    type: u8,
    detail: u8,
    _pad0: u16 = 0,
    time: u32 = 0,
    root: u32 = 0,
    _pad1: [8]u8 = @splat(0),
    root_x: i16 = 0,
    root_y: i16 = 0,
    _pad2: [7]u8 = @splat(0),
    device_id: u8 = 0,
};

const KeySeen = struct { keysym: u32, action: keys_api.KeyAction, text: [8]u8 = @splat(0), text_len: usize = 0, mods: keys_api.Mods };

/// Collects `want` key events from `p`.
fn collectKeys(p: Platform, out: []KeySeen) !void {
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 3 * std.time.ns_per_s;
    var n: usize = 0;
    var evs: [64]Event = undefined;
    while (n < out.len) {
        const got = p.pollEvents(&evs);
        for (evs[0..got]) |e| if (e == .key and n < out.len) {
            const t = p.payload(e.key.ev.text);
            out[n] = .{ .keysym = e.key.ev.keysym, .action = e.key.ev.action, .mods = e.key.ev.mods, .text_len = @min(t.len, 8) };
            @memcpy(out[n].text[0..out[n].text_len], t[0..out[n].text_len]);
            n += 1;
        };
        const now: u64 = @intCast(Io.Clock.awake.now(testing.io).nanoseconds);
        if (now >= deadline) return error.Timeout;
        p.waitEvents(@min(deadline, now + 5 * std.time.ns_per_ms));
    }
}

// XTEST drops a press of a key that is already down, so server
// autorepeat is covered by the seat's `serverRepeat` test instead.
test "Xvfb: XKB keys via XTEST (Shift, Caps Lock)" {
    var x = XvfbForTest.start(6) catch return error.SkipZigTest;
    defer x.stop();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    if (b.xkb_event == null or b.conn.extension("XTEST") == null) return error.SkipZigTest;
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg keys", .size = .{ .w = 32, .h = 32 } });
    _ = try waitFor(p, .window_configure, win);
    try b.conn.checked(proto.SetInputFocus, .{ .focus = b.xidOf(win).? }, &.{});
    _ = try waitFor(p, .window_focus, win);

    const kc_a = 38; // <AC01>
    const kc_shift = 50; // <LFSH>
    const steps = [_]struct { u8, bool }{
        .{ kc_a, true },     .{ kc_a, false },
        .{ kc_shift, true }, .{ kc_a, true },
        .{ kc_a, false },    .{ kc_shift, false },
    };
    for (steps) |s| try b.conn.checked(XTestFakeInput, .{ .type = if (s[1]) 2 else 3, .detail = s[0] }, &.{});
    try b.conn.flush();
    var seen: [6]KeySeen = undefined;
    try collectKeys(p, &seen);
    try testing.expectEqual(@as(u32, 'a'), seen[0].keysym);
    try testing.expectEqualStrings("a", seen[0].text[0..seen[0].text_len]);
    try testing.expectEqual(keys_api.KeyAction.release, seen[1].action);
    try testing.expectEqual(@as(u32, 0xffe1), seen[2].keysym); // Shift_L
    try testing.expectEqual(@as(u32, 'A'), seen[3].keysym);
    try testing.expect(seen[3].mods.shift);
    try testing.expectEqualStrings("A", seen[3].text[0..seen[3].text_len]);
    try testing.expectEqual(keys_api.KeyAction.release, seen[5].action);
    try testing.expect(!seen[5].mods.shift or seen[5].keysym == 0xffe1);

    // Caps Lock locked from another client: StateNotify updates the seat.
    _ = try b.conn.request(xkb_ext.LatchLockState, .{ .affect_mod_locks = 2, .mod_locks = 2 }, &.{});
    _ = try b.conn.request(XTestFakeInput, .{ .type = 2, .detail = kc_a }, &.{});
    _ = try b.conn.request(XTestFakeInput, .{ .type = 3, .detail = kc_a }, &.{});
    try b.conn.flush();
    var caps: [2]KeySeen = undefined;
    try collectKeys(p, &caps);
    try testing.expectEqual(@as(u32, 'A'), caps[0].keysym);
    try testing.expect(caps[0].mods.caps_lock and !caps[0].mods.shift);
}

test "Xvfb: XInput2 pointer via XTEST (motion, buttons, wheel)" {
    var x = XvfbForTest.start(7) catch return error.SkipZigTest;
    defer x.stop();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    if (b.xi_opcode == null or b.conn.extension("XTEST") == null) return error.SkipZigTest;
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg pointer", .size = .{ .w = 64, .h = 48 } });
    _ = try waitFor(p, .window_configure, win);
    const root = b.conn.screen().root;
    _ = try b.conn.request(XTestFakeInput, .{ .type = 6, .detail = 0, .root = root, .root_x = 10, .root_y = 12 }, &.{});
    for ([_]struct { u8, u8 }{ .{ 4, 1 }, .{ 5, 1 }, .{ 4, 4 }, .{ 5, 4 } }) |s| {
        _ = try b.conn.request(XTestFakeInput, .{ .type = s[0], .detail = s[1] }, &.{});
    }
    try b.conn.sync();

    var moved = false;
    var presses: usize = 0;
    var releases: usize = 0;
    var scrolls: usize = 0;
    var dy: f32 = 0;
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 3 * std.time.ns_per_s;
    var evs: [64]Event = undefined;
    while (true) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| switch (e) {
            .pointer_move => |m| if (m.pos_px[0] == 10 and m.pos_px[1] == 12) {
                moved = true;
            },
            .pointer_button => |pb| {
                try testing.expectEqual(types.Button.left, pb.button);
                if (pb.pressed) {
                    presses += 1;
                    try testing.expectEqual(@as(u8, 1), pb.clicks);
                } else releases += 1;
            },
            .scroll => |sc| {
                scrolls += 1;
                dy += sc.dy;
                try testing.expectEqual(event_api.ScrollUnit.lines, sc.unit);
            },
            else => {},
        };
        const now: u64 = @intCast(Io.Clock.awake.now(testing.io).nanoseconds);
        if (moved and presses == 1 and releases == 1 and dy <= -1) {
            // Let duplicates arrive, if any.
            try b.conn.sync();
            const m = p.pollEvents(&evs);
            for (evs[0..m]) |e| if (e == .scroll) {
                scrolls += 1;
            };
            break;
        }
        if (now >= deadline) return error.Timeout;
        p.waitEvents(@min(deadline, now + 5 * std.time.ns_per_ms));
    }
    try testing.expectEqual(@as(usize, 1), scrolls);
    try testing.expectEqual(@as(f32, -1), dy);
}
