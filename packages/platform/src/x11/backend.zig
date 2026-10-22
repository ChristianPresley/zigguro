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
//! Drag and drop (E01.F05.S03.T03): XDND v5 in `xdnd.zig`. Our windows
//! are XdndAware; drops are read from `XdndSelection` through
//! `selection.zig`. A drag we start grabs the pointer and walks the
//! windows under it for an XDND target.
//!
//! Window manager (E01.F05.S02.T01, `ewmh.zig`): `_NET_WM_PING` is
//! answered, `_NET_WM_STATE` changes become `window_configure` state, and
//! client-decorated windows (`Decorations.client`) ask for no WM frame
//! with `_MOTIF_WM_HINTS`. On those, presses on the app's caption and
//! resize regions start `_NET_WM_MOVERESIZE`, a right press on the caption
//! opens `_GTK_SHOW_WINDOW_MENU` and a double click toggles maximize.
//!
//! Cursors (E01.F05.S02.T01, `cursor.zig`): Xcursor theme images through
//! RENDER, else core glyph cursors, set per window with
//! ChangeWindowAttributes. Client-decorated windows show resize cursors
//! over the app's resize regions.
//!
//! Monitors (E01.F05.S02.T01, `randr.zig`): RandR 1.5 `RRGetMonitors`,
//! refreshed on `RRScreenChangeNotify` (→ `monitors_changed`); one monitor
//! for the screen without RandR 1.5.
//!
//! Smooth resizing (`xsync.zig`): with SYNC 3.1 each window has a
//! `_NET_WM_SYNC_REQUEST_COUNTER`; the value a WM asks for is set after
//! the first present at the configured size.

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
const xdnd = @import("xdnd.zig");
const ewmh = @import("ewmh.zig");
const cursor_mod = @import("cursor.zig");
const randr = @import("randr.zig");
const xsync = @import("xsync.zig");
const CursorShape = @import("../api/cursor.zig").CursorShape;
const csd = @import("../wayland/csd.zig");
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
    "_NET_WM_PING",
    "_NET_WM_STATE_HIDDEN",
    "_NET_WM_STATE_DEMANDS_ATTENTION",
    "_NET_WM_MOVERESIZE",
    "_NET_SUPPORTED",
    "_MOTIF_WM_HINTS",
    "_GTK_SHOW_WINDOW_MENU",
    "_NET_WM_SYNC_REQUEST",
    "_NET_WM_SYNC_REQUEST_COUNTER",
};
const Atoms = @import("atoms.zig").AtomTable(&atom_names);

/// Events a top-level window listens for.
const window_events = proto.EventMask.key_press | proto.EventMask.key_release |
    proto.EventMask.button_press | proto.EventMask.button_release |
    proto.EventMask.enter_window | proto.EventMask.leave_window |
    proto.EventMask.pointer_motion | proto.EventMask.exposure |
    proto.EventMask.visibility_change | proto.EventMask.structure_notify |
    proto.EventMask.focus_change | proto.EventMask.property_change;

/// A drag over our windows ends after this long without a message.
const xdnd_target_timeout_ns: u64 = 30 * std.time.ns_per_s;
/// A drop we sent ends after this long without `XdndFinished`.
const xdnd_finish_timeout_ns: u64 = 10 * std.time.ns_per_s;

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
    /// Client-decorated: presses route through `hit`.
    csd: bool = false,
    hit: ?Hit = null,
    /// A button whose press started a WM action; its release is dropped.
    csd_swallow: ?u8 = null,
    csd_clicks: csd.Clicks = .{},
    /// Minimized, per `_NET_WM_STATE_HIDDEN`.
    hidden: bool = false,
    /// The last known root position of the window's origin.
    origin: ?types.PxPoint = null,
    /// The app's cursor, and the resize cursor over a client-decorated
    /// window's resize region.
    cursor: CursorShape = .default,
    auto_cursor: ?CursorShape = null,
    /// The cursor set on the window (0 before the first).
    shown_cursor: u32 = 0,
    /// A `_NET_WM_SYNC_REQUEST` value waiting for its ConfigureNotify.
    sync_request: ?u64 = null,

    const Hit = struct { f: window_api.HitTestFn, ctx: *anyopaque };
};

/// The newest button press: where (root coordinates) and which button.
const Press = struct {
    root: [2]i32 = .{ 0, 0 },
    button: u8 = 0,
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
    /// The master pointer of the last XI2 event (a drag grabs it).
    xi_pointer: u16 = 2,
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
    xdnd_atoms: xdnd.Atoms,
    /// A drag over one of our windows. Guarded by the mutex.
    xdnd_target: ?xdnd.Target = null,
    /// A drag we started. Guarded by the mutex.
    xdnd_source: ?xdnd.Source = null,
    /// The newest server timestamp seen in an event (0 = CurrentTime).
    last_time: u32 = 0,
    /// The newest button press, for WM move/resize requests.
    last_press: Press = .{},
    /// Created cursors. Guarded by the mutex.
    cursors: cursor_mod.Cursors,
    /// RandR 1.5's first event code, or null without it.
    randr_event: ?u8 = null,
    /// The monitors, refreshed on screen changes. Guarded by the mutex.
    mons: std.ArrayList(types.MonitorInfo) = .empty,
    /// SYNC 3.1 is available for `_NET_WM_SYNC_REQUEST`.
    sync_ok: bool = false,
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
            .xdnd_atoms = try conn.internAtoms(&xdnd.atom_names),
            .path = .put_image,
            .arena = arena,
            .ui_wake = ui_wake,
            .cursors = .init(gpa, opts.environ_map),
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
        errdefer b.mons.deinit(gpa);
        b.initRandr();
        b.sync_ok = initSync(conn);
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
        w.* = .{ .id = id, .xid = xid, .gc = gc, .size = size, .presenter = .init(b.gpa, b.io, c, b.path, xid, gc, s.root_depth, id), .csd = opts.decorations == .client };
        w.presenter.bind();
        if (b.gpu) |*g| w.presenter.gpu = g;
        b.createX(w, opts) catch return error.SystemResources;
        b.applyCursor(w);
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
        if (b.sync_ok) {
            const counter = try c.newXid();
            _ = try c.request(xsync.CreateCounter, .{ .id = counter }, &.{});
            w.presenter.sync_counter = counter;
            var v: [4]u8 = undefined;
            std.mem.writeInt(u32, &v, counter, .little);
            try b.setProp(w.xid, a.get("_NET_WM_SYNC_REQUEST_COUNTER"), proto.Atom.cardinal, 32, &v);
            try b.setAtoms(w.xid, a.get("WM_PROTOCOLS"), &.{ a.get("WM_DELETE_WINDOW"), a.get("_NET_WM_PING"), a.get("_NET_WM_SYNC_REQUEST") });
        } else try b.setAtoms(w.xid, a.get("WM_PROTOCOLS"), &.{ a.get("WM_DELETE_WINDOW"), a.get("_NET_WM_PING") });
        if (w.csd) {
            const hints = ewmh.motifNoDecorations();
            try b.setProp(w.xid, a.get("_MOTIF_WM_HINTS"), a.get("_MOTIF_WM_HINTS"), 32, &hints);
        }
        try b.setAtoms(w.xid, a.get("_NET_WM_WINDOW_TYPE"), &.{a.get("_NET_WM_WINDOW_TYPE_NORMAL")});
        try b.setAtoms(w.xid, b.xdnd_atoms.get("XdndAware"), &.{xdnd.version});
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
        if (w.presenter.sync_counter != 0) _ = b.conn.request(xsync.DestroyCounter, .{ .counter = w.presenter.sync_counter }, &.{}) catch {};
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
            // The IME comes with a later E01.F05 task; the window must
            // exist.
            .set_cursor => |t| {
                const w = try b.lookup(t.win);
                w.cursor = t.shape;
                b.applyCursor(w);
            },
            .set_ime_state => |t| _ = try b.lookup(t.win),
            .set_hit_test => |t| (try b.lookup(t.win)).hit = .{ .f = t.f, .ctx = t.ctx },
            .set_min_size => |t| try b.setMinSize((try b.lookup(t.win)).xid, t.size),
            .request_state => |t| {
                const w = try b.lookup(t.win);
                const a = &b.atoms;
                switch (t.op) {
                    .show => try b.activate(w, ewmh.Source.application),
                    .maximize, .unmaximize => try b.sendRoot(w.xid, a.get("_NET_WM_STATE"), .{ @intFromBool(t.op == .maximize), a.get("_NET_WM_STATE_MAXIMIZED_VERT"), a.get("_NET_WM_STATE_MAXIMIZED_HORZ"), ewmh.Source.application, 0 }),
                    .fullscreen, .unfullscreen => try b.sendRoot(w.xid, a.get("_NET_WM_STATE"), .{ @intFromBool(t.op == .fullscreen), a.get("_NET_WM_STATE_FULLSCREEN"), 0, ewmh.Source.application, 0 }),
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
            .start_drag => |t| {
                try b.xdndStart(t.win, t.items, t.allowed);
                // The pointer grab needs a reply: `dispatch` takes it.
                b.ui_wake.signal();
            },
            .set_drop_effect => |t| b.xdndSetEffect(t.win, t.accept, t.effect),
            .begin_move => |win| try b.moveResize(try b.lookup(win), ewmh.move_direction),
            .begin_resize => |t| try b.moveResize(try b.lookup(t.win), ewmh.resizeDirection(t.edge)),
            .show_window_menu => |t| {
                const w = try b.lookup(t.win);
                const r = try b.conn.reply(try b.conn.request(proto.TranslateCoordinates, .{ .src_window = w.xid, .dst_window = b.conn.screen().root, .src_x = @intCast(std.math.clamp(t.at.x, -32768, 32767)), .src_y = @intCast(std.math.clamp(t.at.y, -32768, 32767)) }, &.{}));
                try b.showWindowMenu(w, .{ r.x, r.y });
            },
            .activate => |t| try b.activate(try b.lookup(t.win), if (t.token != null) ewmh.Source.user else ewmh.Source.application),
            .request_attention => |win| {
                const w = try b.lookup(win);
                try b.sendRoot(w.xid, b.atoms.get("_NET_WM_STATE"), .{ ewmh.StateAction.add, b.atoms.get("_NET_WM_STATE_DEMANDS_ATTENTION"), 0, ewmh.Source.application, 0 });
            },
            .open_dialog, .open_uri => return error.Unsupported,
        }
    }

    /// Asks the WM to raise and focus `w`, mapping it first if minimized.
    fn activate(b: *X11Backend, w: *Window, source: u32) !void {
        if (w.hidden) _ = try b.conn.request(proto.MapWindow, .{ .window = w.xid }, &.{});
        try b.sendRoot(w.xid, b.atoms.get("_NET_ACTIVE_WINDOW"), .{ source, b.last_time, 0, 0, 0 });
    }

    /// Hands the pointer to the WM for a move (`ewmh.move_direction`) or
    /// resize from the newest press.
    fn moveResize(b: *X11Backend, w: *Window, direction: u32) !void {
        const p = b.last_press;
        // The press's implicit grab would keep the pointer from the WM.
        b.ungrabPointer();
        try b.sendRoot(w.xid, b.atoms.get("_NET_WM_MOVERESIZE"), .{ @bitCast(p.root[0]), @bitCast(p.root[1]), direction, if (p.button == 0) 1 else p.button, ewmh.Source.user });
    }

    /// Opens the WM's window menu at `root` if it supports
    /// `_GTK_SHOW_WINDOW_MENU`.
    fn showWindowMenu(b: *X11Backend, w: *Window, root: [2]i32) !void {
        const c = b.conn;
        const supported = try c.reply(try c.request(proto.GetProperty, .{ .window = c.screen().root, .property = b.atoms.get("_NET_SUPPORTED"), .type = proto.Atom.atom }, &.{}));
        if (supported.format != 32 or !ewmh.lists(supported.value, b.atoms.get("_GTK_SHOW_WINDOW_MENU"))) return;
        b.ungrabPointer();
        try b.sendRoot(w.xid, b.atoms.get("_GTK_SHOW_WINDOW_MENU"), .{ b.xi_pointer, @bitCast(root[0]), @bitCast(root[1]), 0, 0 });
    }

    fn setSyncCounter(b: *X11Backend, w: *Window, v: u64) void {
        const s = xsync.split(v);
        _ = b.conn.request(xsync.SetCounter, .{ .counter = w.presenter.sync_counter, .hi = s.hi, .lo = s.lo }, &.{}) catch |err| log.warn("setting the sync counter: {t}", .{err});
    }

    /// Answers `_NET_WM_PING` by sending it back to the root window.
    fn pong(b: *X11Backend, ev: []const u8) void {
        const root = b.conn.screen().root;
        _ = b.conn.request(proto.SendEvent, .{
            .destination = root,
            .event_mask = proto.EventMask.substructure_notify | proto.EventMask.substructure_redirect,
            .event = ewmh.pong(ev, root),
        }, &.{}) catch |err| log.warn("answering _NET_WM_PING: {t}", .{err});
    }

    /// Re-reads `_NET_WM_STATE` and reports maximize/fullscreen changes.
    fn readWmState(b: *X11Backend, w: *Window) void {
        const c = b.conn;
        const a = &b.atoms;
        const reply = c.reply(c.request(proto.GetProperty, .{ .window = w.xid, .property = a.get("_NET_WM_STATE"), .type = proto.Atom.atom }, &.{}) catch return) catch return;
        const st = ewmh.parseState(if (reply.format == 32) reply.value else &.{}, .{
            .max_vert = a.get("_NET_WM_STATE_MAXIMIZED_VERT"),
            .max_horz = a.get("_NET_WM_STATE_MAXIMIZED_HORZ"),
            .fullscreen = a.get("_NET_WM_STATE_FULLSCREEN"),
            .hidden = a.get("_NET_WM_STATE_HIDDEN"),
        });
        if (st.hidden != w.hidden) {
            w.hidden = st.hidden;
            // Un-minimizing maps the window again, which clears it.
            if (st.hidden) b.setOccluded(w, true);
        }
        if (st.maximized == w.maximized and st.fullscreen == w.fullscreen) return;
        w.maximized = st.maximized;
        w.fullscreen = st.fullscreen;
        w.serial +%= 1;
        b.stageConfigure(w);
    }

    /// Shows `w`'s cursor (the resize cursor over a resize region, else
    /// the app's) at the current scale.
    fn applyCursor(b: *X11Backend, w: *Window) void {
        const shape = w.auto_cursor orelse w.cursor;
        const size: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(b.cursors.baseSize())) * b.scale));
        const xid = b.cursors.get(b.gpa, b.io, b.conn, shape, @max(size, 1)) catch |err| {
            log.warn("creating the {t} cursor: {t}", .{ shape, err });
            return;
        };
        if (xid == w.shown_cursor) return;
        w.shown_cursor = xid;
        _ = b.conn.request(proto.ChangeWindowAttributes, .{ .window = w.xid, .values = .{ .values = .{ .cursor = xid } } }, &.{}) catch |err| log.warn("setting the cursor: {t}", .{err});
    }

    /// Over a client-decorated window, shows resize cursors on the app's
    /// resize regions.
    fn csdHover(b: *X11Backend, w: *Window, pos: [2]f32) void {
        if (!w.csd) return;
        const h = w.hit orelse return;
        const region = h.f(h.ctx, .{ .x = @intFromFloat(@floor(pos[0])), .y = @intFromFloat(@floor(pos[1])) });
        const shape: ?CursorShape = if (csd.regionEdge(region)) |e| csd.cursorFor(e) else null;
        if (std.meta.eql(shape, w.auto_cursor)) return;
        w.auto_cursor = shape;
        b.applyCursor(w);
    }

    /// Selects RandR 1.5 screen changes and reads the monitors.
    fn initRandr(b: *X11Backend) void {
        const c = b.conn;
        const info = c.extension("RANDR") orelse return;
        const v = c.reply(c.request(randr.QueryVersion, .{}, &.{}) catch return) catch return;
        if (v.major < 1 or (v.major == 1 and v.minor < 5)) return;
        _ = c.request(randr.SelectInput, .{ .window = c.screen().root, .enable = randr.NotifyMask.layout }, &.{}) catch return;
        b.randr_event = info.first_event;
        b.refreshMonitors();
    }

    /// Re-reads the RandR monitors; keeps the old list on failure.
    fn refreshMonitors(b: *X11Backend) void {
        const c = b.conn;
        const reply = c.reply(c.request(randr.GetMonitors, .{ .window = c.screen().root }, &.{}) catch return) catch return;
        var found: [16]randr.Monitor = undefined;
        const total = randr.parseMonitors(reply.bytes, &found) catch return;
        const n = @min(total, found.len);
        b.mons.clearRetainingCapacity();
        const refresh: u32 = @intCast(@divTrunc(std.time.ns_per_s * 1000, @as(u64, b.opts.refresh_ns)));
        for (found[0..n]) |m| {
            var info: types.MonitorInfo = .{ .id = m.name, .rect_px = m.rect, .work_px = m.rect, .scale = .{ .factor = b.scale }, .refresh_mhz = refresh, .primary = m.primary };
            // The reply buffer is reused: names are fetched after parsing.
            if (c.reply(c.request(proto.GetAtomName, .{ .atom = m.name }, &.{}) catch null orelse continue)) |nm| {
                info.name_len = @intCast(@min(nm.name.len, info.name_buf.len));
                @memcpy(info.name_buf[0..info.name_len], nm.name[0..info.name_len]);
            } else |_| {}
            b.mons.append(b.gpa, info) catch return;
        }
    }

    fn stageConfigure(b: *X11Backend, w: *Window) void {
        b.stage(.{ .window_configure = .{ .win = w.id, .size = w.size, .scale = .{ .factor = b.scale }, .state = .{ .maximized = w.maximized, .fullscreen = w.fullscreen, .activated = w.focused }, .serial = w.serial, .screen_origin_px = w.origin } });
    }

    /// Routes a press or release on a client-decorated window: caption
    /// and resize regions go to the WM; true when the event was used.
    fn routeCsd(b: *X11Backend, w: *Window, detail: u8, pressed: bool, pos: [2]f32) bool {
        if (!w.csd) return false;
        if (!pressed) {
            if (w.csd_swallow != detail) return false;
            w.csd_swallow = null;
            return true;
        }
        const region: types.HitRegion = if (w.hit) |h| h.f(h.ctx, .{ .x = @intFromFloat(@floor(pos[0])), .y = @intFromFloat(@floor(pos[1])) }) else .client;
        const button: types.Button = switch (detail) {
            1 => .left,
            2 => .middle,
            3 => .right,
            else => return false,
        };
        const double = region == .caption and button == .left and w.csd_clicks.press(b.nowNs(), pos, double_click_ns, double_click_px);
        const action = csd.pressAction(region, button, double);
        const result = switch (action) {
            .deliver => return false,
            .move => b.moveResize(w, ewmh.move_direction),
            .resize => |e| b.moveResize(w, ewmh.resizeDirection(e)),
            .window_menu => b.showWindowMenu(w, b.last_press.root),
            .toggle_maximize => b.sendRoot(w.xid, b.atoms.get("_NET_WM_STATE"), .{ ewmh.StateAction.toggle, b.atoms.get("_NET_WM_STATE_MAXIMIZED_VERT"), b.atoms.get("_NET_WM_STATE_MAXIMIZED_HORZ"), ewmh.Source.user, 0 }),
        };
        result catch |err| log.warn("window manager request: {t}", .{err});
        w.csd_swallow = detail;
        return true;
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
            if (d.xdnd) {
                const live = if (b.xdnd_target) |t| t.dropping else false;
                const data: types.PayloadSlice = if (live and d.ok and d.data.len > 0) b.putOwned(d.data) else blk: {
                    b.gpa.free(d.data);
                    break :blk .empty;
                };
                b.xdndDropped(d.ok, data);
                continue;
            }
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
        b.lock();
        defer b.unlock();
        if (b.mons.items.len > 0) {
            const n = @min(out.len, b.mons.items.len);
            @memcpy(out[0..n], b.mons.items[0..n]);
            return b.mons.items.len;
        }
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
        b.xdndExpire(b.nowNs());
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
                b.xdndExpire(now);
                if (b.staged.items.len > 0) return;
                if (b.nextFrameNs()) |t| until = if (until) |d| @min(d, t) else t;
                if (b.sel.nextDeadline()) |t| until = if (until) |d| @min(d, t) else t;
                if (b.xdndDeadline()) |t| until = if (until) |d| @min(d, t) else t;
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
        if (b.xdnd_target) |*t| t.deinit(b.gpa);
        if (b.xdnd_source) |*s| s.deinit(b.gpa);
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
        b.mons.deinit(b.gpa);
        b.cursors.deinit(b.gpa, b.conn);
        b.conn.flush() catch {};
        b.conn.deinit();
        b.arena.deinit(b.gpa);
        b.ui_wake.deinit();
        b.gpa.destroy(b);
    }

    // ---- event dispatch (UI thread) ----

    /// Translates every X event the socket has.
    fn dispatch(b: *X11Backend) void {
        if (b.dead) return;
        {
            b.lock();
            defer b.unlock();
            b.xdndGrab();
        }
        while (true) {
            const ev = b.conn.pollEvent() catch |err| {
                log.err("X connection lost: {t}", .{err});
                b.dead = true;
                b.lock();
                for (b.windows.items) |w| b.stage(.{ .window_close_requested = w.id });
                b.unlock();
                return;
            } orelse {
                // Send what translating queued (XDND answers) even when
                // the app only polls.
                b.conn.flush() catch {};
                return;
            };
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
        if (b.randr_event) |base| if (code == base or code == base + 1) {
            if (code == base + 1 and !randr.notifyChangesLayout(ev[1])) return;
            b.refreshMonitors();
            return b.stage(.monitors_changed);
        };
        if (b.xkb_event) |base| if (code == base) return b.onXkbEvent(ev);
        // While we drag, the pointer grab sends core events to us.
        if (b.xdnd_source) |s| if (s.grabbed and b.xi_opcode == null) switch (code) {
            proto.EventCode.motion_notify => return b.xdndSourceMotion(.{ @bitCast(u16At(ev, 20)), @bitCast(u16At(ev, 22)) }, u32At(ev, 4)),
            proto.EventCode.button_release => return if (ev[1] < 4 or ev[1] > 7) b.xdndSourceRelease(u32At(ev, 4)),
            proto.EventCode.button_press, proto.EventCode.enter_notify, proto.EventCode.leave_notify => return,
            else => {},
        };
        if (b.xi_opcode) |op| if (code == proto.generic_event and ev[1] == op) {
            if (b.xdnd_source) |s| if (s.grabbed) return b.xdndXiEvent(ev);
            return b.onXiEvent(ev);
        };
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
                b.csdHover(w, eventPos(ev));
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
                if (w.sync_request) |v| {
                    w.sync_request = null;
                    // Nothing to redraw at an unchanged size: answer now.
                    if (size.w == w.size.w and size.h == w.size.h) b.setSyncCounter(w, v) else w.presenter.armSync(v, size.w, size.h);
                }
                if (size.w == 0 or size.h == 0 or (size.w == w.size.w and size.h == w.size.h)) return;
                w.size = size;
                w.serial +%= 1;
                w.origin = .{ .x = @as(i16, @bitCast(u16At(ev, 16))), .y = @as(i16, @bitCast(u16At(ev, 18))) };
                b.stageConfigure(w);
            },
            proto.EventCode.client_message => {
                if (xdnd.decode(&b.xdnd_atoms, ev)) |m| return b.onXdnd(u32At(ev, 4), m);
                const w = b.byXid(u32At(ev, 4)) orelse return;
                if (u32At(ev, 8) != b.atoms.get("WM_PROTOCOLS")) return;
                const which = u32At(ev, 12);
                if (which == b.atoms.get("WM_DELETE_WINDOW")) {
                    b.stage(.{ .window_close_requested = w.id });
                } else if (which == b.atoms.get("_NET_WM_PING")) {
                    b.pong(ev);
                } else if (which == b.atoms.get("_NET_WM_SYNC_REQUEST") and w.presenter.sync_counter != 0) {
                    w.sync_request = xsync.join(@bitCast(u32At(ev, 24)), u32At(ev, 20));
                }
            },
            proto.EventCode.property_notify => {
                const w = b.byXid(u32At(ev, 4)) orelse return;
                if (u32At(ev, 8) == b.atoms.get("_NET_WM_STATE")) b.readWmState(w);
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
        // Escape cancels a drag we started.
        if (pressed and keycode == 9 and b.xdnd_source != null) return b.xdndCancel();
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
                b.xi_pointer = e.device_id;
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
                        b.csdHover(w, e.pos);
                        b.stage(.{ .pointer_move = .{ .win = w.id, .pos_px = e.pos, .mods = mods, .time_ns = b.nowNs() } });
                    },
                    xinput2.EventType.button_press, xinput2.EventType.button_release => {
                        // Wheel buttons emulated from scroll valuators: the
                        // valuators already scrolled.
                        if (e.flags & xinput2.pointer_emulated != 0) return;
                        b.pointerButton(w, @intCast(@min(e.detail, 255)), e.evtype == xinput2.EventType.button_press, e.pos, e.root, mods);
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
        const root: [2]f32 = .{ @floatFromInt(@as(i16, @bitCast(u16At(ev, 20)))), @floatFromInt(@as(i16, @bitCast(u16At(ev, 22)))) };
        b.pointerButton(w, ev[1], pressed, eventPos(ev), root, modsFromState(u16At(ev, 28)));
    }

    /// A button press or release; 4–7 are wheel notches. Mutex held.
    fn pointerButton(b: *X11Backend, w: *Window, detail: u8, pressed: bool, pos: [2]f32, root: [2]f32, mods: keys_api.Mods) void {
        const now = b.nowNs();
        if (pressed and (detail < 4 or detail > 7)) b.last_press = .{ .root = .{ @intFromFloat(@floor(root[0])), @intFromFloat(@floor(root[1])) }, .button = detail };
        if (b.routeCsd(w, detail, pressed, pos)) return;
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

    // ---- XDND drag and drop (E01.F05.S03.T03, mutex held) ----

    /// Sends an XDND message naming `window` to `dest`.
    fn xdndSend(b: *X11Backend, dest: u32, window: u32, comptime ty: []const u8, l: [5]u32) void {
        _ = b.conn.request(proto.SendEvent, .{ .destination = dest, .event_mask = 0, .event = xdnd.clientMessage(window, b.xdnd_atoms.get(ty), l) }, &.{}) catch |err| log.warn("sending {s}: {t}", .{ ty, err });
    }

    /// An XDND message to our window `xid`.
    fn onXdnd(b: *X11Backend, xid: u32, m: xdnd.Message) void {
        const a = &b.xdnd_atoms;
        switch (m) {
            .enter => |e| {
                const w = b.byXid(xid) orelse return;
                if (e.version < 3) return;
                b.xdndEndTarget(true);
                var t: xdnd.Target = .{ .source = e.source, .win = w.id, .xid = xid, .version = @min(e.version, xdnd.version), .last_ns = b.nowNs() };
                b.xdndTypes(&t, e) catch |err| {
                    log.warn("XDND type list: {t}", .{err});
                    t.deinit(b.gpa);
                    return;
                };
                b.xdnd_target = t;
            },
            .position => |p| {
                const t = &(b.xdnd_target orelse return);
                if (t.source != p.source or t.dropping) return;
                t.last_ns = b.nowNs();
                t.requested = p.action;
                if (t.offset == null) {
                    const c = b.conn;
                    const cookie = c.request(proto.TranslateCoordinates, .{ .src_window = c.screen().root, .dst_window = t.xid, .src_x = 0, .src_y = 0 }, &.{}) catch return;
                    const r = c.reply(cookie) catch return;
                    t.offset = .{ r.x, r.y };
                }
                t.pos = .{ @floatFromInt(@as(i32, p.root[0]) + t.offset.?[0]), @floatFromInt(@as(i32, p.root[1]) + t.offset.?[1]) };
                // XDND names one action per position; none means copy.
                const asked = xdnd.actionOf(a, p.action);
                const allowed: clipboard.DragActions = if (@as(u8, @bitCast(asked)) == 0) .{ .copy = true } else asked;
                if (!t.entered) {
                    // The first position carries the place the drag entered.
                    t.entered = true;
                    var buf: [16]u8 = undefined;
                    const mimes = t.mimeIds(&b.sel, b.xdnd_source != null, &buf);
                    b.stage(.{ .drop = .{ .win = t.win, .phase = .enter, .allowed = allowed, .pos_px = t.pos, .mimes = b.arena.put(mimes) catch .empty } });
                } else b.stage(.{ .drop = .{ .win = t.win, .phase = .over, .allowed = allowed, .pos_px = t.pos } });
                // The app's last answer; `set_drop_effect` sends a newer one.
                b.xdndSend(t.source, t.source, "XdndStatus", t.status(a, &b.sel));
            },
            .leave => |l| {
                const t = b.xdnd_target orelse return;
                if (t.source != l.source or t.dropping) return;
                b.xdndEndTarget(true);
            },
            .drop => |d| {
                const t = &(b.xdnd_target orelse return);
                if (t.source != d.source or t.dropping) return;
                if (!t.accepting(&b.sel)) {
                    b.xdndSend(t.source, t.source, "XdndFinished", .{ t.xid, 0, 0, 0, 0 });
                    return b.xdndEndTarget(true);
                }
                t.action = xdnd.chooseAction(a, t.effect, t.requested);
                b.sel.readXdnd(t.accept.?, d.time, b.nowNs()) catch |err| {
                    log.warn("reading a drop: {t}", .{err});
                    b.xdndSend(t.source, t.source, "XdndFinished", .{ t.xid, 0, 0, 0, 0 });
                    return b.xdndEndTarget(true);
                };
                t.dropping = true;
                // A drag of our own is answered at once.
                b.drainSelections();
            },
            .status => |st| {
                const s = &(b.xdnd_source orelse return);
                const tg = s.target orelse return;
                if (tg.window != st.target or s.dropped) return;
                if (s.statusArrived(st.accept, st.action)) |p| b.xdndSendPosition(p);
                if (s.release_pending and !s.waiting_status) b.xdndRelease();
            },
            .finished => |f| {
                const s = b.xdnd_source orelse return;
                const tg = s.target orelse return;
                if (!s.dropped or tg.window != f.target) return;
                // Before v5 `XdndFinished` carries no action: the last status's.
                const act: clipboard.DragActions = if (tg.version < 5) xdnd.actionOf(a, s.action) else if (f.accepted) xdnd.actionOf(a, f.action) else .{};
                b.xdndEndSource(act);
            },
        }
    }

    /// The offered types: inline in `XdndEnter`, or from `XdndTypeList`.
    fn xdndTypes(b: *X11Backend, t: *xdnd.Target, e: @FieldType(xdnd.Message, "enter")) !void {
        if (!e.more_types) {
            for (e.types) |ty| if (ty != 0) try t.types.append(b.gpa, ty);
            return;
        }
        const c = b.conn;
        const p = try c.reply(try c.request(proto.GetProperty, .{ .window = e.source, .property = b.xdnd_atoms.get("XdndTypeList"), .type = proto.Atom.atom }, &.{}));
        if (p.format != 32) return;
        var i: usize = 0;
        while (i + 4 <= p.value.len) : (i += 4) try t.types.append(b.gpa, u32At(p.value, i));
    }

    /// Forgets the drag over our window; `leave` tells the app, if it saw
    /// the drag.
    fn xdndEndTarget(b: *X11Backend, leave: bool) void {
        var t = b.xdnd_target orelse return;
        b.xdnd_target = null;
        if (leave and t.entered) b.stage(.{ .drop = .{ .win = t.win, .phase = .leave, .allowed = .{}, .pos_px = t.pos } });
        t.deinit(b.gpa);
    }

    /// The dropped data arrived (or the read failed): `drop` (or `leave`)
    /// and `XdndFinished`.
    fn xdndDropped(b: *X11Backend, ok: bool, data: types.PayloadSlice) void {
        const t = b.xdnd_target orelse return;
        if (!t.dropping) return;
        if (ok) b.stage(.{ .drop = .{ .win = t.win, .phase = .drop, .allowed = xdnd.actionOf(&b.xdnd_atoms, t.action), .pos_px = t.pos, .data = data } });
        const l: [5]u32 = if (t.version >= 5) .{ t.xid, @intFromBool(ok), if (ok) t.action else 0, 0, 0 } else .{ t.xid, 0, 0, 0, 0 };
        b.xdndSend(t.source, t.source, "XdndFinished", l);
        b.xdndEndTarget(!ok);
    }

    /// `Command.set_drop_effect`: remember the answer and tell the source.
    fn xdndSetEffect(b: *X11Backend, win: WindowId, accept: ?clipboard.MimeId, effect: clipboard.DragActions) void {
        const t = &(b.xdnd_target orelse return);
        if (t.win != win or t.dropping) return;
        t.accept = accept;
        t.effect = effect;
        if (t.entered) b.xdndSend(t.source, t.source, "XdndStatus", t.status(&b.xdnd_atoms, &b.sel));
    }

    /// `Command.start_drag`: own `XdndSelection` with `items`; the pointer
    /// grab follows on the dispatching thread (`xdndGrab`).
    fn xdndStart(b: *X11Backend, win: WindowId, items: []const clipboard.ClipItem, allowed: clipboard.DragActions) !void {
        const w = try b.lookup(win);
        if (b.xdnd_source != null) b.xdndCancel();
        var s: xdnd.Source = .{ .win = win, .allowed = if (@as(u8, @bitCast(allowed)) == 0) .{ .copy = true } else allowed, .time = b.last_time };
        errdefer s.deinit(b.gpa);
        for (items) |it| try s.types.appendSlice(b.gpa, b.sel.targetsFor(it.mime).slice());
        if (s.types.items.len > 3) {
            var buf: [32 * 4]u8 = undefined;
            const n = @min(s.types.items.len, 32);
            for (s.types.items[0..n], 0..) |t, i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], t, .little);
            try b.setProp(w.xid, b.xdnd_atoms.get("XdndTypeList"), proto.Atom.atom, 32, buf[0 .. n * 4]);
        }
        try b.sel.ownXdnd(items, b.last_time);
        b.xdnd_source = s;
    }

    /// The window a drag of ours started from.
    fn xdndSourceXid(b: *X11Backend) ?u32 {
        const s = b.xdnd_source orelse return null;
        return if (b.find(s.win)) |w| w.xid else null;
    }

    /// Takes the pointer grab of a new drag.
    fn xdndGrab(b: *X11Backend) void {
        const s = &(b.xdnd_source orelse return);
        if (!s.grab_pending) return;
        s.grab_pending = false;
        const xid = b.xdndSourceXid() orelse return b.xdndEndSource(.{});
        // With XI2 the button press began an XI2 implicit grab, which a
        // core grab cannot replace.
        const status = b.grabPointer(xid) catch return b.xdndEndSource(.{});
        if (status != 0) {
            log.warn("drag: pointer grab refused ({d})", .{status});
            return b.xdndEndSource(.{});
        }
        // The reply may have ended the drag (another one replaced it).
        if (b.xdnd_source) |*now| now.grabbed = true;
    }

    /// Grabs the pointer for `xid`: the grab status (0 is success).
    fn grabPointer(b: *X11Backend, xid: u32) !u8 {
        const c = b.conn;
        if (b.xi_opcode != null) {
            const E = xinput2.EventType;
            const mask: u32 = (1 << E.button_press) | (1 << E.button_release) | (1 << E.motion);
            return (try c.reply(try c.request(xinput2.GrabDevice, .{ .grab_window = xid, .device_id = b.xi_pointer, .mask = mask }, &.{}))).status;
        }
        const mask = proto.EventMask.button_press | proto.EventMask.button_release | proto.EventMask.pointer_motion;
        return (try c.reply(try c.request(proto.GrabPointer, .{ .grab_window = xid, .event_mask = @intCast(mask) }, &.{}))).status;
    }

    /// Releases a drag's pointer grab.
    fn ungrabPointer(b: *X11Backend) void {
        if (b.xi_opcode != null) {
            _ = b.conn.request(xinput2.UngrabDevice, .{ .device_id = b.xi_pointer }, &.{}) catch {};
        } else _ = b.conn.request(proto.UngrabPointer, .{}, &.{}) catch {};
    }

    /// An XI2 event while a drag of ours holds the grab.
    fn xdndXiEvent(b: *X11Backend, ev: []const u8) void {
        if (ev.len < 12) return;
        const e = xinput2.decodeDeviceEvent(ev) orelse return;
        switch (e.evtype) {
            xinput2.EventType.motion => b.xdndSourceMotion(.{ @intFromFloat(@floor(e.root[0])), @intFromFloat(@floor(e.root[1])) }, e.time),
            xinput2.EventType.button_release => if (e.detail < 4 or e.detail > 7) b.xdndSourceRelease(e.time),
            else => {},
        }
    }

    /// The child of `parent` containing root point `root`, if any.
    fn childAt(b: *X11Backend, parent: u32, root: [2]i16) ?u32 {
        const c = b.conn;
        const cookie = c.request(proto.TranslateCoordinates, .{ .src_window = c.screen().root, .dst_window = parent, .src_x = root[0], .src_y = root[1] }, &.{}) catch return null;
        const r = c.reply(cookie) catch return null;
        return if (r.child == 0) null else r.child;
    }

    /// One window property's first 32-bit value of type `ty`.
    fn prop32(b: *X11Backend, win: u32, prop: u32, ty: u32) ?u32 {
        const c = b.conn;
        const cookie = c.request(proto.GetProperty, .{ .window = win, .property = prop, .type = ty, .long_length = 1 }, &.{}) catch return null;
        const p = c.reply(cookie) catch return null;
        if (p.format != 32 or p.value.len < 4) return null;
        return u32At(p.value, 0);
    }

    /// `win` as a drop target: its proxy (an `XdndProxy` naming itself)
    /// or itself, if XdndAware at version 3 or later.
    fn xdndAware(b: *X11Backend, win: u32) ?xdnd.Source.Found {
        const a = &b.xdnd_atoms;
        var proxy = win;
        if (b.prop32(win, a.get("XdndProxy"), proto.Atom.window)) |px| {
            if (b.prop32(px, a.get("XdndProxy"), proto.Atom.window) == px) proxy = px;
        }
        const ver = b.prop32(proxy, a.get("XdndAware"), proto.Atom.atom) orelse return null;
        if (ver < 3) return null;
        return .{ .window = win, .proxy = proxy, .version = @intCast(@min(ver, xdnd.version)) };
    }

    /// The drop target under root point `root`: the first XdndAware
    /// window from the top level down, cached per top level.
    fn xdndFind(b: *X11Backend, root: [2]i16) ?xdnd.Source.Found {
        const s = &b.xdnd_source.?;
        const top = b.childAt(b.conn.screen().root, root) orelse return null;
        if (top == s.top) return s.found;
        s.top = top;
        s.found = null;
        var w = top;
        var depth: usize = 0;
        while (depth < 8) : (depth += 1) {
            if (b.xdndAware(w)) |f| {
                s.found = f;
                break;
            }
            w = b.childAt(w, root) orelse break;
        }
        return s.found;
    }

    fn xdndSendPosition(b: *X11Backend, root: [2]i16) void {
        const s = &(b.xdnd_source orelse return);
        const t = s.target orelse return;
        const src = b.xdndSourceXid() orelse return;
        b.xdndSend(t.proxy, t.window, "XdndPosition", .{ src, 0, xdnd.packRoot(root[0], root[1]), s.time, xdnd.chooseAction(&b.xdnd_atoms, s.allowed, 0) });
    }

    /// The grabbed pointer moved to `root` at `time`.
    fn xdndSourceMotion(b: *X11Backend, root: [2]i16, time: u32) void {
        const s = &(b.xdnd_source orelse return);
        if (s.dropped or s.release_pending) return;
        s.time = time;
        const src = b.xdndSourceXid() orelse return b.xdndCancel();
        const found = b.xdndFind(root);
        const same = if (found) |f| (if (s.target) |t| t.window == f.window else false) else s.target == null;
        if (!same) {
            if (s.target) |t| b.xdndSend(t.proxy, t.window, "XdndLeave", .{ src, 0, 0, 0, 0 });
            s.retarget(found);
            if (found) |f| b.xdndSend(f.proxy, f.window, "XdndEnter", s.enterData(src, f.version));
        }
        if (s.target != null and s.moved(root)) b.xdndSendPosition(root);
    }

    /// The button went up at `time`: drop once the target has answered
    /// the last position.
    fn xdndSourceRelease(b: *X11Backend, time: u32) void {
        const s = &(b.xdnd_source orelse return);
        if (s.dropped or s.release_pending) return;
        s.time = time;
        s.pending = null;
        if (s.waiting_status) {
            s.release_pending = true;
            return;
        }
        b.xdndRelease();
    }

    /// Drops on an accepting target, else leaves and ends the drag.
    fn xdndRelease(b: *X11Backend) void {
        const s = &b.xdnd_source.?;
        s.release_pending = false;
        if (s.grabbed) {
            b.ungrabPointer();
            s.grabbed = false;
        }
        const t = s.target orelse return b.xdndEndSource(.{});
        const src = b.xdndSourceXid() orelse return b.xdndEndSource(.{});
        if (!s.accepted) {
            b.xdndSend(t.proxy, t.window, "XdndLeave", .{ src, 0, 0, 0, 0 });
            return b.xdndEndSource(.{});
        }
        b.xdndSend(t.proxy, t.window, "XdndDrop", .{ src, 0, s.time, 0, 0 });
        s.dropped = true;
        s.deadline_ns = b.nowNs() + xdnd_finish_timeout_ns;
    }

    /// Cancels a drag we started (Escape, or a new drag).
    fn xdndCancel(b: *X11Backend) void {
        const s = b.xdnd_source orelse return;
        if (s.target) |t| if (!s.dropped) {
            if (b.xdndSourceXid()) |src| b.xdndSend(t.proxy, t.window, "XdndLeave", .{ src, 0, 0, 0, 0 });
        };
        b.xdndEndSource(.{});
    }

    /// Ends our drag: `source_finished` with `action`.
    fn xdndEndSource(b: *X11Backend, action: clipboard.DragActions) void {
        var s = b.xdnd_source orelse return;
        b.xdnd_source = null;
        if (s.grabbed) b.ungrabPointer();
        b.sel.ownXdnd(&.{}, s.time) catch {};
        s.deinit(b.gpa);
        b.stage(.{ .drop = .{ .win = s.win, .phase = .source_finished, .allowed = action, .pos_px = .{ 0, 0 } } });
    }

    /// Ends drags whose peer went quiet.
    fn xdndExpire(b: *X11Backend, now: u64) void {
        if (b.xdnd_target) |t| if (!t.dropping and now >= t.last_ns + xdnd_target_timeout_ns) b.xdndEndTarget(true);
        if (b.xdnd_source) |s| if (s.dropped and now >= s.deadline_ns) b.xdndEndSource(.{});
    }

    /// When `xdndExpire` has work next.
    fn xdndDeadline(b: *X11Backend) ?u64 {
        var d: ?u64 = null;
        if (b.xdnd_target) |t| if (!t.dropping) {
            d = t.last_ns + xdnd_target_timeout_ns;
        };
        if (b.xdnd_source) |s| if (s.dropped) {
            d = if (d) |x| @min(x, s.deadline_ns) else s.deadline_ns;
        };
        return d;
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

/// Initializes SYNC 3.1; false without it.
fn initSync(c: *Conn) bool {
    if (c.extension("SYNC") == null) return false;
    const v = c.reply(c.request(xsync.Initialize, .{}, &.{}) catch return false) catch return false;
    return v.major > 3 or (v.major == 3 and v.minor >= 1);
}

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

/// A private Xvfb; an absent Xvfb skips.
pub const XvfbForTest = conn_mod.XvfbForTest;

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
    // A round trip: the server has A as owner before B asks.
    try a.conn.sync();
    try pb.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .html, .request = 4 } });
    const lg = try waitBoth(pb, pa, .clipboard_data);
    try testing.expect(lg.data.large);
    try testing.expectEqualSlices(u8, big, pb.payload(lg.data));
    pb.release(lg.data);

    try pa.submit(.{ .clipboard_write = .{ .which = .primary, .items = &.{.{ .mime = .text_utf8, .data = "sel" }} } });

    // A round trip: the server has A as owner before B asks.

    try a.conn.sync();
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

test "Xvfb: XDND between two clients (enter, status, drop, finished)" {
    var x = XvfbForTest.start(8) catch return error.SkipZigTest;
    defer x.stop();
    const a = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer a.deinit();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    if (a.conn.extension("XTEST") == null) return error.SkipZigTest;
    const pa = a.platform();
    const pb = b.platform();
    // The target maps second, so it stacks above the source at (0, 0).
    const wa = try pa.createWindow(.{ .title = "zg drag source", .size = .{ .w = 200, .h = 200 } });
    _ = try waitFor(pa, .window_configure, wa);
    // A round trip: the server has mapped A's window before B's.
    try a.conn.sync();
    const wb = try pb.createWindow(.{ .title = "zg drop target", .size = .{ .w = 50, .h = 50 } });
    _ = try waitFor(pb, .window_configure, wb);
    try b.conn.sync();

    const root = a.conn.screen().root;
    _ = try a.conn.request(XTestFakeInput, .{ .type = 6, .detail = 0, .root = root, .root_x = 150, .root_y = 150 }, &.{});
    _ = try a.conn.request(XTestFakeInput, .{ .type = 4, .detail = 1 }, &.{});
    try a.conn.sync();
    const uris = "file:///tmp/zg-dnd.txt\r\n";
    try pa.submit(.{ .start_drag = .{ .win = wa, .items = &.{.{ .mime = .uri_list, .data = uris }}, .allowed = .{ .copy = true, .move = true } } });
    // Dispatch takes the grab.
    var evs: [64]Event = undefined;
    _ = pa.pollEvents(&evs);
    try testing.expect(a.xdnd_source.?.grabbed);

    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 5 * std.time.ns_per_s;
    var step: u8 = 0;
    var entered = false;
    var dropped: ?clipboard.DropEvent = null;
    var finished: ?clipboard.DropEvent = null;
    var moves: i16 = 0;
    while (dropped == null or finished == null) {
        const now: u64 = @intCast(Io.Clock.awake.now(testing.io).nanoseconds);
        if (now >= deadline) return error.Timeout;
        if (step == 0) {
            _ = try a.conn.request(XTestFakeInput, .{ .type = 6, .detail = 0, .root = root, .root_x = 20, .root_y = 20 }, &.{});
            try a.conn.flush();
            step = 1;
        }
        const nb = pb.pollEvents(&evs);
        for (evs[0..nb]) |e| if (e == .drop) switch (e.drop.phase) {
            .enter => {
                entered = true;
                try testing.expectEqual([2]f32{ 20, 20 }, e.drop.pos_px);
                const mimes = pb.payload(e.drop.mimes);
                try testing.expectEqual(@intFromEnum(clipboard.MimeId.uri_list), std.mem.readInt(u16, mimes[0..2], .little));
                try pb.submit(.{ .set_drop_effect = .{ .win = wb, .accept = .uri_list, .effect = .{ .copy = true } } });
            },
            .drop => {
                dropped = e.drop;
                try testing.expectEqualStrings(uris, pb.payload(e.drop.data));
            },
            .leave => return error.UnexpectedLeave,
            else => {},
        };
        const na = pa.pollEvents(&evs);
        for (evs[0..na]) |e| if (e == .drop and e.drop.phase == .source_finished) {
            finished = e.drop;
        };
        // Once the target accepted, move on it again, then release.
        if (step == 1 and entered and a.xdnd_source != null and a.xdnd_source.?.accepted) {
            moves += 1;
            _ = try a.conn.request(XTestFakeInput, .{ .type = 6, .detail = 0, .root = root, .root_x = 20 + moves, .root_y = 22 }, &.{});
            if (moves == 3) {
                _ = try a.conn.request(XTestFakeInput, .{ .type = 5, .detail = 1 }, &.{});
                step = 2;
            }
            try a.conn.flush();
        }
        pa.waitEvents(now + 2 * std.time.ns_per_ms);
    }
    try testing.expectEqual(clipboard.DragActions{ .copy = true }, dropped.?.allowed);
    try testing.expectEqual(wa, finished.?.win);
    try testing.expectEqual(clipboard.DragActions{ .copy = true }, finished.?.allowed);
    try testing.expect(a.xdnd_source == null and b.xdnd_target == null);
}

/// A second client acting as the window manager: it redirects the root's
/// substructure, so client messages sent to the root reach it.
const FakeWm = struct {
    r: *Conn,
    /// `pointer_button` events `message` saw while polling.
    buttons: usize = 0,

    fn start(display: []const u8) !FakeWm {
        var env: std.process.Environ.Map = .init(testing.allocator);
        defer env.deinit();
        const r = try Conn.connect(testing.allocator, testing.io, &env, .{ .display = display });
        errdefer r.deinit();
        const mask = proto.EventMask.substructure_notify | proto.EventMask.substructure_redirect;
        try r.checked(proto.ChangeWindowAttributes, .{ .window = r.screen().root, .values = .{ .values = .{ .event_mask = mask } } }, &.{});
        return .{ .r = r };
    }

    fn stop(f: *FakeWm) void {
        f.r.deinit();
    }

    /// The next client message of type `ty` sent to the root, letting `p`
    /// dispatch meanwhile; other events are dropped.
    fn message(f: *FakeWm, p: Platform, ty: u32) ![5]u32 {
        var evs: [16]Event = undefined;
        var tries: usize = 0;
        while (tries < 2000) : (tries += 1) {
            const n = p.pollEvents(&evs);
            for (evs[0..n]) |e| if (e == .pointer_button) {
                f.buttons += 1;
            };
            try f.r.flush();
            while (try f.r.pollEvent()) |ev| {
                if (ev[0] & 0x7f != proto.EventCode.client_message or u32At(ev, 8) != ty) continue;
                var out: [5]u32 = undefined;
                for (&out, 0..) |*d, i| d.* = u32At(ev, 12 + i * 4);
                return out;
            }
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.Timeout;
    }
};

test "Xvfb: _NET_WM_PING answered; _NET_WM_STATE reported; move, resize, menu and activate requests" {
    var x = XvfbForTest.start(9) catch return error.SkipZigTest;
    defer x.stop();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg wm", .size = .{ .w = 64, .h = 48 } });
    _ = try waitFor(p, .window_configure, win);
    var wm = try FakeWm.start(x.display());
    defer wm.stop();
    const r = wm.r;
    const a = &b.atoms;
    const xid = b.xidOf(win).?;
    const root = r.screen().root;

    // WM_PROTOCOLS lists the ping.
    const protos = try r.reply(try r.request(proto.GetProperty, .{ .window = xid, .property = a.get("WM_PROTOCOLS"), .type = proto.Atom.atom }, &.{}));
    try testing.expect(ewmh.lists(protos.value, a.get("_NET_WM_PING")));

    var ping: [32]u8 = @splat(0);
    ping[0] = proto.EventCode.client_message;
    ping[1] = 32;
    std.mem.writeInt(u32, ping[4..8], xid, .little);
    std.mem.writeInt(u32, ping[8..12], a.get("WM_PROTOCOLS"), .little);
    std.mem.writeInt(u32, ping[12..16], a.get("_NET_WM_PING"), .little);
    std.mem.writeInt(u32, ping[16..20], 4321, .little);
    std.mem.writeInt(u32, ping[20..24], xid, .little);
    try r.checked(proto.SendEvent, .{ .destination = xid, .event_mask = 0, .event = ping }, &.{});
    const pong = try wm.message(p, a.get("WM_PROTOCOLS"));
    try testing.expectEqual(a.get("_NET_WM_PING"), pong[0]);
    try testing.expectEqual(4321, pong[1]);
    try testing.expectEqual(xid, pong[2]);

    // The WM maximizes the window.
    var state: [8]u8 = undefined;
    std.mem.writeInt(u32, state[0..4], a.get("_NET_WM_STATE_MAXIMIZED_HORZ"), .little);
    std.mem.writeInt(u32, state[4..8], a.get("_NET_WM_STATE_MAXIMIZED_VERT"), .little);
    try r.checked(proto.ChangeProperty, .{ .window = xid, .property = a.get("_NET_WM_STATE"), .type = proto.Atom.atom, .format = 32, .length = 2, .bytes = &state }, &.{});
    const cfg = (try waitFor(p, .window_configure, win)).window_configure;
    try testing.expect(cfg.state.maximized);
    try testing.expect(!cfg.state.fullscreen);

    try p.submit(.{ .begin_resize = .{ .win = win, .edge = .bottom_right } });
    const rs = try wm.message(p, a.get("_NET_WM_MOVERESIZE"));
    try testing.expectEqual(4, rs[2]);
    try testing.expectEqual(1, rs[3]);
    try testing.expectEqual(ewmh.Source.user, rs[4]);
    try p.submit(.{ .begin_move = win });
    try testing.expectEqual(ewmh.move_direction, (try wm.message(p, a.get("_NET_WM_MOVERESIZE")))[2]);

    // The window menu needs _GTK_SHOW_WINDOW_MENU in _NET_SUPPORTED.
    var supported: [4]u8 = undefined;
    std.mem.writeInt(u32, &supported, a.get("_GTK_SHOW_WINDOW_MENU"), .little);
    try r.checked(proto.ChangeProperty, .{ .window = root, .property = a.get("_NET_SUPPORTED"), .type = proto.Atom.atom, .format = 32, .length = 1, .bytes = &supported }, &.{});
    try p.submit(.{ .show_window_menu = .{ .win = win, .at = .{ .x = 5, .y = 6 } } });
    const menu = try wm.message(p, a.get("_GTK_SHOW_WINDOW_MENU"));
    // No WM moved the window: window and root coordinates agree.
    try testing.expectEqual(5, menu[1]);
    try testing.expectEqual(6, menu[2]);

    try p.submit(.{ .activate = .{ .win = win, .token = "t" } });
    try testing.expectEqual(ewmh.Source.user, (try wm.message(p, a.get("_NET_ACTIVE_WINDOW")))[0]);
    try p.submit(.{ .request_attention = win });
    const att = try wm.message(p, a.get("_NET_WM_STATE"));
    try testing.expectEqual(ewmh.StateAction.add, att[0]);
    try testing.expectEqual(a.get("_NET_WM_STATE_DEMANDS_ATTENTION"), att[1]);
}

test "Xvfb: client decorations route caption presses to the window manager" {
    var x = XvfbForTest.start(10) catch return error.SkipZigTest;
    defer x.stop();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    if (b.conn.extension("XTEST") == null) return error.SkipZigTest;
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg csd", .size = .{ .w = 120, .h = 80 }, .decorations = .client });
    _ = try waitFor(p, .window_configure, win);
    const Caption = struct {
        fn hit(_: *anyopaque, pt: types.PxPoint) types.HitRegion {
            if (pt.y < 20) return .caption;
            if (pt.x >= 110 and pt.y >= 70) return .resize_bottom_right;
            return .client;
        }
    };
    var dummy: u8 = 0;
    try p.submit(.{ .set_hit_test = .{ .win = win, .f = Caption.hit, .ctx = &dummy } });
    var wm = try FakeWm.start(x.display());
    defer wm.stop();
    const a = &b.atoms;
    const xid = b.xidOf(win).?;
    const hints = try wm.r.reply(try wm.r.request(proto.GetProperty, .{ .window = xid, .property = a.get("_MOTIF_WM_HINTS"), .type = a.get("_MOTIF_WM_HINTS") }, &.{}));
    try testing.expectEqualSlices(u8, &ewmh.motifNoDecorations(), hints.value);

    const root = b.conn.screen().root;
    const clicks = [_][2]i16{ .{ 10, 5 }, .{ 115, 75 }, .{ 30, 40 } };
    for (clicks) |at| {
        _ = try b.conn.request(XTestFakeInput, .{ .type = 6, .detail = 0, .root = root, .root_x = at[0], .root_y = at[1] }, &.{});
        _ = try b.conn.request(XTestFakeInput, .{ .type = 4, .detail = 1 }, &.{});
        _ = try b.conn.request(XTestFakeInput, .{ .type = 5, .detail = 1 }, &.{});
    }
    try b.conn.sync();
    const move = try wm.message(p, a.get("_NET_WM_MOVERESIZE"));
    try testing.expectEqual([5]u32{ 10, 5, ewmh.move_direction, 1, ewmh.Source.user }, move);
    const resize = try wm.message(p, a.get("_NET_WM_MOVERESIZE"));
    try testing.expectEqual([5]u32{ 115, 75, 4, 1, ewmh.Source.user }, resize);

    // Only the press in the client area reaches the app.
    var buttons: usize = wm.buttons;
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 2 * std.time.ns_per_s;
    var evs: [64]Event = undefined;
    while (buttons < 2) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == .pointer_button) {
            try testing.expectEqual(@as(f32, 30), e.pointer_button.pos_px[0]);
            buttons += 1;
        };
        const now: u64 = @intCast(Io.Clock.awake.now(testing.io).nanoseconds);
        if (now >= deadline) return error.Timeout;
        p.waitEvents(@min(deadline, now + 5 * std.time.ns_per_ms));
    }
    try testing.expectEqual(2, buttons);
    try b.conn.sync();
    const n = p.pollEvents(&evs);
    for (evs[0..n]) |e| try testing.expect(e != .pointer_button);
}

/// XFIXES GetCursorImage: the cursor on screen.
const XFixesGetCursorImage = struct {
    /// The extension that owns this request.
    pub const extension = "XFIXES";
    /// The minor opcode.
    pub const minor = 4;

    /// The cursor's size, hotspot and first pixel.
    pub const Reply = struct {
        width: u16,
        height: u16,
        hot: [2]u16,
        first: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(bytes: []const u8, _: *@import("../wayland/wire/fdqueue.zig").FdQueue) proto.DecodeError!Reply {
            if (bytes.len < 36) return error.Malformed;
            return .{ .width = u16At(bytes, 12), .height = u16At(bytes, 14), .hot = .{ u16At(bytes, 16), u16At(bytes, 18) }, .first = u32At(bytes, 32) };
        }
    };
};

/// Writes an Xcursor file of square `size` px frames, one per color.
fn writeTestCursor(dir: Io.Dir, name: []const u8, size: u32, hot: [2]u32, colors: []const u32) !void {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const n: u32 = @intCast(colors.len);
    const px = size * size * 4;
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(testing.allocator);
    try words.appendSlice(testing.allocator, &.{ 0x72756358, 16, 0x10000, n });
    for (0..n) |i| try words.appendSlice(testing.allocator, &.{ 0xfffd0002, size, 16 + n * 12 + @as(u32, @intCast(i)) * (36 + px) });
    for (words.items) |v| {
        var bb: [4]u8 = undefined;
        std.mem.writeInt(u32, &bb, v, .little);
        try file.appendSlice(testing.allocator, &bb);
    }
    for (colors) |c| {
        for ([_]u32{ 36, 0xfffd0002, size, 1, size, size, hot[0], hot[1], 30 }) |v| {
            var bb: [4]u8 = undefined;
            std.mem.writeInt(u32, &bb, v, .little);
            try file.appendSlice(testing.allocator, &bb);
        }
        var bb: [4]u8 = undefined;
        std.mem.writeInt(u32, &bb, c, .little);
        for (0..size * size) |_| try file.appendSlice(testing.allocator, &bb);
    }
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "icons/test/cursors/{s}", .{name});
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = file.items });
}

test "Xvfb: theme, animated, hidden, glyph and resize cursors" {
    var x = XvfbForTest.start(11) catch return error.SkipZigTest;
    defer x.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "icons/test/cursors");
    try writeTestCursor(tmp.dir, "left_ptr", 24, .{ 1, 1 }, &.{ 0xff0000aa, 0xff0000bb });
    try writeTestCursor(tmp.dir, "xterm", 24, .{ 3, 4 }, &.{0xff102030});
    try writeTestCursor(tmp.dir, "nwse-resize", 24, .{ 12, 12 }, &.{0xff445566});
    var root_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &root_buf);
    const icons = try std.fmt.allocPrint(testing.allocator, "{s}/icons", .{root_buf[0..n]});
    defer testing.allocator.free(icons);
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("XCURSOR_PATH", icons);
    try env.put("XCURSOR_THEME", "test");
    try env.put("ZG_SCALE", "1");

    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display(), .environ_map = &env });
    defer b.deinit();
    if (b.conn.extension("XTEST") == null or b.conn.extension("RENDER") == null or b.sel.xfixes_event == null) return error.SkipZigTest;
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg cursors", .size = .{ .w = 64, .h = 48 }, .decorations = .client });
    _ = try waitFor(p, .window_configure, win);
    const Corner = struct {
        fn hit(_: *anyopaque, pt: types.PxPoint) types.HitRegion {
            return if (pt.x >= 54 and pt.y >= 38) .resize_bottom_right else .client;
        }
    };
    var dummy: u8 = 0;
    try p.submit(.{ .set_hit_test = .{ .win = win, .f = Corner.hit, .ctx = &dummy } });
    const root = b.conn.screen().root;
    const c = b.conn;
    const image = struct {
        fn get(conn: *Conn) !XFixesGetCursorImage.Reply {
            try conn.sync();
            return conn.reply(try conn.request(XFixesGetCursorImage, .{}, &.{}));
        }
    }.get;
    _ = try c.request(XTestFakeInput, .{ .type = 6, .detail = 0, .root = root, .root_x = 10, .root_y = 10 }, &.{});

    // The default arrow animates: both frames show up (an animated
    // cursor itself reads back as an empty 1x1 image between frames).
    var seen: [2]bool = .{ false, false };
    var tries: usize = 0;
    while (!(seen[0] and seen[1])) : (tries += 1) {
        if (tries > 500) return error.Timeout;
        const img = try image(c);
        if (img.width == 24) {
            try testing.expectEqual([2]u16{ 1, 1 }, img.hot);
            if (img.first == 0xff0000aa) seen[0] = true;
            if (img.first == 0xff0000bb) seen[1] = true;
        }
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }

    try p.submit(.{ .set_cursor = .{ .win = win, .shape = .text } });
    const text = try image(c);
    try testing.expectEqual([2]u16{ 3, 4 }, text.hot);
    try testing.expectEqual(0xff102030, text.first);

    try p.submit(.{ .set_cursor = .{ .win = win, .shape = .hidden } });
    const hidden = try image(c);
    try testing.expectEqual(1, hidden.width);
    try testing.expectEqual(0, hidden.first);

    // Not in the theme: a cursor-font glyph.
    try p.submit(.{ .set_cursor = .{ .win = win, .shape = .help } });
    const glyph = try image(c);
    try testing.expect(glyph.width > 1 and glyph.first != 0xff102030);

    // The app's resize region shows the resize cursor, and leaving it
    // restores the app's cursor.
    try p.submit(.{ .set_cursor = .{ .win = win, .shape = .text } });
    _ = try c.request(XTestFakeInput, .{ .type = 6, .detail = 0, .root = root, .root_x = 60, .root_y = 44 }, &.{});
    var spins: usize = 0;
    while ((try image(c)).first != 0xff445566) : (spins += 1) {
        if (spins > 500) return error.Timeout;
        var evs: [16]Event = undefined;
        _ = p.pollEvents(&evs);
        try testing.io.sleep(.fromMilliseconds(2), .awake);
    }
    _ = try c.request(XTestFakeInput, .{ .type = 6, .detail = 0, .root = root, .root_x = 20, .root_y = 20 }, &.{});
    spins = 0;
    while ((try image(c)).first != 0xff102030) : (spins += 1) {
        if (spins > 500) return error.Timeout;
        var evs: [16]Event = undefined;
        _ = p.pollEvents(&evs);
        try testing.io.sleep(.fromMilliseconds(2), .awake);
    }
}

/// RANDR SetMonitor (1.5): adds or replaces a monitor.
const RRSetMonitor = struct {
    /// The extension that owns this request.
    pub const extension = "RANDR";
    /// The minor opcode.
    pub const minor = 43;
    window: u32,
    name: u32,
    primary: bool = false,
    automatic: bool = false,
    noutput: u16 = 0,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    width_mm: u32 = 0,
    height_mm: u32 = 0,
};

test "Xvfb: RandR monitors and monitors_changed" {
    var x = XvfbForTest.start(12) catch return error.SkipZigTest;
    defer x.stop();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    if (b.randr_event == null) return error.SkipZigTest;
    const p = b.platform();
    var out: [4]types.MonitorInfo = undefined;
    try testing.expectEqual(1, p.monitors(&out));
    try testing.expectEqual(types.PxRect{ .x = 0, .y = 0, .w = 640, .h = 480 }, out[0].rect_px);
    try testing.expect(out[0].name().len > 0);

    // Another client splits off a virtual monitor.
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const r = try Conn.connect(testing.allocator, testing.io, &env, .{ .display = x.display() });
    defer r.deinit();
    const at = try r.internAtoms(&.{"ZG-VIRTUAL"});
    try r.checked(RRSetMonitor, .{ .window = r.screen().root, .name = at.get("ZG-VIRTUAL"), .x = 320, .y = 0, .width = 320, .height = 480 }, &.{});
    // Xvfb sends no notify for SetMonitor; send the ScreenChangeNotify a
    // real server would.
    const win = try p.createWindow(.{ .title = "zg randr", .size = .{ .w = 16, .h = 16 } });
    var note: [32]u8 = @splat(0);
    note[0] = b.randr_event.?;
    try r.checked(proto.SendEvent, .{ .destination = b.xidOf(win).?, .event_mask = 0, .event = note }, &.{});

    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 2 * std.time.ns_per_s;
    var evs: [16]Event = undefined;
    outer: while (true) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == .monitors_changed) break :outer;
        const now: u64 = @intCast(Io.Clock.awake.now(testing.io).nanoseconds);
        if (now >= deadline) return error.Timeout;
        p.waitEvents(@min(deadline, now + 5 * std.time.ns_per_ms));
    }
    const n = p.monitors(&out);
    try testing.expectEqual(2, n);
    var found = false;
    for (out[0..n]) |m| if (std.mem.eql(u8, m.name(), "ZG-VIRTUAL")) {
        found = true;
        try testing.expectEqual(types.PxRect{ .x = 320, .y = 0, .w = 320, .h = 480 }, m.rect_px);
        try testing.expectEqual(at.get("ZG-VIRTUAL"), m.id);
    };
    try testing.expect(found);
}

test "Xvfb: _NET_WM_SYNC_REQUEST counter is set after a present at the new size" {
    var x = XvfbForTest.start(13) catch return error.SkipZigTest;
    defer x.stop();
    const b = try X11Backend.init(testing.allocator, testing.io, .{ .display = x.display() });
    defer b.deinit();
    if (!b.sync_ok) return error.SkipZigTest;
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg sync", .size = .{ .w = 64, .h = 48 } });
    _ = try waitFor(p, .window_configure, win);
    const a = &b.atoms;
    const xid = b.xidOf(win).?;
    var wm = try FakeWm.start(x.display());
    defer wm.stop();
    const r = wm.r;
    const counter = (try r.reply(try r.request(proto.GetProperty, .{ .window = xid, .property = a.get("_NET_WM_SYNC_REQUEST_COUNTER"), .type = proto.Atom.cardinal }, &.{}))).value;
    try testing.expectEqual(4, counter.len);
    const cid = u32At(counter, 0);
    const protos = try r.reply(try r.request(proto.GetProperty, .{ .window = xid, .property = a.get("WM_PROTOCOLS"), .type = proto.Atom.atom }, &.{}));
    try testing.expect(ewmh.lists(protos.value, a.get("_NET_WM_SYNC_REQUEST")));

    // The WM asks for 0x1_00000007, then resizes the window.
    var ev: [32]u8 = @splat(0);
    ev[0] = proto.EventCode.client_message;
    ev[1] = 32;
    std.mem.writeInt(u32, ev[4..8], xid, .little);
    std.mem.writeInt(u32, ev[8..12], a.get("WM_PROTOCOLS"), .little);
    std.mem.writeInt(u32, ev[12..16], a.get("_NET_WM_SYNC_REQUEST"), .little);
    std.mem.writeInt(u32, ev[20..24], 7, .little);
    std.mem.writeInt(u32, ev[24..28], 1, .little);
    try r.checked(proto.SendEvent, .{ .destination = xid, .event_mask = 0, .event = ev }, &.{});
    try r.checked(proto.ConfigureWindow, .{ .window = xid, .mask = 0b1100, .values = &.{ 80, 60 } }, &.{});
    const cfg = (try waitFor(p, .window_configure, win)).window_configure;
    try testing.expectEqual(PxSize{ .w = 80, .h = 60 }, cfg.size);
    // Not yet drawn at the new size.
    try testing.expectEqual(0, (try r.reply(try r.request(xsync.QueryCounter, .{ .counter = cid }, &.{}))).value);

    const pr = try p.cpuPresenter(win);
    // A stale-size frame leaves it alone.
    const old = try pr.allocCpuBuffer(64, 48, present_mod.fourcc_argb8888);
    try pr.present(old.handle, &.{}, .none, null);
    try b.conn.sync();
    try testing.expectEqual(0, (try r.reply(try r.request(xsync.QueryCounter, .{ .counter = cid }, &.{}))).value);
    const buf = try pr.allocCpuBuffer(80, 60, present_mod.fourcc_argb8888);
    try pr.present(buf.handle, &.{}, .none, null);
    try b.conn.sync();
    try testing.expectEqual(0x1_0000_0007, (try r.reply(try r.request(xsync.QueryCounter, .{ .counter = cid }, &.{}))).value);
}
