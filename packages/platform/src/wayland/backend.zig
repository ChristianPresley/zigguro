//! The Wayland backend: our own wire client, xdg-shell toplevels, outputs
//! and fractional scaling, with a platform thread that owns reading and
//! dispatch.
//!
//! Threads: the platform thread reads the socket, dispatches events,
//! answers pings, acks stale configures and moves staged events into the
//! ring. Any thread may send (the connection locks), so `createWindow`,
//! `submit` and `present` send their requests and flush on the calling
//! thread. One mutex guards the windows, outputs and the staged events;
//! it is never held while pushing to the ring, which can block.
//!
//! Lock order: backend mutex, then the connection's.
//!
//! Input: the first wl_seat (v5+) gives keyboard, pointer and touch;
//! `seat.zig` turns their events into api events. The keymap is parsed on
//! the platform thread outside the mutex, compose rules load when the
//! thread starts, and key repeat runs on a timerfd in the thread's epoll.
//!
//! Selections (E01.F04.S03.T02): `wl_data_device` for the clipboard and
//! `zwp_primary_selection_device_v1` for the primary selection, with the
//! bookkeeping in `data_device.zig`. Every pipe transfer runs on the
//! platform thread's epoll (`linux/pipe_transfer.zig`); reads time out
//! after `InitOptions.transfer_timeout_ns` with empty data. While we own
//! a selection, reads are answered from our own copy.
//!
//! Cursors (E01.F04.S02.T04, `cursor.zig`): `wp_cursor_shape_device_v1`
//! when offered, else the Xcursor theme (`linux/xcursor.zig`) on a cursor
//! surface, loaded on the platform thread and cached per shape and size.
//! Either way the platform thread applies the focused window's shape
//! after each pointer enter or `set_cursor`.
//!
//! IME (E01.F04.S03.T01, `text_input.zig`): one `zwp_text_input_v3` on
//! the seat. `set_ime_state` is stored per window and sent while the text
//! input is on that window's surface (and again after each `enter`);
//! event batches become `ime_delete_surrounding`, `text_input` and
//! `ime_preedit` at `done`. Keys the IME did not consume still arrive as
//! `wl_keyboard.key` and pass through.
//!
//! Decorations (E01.F04.S01.T02, `csd.zig`): server-side through
//! `zxdg_decoration_manager_v1` when offered, else client-side, where
//! the surface carries invisible resize margins outside the window
//! geometry and presses on the title bar and borders become move, resize,
//! window-menu and maximize requests at each `wl_pointer.frame`.
//!
//! Activation comes with its own task; until then it returns
//! `error.Unsupported`.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const wl = @import("wl_gen");

const types = @import("../api/types.zig");
const event_api = @import("../api/event.zig");
const window_api = @import("../api/window.zig");
const surface = @import("../api/surface.zig");
const clipboard = @import("../api/clipboard.zig");
const native_api = @import("../api/native.zig");
const platform_api = @import("../api/platform.zig");
const PayloadArena = @import("../queue/payload_arena.zig").PayloadArena;
const portal = @import("../portal/desktop.zig");
const EventRing = @import("../queue/event_ring.zig").EventRing;
const Wake = @import("../queue/wake.zig").Wake;

const conn_mod = @import("wire/connection.zig");
const Connection = conn_mod.Connection;
const Registry = @import("wire/registry.zig").Registry;
const Global = @import("wire/registry.zig").Global;
const Handler = @import("wire/objects.zig").Handler;
const FdQueue = @import("wire/fdqueue.zig").FdQueue;
const Output = @import("output.zig").Output;
const win_mod = @import("window.zig");
const Window = win_mod.Window;
const scale = @import("scale.zig");
const ShmPresenter = @import("shm.zig").ShmPresenter;
const dmabuf = @import("dmabuf.zig");
const seat_mod = @import("seat.zig");
const data_device = @import("data_device.zig");
const dnd = @import("dnd.zig");
const cursor_mod = @import("cursor.zig");
const text_input = @import("text_input.zig");
const csd = @import("csd.zig");
const xcursor = @import("../linux/xcursor.zig");
const CursorShape = @import("../api/cursor.zig").CursorShape;
const pipe_transfer = @import("../linux/pipe_transfer.zig");
const memfd = @import("../linux/memfd.zig");
const Keymap = @import("../xkb/keymap.zig").Keymap;
const compose = @import("../xkb/compose.zig");

const Event = event_api.Event;
const Command = window_api.Command;
const WindowId = types.WindowId;
const PxSize = types.PxSize;
const Platform = platform_api.Platform;
const Error = platform_api.Error;

const log = std.log.scoped(.wayland);

/// Options for `WaylandBackend.init`.
pub const InitOptions = struct {
    /// The environment to find the compositor in (`WAYLAND_SOCKET`,
    /// `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`). `WAYLAND_SOCKET` is removed
    /// from it once used.
    environ_map: ?*std.process.Environ.Map = null,
    /// A connected socket to use instead (tests); the backend owns it.
    fd: ?i32 = null,
    /// How long a configure may wait for a present before it is acked
    /// with a bufferless commit.
    ack_timeout_ns: u64 = 100 * std.time.ns_per_ms,
    /// Event ring wake-ups are coalesced to this; refresh assumed when
    /// no output reports a mode.
    default_refresh_ns: u32 = 16_666_667,
    /// Ask wp_presentation for feedback on every present
    /// (`Event.present_feedback`).
    presentation_feedback: bool = true,
    /// A selection transfer that has not finished by then fails.
    transfer_timeout_ns: u64 = 5 * std.time.ns_per_s,
    /// The session bus for the portals (file dialogs, `open_uri`,
    /// appearance); null finds it in `environ_map`, and without either
    /// those commands return `error.Unsupported`.
    dbus_address: ?[]const u8 = null,
};

/// Ring capacity.
const ring_capacity = 4096;

/// Which interface a handler serves.
const Kind = enum { wm_base, xdg_surface, toplevel, surface, frac, frame, buffer, output, dmabuf, dmabuf_feedback, presentation, pres_feedback, seat, keyboard, pointer, touch, data_device, data_offer, data_source, primary_device, primary_offer, primary_source, text_input, decoration, activation_token };

/// Keymaps larger than this are refused.
const max_keymap_bytes = 16 * 1024 * 1024;

/// The environment variables compose loading reads.
const compose_env_keys = [_][]const u8{ "XCOMPOSEFILE", "HOME", "LC_ALL", "LC_CTYPE", "LANG" };

/// A wp_presentation_feedback waiting for its result.
const PresPending = struct { obj: u32, win: WindowId };

/// An xdg_activation_token_v1 waiting for its token, and the window to
/// activate with it.
const TokenPending = struct { obj: u32, win: WindowId };

/// A window and its presenter, allocated together so pointers stay put.
const Slot = struct {
    win: Window,
    presenter: ShmPresenter,
    /// The shape `set_cursor` asked for over this window.
    cursor: CursorShape = .default,
    /// The latest `set_ime_state`.
    ime: text_input.Want = .{},
    /// The app's hit test (client-side decorations).
    hit: ?Hit = null,
    /// A resize cursor shown over the CSD margins, over `cursor`.
    auto_cursor: ?CursorShape = null,
    /// The window's app id, for activation tokens (owned).
    app_id: ?[:0]u8 = null,

    const Hit = struct { f: window_api.HitTestFn, ctx: *anyopaque };
};

/// A theme cursor ready to attach: every frame of the nearest size.
const CachedCursor = struct {
    shape: CursorShape,
    size_px: u32,
    /// Empty when the theme has no such cursor.
    frames: []CursorFrame = &.{},
};

/// One frame of a theme cursor.
const CursorFrame = struct {
    buffer: wl.wl_buffer.Id,
    hot: [2]u32,
    delay_ms: u32,
};

/// The animated cursor being shown: its cache key and current frame.
const CursorAnim = struct {
    shape: CursorShape,
    size_px: u32,
    frame: usize = 0,
};

/// Shortest frame time for animated cursors; themes with 0 delays still
/// step at this rate.
const min_cursor_delay_ms: u32 = 10;

/// The Wayland backend.
pub const WaylandBackend = struct {
    gpa: Allocator,
    io: Io,
    opts: InitOptions,
    /// The connection.
    conn: *Connection,
    registry: *Registry,
    /// Required globals.
    compositor: wl.wl_compositor.Id,
    wm_base: wl.xdg_wm_base.Id,
    shm: wl.wl_shm.Id,
    /// Optional globals.
    viewporter: ?wl.wp_viewporter.Id = null,
    frac_manager: ?wl.wp_fractional_scale_manager_v1.Id = null,
    dmabuf: ?wl.zwp_linux_dmabuf_v1.Id = null,
    presentation: ?wl.wp_presentation.Id = null,
    /// dmabuf formats and device (default feedback, or v3 modifiers).
    /// Guarded by the mutex.
    feedback: dmabuf.Feedback = .{},
    /// The clock wp_presentation timestamps use.
    pres_clock: u32 = @intFromEnum(linux.CLOCK.MONOTONIC),
    /// Outstanding presentation feedback objects. Guarded by the mutex.
    pres_pending: std.ArrayList(PresPending) = .empty,
    /// The first wl_seat and the devices it offers.
    seat_id: ?wl.wl_seat.Id = null,
    keyboard: ?wl.wl_keyboard.Id = null,
    pointer: ?wl.wl_pointer.Id = null,
    touch: ?wl.wl_touch.Id = null,
    /// Keyboard, pointer and touch state. Guarded by the mutex.
    seat: seat_mod.Seat = .{},
    /// Compose rules; `seat.compose` points here once loaded.
    compose_table: ?compose.ComposeTable = null,
    /// The variables compose loading needs, copied at init and freed by
    /// the platform thread once it has loaded the rules.
    compose_env: ?std.process.Environ.Map = null,
    /// Key repeat timer (timerfd), or -1.
    repeat_fd: i32 = -1,
    /// Animated cursor timer (timerfd), or -1.
    cursor_timer_fd: i32 = -1,
    /// The animated cursor on screen, if any. Guarded by the mutex.
    cursor_anim: ?CursorAnim = null,

    mutex: Io.Mutex = .init,
    slots: std.ArrayList(*Slot) = .empty,
    outputs: std.ArrayList(*Output) = .empty,
    next_win: u32 = 1,
    /// Events produced under the mutex, moved to `ring` by the platform
    /// thread.
    staged: std.ArrayList(Event) = .empty,
    /// Our own selections: what our sources send, and what reads return
    /// while we own them (or when there is no data device).
    clip: [2][]ClipItemOwned = .{ &.{}, &.{} },
    /// Selection globals and devices (on `seat_id`).
    data_manager: ?wl.wl_data_device_manager.Id = null,
    data_dev: ?wl.wl_data_device.Id = null,
    primary_manager: ?wl.zwp_primary_selection_device_manager_v1.Id = null,
    primary_dev: ?wl.zwp_primary_selection_device_v1.Id = null,
    /// Offers from the compositor. Guarded by the mutex.
    offers: data_device.Offers = .{},
    /// Our current source object per selection, while we own it.
    sources: [2]?u32 = .{ null, null },
    /// Pipe transfers in flight. Guarded by the mutex.
    transfers: pipe_transfer.Transfers = undefined,
    finished: std.ArrayList(pipe_transfer.Finished) = .empty,
    /// Drag and drop: a drag over our windows, a dropped offer being
    /// read, and a drag we started with its items. Guarded by the mutex.
    dnd_target: ?dnd.Target = null,
    dnd_dropped: ?dnd.Dropped = null,
    dnd_source: ?dnd.Source = null,
    drag_items: []ClipItemOwned = &.{},
    /// Payloads over the arena's limit, by id. Guarded by the mutex.
    large: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    next_large: u32 = 0,
    /// Cursors: the protocol path, or the theme fallback.
    cursor_manager: ?wl.wp_cursor_shape_manager_v1.Id = null,
    cursor_device: ?wl.wp_cursor_shape_device_v1.Id = null,
    cursor_theme: ?cursor_mod.Theme = null,
    cursor_surface: ?wl.wl_surface.Id = null,
    cursor_cache: std.ArrayList(CachedCursor) = .empty,
    /// The platform thread re-applies the cursor. Guarded by the mutex.
    cursor_dirty: bool = false,
    /// IME: the manager, the seat's text input and its state. Guarded by
    /// the mutex.
    ti_manager: ?wl.zwp_text_input_manager_v3.Id = null,
    /// Decorations: the manager, title-bar double-click tracking, and
    /// the button whose release is swallowed after a press started a
    /// move, resize or menu. Guarded by the mutex.
    deco_manager: ?wl.zxdg_decoration_manager_v1.Id = null,
    /// xdg-activation (E01.F01.S03.T01), and tokens being requested.
    activation: ?wl.xdg_activation_v1.Id = null,
    tokens: std.ArrayList(TokenPending) = .empty,
    csd_clicks: csd.Clicks = .{},
    csd_swallow: ?u32 = null,
    text_input: ?wl.zwp_text_input_v3.Id = null,
    ime: text_input.State = .{},

    ring: EventRing(ring_capacity),
    arena: PayloadArena,
    /// Wakes the UI thread in `waitEvents`.
    ui_wake: Wake,
    /// Wakes the platform thread (staged events, shutdown).
    thread_wake: Wake,
    wake_pending: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    /// Set when the connection failed; the platform thread has stopped
    /// dispatching.
    dead: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    epfd: i32 = -1,
    hooks: native_api.NativeHooks,
    /// Pongs sent, for tests.
    pongs: std.atomic.Value(u32) = .init(0),
    /// File dialogs, `open_uri` and appearance through the portals.
    desktop: portal.Desktop = undefined,

    /// Connects, binds the globals, waits for the outputs and starts the
    /// platform thread.
    pub fn init(gpa: Allocator, io: Io, opts: InitOptions) !*WaylandBackend {
        const conn = if (opts.fd) |fd|
            try Connection.fromFd(gpa, io, fd)
        else if (opts.environ_map) |env|
            try Connection.connect(gpa, io, env)
        else
            return error.NoRuntimeDir;
        errdefer conn.deinit();
        const registry = try Registry.init(conn);
        errdefer registry.deinit();
        var arena = try PayloadArena.init(gpa);
        errdefer arena.deinit(gpa);
        var ui_wake = try Wake.init(io);
        errdefer ui_wake.deinit();
        var thread_wake = try Wake.init(io);
        errdefer thread_wake.deinit();

        const b = try gpa.create(WaylandBackend);
        errdefer gpa.destroy(b);
        b.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .conn = conn,
            .registry = registry,
            .compositor = undefined,
            .wm_base = undefined,
            .shm = undefined,
            .ring = .{ .io = io },
            .arena = arena,
            .ui_wake = ui_wake,
            .thread_wake = thread_wake,
            .hooks = .{
                .ptr = b,
                .win32SetMessageHook = noHook,
                .win32CreateMessageWindow = noMsgWindow,
                .win32DestroyMessageWindow = noDestroy,
                .windowHandle = windowHandle,
            },
        };
        errdefer b.freeLists();

        b.compositor = (try registry.bind(wl.wl_compositor, 4, 6, null)) orelse return error.MissingGlobal;
        b.wm_base = (try registry.bind(wl.xdg_wm_base, 2, 7, b.handler(.wm_base))) orelse return error.MissingGlobal;
        b.shm = (try registry.bind(wl.wl_shm, 1, 2, null)) orelse return error.MissingGlobal;
        b.viewporter = try registry.bind(wl.wp_viewporter, 1, 1, null);
        b.frac_manager = try registry.bind(wl.wp_fractional_scale_manager_v1, 1, 1, null);
        b.dmabuf = try registry.bind(wl.zwp_linux_dmabuf_v1, 3, 5, b.handler(.dmabuf));
        if (b.dmabuf) |dm| if (conn.version(@intFromEnum(dm)) >= 4) {
            // The default feedback describes the formats before any surface
            // exists; it arrives with the roundtrip below.
            const fb = try conn.newIdVersion(wl.zwp_linux_dmabuf_feedback_v1, conn.version(@intFromEnum(dm)), b.handler(.dmabuf_feedback));
            try wl.zwp_linux_dmabuf_v1.getDefaultFeedback(conn, dm, fb);
        };
        b.presentation = try registry.bind(wl.wp_presentation, 1, 2, b.handler(.presentation));
        // Capabilities arrive with the roundtrip below.
        b.seat_id = try registry.bind(wl.wl_seat, 5, 9, b.handler(.seat));
        b.data_manager = try registry.bind(wl.wl_data_device_manager, 1, 3, null);
        b.primary_manager = try registry.bind(wl.zwp_primary_selection_device_manager_v1, 1, 1, null);
        b.cursor_manager = try registry.bind(wl.wp_cursor_shape_manager_v1, 1, 2, null);
        if (b.cursor_manager == null) b.cursor_theme = try cursor_mod.Theme.fromEnv(gpa, opts.environ_map);
        b.ti_manager = try registry.bind(wl.zwp_text_input_manager_v3, 1, 1, null);
        b.deco_manager = try registry.bind(wl.zxdg_decoration_manager_v1, 1, 1, null);
        b.activation = try registry.bind(wl.xdg_activation_v1, 1, 1, null);
        if (b.seat_id) |sid| {
            if (b.ti_manager) |m| {
                const ti = try conn.newIdVersion(wl.zwp_text_input_v3, 1, b.handler(.text_input));
                try wl.zwp_text_input_manager_v3.getTextInput(conn, m, ti, sid);
                b.text_input = ti;
            }
            if (b.data_manager) |m| {
                const d = try conn.newIdVersion(wl.wl_data_device, conn.version(@intFromEnum(m)), b.handler(.data_device));
                try wl.wl_data_device_manager.getDataDevice(conn, m, d, sid);
                b.data_dev = d;
            }
            if (b.primary_manager) |m| {
                const d = try conn.newIdVersion(wl.zwp_primary_selection_device_v1, 1, b.handler(.primary_device));
                try wl.zwp_primary_selection_device_manager_v1.getDevice(conn, m, d, sid);
                b.primary_dev = d;
            }
        }
        if (opts.environ_map) |env| {
            var copy: std.process.Environ.Map = .init(gpa);
            for (compose_env_keys) |k| if (env.get(k)) |v| try copy.put(k, v);
            b.compose_env = copy;
        }
        for (registry.globals.items) |g| if (std.mem.eql(u8, g.interface, wl.wl_output.name)) try b.addOutput(g);
        registry.onGlobalAdd(.{ .ctx = b, .on_add = onGlobalAdd });
        registry.onGlobalRemove(.{ .ctx = b, .on_remove = onGlobalRemove });
        // Outputs describe themselves in reply to the bind.
        try conn.roundtrip();

        const ep = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(ep) != .SUCCESS) return error.SystemResources;
        b.epfd = @intCast(ep);
        errdefer _ = linux.close(b.epfd);
        b.transfers = .{ .gpa = gpa, .epfd = b.epfd };
        errdefer b.transfers.deinit();
        try b.watch(conn.pollFd(), 0);
        try b.watch(b.thread_wake.handle().fd, 1);
        const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (linux.errno(tfd) == .SUCCESS) {
            b.repeat_fd = @intCast(tfd);
            try b.watch(b.repeat_fd, 2);
        } else log.warn("timerfd_create failed; no key repeat", .{});
        const cfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (linux.errno(cfd) == .SUCCESS) {
            b.cursor_timer_fd = @intCast(cfd);
            try b.watch(b.cursor_timer_fd, 3);
        } else log.warn("timerfd_create failed; cursors do not animate", .{});
        // The platform thread takes portal answers, so the portal must be
        // ready before it starts.
        var abuf: [256]u8 = undefined;
        const address = opts.dbus_address orelse if (opts.environ_map) |env| portal.sessionAddress(&abuf, env) else null;
        b.desktop.init(gpa, io, .{ .ctx = b, .func = wakeForPortal }, .{ .address = address });
        errdefer b.desktop.deinit();
        b.thread = try std.Thread.spawn(.{}, threadMain, .{b});
        return b;
    }

    fn wakeForPortal(ctx: *anyopaque) void {
        const b: *WaylandBackend = @ptrCast(@alignCast(ctx));
        b.thread_wake.signal();
    }

    /// Turns portal answers into events. Mutex held.
    fn takePortalLocked(b: *WaylandBackend) void {
        while (b.desktop.take()) |a| switch (a) {
            .dialog => |r| {
                const paths: types.PayloadSlice = if (r.paths.len > 0) b.putOwned(r.paths) else .empty;
                b.stage(.{ .dialog_result = .{ .request = r.request, .paths = paths, .cancelled = r.cancelled } }) catch {};
            },
            .appearance => |app| b.stage(.{ .appearance_changed = app }) catch {},
        };
    }

    fn watch(b: *WaylandBackend, fd: i32, tag: u64) !void {
        var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = tag } };
        if (linux.errno(linux.epoll_ctl(b.epfd, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) return error.SystemResources;
    }

    /// The type-erased interface.
    pub fn platform(b: *WaylandBackend) Platform {
        return Platform.fromImpl(WaylandBackend, b);
    }

    // ---- Platform.VTable ----

    /// See `Platform.VTable.createWindow`. The window maps with its first
    /// present; its first `window_configure` follows the initial commit.
    pub fn createWindow(b: *WaylandBackend, opts: window_api.WindowOptions) Error!WindowId {
        b.lock();
        defer b.unlock();
        return b.createLocked(opts) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SystemResources,
        };
    }

    fn createLocked(b: *WaylandBackend, opts: window_api.WindowOptions) !WindowId {
        const c = b.conn;
        const id: WindowId = @enumFromInt(b.next_win);
        const slot = try b.gpa.create(Slot);
        errdefer b.gpa.destroy(slot);
        try b.slots.ensureUnusedCapacity(b.gpa, 1);

        const surf = try c.newIdVersion(wl.wl_surface, c.version(@intFromEnum(b.compositor)), b.handler(.surface));
        try wl.wl_compositor.createSurface(c, b.compositor, surf);
        const wm_ver = c.version(@intFromEnum(b.wm_base));
        const xs = try c.newIdVersion(wl.xdg_surface, wm_ver, b.handler(.xdg_surface));
        try wl.xdg_wm_base.getXdgSurface(c, b.wm_base, xs, surf);
        const tl = try c.newIdVersion(wl.xdg_toplevel, wm_ver, b.handler(.toplevel));
        try wl.xdg_surface.getToplevel(c, xs, tl);

        slot.* = .{
            .win = .{ .id = id, .surface = surf, .xdg_surface = xs, .toplevel = tl, .default_logical = nonZero(opts.size), .logical = nonZero(opts.size) },
            .presenter = .init(b, id),
        };
        slot.presenter.bind();
        const w = &slot.win;

        try b.sendTitle(tl, opts.title);
        slot.app_id = try b.gpa.dupeZ(u8, opts.app_id);
        try wl.xdg_toplevel.setAppId(c, tl, slot.app_id.?);
        if (opts.min_size) |m| {
            w.min_logical = m;
            try wl.xdg_toplevel.setMinSize(c, tl, @intCast(m.w), @intCast(m.h));
        }
        if (opts.parent) |p| if (b.find(p)) |ps| try wl.xdg_toplevel.setParent(c, tl, ps.win.toplevel);
        // Server-side decorations unless the app draws its own; without
        // the manager the window is client-decorated.
        w.csd = true;
        if (b.deco_manager) |dm| {
            const d = try c.newIdVersion(wl.zxdg_toplevel_decoration_v1, 1, b.handler(.decoration));
            try wl.zxdg_decoration_manager_v1.getToplevelDecoration(c, dm, d, tl);
            try wl.zxdg_toplevel_decoration_v1.setMode(c, d, if (opts.decorations == .client) .client_side else .server_side);
            w.decoration = d;
            w.csd = opts.decorations == .client;
        }
        if (b.viewporter) |vp| {
            const v = try c.newIdVersion(wl.wp_viewport, c.version(@intFromEnum(vp)), null);
            try wl.wp_viewporter.getViewport(c, vp, v, surf);
            w.viewport = v;
        }
        if (b.frac_manager) |fm| {
            const f = try c.newIdVersion(wl.wp_fractional_scale_v1, c.version(@intFromEnum(fm)), b.handler(.frac));
            try wl.wp_fractional_scale_manager_v1.getFractionalScale(c, fm, f, surf);
            w.frac = f;
        }
        // The initial commit without a buffer asks for the first configure.
        try wl.wl_surface.commit(c, surf);
        try c.flush();
        b.slots.appendAssumeCapacity(slot);
        b.next_win += 1;
        return id;
    }

    fn sendTitle(b: *WaylandBackend, tl: wl.xdg_toplevel.Id, title: []const u8) !void {
        const z = try b.gpa.dupeZ(u8, win_mod.truncateTitle(title));
        defer b.gpa.free(z);
        try wl.xdg_toplevel.setTitle(b.conn, tl, z);
    }

    /// See `Platform.VTable.destroyWindow`. The window's presenter is
    /// invalid afterwards.
    pub fn destroyWindow(b: *WaylandBackend, win: WindowId) void {
        b.lock();
        defer b.unlock();
        for (b.slots.items, 0..) |s, i| if (s.win.id == win) {
            _ = b.slots.swapRemove(i);
            b.destroySlot(s);
            b.conn.flush() catch {};
            return;
        };
    }

    fn destroySlot(b: *WaylandBackend, s: *Slot) void {
        const c = b.conn;
        const w = &s.win;
        if (b.seat.kb_focus == w.id) b.armRepeat(.disarm);
        b.seat.forget(w.id);
        if (b.ime.focus == w.id) b.ime.focus = null;
        s.ime.deinit(b.gpa);
        if (s.app_id) |a| b.gpa.free(a);
        s.app_id = null;
        if (w.frame_cb) |cb| c.setHandler(@intFromEnum(cb), null);
        var i: usize = 0;
        while (i < b.pres_pending.items.len) {
            const pp = b.pres_pending.items[i];
            if (pp.win != w.id) {
                i += 1;
                continue;
            }
            c.setHandler(pp.obj, null);
            _ = b.pres_pending.swapRemove(i);
        }
        if (w.frac) |f| wl.wp_fractional_scale_v1.destroy(c, f) catch {};
        // Before the toplevel, or the decoration is orphaned.
        if (w.decoration) |d| wl.zxdg_toplevel_decoration_v1.destroy(c, d) catch {};
        if (w.viewport) |v| wl.wp_viewport.destroy(c, v) catch {};
        wl.xdg_toplevel.destroy(c, w.toplevel) catch {};
        wl.xdg_surface.destroy(c, w.xdg_surface) catch {};
        s.presenter.deinit();
        wl.wl_surface.destroy(c, w.surface) catch {};
        b.gpa.destroy(s);
    }

    /// See `Platform.VTable.submit`. Runs the command on the calling
    /// thread (the connection is thread-safe), so its result is known.
    pub fn submit(b: *WaylandBackend, cmd: Command) Error!void {
        b.lock();
        defer b.unlock();
        b.run(cmd) catch |err| return switch (err) {
            error.InvalidWindow, error.Unsupported, error.OutOfMemory => |e| e,
            else => error.SystemResources,
        };
        b.conn.flush() catch return error.SystemResources;
    }

    /// See `Platform.VTable.surfaceTarget`: E02 presents through the
    /// window's presenter.
    pub fn surfaceTarget(b: *WaylandBackend, win: WindowId) Error!surface.SurfaceTarget {
        b.lock();
        defer b.unlock();
        const s = b.find(win) orelse return error.InvalidWindow;
        return .{ .external = &s.presenter.presenter };
    }

    /// See `Platform.VTable.cpuPresenter`.
    pub fn cpuPresenter(b: *WaylandBackend, win: WindowId) Error!*surface.Presenter {
        b.lock();
        defer b.unlock();
        const s = b.find(win) orelse return error.InvalidWindow;
        return &s.presenter.presenter;
    }

    /// See `Platform.VTable.native`.
    pub fn native(b: *WaylandBackend) *const native_api.NativeHooks {
        return &b.hooks;
    }

    /// See `Platform.VTable.payload`.
    pub fn payload(b: *WaylandBackend, s: types.PayloadSlice) []const u8 {
        if (!s.large) return b.arena.get(s);
        b.lock();
        defer b.unlock();
        return b.large.get(s.off) orelse &.{};
    }

    /// See `Platform.VTable.release`.
    pub fn release(b: *WaylandBackend, s: types.PayloadSlice) void {
        if (!s.large) return;
        b.lock();
        defer b.unlock();
        if (b.large.fetchRemove(s.off)) |kv| b.gpa.free(kv.value);
    }

    /// `bytes` as a payload: inline in the arena, else a large payload
    /// that takes ownership of `bytes`. Mutex held. `bytes` is freed on
    /// the inline path and on error.
    fn putOwned(b: *WaylandBackend, bytes: []u8) types.PayloadSlice {
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

    /// See `Platform.VTable.monitors`. The first output is reported as
    /// primary: Wayland has no such notion.
    pub fn monitors(b: *WaylandBackend, out: []types.MonitorInfo) usize {
        b.lock();
        defer b.unlock();
        var n: usize = 0;
        for (b.outputs.items) |o| {
            if (!o.ready) continue;
            if (n < out.len) {
                out[n] = o.info;
                out[n].primary = n == 0;
            }
            n += 1;
        }
        return n;
    }

    /// See `Platform.VTable.pollEvents`.
    pub fn pollEvents(b: *WaylandBackend, out: []Event) usize {
        if (out.len == 0) return 0;
        _ = b.arena.flip();
        var n: usize = 0;
        if (b.wake_pending.swap(false, .acquire)) {
            out[0] = .wake;
            n = 1;
        }
        const got = b.ring.popMany(out[n..]);
        for (out[n..][0..got]) |*e| b.arena.retire(e);
        return n + got;
    }

    /// See `Platform.VTable.waitEvents`.
    pub fn waitEvents(b: *WaylandBackend, deadline_ns: ?u64) void {
        while (b.ring.count() == 0 and !b.wake_pending.load(.acquire)) {
            var timeout: ?u64 = null;
            if (deadline_ns) |d| {
                const t = b.nowNs();
                if (t >= d) return;
                timeout = d - t;
            }
            if (b.ui_wake.wait(timeout)) b.ui_wake.consume() else return;
        }
    }

    /// See `Platform.VTable.wake`.
    pub fn wake(b: *WaylandBackend) void {
        b.wake_pending.store(true, .release);
        b.ui_wake.signal();
    }

    /// See `Platform.VTable.deinit`.
    pub fn deinit(b: *WaylandBackend) void {
        b.stopping.store(true, .release);
        b.thread_wake.signal();
        if (b.thread) |t| t.join();
        // After the join: the platform thread takes portal answers.
        b.desktop.deinit();
        b.lock();
        for (b.slots.items) |s| b.destroySlot(s);
        b.slots.clearRetainingCapacity();
        b.conn.flush() catch {};
        b.unlock();
        b.transfers.deinit();
        if (b.epfd >= 0) _ = linux.close(b.epfd);
        if (b.repeat_fd >= 0) _ = linux.close(b.repeat_fd);
        if (b.cursor_timer_fd >= 0) _ = linux.close(b.cursor_timer_fd);
        b.freeState();
        b.gpa.destroy(b);
    }

    fn freeState(b: *WaylandBackend) void {
        b.freeLists();
        b.registry.deinit();
        b.conn.deinit();
        b.arena.deinit(b.gpa);
        b.ui_wake.deinit();
        b.thread_wake.deinit();
    }

    fn freeLists(b: *WaylandBackend) void {
        const gpa = b.gpa;
        b.slots.deinit(gpa);
        for (b.outputs.items) |o| gpa.destroy(o);
        b.outputs.deinit(gpa);
        b.staged.deinit(gpa);
        b.feedback.deinit(gpa);
        b.pres_pending.deinit(gpa);
        for (&b.clip) |items| freeClip(gpa, items);
        freeClip(gpa, b.drag_items);
        b.drag_items = &.{};
        b.seat.deinit(gpa);
        b.seat.compose = null;
        if (b.compose_table) |*t| t.deinit(gpa);
        b.compose_table = null;
        if (b.compose_env) |*e| e.deinit();
        b.compose_env = null;
        b.offers.deinit(gpa);
        b.tokens.deinit(gpa);
        b.ime.deinit(gpa);
        b.finished.deinit(gpa);
        for (b.cursor_cache.items) |e| gpa.free(e.frames);
        b.cursor_cache.deinit(gpa);
        if (b.cursor_theme) |*t| t.deinit(gpa);
        b.cursor_theme = null;
        var it = b.large.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        b.large.deinit(gpa);
    }

    // ---- presentation (from shm.zig, mutex held) ----

    /// Acks the pending configure if `serial` names it, applies the scale,
    /// attaches `buffer`, damages and commits, then flushes, so the ack and
    /// the buffer reach the compositor together.
    pub fn presentLocked(b: *WaylandBackend, win: WindowId, buffer: wl.wl_buffer.Id, damage: []const types.PxRect, serial: ?u32) !void {
        const s = b.find(win) orelse return error.InvalidWindow;
        const w = &s.win;
        const c = b.conn;
        // Without a serial (E02's software path passes none) the present
        // answers the newest configure: the renderer resized on it.
        if (w.takeAck(serial)) |ack| try wl.xdg_surface.ackConfigure(c, w.xdg_surface, ack);
        try b.applyScale(w);
        try wl.wl_surface.attach(c, w.surface, buffer, 0, 0);
        w.presented = true;
        if (damage.len == 0) {
            try wl.wl_surface.damageBuffer(c, w.surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        } else for (damage) |d| {
            try wl.wl_surface.damageBuffer(c, w.surface, d.x, d.y, @intCast(d.w), @intCast(d.h));
        }
        try b.requestFrameLocked(w);
        if (b.presentation) |pres| if (b.opts.presentation_feedback) {
            try b.pres_pending.ensureUnusedCapacity(b.gpa, 1);
            const fb = try c.newIdVersion(wl.wp_presentation_feedback, 1, b.handler(.pres_feedback));
            try wl.wp_presentation.feedback(c, pres, w.surface, fb);
            b.pres_pending.appendAssumeCapacity(.{ .obj = @intFromEnum(fb), .win = w.id });
        };
        try wl.wl_surface.commit(c, w.surface);
        try c.flush();
    }

    fn applyScale(b: *WaylandBackend, w: *Window) !void {
        const c = b.conn;
        if (w.viewport) |v| {
            if (w.applied_buffer_scale != 1) {
                try wl.wl_surface.setBufferScale(c, w.surface, 1);
                w.applied_buffer_scale = 1;
            }
            const dest = w.surfaceLogical();
            if (w.applied_destination == null or !std.meta.eql(w.applied_destination.?, dest)) {
                try wl.wp_viewport.setDestination(c, v, @intCast(dest.w), @intCast(dest.h));
                w.applied_destination = dest;
            }
        } else {
            const bs = scale.integerScale(w.scale120);
            if (bs != w.applied_buffer_scale and c.version(@intFromEnum(w.surface)) >= 3) {
                try wl.wl_surface.setBufferScale(c, w.surface, bs);
                w.applied_buffer_scale = bs;
            }
        }
    }

    /// Stages `Event.frame` for `w`. Mutex held.
    fn stageFrame(b: *WaylandBackend, w: *Window) !void {
        const refresh = b.refreshFor(w);
        try b.stage(.{ .frame = .{ .win = w.id, .target_ns = b.nowNs() + refresh, .refresh_ns = refresh } });
    }

    fn requestFrameLocked(b: *WaylandBackend, w: *Window) !void {
        if (w.frame_cb != null) return;
        const cb = try b.conn.newIdVersion(wl.wl_callback, 1, b.handler(.frame));
        try wl.wl_surface.frame(b.conn, w.surface, cb);
        w.frame_cb = cb;
    }

    // ---- commands (mutex held) ----

    fn run(b: *WaylandBackend, cmd: Command) !void {
        const c = b.conn;
        switch (cmd) {
            .set_title => |t| try b.sendTitle((try b.lookup(t.win)).toplevel, t.title),
            // Cursor shapes and the IME arrive with E01.F04.S02 and the
            // text-input task; the window must exist.
            .set_cursor => |t| {
                const s = b.find(t.win) orelse return error.InvalidWindow;
                if (s.cursor == t.shape) return;
                s.cursor = t.shape;
                if (b.seat.ptr_focus == t.win) {
                    b.cursor_dirty = true;
                    b.thread_wake.signal();
                }
            },
            .set_ime_state => |t| {
                const s = b.find(t.win) orelse return error.InvalidWindow;
                try s.ime.set(b.gpa, t.enabled, t.purpose, t.caret_rect_px, t.surrounding);
                if (b.ime.focus == t.win) try b.sendIme(s);
            },
            .set_hit_test => |t| {
                const s = b.find(t.win) orelse return error.InvalidWindow;
                s.hit = .{ .f = t.f, .ctx = t.ctx };
            },
            .begin_move => |win| {
                const w = try b.lookup(win);
                try wl.xdg_toplevel.move(c, w.toplevel, b.seat_id orelse return error.Unsupported, b.seat.last_button_serial);
            },
            .begin_resize => |t| {
                const w = try b.lookup(t.win);
                try wl.xdg_toplevel.resize(c, w.toplevel, b.seat_id orelse return error.Unsupported, b.seat.last_button_serial, csd.wlEdge(t.edge));
            },
            .show_window_menu => |t| {
                const w = try b.lookup(t.win);
                const s120 = w.effectiveScale120();
                const x: i32 = @intCast(@divFloor(@as(i64, t.at.x) * scale.unit, s120));
                const y: i32 = @intCast(@divFloor(@as(i64, t.at.y) * scale.unit, s120));
                try wl.xdg_toplevel.showWindowMenu(c, w.toplevel, b.seat_id orelse return error.Unsupported, b.seat.last_button_serial, x, y);
            },
            .set_min_size => |t| {
                const w = try b.lookup(t.win);
                const m = scale.logicalSize(t.size, w.effectiveScale120());
                w.min_logical = m;
                try wl.xdg_toplevel.setMinSize(c, w.toplevel, @intCast(m.w), @intCast(m.h));
                try wl.wl_surface.commit(c, w.surface);
            },
            .request_state => |t| {
                const w = try b.lookup(t.win);
                switch (t.op) {
                    .show => {},
                    .maximize => try wl.xdg_toplevel.setMaximized(c, w.toplevel),
                    .unmaximize => try wl.xdg_toplevel.unsetMaximized(c, w.toplevel),
                    .minimize => try wl.xdg_toplevel.setMinimized(c, w.toplevel),
                    .fullscreen => try wl.xdg_toplevel.setFullscreen(c, w.toplevel, null),
                    .unfullscreen => try wl.xdg_toplevel.unsetFullscreen(c, w.toplevel),
                }
            },
            .request_frame => |win| {
                const w = try b.lookup(win);
                // An unmapped surface gets no frame callbacks: answer at
                // once (or at the first configure) so frame 0 can map it.
                if (!w.presented) {
                    if (w.configured) try b.stageFrame(w) else w.frame_requested = true;
                    return;
                }
                try b.requestFrameLocked(w);
                try wl.wl_surface.commit(c, w.surface);
            },
            .clipboard_write => |t| {
                const items = try b.gpa.alloc(ClipItemOwned, t.items.len);
                var done: usize = 0;
                errdefer {
                    for (items[0..done]) |it| b.gpa.free(it.data);
                    b.gpa.free(items);
                }
                for (t.items, 0..) |it, i| {
                    items[i] = .{ .mime = it.mime, .data = try b.gpa.dupe(u8, it.data) };
                    done = i + 1;
                }
                freeClip(b.gpa, b.clip[@intFromEnum(t.which)]);
                b.clip[@intFromEnum(t.which)] = items;
                try b.offerSelection(t.which);
            },
            .clipboard_read => |t| try b.readSelection(t.which, t.mime, t.request),
            .start_drag => |t| try b.startDrag(t.win, t.items, t.allowed),
            .set_drop_effect => |t| try b.setDropEffect(t.win, t.accept, t.effect),
            .activate => |t| {
                const w = try b.lookup(t.win);
                const act = b.activation orelse return error.Unsupported;
                if (t.token) |tok| {
                    const z = try b.gpa.dupeZ(u8, tok);
                    defer b.gpa.free(z);
                    try wl.xdg_activation_v1.activate(c, act, z, w.surface);
                } else if (!w.state.activated) try b.requestToken(t.win, true);
            },
            .request_attention => |win| {
                _ = try b.lookup(win);
                if (b.activation == null) return error.Unsupported;
                // A token without an input serial: compositors mark the
                // window urgent instead of focusing it.
                try b.requestToken(win, false);
            },
            // No xdg-foreign export yet, so dialogs are not parented.
            .open_dialog => |d| try b.desktop.openDialog(d, ""),
            .open_uri => |uri| try b.desktop.openUri(uri, ""),
        }
    }

    /// Asks for an activation token for `win` (with the newest input
    /// serial when `with_serial`); `done` activates it. Mutex held.
    fn requestToken(b: *WaylandBackend, win: WindowId, with_serial: bool) !void {
        const c = b.conn;
        const slot = b.find(win) orelse return error.InvalidWindow;
        try b.tokens.ensureUnusedCapacity(b.gpa, 1);
        const tok = try c.newIdVersion(wl.xdg_activation_token_v1, 1, b.handler(.activation_token));
        try wl.xdg_activation_v1.getActivationToken(c, b.activation.?, tok);
        if (with_serial and b.seat.last_serial != 0) if (b.seat_id) |sid| try wl.xdg_activation_token_v1.setSerial(c, tok, b.seat.last_serial, sid);
        // The focused surface vouches for the request.
        if (b.seat.kb_focus) |f| if (b.find(f)) |fs| try wl.xdg_activation_token_v1.setSurface(c, tok, fs.win.surface);
        try wl.xdg_activation_token_v1.setAppId(c, tok, slot.app_id orelse "");
        try wl.xdg_activation_token_v1.commit(c, tok);
        b.tokens.appendAssumeCapacity(.{ .obj = @intFromEnum(tok), .win = win });
    }

    fn lookup(b: *WaylandBackend, id: WindowId) error{InvalidWindow}!*Window {
        return if (b.find(id)) |s| &s.win else error.InvalidWindow;
    }

    fn find(b: *WaylandBackend, id: WindowId) ?*Slot {
        for (b.slots.items) |s| if (s.win.id == id) return s;
        return null;
    }

    /// Queues `ev` for the ring and wakes the platform thread to move it.
    fn stage(b: *WaylandBackend, ev: Event) !void {
        try b.staged.append(b.gpa, ev);
        b.thread_wake.signal();
    }

    // ---- the platform thread ----

    fn threadMain(b: *WaylandBackend) void {
        pipe_transfer.blockSigpipe();
        b.loadCompose();
        var moving: std.ArrayList(Event) = .empty;
        defer moving.deinit(b.gpa);
        var evs: [16]linux.epoll_event = undefined;
        while (!b.stopping.load(.acquire)) {
            if (!b.dead.load(.acquire)) {
                b.pump() catch |err| b.fail(err);
                b.updateCursor() catch |err| log.warn("setting the cursor: {t}", .{err});
            }
            // Move staged events out under the lock, push them without it.
            b.lock();
            b.finishTransfersLocked(null);
            b.takePortalLocked();
            std.mem.swap(std.ArrayList(Event), &moving, &b.staged);
            const timeout = b.nextTimeoutLocked();
            b.unlock();
            if (moving.items.len > 0) {
                for (moving.items) |e| b.ring.pushCoalescing(e);
                moving.clearRetainingCapacity();
                b.ui_wake.signal();
            }
            const rc = linux.epoll_wait(b.epfd, &evs, evs.len, timeout);
            if (linux.errno(rc) != .SUCCESS) continue;
            for (evs[0..rc]) |e| switch (e.data.u64) {
                1 => b.thread_wake.consume(),
                2 => b.onRepeatTimer(),
                3 => b.onCursorTimer(),
                else => |tag| if (pipe_transfer.Transfers.owns(tag)) b.serviceTransfers(tag),
            };
        }
    }

    /// Drives transfer `tag` (if any), fails overdue ones, and answers
    /// finished reads with `clipboard_data`. The locked variant runs
    /// every loop iteration, so deadlines are checked after each wait.
    fn serviceTransfers(b: *WaylandBackend, tag: u64) void {
        b.lock();
        defer b.unlock();
        b.finishTransfersLocked(tag);
    }

    fn finishTransfersLocked(b: *WaylandBackend, tag: ?u64) void {
        if (tag) |t| b.transfers.onReady(t, &b.finished) catch |err| log.warn("selection transfer: {t}", .{err});
        b.transfers.expire(b.nowNs(), &b.finished) catch {};
        for (b.finished.items) |f| {
            if (f.dir != .read) continue;
            if (f.purpose == .drop) {
                b.finishDrop(f);
                continue;
            }
            const data: types.PayloadSlice = if (f.ok) b.putOwned(f.data) else .empty;
            b.stage(.{ .clipboard_data = .{ .request = f.request, .data = data, .mime = f.mime } }) catch {};
        }
        b.finished.clearRetainingCapacity();
    }

    /// Reads and dispatches everything available, acks configures whose
    /// present is overdue, and flushes (pongs go out here).
    fn pump(b: *WaylandBackend) !void {
        while (true) {
            const dispatched = try b.conn.dispatchPending();
            const read = try b.conn.readSocket();
            if (read == 0 and dispatched == 0) break;
        }
        b.lock();
        defer b.unlock();
        const t = b.nowNs();
        for (b.slots.items) |s| {
            const w = &s.win;
            if (w.pending_ack == null or t < w.ack_deadline_ns) continue;
            const ack = w.takeAck(null).?;
            try wl.xdg_surface.ackConfigure(b.conn, w.xdg_surface, ack);
            try b.applyScale(w);
            try wl.wl_surface.commit(b.conn, w.surface);
        }
        try b.conn.flush();
    }

    /// Milliseconds until the earliest overdue ack or transfer, or -1.
    /// Mutex held.
    fn nextTimeoutLocked(b: *WaylandBackend) i32 {
        var next: ?u64 = b.transfers.nextDeadline();
        for (b.slots.items) |s| if (s.win.pending_ack != null) {
            next = if (next) |n| @min(n, s.win.ack_deadline_ns) else s.win.ack_deadline_ns;
        };
        const d = next orelse return -1;
        const t = b.nowNs();
        if (d <= t) return 0;
        return @intCast(@min((d - t + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(i32)));
    }

    fn fail(b: *WaylandBackend, err: anyerror) void {
        b.dead.store(true, .release);
        if (b.conn.last_error) |e| {
            log.err("compositor error on {s}@{d}: {d}: {s}", .{ e.interface, e.object, e.code, e.message });
        } else log.err("wayland connection failed: {t}", .{err});
        _ = linux.epoll_ctl(b.epfd, linux.EPOLL.CTL_DEL, b.conn.pollFd(), null);
        // The windows are gone with the connection; let the app close them.
        b.lock();
        defer b.unlock();
        for (b.slots.items) |s| b.staged.append(b.gpa, .{ .window_close_requested = s.win.id }) catch {};
    }

    // ---- event handlers (platform thread) ----

    /// The handler for objects of kind `k`.
    pub fn handler(b: *WaylandBackend, comptime k: Kind) Handler {
        return .{ .ctx = b, .on_event = struct {
            fn f(ctx: *anyopaque, c: *Connection, obj: u32, opcode: u16, body: []const u32, fds: *FdQueue) anyerror!void {
                const self: *WaylandBackend = @ptrCast(@alignCast(ctx));
                return self.onEvent(k, c, obj, opcode, body, fds);
            }
        }.f };
    }

    fn onEvent(b: *WaylandBackend, comptime k: Kind, c: *Connection, obj: u32, opcode: u16, body: []const u32, fds: *FdQueue) !void {
        switch (k) {
            .wm_base => switch (try wl.xdg_wm_base.decodeEvent(opcode, body, fds)) {
                // Answered here, without the mutex, so a stalled UI thread
                // never makes the app "not responding".
                .ping => |p| {
                    // Counted before sending, so whoever sees the pong also
                    // sees the count.
                    _ = b.pongs.fetchAdd(1, .monotonic);
                    try wl.xdg_wm_base.pong(c, b.wm_base, p.serial);
                    try c.flush();
                },
            },
            .xdg_surface => {
                const ev = try wl.xdg_surface.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const w = b.byObject("xdg_surface", obj) orelse return;
                switch (ev) {
                    .configure => |cf| {
                        try b.stageConfigure(w, w.onConfigure(cf.serial, b.nowNs(), b.opts.ack_timeout_ns));
                        if (w.frame_requested and !w.presented) {
                            w.frame_requested = false;
                            try b.stageFrame(w);
                        }
                    },
                }
            },
            .toplevel => {
                const ev = try wl.xdg_toplevel.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const w = b.byObject("toplevel", obj) orelse return;
                switch (ev) {
                    .configure => |cf| w.onToplevelConfigure(cf.width, cf.height, cf.states),
                    .close => try b.stage(.{ .window_close_requested = w.id }),
                    .configure_bounds => {},
                    .wm_capabilities => |cap| w.wm_caps = win_mod.capsFrom(cap.capabilities),
                }
            },
            .surface => {
                const ev = try wl.wl_surface.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const w = b.byObject("surface", obj) orelse return;
                switch (ev) {
                    .enter => |e| w.enter(e.output),
                    .leave => |e| w.leave(e.output),
                    .preferred_buffer_scale => |p| w.preferred_buffer = p.factor,
                    .preferred_buffer_transform => return,
                }
                try b.rescaleLocked(w);
            },
            .frac => {
                const ev = try wl.wp_fractional_scale_v1.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const w = b.byObject("frac", obj) orelse return;
                switch (ev) {
                    .preferred_scale => |p| w.frac_scale = p.scale,
                }
                try b.rescaleLocked(w);
            },
            .frame => {
                _ = try wl.wl_callback.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const w = b.byObject("frame_cb", obj) orelse return;
                w.frame_cb = null;
                try b.stageFrame(w);
            },
            .buffer => {
                _ = try wl.wl_buffer.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                for (b.slots.items) |s| if (s.presenter.byObject(obj)) |buf| {
                    try s.presenter.onRelease(buf);
                    try c.flush();
                    return;
                };
            },
            .dmabuf => {
                const ev = try wl.zwp_linux_dmabuf_v1.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                switch (ev) {
                    .format => {},
                    .modifier => |m| try b.feedback.onModifier(b.gpa, m.format, m.modifier_hi, m.modifier_lo),
                }
            },
            .dmabuf_feedback => {
                const ev = try wl.zwp_linux_dmabuf_feedback_v1.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const f = &b.feedback;
                switch (ev) {
                    .format_table => |t| try f.onFormatTable(b.gpa, t.fd, t.size),
                    .main_device => |d| f.onMainDevice(d.device),
                    .tranche_target_device => |d| f.onTrancheDevice(d.device),
                    .tranche_formats => |t| try f.onTrancheFormats(b.gpa, t.indices),
                    .tranche_flags => {},
                    .tranche_done => f.onTrancheDone(),
                    .done => if (f.onDone() and f.rounds > 1) {
                        // E02 reads `formats`/`drmDevice` when it builds a
                        // ring; a later change applies to the next one.
                        log.info("dmabuf feedback changed: {d} formats", .{f.formats.items.len});
                    },
                }
            },
            .presentation => switch (try wl.wp_presentation.decodeEvent(opcode, body, fds)) {
                .clock_id => |cl| {
                    b.lock();
                    defer b.unlock();
                    b.pres_clock = cl.clk_id;
                },
            },
            .pres_feedback => {
                const ev = try wl.wp_presentation_feedback.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const idx = for (b.pres_pending.items, 0..) |pp, i| {
                    if (pp.obj == obj) break i;
                } else return;
                const win = b.pres_pending.items[idx].win;
                switch (ev) {
                    .sync_output => return,
                    .presented => |pr| {
                        _ = b.pres_pending.swapRemove(idx);
                        const ours = b.nowNs();
                        const theirs = if (b.pres_clock == @intFromEnum(linux.CLOCK.MONOTONIC)) ours else dmabuf.clockNow(b.pres_clock);
                        try b.stage(.{ .present_feedback = .{
                            .win = win,
                            .presented_ns = dmabuf.presentedNs(pr.tv_sec_hi, pr.tv_sec_lo, pr.tv_nsec, b.pres_clock, ours, theirs),
                            .seq = @as(u64, pr.seq_hi) << 32 | pr.seq_lo,
                            .flags = @truncate(@as(u32, @bitCast(pr.flags))),
                        } });
                    },
                    .discarded => {
                        _ = b.pres_pending.swapRemove(idx);
                        try b.stage(.{ .present_feedback = .{ .win = win, .presented_ns = 0, .seq = 0, .flags = event_api.PresentFlags.discarded } });
                    },
                }
            },
            .output => {
                const ev = try wl.wl_output.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                for (b.outputs.items) |o| if (@intFromEnum(o.id) == obj) {
                    if (!o.apply(ev)) return;
                    try b.stage(.monitors_changed);
                    for (b.slots.items) |s| for (s.win.enteredOutputs()) |e| if (e == o.id) {
                        try b.rescaleLocked(&s.win);
                        break;
                    };
                    return;
                };
            },
            .seat => switch (try wl.wl_seat.decodeEvent(opcode, body, fds)) {
                .capabilities => |cap| {
                    b.lock();
                    defer b.unlock();
                    try b.onCapabilities(cap.capabilities);
                    try c.flush();
                },
                .name => {},
            },
            .keyboard => {
                const ev = try wl.wl_keyboard.decodeEvent(opcode, body, fds);
                if (ev == .keymap) return b.onKeymap(ev.keymap.format, ev.keymap.fd, ev.keymap.size);
                b.lock();
                defer b.unlock();
                const out: Sink = .{ .b = b };
                const st = &b.seat;
                switch (ev) {
                    .keymap => unreachable,
                    .enter => |e| {
                        const w = b.byObject("surface", @intFromEnum(e.surface)) orelse return;
                        var held: [32]u32 = undefined;
                        const n = @min(e.keys.len / 4, held.len);
                        for (held[0..n], 0..) |*h, i| h.* = std.mem.readInt(u32, e.keys[i * 4 ..][0..4], native_endian);
                        try st.kbEnter(out, w.id, e.serial, held[0..n]);
                    },
                    .leave => b.armRepeat(try st.kbLeave(out, b.nowNs())),
                    .key => |ky| b.armRepeat(try st.key(out, ky.serial, ky.key, ky.state == .pressed, b.nowNs())),
                    .modifiers => |m| st.modifiers(m.serial, m.mods_depressed, m.mods_latched, m.mods_locked, m.group),
                    .repeat_info => |r| b.armRepeat(st.repeatInfo(r.rate, r.delay)),
                }
            },
            .pointer => {
                const ev = try wl.wl_pointer.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const out: Sink = .{ .b = b };
                const st = &b.seat;
                switch (ev) {
                    .enter => |e| {
                        const w = b.byObject("surface", @intFromEnum(e.surface)) orelse return;
                        try st.ptrEnter(out, w.id, e.serial, toPx(w, e.surface_x, e.surface_y));
                        // A new enter serial: the cursor must be set again.
                        b.cursor_dirty = true;
                    },
                    .leave => {
                        b.stopCursorAnimLocked();
                        try st.ptrLeave(out);
                    },
                    .motion => |m| if (b.focusWindow(st.ptr_focus)) |w| st.ptrMotion(toPx(w, m.surface_x, m.surface_y)),
                    .button => |bt| st.ptrButton(bt.serial, bt.button, bt.state == .pressed),
                    .axis => |a| st.ptrAxis(axisOf(a.axis), a.value.toF64()),
                    .frame => {
                        try b.routeCsd();
                        const s120 = if (b.focusWindow(st.ptr_focus)) |w| w.effectiveScale120() else scale.unit;
                        try st.ptrFrame(out, b.nowNs(), s120);
                    },
                    .axis_source => |a| st.ptrAxisSource(@enumFromInt(@intFromEnum(a.axis_source))),
                    .axis_stop => |a| st.ptrAxisStop(axisOf(a.axis)),
                    .axis_discrete => |a| st.ptrAxisDiscrete(axisOf(a.axis), a.discrete),
                    .axis_value120 => |a| st.ptrAxis120(axisOf(a.axis), a.value120),
                    .axis_relative_direction => {},
                }
            },
            .touch => {
                const ev = try wl.wl_touch.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const out: Sink = .{ .b = b };
                const st = &b.seat;
                switch (ev) {
                    .down => |d| {
                        const w = b.byObject("surface", @intFromEnum(d.surface)) orelse return;
                        st.touchDown(d.serial, w.id, d.id, toPx(w, d.x, d.y), w.effectiveScale120());
                    },
                    .up => |u| st.touchUp(u.serial, u.id),
                    .motion => |m| st.touchMotion(m.id, .{ m.x.toF64(), m.y.toF64() }),
                    .frame => try st.touchFrame(out),
                    .cancel => try st.touchCancel(out),
                    .shape, .orientation => {},
                }
            },
            .data_device => {
                const ev = try wl.wl_data_device.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                switch (ev) {
                    .data_offer => |o| {
                        c.setHandler(@intFromEnum(o.id), b.handler(.data_offer));
                        try b.offers.add(b.gpa, @intFromEnum(o.id), .clipboard);
                    },
                    .selection => |sel| try b.onSelection(.clipboard, if (sel.id) |i| @intFromEnum(i) else null),
                    .enter => |e| try b.onDndEnter(e.serial, @intFromEnum(e.surface), e.x, e.y, if (e.id) |i| @intFromEnum(i) else null),
                    .motion => |m| try b.onDndMotion(m.x, m.y),
                    .leave => try b.onDndLeave(),
                    .drop => try b.onDndDrop(),
                }
            },
            .primary_device => {
                const ev = try wl.zwp_primary_selection_device_v1.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                switch (ev) {
                    .data_offer => |o| {
                        c.setHandler(@intFromEnum(o.offer), b.handler(.primary_offer));
                        try b.offers.add(b.gpa, @intFromEnum(o.offer), .primary);
                    },
                    .selection => |sel| try b.onSelection(.primary, if (sel.id) |i| @intFromEnum(i) else null),
                }
            },
            .data_offer => {
                const ev = try wl.wl_data_offer.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                switch (ev) {
                    .offer => |o| try b.offers.addMime(b.gpa, obj, o.mime_type),
                    .source_actions => |a| if (b.offers.get(obj)) |o| {
                        o.source_actions = dnd.fromWl(a.source_actions);
                    },
                    .action => |a| if (b.offers.get(obj)) |o| {
                        o.action = dnd.fromWl(a.dnd_action);
                    },
                }
            },
            .primary_offer => switch (try wl.zwp_primary_selection_offer_v1.decodeEvent(opcode, body, fds)) {
                .offer => |o| {
                    b.lock();
                    defer b.unlock();
                    try b.offers.addMime(b.gpa, obj, o.mime_type);
                },
            },
            .data_source => {
                const ev = try wl.wl_data_source.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                if (b.dnd_source) |ds| if (ds.source == obj) return b.onDragSourceEvent(ev);
                switch (ev) {
                    .send => |sd| b.sendSelection(.clipboard, sd.mime_type, sd.fd),
                    .cancelled => b.dropSource(.clipboard, obj),
                    .target, .dnd_drop_performed, .dnd_finished, .action => {},
                }
            },
            .activation_token => {
                const ev = try wl.xdg_activation_token_v1.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const tok: wl.xdg_activation_token_v1.Id = @enumFromInt(obj);
                for (b.tokens.items, 0..) |p, i| if (p.obj == obj) {
                    _ = b.tokens.swapRemove(i);
                    switch (ev) {
                        .done => |d| if (b.find(p.win)) |s| try wl.xdg_activation_v1.activate(c, b.activation.?, d.token, s.win.surface),
                    }
                    break;
                };
                try wl.xdg_activation_token_v1.destroy(c, tok);
                try c.flush();
            },
            .decoration => {
                const ev = try wl.zxdg_toplevel_decoration_v1.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const w = b.byObject("decoration", obj) orelse return;
                // Applies with the xdg_surface.configure that follows.
                switch (ev) {
                    .configure => |cf| w.csd = cf.mode != .server_side,
                }
            },
            .text_input => {
                const ev = try wl.zwp_text_input_v3.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                const out: Sink = .{ .b = b };
                switch (ev) {
                    .enter => |e| {
                        const w = b.byObject("surface", @intFromEnum(e.surface)) orelse return;
                        b.ime.onEnter(b.gpa, w.id);
                        try b.sendIme(b.find(w.id).?);
                        try c.flush();
                    },
                    .leave => try b.ime.onLeave(b.gpa, out),
                    .preedit_string => |pe| try b.ime.onPreedit(b.gpa, pe.text, pe.cursor_begin, pe.cursor_end),
                    .commit_string => |cs| try b.ime.onCommit(b.gpa, cs.text),
                    .delete_surrounding_text => |d| b.ime.onDelete(d.before_length, d.after_length),
                    .done => |d| if (try b.ime.onDone(b.gpa, out, d.serial)) {
                        // The IME answered an older state: send ours again.
                        if (b.focusWindow(b.ime.focus)) |w| {
                            try b.sendIme(b.find(w.id).?);
                            try c.flush();
                        }
                    },
                }
            },
            .primary_source => {
                const ev = try wl.zwp_primary_selection_source_v1.decodeEvent(opcode, body, fds);
                b.lock();
                defer b.unlock();
                switch (ev) {
                    .send => |sd| b.sendSelection(.primary, sd.mime_type, sd.fd),
                    .cancelled => b.dropSource(.primary, obj),
                }
            },
        }
    }

    /// Sends `s`'s IME state (its window has the text input). Mutex held.
    fn sendIme(b: *WaylandBackend, s: *Slot) !void {
        const ti = b.text_input orelse return;
        try b.ime.send(b.gpa, b.conn, ti, &s.ime, s.win.effectiveScale120());
    }

    // ---- cursors (E01.F04.S02.T04, platform thread) ----

    /// Applies the focused window's cursor if something changed. Theme
    /// files are read without the mutex.
    fn updateCursor(b: *WaylandBackend) !void {
        b.lock();
        if (!b.cursor_dirty) return b.unlock();
        b.cursor_dirty = false;
        const req = b.cursorRequestLocked() orelse return b.unlock();
        if (req.shape == .hidden or b.cursor_device != null or b.cursorCached(req.shape, req.size_px) != null) {
            defer b.unlock();
            return b.applyCursorLocked(req);
        }
        b.unlock();
        // Load outside the lock; the next `updateCursor` uses the cache.
        var frames = b.cursor_theme.?.load(b.gpa, b.io, req.shape, req.size_px);
        defer if (frames) |*f| f.deinit(b.gpa);
        b.lock();
        defer b.unlock();
        if (b.cursorCached(req.shape, req.size_px) == null) {
            var list: std.ArrayList(CursorFrame) = .empty;
            errdefer list.deinit(b.gpa);
            if (frames) |f| {
                try list.ensureTotalCapacity(b.gpa, f.frames.len);
                for (f.frames) |img| list.appendAssumeCapacity(.{
                    .buffer = try b.cursorBuffer(img),
                    .hot = .{ img.hot_x, img.hot_y },
                    .delay_ms = img.delay_ms,
                });
            } else log.info("no {t} cursor in theme {s}", .{ req.shape, b.cursor_theme.?.name });
            const owned = try list.toOwnedSlice(b.gpa);
            errdefer b.gpa.free(owned);
            try b.cursor_cache.append(b.gpa, .{ .shape = req.shape, .size_px = req.size_px, .frames = owned });
        }
        // Focus or shape may have moved on meanwhile.
        const now = b.cursorRequestLocked() orelse return;
        try b.applyCursorLocked(now);
    }

    const CursorRequest = struct { shape: CursorShape, serial: u32, scale: i32, size_px: u32 };

    fn cursorRequestLocked(b: *WaylandBackend) ?CursorRequest {
        if (b.pointer == null) return null;
        const s = b.find(b.seat.ptr_focus orelse return null) orelse return null;
        const k = scale.integerScale(s.win.effectiveScale120());
        const base = if (b.cursor_theme) |t| t.size else 24;
        return .{ .shape = s.auto_cursor orelse s.cursor, .serial = b.seat.last_enter_serial, .scale = k, .size_px = base * @as(u32, @intCast(k)) };
    }

    fn cursorCached(b: *WaylandBackend, shape: CursorShape, size_px: u32) ?*CachedCursor {
        for (b.cursor_cache.items) |*e| if (e.shape == shape and e.size_px == size_px) return e;
        return null;
    }

    fn applyCursorLocked(b: *WaylandBackend, req: CursorRequest) !void {
        const c = b.conn;
        const ptr = b.pointer orelse return;
        defer c.flush() catch {};
        b.stopCursorAnimLocked();
        if (req.shape == .hidden) return wl.wl_pointer.setCursor(c, ptr, req.serial, null, 0, 0);
        if (b.cursor_device) |d| return wl.wp_cursor_shape_device_v1.setShape(c, d, req.serial, cursor_mod.protocolShape(req.shape).?);
        // A shape the theme lacks falls back to the default arrow.
        var e = b.cursorCached(req.shape, req.size_px) orelse return;
        if (e.frames.len == 0) {
            if (req.shape == .default) return;
            e = b.cursorCached(.default, req.size_px) orelse {
                b.cursor_dirty = true;
                if (b.find(b.seat.ptr_focus.?)) |s| s.cursor = .default;
                return;
            };
            if (e.frames.len == 0) return;
        }
        try b.showCursorFrameLocked(e.frames[0], req);
        if (e.frames.len > 1) {
            b.cursor_anim = .{ .shape = e.shape, .size_px = e.size_px };
            b.armCursorTimer(e.frames[0].delay_ms);
        }
    }

    /// Attaches `f` to the cursor surface and points the cursor at it.
    fn showCursorFrameLocked(b: *WaylandBackend, f: CursorFrame, req: CursorRequest) !void {
        const c = b.conn;
        const ptr = b.pointer orelse return;
        const surf = b.cursor_surface orelse blk: {
            const sf = try c.newIdVersion(wl.wl_surface, c.version(@intFromEnum(b.compositor)), null);
            try wl.wl_compositor.createSurface(c, b.compositor, sf);
            b.cursor_surface = sf;
            break :blk sf;
        };
        try wl.wl_surface.attach(c, surf, f.buffer, 0, 0);
        if (c.version(@intFromEnum(surf)) >= 3) try wl.wl_surface.setBufferScale(c, surf, req.scale);
        try wl.wl_surface.damageBuffer(c, surf, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        try wl.wl_surface.commit(c, surf);
        // Frames may move the hotspot, so the cursor is set every frame.
        const k: u32 = @intCast(req.scale);
        try wl.wl_pointer.setCursor(c, ptr, req.serial, surf, @intCast(f.hot[0] / k), @intCast(f.hot[1] / k));
    }

    /// Stops cursor animation. Mutex held.
    fn stopCursorAnimLocked(b: *WaylandBackend) void {
        if (b.cursor_anim == null) return;
        b.cursor_anim = null;
        b.armCursorTimer(0);
    }

    /// Fires the cursor timer once after `delay_ms` (at least
    /// `min_cursor_delay_ms`), or disarms it for 0.
    fn armCursorTimer(b: *WaylandBackend, delay_ms: u32) void {
        if (b.cursor_timer_fd < 0) return;
        const zero: linux.timespec = .{ .sec = 0, .nsec = 0 };
        const value = if (b.cursor_anim == null) zero else msSpec(@max(delay_ms, min_cursor_delay_ms));
        const spec: linux.itimerspec = .{ .it_interval = zero, .it_value = value };
        _ = linux.timerfd_settime(b.cursor_timer_fd, .{}, &spec, null);
    }

    /// Shows the next frame of the animated cursor while the pointer is
    /// still on a window showing it.
    fn onCursorTimer(b: *WaylandBackend) void {
        var n: u64 = 0;
        const rc = linux.read(b.cursor_timer_fd, std.mem.asBytes(&n), @sizeOf(u64));
        if (linux.errno(rc) != .SUCCESS or n == 0) return;
        b.lock();
        defer b.unlock();
        if (b.cursor_anim == null) return;
        const anim = &b.cursor_anim.?;
        const req = b.cursorRequestLocked() orelse return b.stopCursorAnimLocked();
        const e = b.cursorCached(anim.shape, anim.size_px) orelse return b.stopCursorAnimLocked();
        if (req.size_px != anim.size_px or e.frames.len < 2) return b.stopCursorAnimLocked();
        anim.frame = (anim.frame + 1) % e.frames.len;
        const f = e.frames[anim.frame];
        b.showCursorFrameLocked(f, req) catch |err| log.warn("animating the cursor: {t}", .{err});
        b.conn.flush() catch {};
        b.armCursorTimer(f.delay_ms);
    }

    /// An shm buffer holding `img` (premultiplied ARGB). Mutex held.
    fn cursorBuffer(b: *WaylandBackend, img: xcursor.CursorImage) !wl.wl_buffer.Id {
        const bytes = std.mem.sliceAsBytes(img.pixels);
        // The compositor keeps its own mapping of the sealed memfd.
        var m = try memfd.Memfd.fromBytes("zg-cursor", bytes);
        defer m.deinit();
        const c = b.conn;
        const pool = try c.newIdVersion(wl.wl_shm_pool, c.version(@intFromEnum(b.shm)), null);
        try wl.wl_shm.createPool(c, b.shm, pool, m.fd, @intCast(m.mem.len));
        const buffer = try c.newIdVersion(wl.wl_buffer, c.version(@intFromEnum(pool)), null);
        try wl.wl_shm_pool.createBuffer(c, pool, buffer, 0, @intCast(img.width), @intCast(img.height), @intCast(img.width * 4), .argb8888);
        try wl.wl_shm_pool.destroy(c, pool);
        return buffer;
    }

    // ---- selections (E01.F04.S03.T02, mutex held) ----

    /// Makes our `clip[which]` the selection: a new source offering its
    /// formats, set with the latest input serial.
    fn offerSelection(b: *WaylandBackend, which: clipboard.Selection) !void {
        const c = b.conn;
        const items = b.clip[@intFromEnum(which)];
        const serial = b.seat.last_serial;
        const old = b.sources[@intFromEnum(which)];
        b.sources[@intFromEnum(which)] = null;
        switch (which) {
            .clipboard => {
                const dev = b.data_dev orelse return;
                var src: ?wl.wl_data_source.Id = null;
                if (items.len > 0) {
                    const m = b.data_manager.?;
                    const s = try c.newIdVersion(wl.wl_data_source, c.version(@intFromEnum(m)), b.handler(.data_source));
                    try wl.wl_data_device_manager.createDataSource(c, m, s);
                    for (items) |it| for (data_device.mimesFor(it.mime)) |mt| try wl.wl_data_source.offer(c, s, mt);
                    src = s;
                }
                try wl.wl_data_device.setSelection(c, dev, src, serial);
                if (old) |o| try wl.wl_data_source.destroy(c, @enumFromInt(o));
                if (src) |s| b.sources[0] = @intFromEnum(s);
            },
            .primary => {
                const dev = b.primary_dev orelse return;
                var src: ?wl.zwp_primary_selection_source_v1.Id = null;
                if (items.len > 0) {
                    const m = b.primary_manager.?;
                    const s = try c.newIdVersion(wl.zwp_primary_selection_source_v1, 1, b.handler(.primary_source));
                    try wl.zwp_primary_selection_device_manager_v1.createSource(c, m, s);
                    for (items) |it| for (data_device.mimesFor(it.mime)) |mt| try wl.zwp_primary_selection_source_v1.offer(c, s, mt);
                    src = s;
                }
                try wl.zwp_primary_selection_device_v1.setSelection(c, dev, src, serial);
                if (old) |o| try wl.zwp_primary_selection_source_v1.destroy(c, @enumFromInt(o));
                if (src) |s| b.sources[1] = @intFromEnum(s);
            },
        }
    }

    /// Answers `clipboard_read`: from our copy while we own the selection
    /// (or without a device), else through a pipe from the current offer.
    fn readSelection(b: *WaylandBackend, which: clipboard.Selection, mime: clipboard.MimeId, request: u32) !void {
        const has_device = switch (which) {
            .clipboard => b.data_dev != null,
            .primary => b.primary_dev != null,
        };
        if (b.sources[@intFromEnum(which)] != null or !has_device) {
            var data: types.PayloadSlice = .empty;
            for (b.clip[@intFromEnum(which)]) |it| if (it.mime == mime) {
                data = b.putOwned(try b.gpa.dupe(u8, it.data));
                break;
            };
            return b.stage(.{ .clipboard_data = .{ .request = request, .data = data, .mime = mime } });
        }
        const empty: Event = .{ .clipboard_data = .{ .request = request, .data = .empty, .mime = mime } };
        const offer = b.offers.currentOf(which) orelse return b.stage(empty);
        const mt = data_device.pickMime(mime, offer.mimes.items) orelse return b.stage(empty);
        const fds = try pipe_transfer.pipe();
        // `send` duplicates the fd, so our write end closes at once and
        // the read sees EOF when the source closes its copy.
        defer _ = linux.close(fds[1]);
        b.receive(which, offer.id, mt, fds[1]) catch |err| {
            _ = linux.close(fds[0]);
            return err;
        };
        try b.transfers.startRead(fds[0], request, mime, b.nowNs() + b.opts.transfer_timeout_ns);
        // The platform thread recomputes its timeout.
        b.thread_wake.signal();
    }

    fn receive(b: *WaylandBackend, which: clipboard.Selection, offer: u32, mime: [:0]const u8, fd: i32) !void {
        switch (which) {
            .clipboard => try wl.wl_data_offer.receive(b.conn, @enumFromInt(offer), mime, fd),
            .primary => try wl.zwp_primary_selection_offer_v1.receive(b.conn, @enumFromInt(offer), mime, fd),
        }
    }

    /// `selection(offer)` from either device.
    fn onSelection(b: *WaylandBackend, which: clipboard.Selection, id: ?u32) !void {
        if (b.offers.setSelection(which, id)) |old| b.dropOffer(old);
        // Ours comes back as an offer too; only others' changes count.
        if (b.sources[@intFromEnum(which)] == null) try b.stage(.{ .clipboard_changed = which });
    }

    fn dropOffer(b: *WaylandBackend, id: u32) void {
        const which = if (b.offers.get(id)) |o| o.which else .clipboard;
        switch (which) {
            .clipboard => wl.wl_data_offer.destroy(b.conn, @enumFromInt(id)) catch {},
            .primary => wl.zwp_primary_selection_offer_v1.destroy(b.conn, @enumFromInt(id)) catch {},
        }
        b.offers.remove(b.gpa, id);
    }

    /// A source's `send(mime, fd)`: write our bytes on the platform thread.
    fn sendSelection(b: *WaylandBackend, which: clipboard.Selection, mime: []const u8, fd: i32) void {
        const want = data_device.idForMime(mime);
        for (b.clip[@intFromEnum(which)]) |it| if (want != null and it.mime == want.?) {
            b.transfers.startWrite(fd, it.data, b.nowNs() + b.opts.transfer_timeout_ns) catch |err| log.warn("selection send: {t}", .{err});
            return;
        };
        _ = linux.close(fd);
    }

    // ---- drag and drop (E01.F04.S03.T03, mutex held) ----

    fn dataDeviceVersion(b: *WaylandBackend) u32 {
        return if (b.data_dev) |d| b.conn.version(@intFromEnum(d)) else 0;
    }

    /// `wl_data_device.enter`: a drag (with `offer`, unless it carries no
    /// data) entered one of our surfaces.
    fn onDndEnter(b: *WaylandBackend, serial: u32, surf: u32, x: wl.Fixed, y: wl.Fixed, offer: ?u32) !void {
        b.endDndTarget();
        const w = b.byObject("surface", surf) orelse {
            if (offer) |o| b.dropOffer(o);
            return;
        };
        const pos = toPx(w, x, y);
        b.dnd_target = .{ .offer = offer, .win = w.id, .serial = serial, .pos = pos };
        var buf: [32]u8 = undefined;
        var mimes: []const u8 = &.{};
        var allowed: clipboard.DragActions = .{};
        if (offer) |id| if (b.offers.get(id)) |o| {
            mimes = dnd.offeredIds(o.mimes.items, b.dnd_source != null, &buf);
            // Before v3 the source's actions are unknown: copy.
            allowed = if (b.dataDeviceVersion() >= 3) o.source_actions else .{ .copy = true };
        };
        try b.stage(.{ .drop = .{ .win = w.id, .phase = .enter, .allowed = allowed, .pos_px = pos, .mimes = b.arena.put(mimes) catch .empty } });
    }

    fn onDndMotion(b: *WaylandBackend, x: wl.Fixed, y: wl.Fixed) !void {
        const t = &(b.dnd_target orelse return);
        const s = b.find(t.win) orelse return;
        t.pos = toPx(&s.win, x, y);
        try b.stage(.{ .drop = .{ .win = t.win, .phase = .over, .allowed = b.targetActions(t.*), .pos_px = t.pos } });
    }

    fn onDndLeave(b: *WaylandBackend) !void {
        const t = b.dnd_target orelse return;
        b.endDndTarget();
        try b.stage(.{ .drop = .{ .win = t.win, .phase = .leave, .allowed = .{}, .pos_px = t.pos } });
    }

    /// Forgets the drag target, destroying its offer.
    fn endDndTarget(b: *WaylandBackend) void {
        const t = b.dnd_target orelse return;
        b.dnd_target = null;
        if (t.offer) |o| b.dropOffer(o);
    }

    /// What the source allows (v3), or copy.
    fn targetActions(b: *WaylandBackend, t: dnd.Target) clipboard.DragActions {
        if (b.dataDeviceVersion() < 3) return .{ .copy = true };
        const id = t.offer orelse return .{};
        return if (b.offers.get(id)) |o| o.source_actions else .{};
    }

    /// `wl_data_device.drop`: read the accepted type, or leave if we
    /// accepted nothing.
    fn onDndDrop(b: *WaylandBackend) !void {
        const t = b.dnd_target orelse return;
        const leave: Event = .{ .drop = .{ .win = t.win, .phase = .leave, .allowed = .{}, .pos_px = t.pos } };
        const answer = t.sent orelse return b.onDndLeave();
        const mime = answer.mime orelse return b.onDndLeave();
        const offer_id = t.offer orelse return b.onDndLeave();
        const o = b.offers.get(offer_id) orelse return b.onDndLeave();
        // The trailing `leave` must not destroy the offer being read.
        b.dnd_target = null;
        const id = data_device.idForMime(mime) orelse .text_utf8;
        const action: clipboard.DragActions = if (b.dataDeviceVersion() >= 3) o.action else .{ .copy = true };
        const fds = pipe_transfer.pipe() catch |err| {
            b.dropOffer(offer_id);
            try b.stage(leave);
            return err;
        };
        defer _ = linux.close(fds[1]);
        wl.wl_data_offer.receive(b.conn, @enumFromInt(offer_id), mime, fds[1]) catch |err| {
            _ = linux.close(fds[0]);
            b.dropOffer(offer_id);
            try b.stage(leave);
            return err;
        };
        b.transfers.startDropRead(fds[0], id, b.nowNs() + b.opts.transfer_timeout_ns) catch |err| {
            b.dropOffer(offer_id);
            try b.stage(leave);
            return err;
        };
        if (b.dnd_dropped) |old| b.dropOffer(old.offer);
        b.dnd_dropped = .{ .offer = offer_id, .win = t.win, .pos = t.pos, .action = action };
        b.thread_wake.signal();
    }

    /// The dropped payload arrived (or the read failed): `drop` (or
    /// `leave`), then `finish` (v3, unless the action is ask) and destroy
    /// the offer.
    fn finishDrop(b: *WaylandBackend, f: pipe_transfer.Finished) void {
        const d = b.dnd_dropped orelse {
            b.gpa.free(f.data);
            return;
        };
        b.dnd_dropped = null;
        if (f.ok) {
            const data = b.putOwned(f.data);
            b.stage(.{ .drop = .{ .win = d.win, .phase = .drop, .allowed = d.action, .pos_px = d.pos, .data = data } }) catch {};
            if (b.dataDeviceVersion() >= 3 and !d.action.ask) wl.wl_data_offer.finish(b.conn, @enumFromInt(d.offer)) catch {};
        } else {
            b.gpa.free(f.data);
            b.stage(.{ .drop = .{ .win = d.win, .phase = .leave, .allowed = .{}, .pos_px = d.pos } }) catch {};
        }
        b.dropOffer(d.offer);
        b.conn.flush() catch {};
    }

    /// `Command.set_drop_effect`: tell the compositor what we accept, only
    /// when it changes.
    fn setDropEffect(b: *WaylandBackend, win: WindowId, accept: ?clipboard.MimeId, effect: clipboard.DragActions) !void {
        const t = &(b.dnd_target orelse return);
        if (t.win != win) return;
        const offer_id = t.offer orelse return;
        const o = b.offers.get(offer_id) orelse return;
        const a = dnd.Target.answerFor(o.mimes.items, accept, effect);
        if (t.mimeChanged(a)) try wl.wl_data_offer.accept(b.conn, @enumFromInt(offer_id), t.serial, a.mime);
        if (b.dataDeviceVersion() >= 3 and t.actionsChanged(a)) {
            try wl.wl_data_offer.setActions(b.conn, @enumFromInt(offer_id), dnd.toWl(a.actions), dnd.preferred(a.actions));
        }
        t.sent = a;
    }

    /// `Command.start_drag`: a source offering `items`, started with the
    /// serial of the button press that began the drag.
    fn startDrag(b: *WaylandBackend, win: WindowId, items: []const clipboard.ClipItem, allowed: clipboard.DragActions) !void {
        const dev = b.data_dev orelse return error.Unsupported;
        const m = b.data_manager orelse return error.Unsupported;
        const w = try b.lookup(win);
        const owned = try b.gpa.alloc(ClipItemOwned, items.len);
        var done: usize = 0;
        errdefer {
            for (owned[0..done]) |it| b.gpa.free(it.data);
            b.gpa.free(owned);
        }
        for (items, 0..) |it, i| {
            owned[i] = .{ .mime = it.mime, .data = try b.gpa.dupe(u8, it.data) };
            done = i + 1;
        }
        if (b.dnd_source != null) b.endDragSource(.{});
        const c = b.conn;
        const src = try c.newIdVersion(wl.wl_data_source, c.version(@intFromEnum(m)), b.handler(.data_source));
        try wl.wl_data_device_manager.createDataSource(c, m, src);
        for (items) |it| for (data_device.mimesFor(it.mime)) |mt| try wl.wl_data_source.offer(c, src, mt);
        if (c.version(@intFromEnum(m)) >= 3) try wl.wl_data_source.setActions(c, src, dnd.toWl(allowed));
        try wl.wl_data_device.startDrag(c, dev, src, w.surface, null, b.seat.last_button_serial);
        b.drag_items = owned;
        b.dnd_source = .{ .source = @intFromEnum(src), .win = win };
    }

    /// Events of the source of a drag we started.
    fn onDragSourceEvent(b: *WaylandBackend, ev: wl.wl_data_source.Event) !void {
        const ds = &b.dnd_source.?;
        switch (ev) {
            .send => |sd| {
                const want = data_device.idForMime(sd.mime_type);
                for (b.drag_items) |it| if (want != null and it.mime == want.?) {
                    b.transfers.startWrite(sd.fd, it.data, b.nowNs() + b.opts.transfer_timeout_ns) catch |err| log.warn("drag send: {t}", .{err});
                    return;
                };
                _ = linux.close(sd.fd);
            },
            .action => |a| ds.action = dnd.fromWl(a.dnd_action),
            .target, .dnd_drop_performed => {},
            .dnd_finished => b.endDragSource(ds.action),
            .cancelled => b.endDragSource(.{}),
        }
    }

    /// Ends our drag: `source_finished` with `action`, then frees it.
    fn endDragSource(b: *WaylandBackend, action: clipboard.DragActions) void {
        const ds = b.dnd_source orelse return;
        b.dnd_source = null;
        wl.wl_data_source.destroy(b.conn, @enumFromInt(ds.source)) catch {};
        freeClip(b.gpa, b.drag_items);
        b.drag_items = &.{};
        b.stage(.{ .drop = .{ .win = ds.win, .phase = .source_finished, .allowed = action, .pos_px = .{ 0, 0 } } }) catch {};
    }

    /// A source's `cancelled`: another client owns the selection now.
    fn dropSource(b: *WaylandBackend, which: clipboard.Selection, obj: u32) void {
        switch (which) {
            .clipboard => wl.wl_data_source.destroy(b.conn, @enumFromInt(obj)) catch {},
            .primary => wl.zwp_primary_selection_source_v1.destroy(b.conn, @enumFromInt(obj)) catch {},
        }
        if (b.sources[@intFromEnum(which)] == obj) b.sources[@intFromEnum(which)] = null;
    }

    // ---- input (E01.F04.S02.T02) ----

    /// Gets or releases the seat's devices to match `caps`. Mutex held.
    fn onCapabilities(b: *WaylandBackend, caps: wl.wl_seat.Capability) !void {
        const c = b.conn;
        const sid = b.seat_id orelse return;
        const ver = c.version(@intFromEnum(sid));
        const out: Sink = .{ .b = b };
        if (caps.keyboard and b.keyboard == null) {
            const k = try c.newIdVersion(wl.wl_keyboard, ver, b.handler(.keyboard));
            try wl.wl_seat.getKeyboard(c, sid, k);
            b.keyboard = k;
        } else if (!caps.keyboard) if (b.keyboard) |k| {
            b.armRepeat(try b.seat.kbLeave(out, b.nowNs()));
            try wl.wl_keyboard.release(c, k);
            b.keyboard = null;
        };
        if (caps.pointer and b.pointer == null) {
            const p = try c.newIdVersion(wl.wl_pointer, ver, b.handler(.pointer));
            try wl.wl_seat.getPointer(c, sid, p);
            b.pointer = p;
            if (b.cursor_manager) |m| {
                const d = try c.newIdVersion(wl.wp_cursor_shape_device_v1, c.version(@intFromEnum(m)), null);
                try wl.wp_cursor_shape_manager_v1.getPointer(c, m, d, p);
                b.cursor_device = d;
            }
        } else if (!caps.pointer) if (b.pointer) |p| {
            try b.seat.ptrLeave(out);
            if (b.cursor_device) |d| try wl.wp_cursor_shape_device_v1.destroy(c, d);
            b.cursor_device = null;
            try wl.wl_pointer.release(c, p);
            b.pointer = null;
        };
        if (caps.touch and b.touch == null) {
            const t = try c.newIdVersion(wl.wl_touch, ver, b.handler(.touch));
            try wl.wl_seat.getTouch(c, sid, t);
            b.touch = t;
        } else if (!caps.touch) if (b.touch) |t| {
            try b.seat.touchCancel(out);
            try wl.wl_touch.release(c, t);
            b.touch = null;
        };
    }

    /// `wl_keyboard.keymap`: maps and parses the keymap without the mutex
    /// (it takes a few milliseconds), then installs it. Owns `fd`.
    fn onKeymap(b: *WaylandBackend, format: wl.wl_keyboard.KeymapFormat, fd: i32, size: u32) !void {
        defer _ = linux.close(fd);
        if (format != .xkb_v1 or size == 0 or size > max_keymap_bytes) {
            log.warn("ignoring keymap (format {d}, {d} bytes)", .{ @intFromEnum(format), size });
            return;
        }
        const mem = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch |err| {
            log.warn("mapping the keymap: {t}", .{err});
            return;
        };
        defer std.posix.munmap(mem);
        // The text is NUL-terminated within `size`.
        const text = mem[0 .. std.mem.indexOfScalar(u8, mem, 0) orelse mem.len];
        const km = Keymap.parse(b.gpa, text) catch |err| {
            log.warn("parsing the keymap: {t}", .{err});
            return;
        };
        b.lock();
        defer b.unlock();
        b.seat.setKeymap(b.gpa, km);
    }

    /// Loads the user's compose rules (platform thread, at start).
    fn loadCompose(b: *WaylandBackend) void {
        var env = b.compose_env orelse return;
        b.compose_env = null;
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

    /// Arms or disarms the repeat timer. Mutex held.
    fn armRepeat(b: *WaylandBackend, r: seat_mod.Repeat) void {
        if (b.repeat_fd < 0) return;
        const spec: linux.itimerspec = switch (r) {
            .keep => return,
            .disarm => .{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = .{ .sec = 0, .nsec = 0 } },
            .arm => |a| .{ .it_interval = msSpec(a.interval_ms), .it_value = msSpec(a.delay_ms) },
        };
        _ = linux.timerfd_settime(b.repeat_fd, .{}, &spec, null);
    }

    fn onRepeatTimer(b: *WaylandBackend) void {
        var n: u64 = 0;
        const rc = linux.read(b.repeat_fd, std.mem.asBytes(&n), @sizeOf(u64));
        if (linux.errno(rc) != .SUCCESS or n == 0) return;
        b.lock();
        defer b.unlock();
        b.seat.repeatFired(Sink{ .b = b }, n, b.nowNs()) catch |err| log.warn("key repeat: {t}", .{err});
    }

    fn focusWindow(b: *WaylandBackend, id: ?WindowId) ?*Window {
        return if (b.find(id orelse return null)) |s| &s.win else null;
    }

    fn byObject(b: *WaylandBackend, comptime field: []const u8, obj: u32) ?*Window {
        for (b.slots.items) |s| {
            const v = @field(s.win, field);
            const id: ?u32 = switch (@typeInfo(@TypeOf(v))) {
                .optional => if (v) |x| @intFromEnum(x) else null,
                else => @intFromEnum(v),
            };
            if (id == obj) return &s.win;
        }
        return null;
    }

    fn stageConfigure(b: *WaylandBackend, w: *Window, cf: win_mod.Configured) !void {
        if (cf.occluded) |occ| try b.stage(.{ .window_occluded = .{ .win = w.id, .occluded = occ } });
        try b.applyDecorations(w);
        try b.stage(.{ .window_configure = .{ .win = w.id, .size = cf.size, .scale = cf.scale, .state = cf.state, .serial = cf.serial, .screen_origin_px = null } });
    }

    /// Sends the CSD window geometry and input region when they changed
    /// (they apply with the next commit, which carries the new size), and
    /// stages `window_decorations` when the mode or margins changed.
    fn applyDecorations(b: *WaylandBackend, w: *Window) !void {
        const c = b.conn;
        if (w.csd) {
            const geo = csd.geometry(w.margins, w.logical);
            if (w.applied_geometry == null or !std.meta.eql(w.applied_geometry.?, geo)) {
                try wl.xdg_surface.setWindowGeometry(c, w.xdg_surface, geo[0], geo[1], geo[2], geo[3]);
                w.applied_geometry = geo;
            }
            const in = csd.inputRect(w.margins, w.logical);
            if (w.applied_input == null or !std.meta.eql(w.applied_input.?, in)) {
                const r = try c.newIdVersion(wl.wl_region, 1, null);
                try wl.wl_compositor.createRegion(c, b.compositor, r);
                try wl.wl_region.add(c, r, in[0], in[1], in[2], in[3]);
                try wl.wl_surface.setInputRegion(c, w.surface, r);
                try wl.wl_region.destroy(c, r);
                w.applied_input = in;
            }
        } else if (w.applied_geometry != null) {
            // Back to server-side: the whole surface is the window.
            try wl.xdg_surface.setWindowGeometry(c, w.xdg_surface, 0, 0, @intCast(w.logical.w), @intCast(w.logical.h));
            try wl.wl_surface.setInputRegion(c, w.surface, null);
            w.applied_geometry = null;
            w.applied_input = null;
        }
        const m = w.margins.scaled(w.effectiveScale120()).array();
        if (w.reported_client == w.csd and std.meta.eql(w.reported_margins, m)) return;
        w.reported_client = w.csd;
        w.reported_margins = m;
        try b.stage(.{ .window_decorations = .{ .win = w.id, .client = w.csd, .margins_px = m } });
    }

    /// Client-side decorations: presses on the title bar and borders of
    /// the pointer's window start a move, resize, window menu or
    /// maximize instead of reaching the app (their releases are dropped
    /// too), and the margins show resize cursors. Runs at
    /// `wl_pointer.frame`, before the frame is turned into events. Mutex
    /// held.
    fn routeCsd(b: *WaylandBackend) !void {
        const st = &b.seat;
        const s = b.find(st.ptr_focus orelse return) orelse return;
        const w = &s.win;
        if (!w.csd) return;
        const s120 = w.effectiveScale120();
        const edge = csd.edgeAt(st.ptr_pos, w.bufferSize(), w.margins.scaled(s120), scale.scaleDim(csd.corner_len, s120));
        const region: types.HitRegion = if (edge) |e| csd.edgeRegion(e) else if (s.hit) |h| h.f(h.ctx, .{
            .x = @intFromFloat(@floor(st.ptr_pos[0])),
            .y = @intFromFloat(@floor(st.ptr_pos[1])),
        }) else .client;
        const shape: ?CursorShape = if (csd.regionEdge(region)) |e| csd.cursorFor(e) else null;
        if (!std.meta.eql(shape, s.auto_cursor)) {
            s.auto_cursor = shape;
            b.cursor_dirty = true;
            b.thread_wake.signal();
        }
        const f = &st.frame;
        var kept: usize = 0;
        for (f.buttons[0..f.n_buttons]) |bt| {
            if (!bt.pressed) {
                if (b.csd_swallow == bt.code) {
                    b.csd_swallow = null;
                    continue;
                }
            } else {
                const button = seat_mod.buttonOf(bt.code);
                const double = region == .caption and button == .left and
                    b.csd_clicks.press(b.nowNs(), st.ptr_pos, seat_mod.double_click_ns, seat_mod.double_click_px);
                const action = csd.pressAction(region, button, double);
                if (action != .deliver) {
                    try b.runCsdAction(w, action);
                    b.csd_swallow = bt.code;
                    continue;
                }
            }
            f.buttons[kept] = bt;
            kept += 1;
        }
        f.n_buttons = @intCast(kept);
    }

    fn runCsdAction(b: *WaylandBackend, w: *Window, action: csd.Action) !void {
        const c = b.conn;
        const seat = b.seat_id orelse return;
        const serial = b.seat.last_button_serial;
        switch (action) {
            .deliver => {},
            .move => try wl.xdg_toplevel.move(c, w.toplevel, seat, serial),
            .resize => |e| try wl.xdg_toplevel.resize(c, w.toplevel, seat, serial, csd.wlEdge(e)),
            .window_menu => if (w.wm_caps.window_menu) {
                const s120 = w.effectiveScale120();
                const x: i32 = @intFromFloat(b.seat.ptr_pos[0] * scale.unit / @as(f32, @floatFromInt(s120)));
                const y: i32 = @intFromFloat(b.seat.ptr_pos[1] * scale.unit / @as(f32, @floatFromInt(s120)));
                try wl.xdg_toplevel.showWindowMenu(c, w.toplevel, seat, serial, x, y);
            },
            .toggle_maximize => if (w.wm_caps.maximize) {
                if (w.state.maximized) try wl.xdg_toplevel.unsetMaximized(c, w.toplevel) else try wl.xdg_toplevel.setMaximized(c, w.toplevel);
            },
        }
        try c.flush();
    }

    fn rescaleLocked(b: *WaylandBackend, w: *Window) !void {
        var max: ?i32 = null;
        for (w.enteredOutputs()) |e| for (b.outputs.items) |o| if (o.id == e) {
            max = @max(max orelse 0, o.scale);
        };
        if (w.rescale(max)) |cf| try b.stageConfigure(w, cf);
    }

    fn refreshFor(b: *WaylandBackend, w: *const Window) u32 {
        var best: u32 = 0;
        for (w.enteredOutputs()) |e| for (b.outputs.items) |o| if (o.id == e) {
            best = @max(best, o.info.refresh_mhz);
        };
        if (best == 0) return b.opts.default_refresh_ns;
        return @intCast(@as(u64, 1_000_000_000_000) / best);
    }

    fn addOutput(b: *WaylandBackend, g: Global) !void {
        const o = try b.gpa.create(Output);
        errdefer b.gpa.destroy(o);
        const id = (try b.registry.bindGlobal(wl.wl_output, g, 2, 4, b.handler(.output))) orelse return b.gpa.destroy(o);
        o.* = .init(g.name, id);
        b.lock();
        defer b.unlock();
        try b.outputs.append(b.gpa, o);
    }

    fn onGlobalAdd(ctx: *anyopaque, g: Global) void {
        const b: *WaylandBackend = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, g.interface, wl.wl_output.name)) return;
        b.addOutput(g) catch |err| log.warn("binding output {d}: {t}", .{ g.name, err });
    }

    fn onGlobalRemove(ctx: *anyopaque, g: Global) void {
        const b: *WaylandBackend = @ptrCast(@alignCast(ctx));
        b.lock();
        defer b.unlock();
        for (b.outputs.items, 0..) |o, i| if (o.global == g.name) {
            for (b.slots.items) |s| {
                s.win.leave(o.id);
                b.rescaleLocked(&s.win) catch {};
            }
            if (b.conn.version(@intFromEnum(o.id)) >= 3) wl.wl_output.release(b.conn, o.id) catch {};
            _ = b.outputs.swapRemove(i);
            b.gpa.destroy(o);
            b.stage(.monitors_changed) catch {};
            return;
        };
    }

    // ---- small helpers ----

    /// Takes the backend mutex.
    pub fn lock(b: *WaylandBackend) void {
        b.mutex.lockUncancelable(b.io);
    }

    /// Releases the backend mutex.
    pub fn unlock(b: *WaylandBackend) void {
        b.mutex.unlock(b.io);
    }

    fn nowNs(b: *WaylandBackend) u64 {
        return @intCast(@max(0, Io.Clock.awake.now(b.io).nanoseconds));
    }

    fn noHook(_: *anyopaque, _: WindowId, _: []const u32, _: ?native_api.Win32MsgHook, _: *anyopaque) error{Unsupported}!void {
        return error.Unsupported;
    }

    fn noMsgWindow(_: *anyopaque, _: native_api.Win32MsgHook, _: *anyopaque) error{ Unsupported, SystemResources }!*anyopaque {
        return error.Unsupported;
    }

    fn noDestroy(_: *anyopaque, _: *anyopaque) void {}

    fn windowHandle(ctx: *anyopaque, win: WindowId) native_api.NativeWindow {
        const b: *WaylandBackend = @ptrCast(@alignCast(ctx));
        b.lock();
        defer b.unlock();
        return if (b.find(win)) |s| .{ .wayland_surface = @intFromEnum(s.win.surface) } else .headless;
    }

    // ---- test access ----

    /// The window's state, for tests. Copied under the mutex.
    pub fn windowSnapshot(b: *WaylandBackend, win: WindowId) ?Window {
        b.lock();
        defer b.unlock();
        return if (b.find(win)) |s| s.win else null;
    }
};

const ClipItemOwned = struct { mime: clipboard.MimeId, data: []u8 };

const native_endian = @import("builtin").cpu.arch.endian();

/// Where `Seat` sends events: the staged list and the payload arena.
/// Used with the mutex held.
const Sink = struct {
    b: *WaylandBackend,

    /// Stages `ev`.
    pub fn stage(s: Sink, ev: Event) !void {
        return s.b.stage(ev);
    }

    /// Copies `bytes` into the payload arena.
    pub fn text(s: Sink, bytes: []const u8) types.PayloadSlice {
        return s.b.arena.put(bytes) catch .empty;
    }
};

/// Surface coordinates to the window's physical pixels.
fn toPx(w: *const Window, x: wl.Fixed, y: wl.Fixed) [2]f32 {
    const k = @as(f64, @floatFromInt(w.effectiveScale120())) / @as(f64, @floatFromInt(scale.unit));
    return .{ @floatCast(x.toF64() * k), @floatCast(y.toF64() * k) };
}

fn axisOf(a: wl.wl_pointer.Axis) seat_mod.Axis {
    return if (@intFromEnum(a) == 1) .horizontal else .vertical;
}

fn msSpec(ms: u32) linux.timespec {
    return .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
}

fn freeClip(gpa: Allocator, items: []ClipItemOwned) void {
    for (items) |it| gpa.free(it.data);
    gpa.free(items);
}

fn nonZero(s: PxSize) PxSize {
    return .{ .w = if (s.w == 0) 800 else s.w, .h = if (s.h == 0) 600 else s.h };
}

// ---- tests ----

const testing = std.testing;
const fake = @import("testing/fake_compositor.zig");
const conformance = @import("../testing/conformance.zig");
const WestonForTest = @import("testing/weston.zig").WestonForTest;

/// A scripted compositor. It learns object ids from the requests it
/// decodes: an id argument it has not seen is a new object of that type.
const Peer = struct {
    fc: *fake.FakeCompositor,
    ids: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// Requests seen, as (interface, opcode), in order.
    log: std.ArrayList(Seen) = .empty,
    outputs: []const OutputSpec = &.{},
    serial: u32 = 100,
    last_bound: ?[]const u8 = null,
    /// Sent in answer to `get_default_feedback`, if set.
    feedback: ?FeedbackScript = null,
    /// Keep the newest request fd in `kept_fd` instead of closing it.
    keep_fds: bool = false,
    kept_fd: ?i32 = null,
    /// The newest request's `mime_type` and `serial` arguments.
    last_mime: [64]u8 = undefined,
    last_mime_len: usize = 0,
    last_token: [64]u8 = undefined,
    last_token_len: usize = 0,
    last_serial: ?u32 = null,
    /// The newest `accept` mime (null = refused) and `set_actions`.
    last_accept: ?[64]u8 = null,
    last_accept_len: usize = 0,
    last_actions: ?u32 = null,
    /// The newest `hotspot_x`/`hotspot_y` and `scale` arguments.
    last_hotspot: [2]i32 = .{ -1, -1 },
    last_scale: ?i32 = null,
    /// The newest `set_content_type` purpose, `set_surrounding_text`
    /// cursor and `set_cursor_rectangle` origin.
    last_purpose: ?u32 = null,
    last_ime_cursor: ?i32 = null,
    last_rect: [2]i32 = .{ -1, -1 },
    /// The newest `set_window_geometry`, decoration `set_mode` and
    /// `xdg_toplevel.resize` edges.
    last_geometry: [4]i32 = .{ -1, -1, -1, -1 },
    last_mode: ?u32 = null,
    last_edges: ?u32 = null,
    /// The newest `wl_shm_pool.create_buffer` (offset, width, height,
    /// stride) and pool size (`create_pool` or `resize`).
    last_shm_buffer: [4]i32 = .{ -1, -1, -1, -1 },
    last_pool_size: ?i32 = null,

    const FeedbackScript = struct { table_fd: i32, size: u32, dev: [8]u8, indices: []const u8 };

    const Seen = struct { iface: []const u8, obj: u32, opcode: u16 };
    const OutputSpec = struct { w: i32, h: i32, refresh: i32, scale: i32, name: [:0]const u8 };

    fn init() !Peer {
        var p: Peer = .{ .fc = try fake.FakeCompositor.init(testing.allocator) };
        try p.ids.put(testing.allocator, 1, wl.wl_display.name);
        return p;
    }

    fn deinit(p: *Peer) void {
        if (p.kept_fd) |fd| _ = linux.close(fd);
        p.ids.deinit(testing.allocator);
        p.log.deinit(testing.allocator);
        p.fc.deinit();
    }

    fn id(p: *Peer, comptime I: type) I.Id {
        var it = p.ids.iterator();
        var best: ?u32 = null;
        // The newest object of the interface (ids grow).
        while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, I.name)) {
            if (best == null or e.key_ptr.* > best.?) best = e.key_ptr.*;
        };
        return @enumFromInt(best orelse std.debug.panic("peer: no {s} yet", .{I.name}));
    }

    /// Reads one request, learning ids; null on timeout.
    fn next(p: *Peer, timeout_ns: ?u64) !?Seen {
        const r = (try p.fc.recvTimeout(timeout_ns)) orelse return null;
        const iface = p.ids.get(r.obj) orelse return error.UnknownObject;
        try p.learn(iface, r);
        const s: Seen = .{ .iface = iface, .obj = r.obj, .opcode = r.opcode };
        try p.log.append(testing.allocator, s);
        return s;
    }

    fn learn(p: *Peer, iface: []const u8, r: fake.Request) !void {
        inline for (wl.interfaces) |I| if (std.mem.eql(u8, I.name, iface)) {
            const req = try I.decodeRequest(r.opcode, r.body, &p.fc.fds);
            if (I == wl.wl_registry) switch (req) {
                .bind => |bd| {
                    const n = try internName(bd.interface);
                    try p.ids.put(testing.allocator, bd.id, n);
                    p.last_bound = n;
                },
            };
            if (I == wl.wl_display) switch (req) {
                .sync => |s| {
                    try p.ids.put(testing.allocator, @intFromEnum(s.callback), wl.wl_callback.name);
                    return;
                },
                else => {},
            };
            switch (req) {
                inline else => |payload| try p.learnFields(payload),
            }
            return;
        };
    }

    fn learnFields(p: *Peer, payload: anytype) !void {
        const T = @TypeOf(payload);
        if (@typeInfo(T) != .@"struct") return;
        inline for (@typeInfo(T).@"struct".fields) |f| {
            const v = @field(payload, f.name);
            if (comptime std.mem.eql(u8, f.name, "fd")) {
                if (p.keep_fds) {
                    if (p.kept_fd) |old| _ = linux.close(old);
                    p.kept_fd = v;
                } else _ = linux.close(v);
            }
            if (comptime std.mem.eql(u8, f.name, "mime_type") and f.type == [:0]const u8) {
                p.last_mime_len = @min(v.len, p.last_mime.len);
                @memcpy(p.last_mime[0..p.last_mime_len], v[0..p.last_mime_len]);
            }
            if (comptime std.mem.eql(u8, f.name, "token") and f.type == [:0]const u8) {
                p.last_token_len = @min(v.len, p.last_token.len);
                @memcpy(p.last_token[0..p.last_token_len], v[0..p.last_token_len]);
            }
            if (comptime std.mem.eql(u8, f.name, "serial")) p.last_serial = v;
            if (comptime std.mem.eql(u8, f.name, "mime_type") and f.type == ?[:0]const u8) {
                if (v) |m| {
                    var a: [64]u8 = undefined;
                    p.last_accept_len = @min(m.len, a.len);
                    @memcpy(a[0..p.last_accept_len], m[0..p.last_accept_len]);
                    p.last_accept = a;
                } else p.last_accept = null;
            }
            if (comptime std.mem.eql(u8, f.name, "dnd_actions")) p.last_actions = @bitCast(v);
            if (comptime std.mem.eql(u8, f.name, "hotspot_x")) p.last_hotspot[0] = v;
            if (comptime std.mem.eql(u8, f.name, "hotspot_y")) p.last_hotspot[1] = v;
            if (comptime std.mem.eql(u8, f.name, "scale") and f.type == i32) p.last_scale = v;
            if (f.type == wl.zwp_text_input_v3.ContentPurpose) p.last_purpose = @intFromEnum(v);
            if (f.type == wl.zxdg_toplevel_decoration_v1.Mode) p.last_mode = @intFromEnum(v);
            if (f.type == wl.xdg_toplevel.ResizeEdge) p.last_edges = @intFromEnum(v);
            if (@TypeOf(payload) == @FieldType(wl.wl_shm_pool.Request, "create_buffer")) {
                inline for (.{ "offset", "width", "height", "stride" }, 0..) |n, i| if (comptime std.mem.eql(u8, f.name, n)) {
                    p.last_shm_buffer[i] = v;
                };
            }
            if (comptime std.mem.eql(u8, f.name, "size") and f.type == i32) p.last_pool_size = v;
            if (@TypeOf(payload) == @FieldType(wl.xdg_surface.Request, "set_window_geometry")) {
                inline for (.{ "x", "y", "width", "height" }, 0..) |n, i| if (comptime std.mem.eql(u8, f.name, n)) {
                    p.last_geometry[i] = v;
                };
            }
            if (@TypeOf(payload) == @FieldType(wl.zwp_text_input_v3.Request, "set_surrounding_text") and comptime std.mem.eql(u8, f.name, "cursor")) p.last_ime_cursor = v;
            if (@TypeOf(payload) == @FieldType(wl.zwp_text_input_v3.Request, "set_cursor_rectangle")) {
                if (comptime std.mem.eql(u8, f.name, "x")) p.last_rect[0] = v;
                if (comptime std.mem.eql(u8, f.name, "y")) p.last_rect[1] = v;
            }
            inline for (wl.interfaces) |J| if (f.type == J.Id) {
                const n = @intFromEnum(v);
                if (!p.ids.contains(n)) try p.ids.put(testing.allocator, n, J.name);
            };
        }
    }

    fn internName(s: []const u8) ![]const u8 {
        inline for (wl.interfaces) |I| if (std.mem.eql(u8, I.name, s)) return I.name;
        return error.UnknownInterface;
    }

    /// Plays the compositor through `init`: globals, binds, outputs, and
    /// `syncs` roundtrips.
    fn serveInit(p: *Peer, globals: []const fake.Global, syncs: usize) !void {
        var answered: usize = 0;
        while (answered < syncs) {
            const s = (try p.next(null)).?;
            if (s.obj != 1) {
                if (p.feedback) |fs| if (std.mem.eql(u8, s.iface, wl.zwp_linux_dmabuf_v1.name) and s.opcode == @intFromEnum(wl.zwp_linux_dmabuf_v1.Request.get_default_feedback)) {
                    const fb = p.id(wl.zwp_linux_dmabuf_feedback_v1);
                    const S = wl.zwp_linux_dmabuf_feedback_v1.server;
                    try S.formatTable(p.fc, fb, fs.table_fd, fs.size);
                    try S.mainDevice(p.fc, fb, &fs.dev);
                    try S.trancheTargetDevice(p.fc, fb, &fs.dev);
                    try S.trancheFormats(p.fc, fb, fs.indices);
                    try S.trancheFlags(p.fc, fb, .{});
                    try S.trancheDone(p.fc, fb);
                    try S.done(p.fc, fb);
                };
                if (std.mem.eql(u8, s.iface, wl.wl_registry.name) and s.opcode == 0) {
                    if (p.last_bound != null and p.last_bound.?.ptr == wl.wl_seat.name.ptr)
                        try wl.wl_seat.server.capabilities(p.fc, p.id(wl.wl_seat), .{ .pointer = true, .keyboard = true, .touch = true });
                    // bind: describe a new output before the next sync
                    if (p.last_bound != null and p.last_bound.?.ptr == wl.wl_output.name.ptr and p.outputs.len > 0) {
                        const out_id = p.id(wl.wl_output);
                        const o = p.outputs[0];
                        try wl.wl_output.server.geometry(p.fc, out_id, 0, 0, 300, 200, @enumFromInt(0), "ACME", "Test", @enumFromInt(0));
                        try wl.wl_output.server.mode(p.fc, out_id, .{ .current = true }, o.w, o.h, o.refresh);
                        try wl.wl_output.server.scale(p.fc, out_id, o.scale);
                        try wl.wl_output.server.name(p.fc, out_id, o.name);
                        try wl.wl_output.server.done(p.fc, out_id);
                    }
                }
                continue;
            }
            switch (s.opcode) {
                0 => { // sync
                    const cb = p.id(wl.wl_callback);
                    try wl.wl_callback.server.done(p.fc, cb, 0);
                    try wl.wl_display.server.deleteId(p.fc, @enumFromInt(1), @intFromEnum(cb));
                    _ = p.ids.remove(@intFromEnum(cb));
                    answered += 1;
                },
                1 => { // get_registry
                    const reg = p.id(wl.wl_registry);
                    for (globals) |g| try wl.wl_registry.server.global(p.fc, reg, g.name, g.interface, g.version);
                },
                else => return error.UnexpectedRequest,
            }
        }
    }

    fn serveInitThread(p: *Peer, globals: []const fake.Global, syncs: usize) void {
        p.serveInit(globals, syncs) catch |err| std.debug.panic("peer: {t}", .{err});
    }

    /// Reads until a request `I.opcode` arrives, or fails after `timeout_ns`.
    fn waitFor(p: *Peer, comptime I: type, comptime tag: std.meta.Tag(I.Request), timeout_ns: u64) !Seen {
        while (try p.next(timeout_ns)) |s| {
            if (std.mem.eql(u8, s.iface, I.name) and s.opcode == @intFromEnum(tag)) return s;
        }
        return error.Timeout;
    }

    /// Sends a toplevel and surface configure.
    fn configure(p: *Peer, w: i32, h: i32, states: []const wl.xdg_toplevel.State) !u32 {
        var buf: [16 * 4]u8 = undefined;
        for (states, 0..) |s, i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], @intFromEnum(s), @import("builtin").cpu.arch.endian());
        try wl.xdg_toplevel.server.configure(p.fc, p.id(wl.xdg_toplevel), w, h, buf[0 .. states.len * 4]);
        p.serial += 1;
        try wl.xdg_surface.server.configure(p.fc, p.id(wl.xdg_surface), p.serial);
        return p.serial;
    }
};

const all_globals = [_]fake.Global{
    .{ .name = 1, .interface = "wl_compositor", .version = 6 },
    .{ .name = 2, .interface = "xdg_wm_base", .version = 6 },
    .{ .name = 3, .interface = "wl_shm", .version = 1 },
    .{ .name = 4, .interface = "wp_viewporter", .version = 1 },
    .{ .name = 5, .interface = "wp_fractional_scale_manager_v1", .version = 1 },
    .{ .name = 6, .interface = "wl_output", .version = 4 },
    // Server-side decorations, so windows have no CSD margins.
    .{ .name = 11, .interface = "zxdg_decoration_manager_v1", .version = 1 },
};

/// `all_globals` and a seat.
const seat_globals = all_globals ++ [_]fake.Global{.{ .name = 7, .interface = "wl_seat", .version = 9 }};

/// `seat_globals` and both selection managers.
const selection_globals = seat_globals ++ [_]fake.Global{
    .{ .name = 8, .interface = "wl_data_device_manager", .version = 3 },
    .{ .name = 9, .interface = "zwp_primary_selection_device_manager_v1", .version = 1 },
};

/// A backend connected to a fresh `Peer`.
const Rig = struct {
    peer: Peer,
    b: *WaylandBackend,

    fn start(rig: *Rig, opts: InitOptions, outputs: []const Peer.OutputSpec) !void {
        return rig.startWith(opts, outputs, &all_globals, null);
    }

    fn startWith(rig: *Rig, opts: InitOptions, outputs: []const Peer.OutputSpec, globals: []const fake.Global, feedback: ?Peer.FeedbackScript) !void {
        rig.peer = try Peer.init();
        errdefer rig.peer.deinit();
        rig.peer.outputs = outputs;
        rig.peer.feedback = feedback;
        const t = try std.Thread.spawn(.{}, Peer.serveInitThread, .{ &rig.peer, globals, 2 });
        var o = opts;
        o.fd = rig.peer.fc.client_fd;
        rig.b = WaylandBackend.init(testing.allocator, testing.io, o) catch |err| {
            t.join();
            return err;
        };
        t.join();
    }

    fn stop(rig: *Rig) void {
        rig.b.deinit();
        rig.peer.deinit();
    }

    /// Creates a window and reads its requests up to the initial commit.
    fn window(rig: *Rig, size: PxSize) !WindowId {
        const win = try rig.b.platform().createWindow(.{ .title = "zg test", .size = size });
        _ = try rig.peer.waitFor(wl.wl_surface, .commit, std.time.ns_per_s);
        return win;
    }
};

/// Polls until an event with tag `tag` for `win` arrives.
fn expectEvent(p: Platform, comptime tag: Event.Tag, win: ?WindowId) !@FieldType(Event, @tagName(tag)) {
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 2 * std.time.ns_per_s;
    var evs: [32]Event = undefined;
    while (true) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == tag and (win == null or std.meta.eql(e.window(), win))) return @field(e, @tagName(tag));
        if (@as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) >= deadline) return error.Timeout;
        p.waitEvents(deadline);
    }
}

test "missing xdg_wm_base is MissingGlobal" {
    var peer = try Peer.init();
    defer peer.deinit();
    const globals = [_]fake.Global{ all_globals[0], all_globals[2] };
    const Serve = struct {
        // The client hangs up once it sees the registry, so the peer may
        // lose the connection while it answers.
        fn run(p: *Peer, g: []const fake.Global) void {
            p.serveInit(g, 1) catch |err| switch (err) {
                error.ConnectionLost => {},
                else => std.debug.panic("peer: {t}", .{err}),
            };
        }
    };
    const t = try std.Thread.spawn(.{}, Serve.run, .{ &peer, &globals });
    const r = WaylandBackend.init(testing.allocator, testing.io, .{ .fd = peer.fc.client_fd });
    t.join();
    try testing.expectError(error.MissingGlobal, r);
}

test "configure → ack only on present" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{});
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const serial = try rig.peer.configure(200, 100, &.{.activated});
    const cf = try expectEvent(p, .window_configure, win);
    try testing.expectEqual(serial, cf.serial);
    try testing.expectEqual(PxSize{ .w = 200, .h = 100 }, cf.size);
    try testing.expect(cf.state.activated);
    // Nothing is acked while the app has not presented.
    try testing.expectEqual(@as(?Peer.Seen, null), try rig.peer.next(50 * std.time.ns_per_ms));

    const pr = try p.cpuPresenter(win);
    const buf = try pr.allocCpuBuffer(cf.size.w, cf.size.h, @import("shm.zig").fourcc_argb8888);
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .create_buffer, std.time.ns_per_s);
    rig.peer.log.clearRetainingCapacity();
    try pr.present(buf.handle, &.{}, .none, .{ .win = win, .serial = serial });
    _ = try rig.peer.waitFor(wl.wl_surface, .commit, std.time.ns_per_s);
    var ack: ?usize = null;
    var attach: ?usize = null;
    for (rig.peer.log.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.iface, "xdg_surface") and s.opcode == @intFromEnum(wl.xdg_surface.Request.ack_configure)) ack = i;
        if (std.mem.eql(u8, s.iface, "wl_surface") and s.opcode == @intFromEnum(wl.wl_surface.Request.attach)) attach = i;
    }
    try testing.expect(ack.? < attach.?);
    try testing.expectEqual(@as(?u32, null), rig.b.windowSnapshot(win).?.pending_ack);
    pr.releaseBuffer(buf.handle);
}

test "without a present the configure is acked after the timeout" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 20 * std.time.ns_per_ms }, &.{});
    defer rig.stop();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    _ = try rig.peer.configure(0, 0, &.{});
    _ = try rig.peer.waitFor(wl.xdg_surface, .ack_configure, std.time.ns_per_s);
    rig.peer.log.clearRetainingCapacity();
    _ = try rig.peer.waitFor(wl.wl_surface, .commit, std.time.ns_per_s);
    for (rig.peer.log.items) |s| try testing.expect(!(std.mem.eql(u8, s.iface, "wl_surface") and s.opcode == @intFromEnum(wl.wl_surface.Request.attach)));
    _ = win;
}

test "0x0 configure keeps size" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{});
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    _ = try rig.peer.configure(0, 0, &.{});
    try testing.expectEqual(PxSize{ .w = 320, .h = 240 }, (try expectEvent(p, .window_configure, win)).size);
    _ = try rig.peer.configure(500, 400, &.{});
    try testing.expectEqual(PxSize{ .w = 500, .h = 400 }, (try expectEvent(p, .window_configure, win)).size);
    _ = try rig.peer.configure(0, 0, &.{});
    try testing.expectEqual(PxSize{ .w = 500, .h = 400 }, (try expectEvent(p, .window_configure, win)).size);
}

test "fractional 180 → buffer 150x75 for 100x50" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{});
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 100, .h = 50 });
    try wl.wp_fractional_scale_v1.server.preferredScale(rig.peer.fc, rig.peer.id(wl.wp_fractional_scale_v1), 180);
    const serial = try rig.peer.configure(100, 50, &.{});
    const cf = try expectEvent(p, .window_configure, win);
    try testing.expectEqual(PxSize{ .w = 150, .h = 75 }, cf.size);
    try testing.expectEqual(@as(f32, 1.5), cf.scale.factor);

    const pr = try p.cpuPresenter(win);
    const buf = try pr.allocCpuBuffer(150, 75, @import("shm.zig").fourcc_xrgb8888);
    try pr.present(buf.handle, &.{}, .none, .{ .win = win, .serial = serial });
    var dest: ?[2]i32 = null;
    while (try rig.peer.next(std.time.ns_per_s)) |s| {
        try testing.expect(!(std.mem.eql(u8, s.iface, "wl_surface") and s.opcode == @intFromEnum(wl.wl_surface.Request.set_buffer_scale)));
        if (std.mem.eql(u8, s.iface, "wp_viewport") and s.opcode == @intFromEnum(wl.wp_viewport.Request.set_destination)) {
            // The body was valid only during `next`; the snapshot has the values.
            dest = .{ 0, 0 };
        }
        if (std.mem.eql(u8, s.iface, "wl_surface") and s.opcode == @intFromEnum(wl.wl_surface.Request.commit)) break;
    }
    try testing.expect(dest != null);
    try testing.expectEqual(PxSize{ .w = 100, .h = 50 }, rig.b.windowSnapshot(win).?.applied_destination.?);
    pr.releaseBuffer(buf.handle);
}

test "ping answered while UI thread blocked" {
    var rig: Rig = undefined;
    try rig.start(.{}, &.{});
    defer rig.stop();
    // The UI thread (this one) never polls; the platform thread answers.
    try wl.xdg_wm_base.server.ping(rig.peer.fc, rig.peer.id(wl.xdg_wm_base), 4242);
    _ = try rig.peer.waitFor(wl.xdg_wm_base, .pong, std.time.ns_per_s);
    try testing.expectEqual(@as(u32, 1), rig.b.pongs.load(.monotonic));
}

test "suspended → occluded" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{});
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    _ = try rig.peer.configure(0, 0, &.{.suspended});
    try testing.expect((try expectEvent(p, .window_occluded, win)).occluded);
    _ = try rig.peer.configure(0, 0, &.{.activated});
    try testing.expect(!(try expectEvent(p, .window_occluded, win)).occluded);
}

test "outputs, integer output scale, close and destroy" {
    var rig: Rig = undefined;
    const outs = [_]Peer.OutputSpec{.{ .w = 2560, .h = 1440, .refresh = 120000, .scale = 2, .name = "DP-3" }};
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &outs);
    defer rig.stop();
    const p = rig.b.platform();
    var mon: [4]types.MonitorInfo = undefined;
    try testing.expectEqual(1, p.monitors(&mon));
    try testing.expectEqualStrings("DP-3", mon[0].name());
    try testing.expectEqual(@as(u32, 2560), mon[0].rect_px.w);
    try testing.expectEqual(@as(u32, 120000), mon[0].refresh_mhz);
    try testing.expect(mon[0].primary);

    const win = try rig.window(.{ .w = 320, .h = 240 });
    _ = try rig.peer.configure(0, 0, &.{});
    try testing.expectEqual(PxSize{ .w = 320, .h = 240 }, (try expectEvent(p, .window_configure, win)).size);
    // Entering a 2x output without a fractional preference doubles the buffer.
    try wl.wl_surface.server.enter(rig.peer.fc, rig.peer.id(wl.wl_surface), rig.peer.id(wl.wl_output));
    const cf = try expectEvent(p, .window_configure, win);
    try testing.expectEqual(PxSize{ .w = 640, .h = 480 }, cf.size);
    try testing.expectEqual(@as(f32, 2), cf.scale.factor);

    // Unmapped surfaces get no frame callbacks: the request is answered
    // at once so frame 0 can map the window.
    try p.submit(.{ .request_frame = win });
    const fr = try expectEvent(p, .frame, win);
    try testing.expectEqual(@as(u32, 8_333_333), fr.refresh_ns);

    try wl.xdg_toplevel.server.close(rig.peer.fc, rig.peer.id(wl.xdg_toplevel));
    try testing.expectEqual(win, try expectEvent(p, .window_close_requested, win));
    p.destroyWindow(win);
    _ = try rig.peer.waitFor(wl.wl_surface, .destroy, std.time.ns_per_s);
    try testing.expectError(error.InvalidWindow, p.submit(.{ .set_title = .{ .win = win, .title = "gone" } }));
}

const dmabuf_globals = all_globals ++ [_]fake.Global{
    .{ .name = 7, .interface = "zwp_linux_dmabuf_v1", .version = 4 },
    .{ .name = 8, .interface = "wp_presentation", .version = 1 },
};

test "dmabuf default feedback → formats, drmDevice, syncMode" {
    const xr24: u32 = 0x34325258;
    const table = [_]dmabuf.TableEntry{
        .{ .format = xr24, .pad = 0, .modifier = 0 },
        .{ .format = xr24, .pad = 0, .modifier = 0x0100_0000_0000_0002 },
    };
    const fd: i32 = @intCast(linux.memfd_create("zg-test-table", linux.MFD.CLOEXEC));
    defer _ = linux.close(fd);
    const bytes = std.mem.sliceAsBytes(&table);
    _ = linux.ftruncate(fd, @intCast(bytes.len));
    _ = linux.pwrite(fd, bytes.ptr, bytes.len, 0);
    var dev: [8]u8 = undefined;
    std.mem.writeInt(u64, &dev, (226 << 8) | 128, @import("builtin").cpu.arch.endian());
    var idx: [4]u8 = undefined;
    std.mem.writeInt(u16, idx[0..2], 1, @import("builtin").cpu.arch.endian());
    std.mem.writeInt(u16, idx[2..4], 0, @import("builtin").cpu.arch.endian());

    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &dmabuf_globals, .{ .table_fd = fd, .size = @intCast(bytes.len), .dev = dev, .indices = &idx });
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 64, .h = 32 });
    const pr = (try p.surfaceTarget(win)).external;
    try testing.expectEqual(surface.SyncMode.implicit_sync_file, pr.syncMode());
    try testing.expectEqual(surface.DrmDevice{ .major = 226, .minor = 128 }, pr.drmDevice().?);
    var out: [4]surface.FormatModifier = undefined;
    try testing.expectEqual(@as(usize, 2), pr.formats(&out));
    try testing.expectEqual(@as(u64, 0x0100_0000_0000_0002), out[0].modifier);
    try testing.expectEqual(@as(u64, 0), out[1].modifier);
}

test "dmabuf import, implicit sync, present order, feedback and release" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &dmabuf_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 64, .h = 32 });
    const serial = try rig.peer.configure(64, 32, &.{});
    _ = try expectEvent(p, .window_configure, win);
    const pr = (try p.surfaceTarget(win)).external;
    // Stand-ins: a memfd for the dmabuf, a signalled eventfd for the
    // sync_file (the import ioctl fails, so the presenter waits on it).
    const buf_fd: i32 = @intCast(linux.memfd_create("zg-test-dmabuf", linux.MFD.CLOEXEC));
    defer _ = linux.close(buf_fd);
    const planes = [_]surface.Plane{.{ .fd = buf_fd, .offset = 0, .stride = 256 }};
    const h = try pr.importBuffer(&.{ .width = 64, .height = 32, .fourcc = 0x34325258, .modifier = 0, .planes = &planes, .kind = .dmabuf });
    _ = try rig.peer.waitFor(wl.zwp_linux_buffer_params_v1, .add, std.time.ns_per_s);
    _ = try rig.peer.waitFor(wl.zwp_linux_buffer_params_v1, .create_immed, std.time.ns_per_s);
    _ = try rig.peer.waitFor(wl.zwp_linux_buffer_params_v1, .destroy, std.time.ns_per_s);
    const wl_buf = rig.peer.id(wl.wl_buffer);

    rig.peer.log.clearRetainingCapacity();
    const sync_fd: i32 = @intCast(linux.eventfd(1, linux.EFD.CLOEXEC));
    try pr.present(h, &.{.{ .x = 0, .y = 0, .w = 8, .h = 8 }}, .{ .sync_file = sync_fd }, .{ .win = win, .serial = serial });
    _ = try rig.peer.waitFor(wl.wl_surface, .commit, std.time.ns_per_s);
    // The presenter closed the sync_file.
    try testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(sync_fd, linux.F.GETFD, 0)));
    const want = [_]struct { []const u8, u16 }{
        .{ "xdg_surface", @intFromEnum(wl.xdg_surface.Request.ack_configure) },
        .{ "wl_surface", @intFromEnum(wl.wl_surface.Request.attach) },
        .{ "wl_surface", @intFromEnum(wl.wl_surface.Request.damage_buffer) },
        .{ "wl_surface", @intFromEnum(wl.wl_surface.Request.frame) },
        .{ "wp_presentation", @intFromEnum(wl.wp_presentation.Request.feedback) },
        .{ "wl_surface", @intFromEnum(wl.wl_surface.Request.commit) },
    };
    var at: usize = 0;
    for (rig.peer.log.items) |s| {
        if (at < want.len and std.mem.eql(u8, s.iface, want[at][0]) and s.opcode == want[at][1]) at += 1;
    }
    try testing.expectEqual(want.len, at);
    try testing.expectError(error.Unsupported, pr.present(h, &.{}, .{ .syncobj = .{ .timeline_fd = -1, .point = 1 } }, null));

    // presented → Event.present_feedback in our monotonic clock.
    const fb = rig.peer.id(wl.wp_presentation_feedback);
    try wl.wp_presentation_feedback.server.presented(rig.peer.fc, fb, 0, 12, 345, 16_666_667, 0, 77, .{ .vsync = true, .hw_clock = true });
    const pf = try expectEvent(p, .present_feedback, win);
    try testing.expectEqual(@as(u64, 12 * std.time.ns_per_s + 345), pf.presented_ns);
    try testing.expectEqual(@as(u64, 77), pf.seq);
    try testing.expectEqual(event_api.PresentFlags.vsync | event_api.PresentFlags.hw_clock, pf.flags);

    // The compositor releases the buffer.
    try wl.wl_buffer.server.release(rig.peer.fc, wl_buf);
    var rel: [4]surface.BufferHandle = undefined;
    const deadline = rig.b.nowNs() + 2 * std.time.ns_per_s;
    var n: usize = 0;
    while (n == 0 and rig.b.nowNs() < deadline) {
        n = pr.pollReleased(&rel);
        if (n == 0) try Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(h, rel[0]);
    pr.releaseBuffer(h);
}

test "importBuffer without zwp_linux_dmabuf_v1 is Unsupported; shm imports work" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{});
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 16, .h = 16 });
    const pr = (try p.surfaceTarget(win)).external;
    try testing.expectEqual(surface.SyncMode.cpu_only, pr.syncMode());
    const fd: i32 = @intCast(linux.memfd_create("zg-test-shm", linux.MFD.CLOEXEC));
    defer _ = linux.close(fd);
    _ = linux.ftruncate(fd, 16 * 16 * 4);
    const planes = [_]surface.Plane{.{ .fd = fd, .offset = 0, .stride = 64 }};
    try testing.expectError(error.Unsupported, pr.importBuffer(&.{ .width = 16, .height = 16, .fourcc = 0x34325258, .modifier = 0, .planes = &planes, .kind = .dmabuf }));
    const h = try pr.importBuffer(&.{ .width = 16, .height = 16, .fourcc = 0x34325258, .modifier = 0, .planes = &planes, .kind = .shm });
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .create_buffer, std.time.ns_per_s);
    pr.releaseBuffer(h);
}

const WestonHarness = struct {
    io: Io,
    weston: *WestonForTest,
    env: *std.process.Environ.Map,

    /// Conformance hook: a backend on the test weston.
    pub fn create(h: *WestonHarness) !Platform {
        const b = try WaylandBackend.init(testing.allocator, h.io, .{ .environ_map = h.env });
        return b.platform();
    }
};

test "weston conformance" {
    var w = WestonForTest.start() catch return error.SkipZigTest;
    defer w.stop();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try w.environ(&env);
    var h: WestonHarness = .{ .io = testing.io, .weston = &w, .env = &env };
    try conformance.runConformance(WestonHarness, &h);
}

/// The next `key` event with `action`, skipping others.
fn expectKey(p: Platform, action: @import("../api/keys.zig").KeyAction) !event_api.KeyEvent {
    while (true) {
        const k = try expectEvent(p, .key, null);
        if (k.ev.action == action) return k.ev;
    }
}

test "seat: keymap, focus, text, shift, repeat, pointer frame and touch" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &seat_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const kb = rig.peer.id(wl.wl_keyboard);
    const ptr = rig.peer.id(wl.wl_pointer);
    const tch = rig.peer.id(wl.wl_touch);
    const surf = rig.peer.id(wl.wl_surface);

    const text = @embedFile("../xkb/testdata/us.xkb");
    const fd: i32 = @intCast(linux.memfd_create("zg-test-keymap", linux.MFD.CLOEXEC));
    defer _ = linux.close(fd);
    _ = linux.pwrite(fd, text.ptr, text.len, 0);
    _ = linux.pwrite(fd, "\x00", 1, text.len);
    const K = wl.wl_keyboard.server;
    try K.keymap(fc, kb, .xkb_v1, fd, @intCast(text.len + 1));
    try K.repeatInfo(fc, kb, 100, 20);
    try K.enter(fc, kb, 1, surf, &.{});
    try testing.expect((try expectEvent(p, .window_focus, win)).focused);

    const key_a = 30; // evdev KEY_A
    try K.key(fc, kb, 2, 0, key_a, .pressed);
    const press = try expectKey(p, .press);
    try testing.expectEqual(@import("../api/keys.zig").Key.key_a, press.key);
    try testing.expectEqualStrings("a", p.payload(press.text));
    // Held past the delay: the timer repeats it.
    const rep = try expectKey(p, .repeat);
    try testing.expectEqual(@as(u21, 'a'), rep.codepoint);
    try K.key(fc, kb, 3, 0, key_a, .released);
    _ = try expectKey(p, .release);

    try K.modifiers(fc, kb, 4, 1, 0, 0, 0); // Shift
    try K.key(fc, kb, 5, 0, key_a, .pressed);
    const shifted = try expectKey(p, .press);
    try testing.expectEqual(@as(u21, 'A'), shifted.codepoint);
    try testing.expect(shifted.mods.shift);
    try testing.expectEqualStrings("A", p.payload(shifted.text));
    try K.key(fc, kb, 6, 0, key_a, .released);
    try K.modifiers(fc, kb, 7, 0, 0, 0, 0);

    const P = wl.wl_pointer.server;
    try P.enter(fc, ptr, 8, surf, .fromInt(10), .fromInt(20));
    try P.frame(fc, ptr);
    // `expectEvent` drops the rest of a batch, so only the move (which
    // needs the enter's focus) is checked.
    const mv = try expectEvent(p, .pointer_move, win);
    try testing.expectEqual([2]f32{ 10, 20 }, mv.pos_px);
    try P.button(fc, ptr, 9, 0, seat_mod.BTN.left, .pressed);
    try P.frame(fc, ptr);
    const bt = try expectEvent(p, .pointer_button, win);
    try testing.expect(bt.pressed and bt.button == .left and bt.clicks == 1);
    try P.axisSource(fc, ptr, .wheel);
    try P.axisValue120(fc, ptr, .vertical_scroll, 120);
    try P.axis(fc, ptr, 0, .vertical_scroll, .fromInt(10));
    try P.frame(fc, ptr);
    const sc = try expectEvent(p, .scroll, win);
    try testing.expectEqual(@as(f32, 1), sc.dy);

    const T = wl.wl_touch.server;
    try T.down(fc, tch, 10, 0, surf, 3, .fromInt(5), .fromInt(6));
    try T.frame(fc, tch);
    const td = try expectEvent(p, .touch, win);
    try testing.expectEqual(types.Phase.begin, td.phase);
    try testing.expectEqual([2]f32{ 5, 6 }, td.pos_px);

    // Losing focus releases nothing that is not held, and stops repeat.
    try K.leave(fc, kb, 11, surf);
    try testing.expect(!(try expectEvent(p, .window_focus, win)).focused);
}

/// Writes all of `data` to a non-blocking `fd`, waiting out EAGAIN.
fn writeAllPipe(fd: i32, data: []const u8) !void {
    var done: usize = 0;
    while (done < data.len) {
        const rc = linux.write(fd, data[done..].ptr, data.len - done);
        switch (linux.errno(rc)) {
            .SUCCESS => done += rc,
            .AGAIN, .INTR => {
                var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                _ = linux.poll(&pfd, 1, 1000);
            },
            else => return error.Unexpected,
        }
    }
}

/// Reads a non-blocking `fd` to EOF.
fn readAllPipe(fd: i32, out: *std.ArrayList(u8)) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return;
                try out.appendSlice(testing.allocator, buf[0..rc]);
            },
            .AGAIN, .INTR => {
                var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
                if (linux.poll(&pfd, 1, 2000) == 0) return error.Timeout;
            },
            else => return error.Unexpected,
        }
    }
}

test "selection: write uses the latest input serial; send, paste, large paste, primary" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &selection_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const dev = rig.peer.id(wl.wl_data_device);
    const surf = rig.peer.id(wl.wl_surface);
    const kb = rig.peer.id(wl.wl_keyboard);
    rig.peer.keep_fds = true;

    // A key press makes 42 the newest serial.
    try wl.wl_keyboard.server.enter(fc, kb, 41, surf, &.{});
    try wl.wl_keyboard.server.key(fc, kb, 42, 0, 30, .pressed);
    _ = try expectEvent(p, .key, win);
    try p.submit(.{ .clipboard_write = .{ .which = .clipboard, .items = &.{.{ .mime = .text_utf8, .data = "hello" }} } });
    _ = try rig.peer.waitFor(wl.wl_data_device, .set_selection, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 42), rig.peer.last_serial);
    var offered: usize = 0;
    for (rig.peer.log.items) |s| {
        if (std.mem.eql(u8, s.iface, wl.wl_data_source.name) and s.opcode == @intFromEnum(wl.wl_data_source.Request.offer)) offered += 1;
    }
    try testing.expectEqual(@as(usize, 5), offered);

    // Another client pastes: the source writes our bytes into its pipe.
    const src = rig.peer.id(wl.wl_data_source);
    const sp = try pipe_transfer.pipe();
    defer _ = linux.close(sp[0]);
    try wl.wl_data_source.server.send(fc, src, "UTF8_STRING", sp[1]);
    _ = linux.close(sp[1]);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try readAllPipe(sp[0], &got);
    try testing.expectEqualStrings("hello", got.items);

    // While we own it, reads come from our copy.
    try p.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 1 } });
    const own = try expectEvent(p, .clipboard_data, null);
    try testing.expectEqualStrings("hello", p.payload(own.data));

    // Another client takes the selection.
    const offer_id: u32 = 0xff000001;
    try rig.peer.ids.put(testing.allocator, offer_id, wl.wl_data_offer.name);
    try wl.wl_data_source.server.cancelled(fc, src);
    try wl.wl_data_device.server.dataOffer(fc, dev, @enumFromInt(offer_id));
    try wl.wl_data_offer.server.offer(fc, @enumFromInt(offer_id), "text/plain");
    try wl.wl_data_offer.server.offer(fc, @enumFromInt(offer_id), "UTF8_STRING");
    try wl.wl_data_device.server.selection(fc, dev, @enumFromInt(offer_id));
    try testing.expectEqual(clipboard.Selection.clipboard, try expectEvent(p, .clipboard_changed, null));

    try p.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 5 } });
    _ = try rig.peer.waitFor(wl.wl_data_offer, .receive, std.time.ns_per_s);
    try testing.expectEqualStrings("UTF8_STRING", rig.peer.last_mime[0..rig.peer.last_mime_len]);
    const wfd = rig.peer.kept_fd.?;
    rig.peer.kept_fd = null;
    try writeAllPipe(wfd, "pasted");
    _ = linux.close(wfd);
    const cd = try expectEvent(p, .clipboard_data, null);
    try testing.expectEqual(@as(u32, 5), cd.request);
    try testing.expectEqualStrings("pasted", p.payload(cd.data));

    // Over the arena limit: a large payload, released by the app.
    try p.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 6 } });
    _ = try rig.peer.waitFor(wl.wl_data_offer, .receive, std.time.ns_per_s);
    const big = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(big);
    @memset(big, 'z');
    const wfd2 = rig.peer.kept_fd.?;
    rig.peer.kept_fd = null;
    try writeAllPipe(wfd2, big);
    _ = linux.close(wfd2);
    const lg = try expectEvent(p, .clipboard_data, null);
    try testing.expect(lg.data.large);
    try testing.expectEqual(big.len, p.payload(lg.data).len);
    p.release(lg.data);

    // Primary selection: same model on its own device.
    try p.submit(.{ .clipboard_write = .{ .which = .primary, .items = &.{.{ .mime = .text_utf8, .data = "sel" }} } });
    _ = try rig.peer.waitFor(wl.zwp_primary_selection_device_v1, .set_selection, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 42), rig.peer.last_serial);
}

test "selection: a read with no answer times out with empty data" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s, .transfer_timeout_ns = 50 * std.time.ns_per_ms }, &.{}, &selection_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    _ = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const dev = rig.peer.id(wl.wl_data_device);
    rig.peer.keep_fds = true;
    const offer_id: u32 = 0xff000001;
    try rig.peer.ids.put(testing.allocator, offer_id, wl.wl_data_offer.name);
    try wl.wl_data_device.server.dataOffer(fc, dev, @enumFromInt(offer_id));
    try wl.wl_data_offer.server.offer(fc, @enumFromInt(offer_id), "text/plain;charset=utf-8");
    try wl.wl_data_device.server.selection(fc, dev, @enumFromInt(offer_id));
    _ = try expectEvent(p, .clipboard_changed, null);
    try p.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 9 } });
    _ = try rig.peer.waitFor(wl.wl_data_offer, .receive, std.time.ns_per_s);
    // The peer holds the write end open and never writes.
    const cd = try expectEvent(p, .clipboard_data, null);
    try testing.expectEqual(@as(u32, 9), cd.request);
    try testing.expectEqual(@as(u32, 0), cd.data.len);
}

test "cursor: set_shape uses the last enter serial; hidden clears the cursor" {
    const globals = seat_globals ++ [_]fake.Global{.{ .name = 10, .interface = "wp_cursor_shape_manager_v1", .version = 2 }};
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const ptr = rig.peer.id(wl.wl_pointer);
    _ = rig.peer.id(wl.wp_cursor_shape_device_v1);
    try wl.wl_pointer.server.enter(fc, ptr, 77, rig.peer.id(wl.wl_surface), .fromInt(1), .fromInt(1));
    try wl.wl_pointer.server.frame(fc, ptr);
    _ = try rig.peer.waitFor(wl.wp_cursor_shape_device_v1, .set_shape, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 77), rig.peer.last_serial);
    try p.submit(.{ .set_cursor = .{ .win = win, .shape = .text } });
    _ = try rig.peer.waitFor(wl.wp_cursor_shape_device_v1, .set_shape, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 77), rig.peer.last_serial);
    try p.submit(.{ .set_cursor = .{ .win = win, .shape = .hidden } });
    _ = try rig.peer.waitFor(wl.wl_pointer, .set_cursor, std.time.ns_per_s);
}

test "portal: file dialogs, open_uri and appearance through xdg-desktop-portal" {
    const dbus_conn = @import("../dbus/conn.zig");
    var daemon: dbus_conn.TestDaemon = undefined;
    if (!try daemon.start()) return error.SkipZigTest;
    defer daemon.stop();
    var fp: @import("../portal/fake_portal.zig").FakePortal = .{
        .uris = &.{ "file:///tmp/a", "file:///tmp/b" },
        .settings = &.{.{ "color-scheme", .{ .u32 = 1 } }},
    };
    try fp.start(testing.allocator, testing.io, daemon.address());
    defer fp.stop();
    var rig: Rig = undefined;
    try rig.startWith(.{ .dbus_address = daemon.address() }, &.{}, &all_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const app = try expectEvent(p, .appearance_changed, null);
    try testing.expectEqual(event_api.ColorScheme.dark, app.scheme);
    try p.submit(.{ .open_dialog = .{ .request = 9, .kind = .open_files } });
    const res = try expectEvent(p, .dialog_result, null);
    try testing.expectEqual(9, res.request);
    try testing.expect(!res.cancelled);
    try testing.expectEqualStrings("/tmp/a\x00/tmp/b\x00", p.payload(res.paths));
    try p.submit(.{ .open_uri = "https://ziglang.org" });
    try testing.expectError(error.Unsupported, p.submit(.{ .open_uri = "javascript:x" }));
}

test "portal: without a session bus, dialogs and URIs are unsupported" {
    var rig: Rig = undefined;
    try rig.startWith(.{}, &.{}, &all_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    try testing.expectError(error.Unsupported, p.submit(.{ .open_dialog = .{ .request = 1, .kind = .open_file } }));
    try testing.expectError(error.Unsupported, p.submit(.{ .open_uri = "https://ziglang.org" }));
}

test "xdg-activation: activate with and without a token; request_attention" {
    const globals = seat_globals ++ [_]fake.Global{.{ .name = 12, .interface = "xdg_activation_v1", .version = 1 }};
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const s = std.time.ns_per_s;
    // A token from another client is used as is.
    try p.submit(.{ .activate = .{ .win = win, .token = "abc" } });
    _ = try rig.peer.waitFor(wl.xdg_activation_v1, .activate, s);
    try testing.expectEqualStrings("abc", rig.peer.last_token[0..rig.peer.last_token_len]);
    // Without one, the backend asks for a token and activates with it.
    inline for (.{ Command{ .activate = .{ .win = win, .token = null } }, Command{ .request_attention = win } }, .{ "tok1", "tok2" }) |cmd, name| {
        try p.submit(cmd);
        _ = try rig.peer.waitFor(wl.xdg_activation_token_v1, .commit, s);
        try wl.xdg_activation_token_v1.server.done(fc, rig.peer.id(wl.xdg_activation_token_v1), name);
        _ = try rig.peer.waitFor(wl.xdg_activation_v1, .activate, s);
        try testing.expectEqualStrings(name, rig.peer.last_token[0..rig.peer.last_token_len]);
        _ = try rig.peer.waitFor(wl.xdg_activation_token_v1, .destroy, s);
    }
}

test "cursor: the Xcursor fallback attaches a buffer with the hotspot at scale 2" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A 48 px cursor (24 at scale 2) with its hotspot at (10, 6).
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const header = [_]u32{ 0x72756358, 16, 0x10000, 1, 0xfffd0002, 48, 28, 36, 0xfffd0002, 48, 1, 48, 48, 10, 6, 0 };
    for (header) |v| {
        var bb: [4]u8 = undefined;
        std.mem.writeInt(u32, &bb, v, .little);
        try file.appendSlice(testing.allocator, &bb);
    }
    try file.appendNTimes(testing.allocator, 0xff, 48 * 48 * 4);
    try tmp.dir.createDirPath(testing.io, "icons/test/cursors");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "icons/test/cursors/left_ptr", .data = file.items });
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &root);
    const icons = try std.fmt.allocPrint(testing.allocator, "{s}/icons", .{root[0..n]});
    defer testing.allocator.free(icons);
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("XCURSOR_PATH", icons);
    try env.put("XCURSOR_THEME", "test");

    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s, .environ_map = &env }, &.{}, &seat_globals, null);
    defer rig.stop();
    _ = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    try wl.wp_fractional_scale_v1.server.preferredScale(fc, rig.peer.id(wl.wp_fractional_scale_v1), 240);
    const ptr = rig.peer.id(wl.wl_pointer);
    const win_surface = rig.peer.id(wl.wl_surface);
    try wl.wl_pointer.server.enter(fc, ptr, 88, win_surface, .fromInt(5), .fromInt(5));
    try wl.wl_pointer.server.frame(fc, ptr);
    _ = try rig.peer.waitFor(wl.wl_surface, .set_buffer_scale, std.time.ns_per_s);
    try testing.expectEqual(@as(?i32, 2), rig.peer.last_scale);
    _ = try rig.peer.waitFor(wl.wl_pointer, .set_cursor, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 88), rig.peer.last_serial);
    try testing.expectEqual([2]i32{ 5, 3 }, rig.peer.last_hotspot);
}

test "cursor: an animated theme cursor steps its frames and stops on leave" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Two 24 px frames, 20 ms each, with hotspots (2, 3) and (7, 9).
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const px = 24 * 24 * 4;
    const second = 16 + 2 * 12 + 36 + px;
    const header = [_]u32{ 0x72756358, 16, 0x10000, 2, 0xfffd0002, 24, 40, 0xfffd0002, 24, second };
    const frames = [_][9]u32{
        .{ 36, 0xfffd0002, 24, 1, 24, 24, 2, 3, 20 },
        .{ 36, 0xfffd0002, 24, 1, 24, 24, 7, 9, 20 },
    };
    var bb: [4]u8 = undefined;
    for (header) |v| {
        std.mem.writeInt(u32, &bb, v, .little);
        try file.appendSlice(testing.allocator, &bb);
    }
    for (frames) |fr| {
        for (fr) |v| {
            std.mem.writeInt(u32, &bb, v, .little);
            try file.appendSlice(testing.allocator, &bb);
        }
        try file.appendNTimes(testing.allocator, 0xff, px);
    }
    try tmp.dir.createDirPath(testing.io, "icons/test/cursors");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "icons/test/cursors/left_ptr", .data = file.items });
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &root);
    const icons = try std.fmt.allocPrint(testing.allocator, "{s}/icons", .{root[0..n]});
    defer testing.allocator.free(icons);
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("XCURSOR_PATH", icons);
    try env.put("XCURSOR_THEME", "test");

    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s, .environ_map = &env }, &.{}, &seat_globals, null);
    defer rig.stop();
    _ = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const ptr = rig.peer.id(wl.wl_pointer);
    const win_surface = rig.peer.id(wl.wl_surface);
    try wl.wl_pointer.server.enter(fc, ptr, 41, win_surface, .fromInt(5), .fromInt(5));
    try wl.wl_pointer.server.frame(fc, ptr);
    _ = try rig.peer.waitFor(wl.wl_pointer, .set_cursor, std.time.ns_per_s);
    try testing.expectEqual([2]i32{ 2, 3 }, rig.peer.last_hotspot);
    _ = try rig.peer.waitFor(wl.wl_pointer, .set_cursor, std.time.ns_per_s);
    try testing.expectEqual([2]i32{ 7, 9 }, rig.peer.last_hotspot);
    try testing.expectEqual(@as(?u32, 41), rig.peer.last_serial);
    _ = try rig.peer.waitFor(wl.wl_pointer, .set_cursor, std.time.ns_per_s);
    try testing.expectEqual([2]i32{ 2, 3 }, rig.peer.last_hotspot);

    // Off the window, the animation stops.
    try wl.wl_pointer.server.leave(fc, ptr, 42, win_surface);
    try wl.wl_pointer.server.frame(fc, ptr);
    // A frame already in flight may still arrive; after that, none.
    _ = rig.peer.waitFor(wl.wl_pointer, .set_cursor, 60 * std.time.ns_per_ms) catch {};
    try testing.expectError(error.Timeout, rig.peer.waitFor(wl.wl_pointer, .set_cursor, 150 * std.time.ns_per_ms));
}

/// Waits for a `drop` event in `phase`; other events are dropped.
fn expectDrop(p: Platform, phase: clipboard.DropPhase) !clipboard.DropEvent {
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 2 * std.time.ns_per_s;
    var evs: [32]Event = undefined;
    while (true) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == .drop and e.drop.phase == phase) return e.drop;
        if (@as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) >= deadline) return error.Timeout;
        p.waitEvents(deadline);
    }
}

/// Announces a drag offer with `mimes` and copy|move, and enters `surf`.
fn enterDrag(rig: *Rig, offer_id: u32, mimes: []const [:0]const u8) !void {
    const fc = rig.peer.fc;
    try rig.peer.ids.put(testing.allocator, offer_id, wl.wl_data_offer.name);
    const offer: wl.wl_data_offer.Id = @enumFromInt(offer_id);
    const dev = rig.peer.id(wl.wl_data_device);
    try wl.wl_data_device.server.dataOffer(fc, dev, offer);
    for (mimes) |m| try wl.wl_data_offer.server.offer(fc, offer, m);
    try wl.wl_data_offer.server.sourceActions(fc, offer, .{ .copy = true, .move = true });
    try wl.wl_data_device.server.enter(fc, dev, 77, rig.peer.id(wl.wl_surface), .fromInt(10), .fromInt(20), offer);
}

test "dnd target: enter, accept and actions sent once, motion, drop reads then finish" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &selection_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const dev = rig.peer.id(wl.wl_data_device);
    rig.peer.keep_fds = true;
    const offer_id: u32 = 0xff000001;
    try enterDrag(&rig, offer_id, &.{ "text/uri-list", "text/plain", "application/x-zigguro-internal" });

    const en = try expectDrop(p, .enter);
    try testing.expectEqual(win, en.win);
    try testing.expectEqual([2]f32{ 10, 20 }, en.pos_px);
    try testing.expectEqual(clipboard.DragActions{ .copy = true, .move = true }, en.allowed);
    // Another client's private type is not listed.
    const ids = p.payload(en.mimes);
    try testing.expectEqual(@as(usize, 4), ids.len);
    try testing.expectEqual(@intFromEnum(clipboard.MimeId.uri_list), std.mem.readInt(u16, ids[0..2], .little));

    try p.submit(.{ .set_drop_effect = .{ .win = win, .accept = .uri_list, .effect = .{ .copy = true } } });
    _ = try rig.peer.waitFor(wl.wl_data_offer, .accept, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 77), rig.peer.last_serial);
    try testing.expectEqualStrings("text/uri-list", rig.peer.last_accept.?[0..rig.peer.last_accept_len]);
    _ = try rig.peer.waitFor(wl.wl_data_offer, .set_actions, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 1), rig.peer.last_actions);
    // The same answer again sends nothing.
    const before = rig.peer.log.items.len;
    try p.submit(.{ .set_drop_effect = .{ .win = win, .accept = .uri_list, .effect = .{ .copy = true } } });
    try wl.wl_data_device.server.motion(fc, dev, 0, .fromInt(30), .fromInt(40));
    const ov = try expectDrop(p, .over);
    try testing.expectEqual([2]f32{ 30, 40 }, ov.pos_px);
    try rig.b.conn.flush();
    while (try rig.peer.next(20 * std.time.ns_per_ms)) |_| {}
    for (rig.peer.log.items[before..]) |s| try testing.expect(!std.mem.eql(u8, s.iface, wl.wl_data_offer.name));

    // Drop: the payload is read through a pipe, then finish and destroy.
    try wl.wl_data_offer.server.action(fc, @enumFromInt(offer_id), .{ .copy = true });
    try wl.wl_data_device.server.drop(fc, dev);
    try wl.wl_data_device.server.leave(fc, dev);
    _ = try rig.peer.waitFor(wl.wl_data_offer, .receive, std.time.ns_per_s);
    try testing.expectEqualStrings("text/uri-list", rig.peer.last_mime[0..rig.peer.last_mime_len]);
    const wfd = rig.peer.kept_fd.?;
    rig.peer.kept_fd = null;
    try writeAllPipe(wfd, "file:///tmp/a%20b\r\n");
    _ = linux.close(wfd);
    const dr = try expectDrop(p, .drop);
    try testing.expectEqual(win, dr.win);
    try testing.expectEqual(clipboard.DragActions{ .copy = true }, dr.allowed);
    try testing.expectEqualStrings("file:///tmp/a%20b\r\n", p.payload(dr.data));
    _ = try rig.peer.waitFor(wl.wl_data_offer, .finish, std.time.ns_per_s);
    _ = try rig.peer.waitFor(wl.wl_data_offer, .destroy, std.time.ns_per_s);
}

test "dnd target: a drop with nothing accepted is a leave" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &selection_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const offer_id: u32 = 0xff000001;
    try enterDrag(&rig, offer_id, &.{"image/png"});
    _ = try expectDrop(p, .enter);
    // The app accepts a type the source does not offer: refused.
    try p.submit(.{ .set_drop_effect = .{ .win = win, .accept = .uri_list, .effect = .{ .copy = true } } });
    _ = try rig.peer.waitFor(wl.wl_data_offer, .accept, std.time.ns_per_s);
    try testing.expectEqual(@as(?[64]u8, null), rig.peer.last_accept);
    try wl.wl_data_device.server.drop(rig.peer.fc, rig.peer.id(wl.wl_data_device));
    const lv = try expectDrop(p, .leave);
    try testing.expectEqual(win, lv.win);
    _ = try rig.peer.waitFor(wl.wl_data_offer, .destroy, std.time.ns_per_s);
}

test "dnd source: start_drag offers items, send writes a large payload, finished and cancelled" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &selection_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const ptr = rig.peer.id(wl.wl_pointer);
    const surf = rig.peer.id(wl.wl_surface);

    // The drag starts from a button press: its serial starts the drag.
    try wl.wl_pointer.server.enter(fc, ptr, 8, surf, .fromInt(5), .fromInt(5));
    try wl.wl_pointer.server.button(fc, ptr, 9, 0, seat_mod.BTN.left, .pressed);
    try wl.wl_pointer.server.frame(fc, ptr);
    _ = try expectEvent(p, .pointer_button, win);

    const big = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*c, i| c.* = @truncate(i);
    try p.submit(.{ .start_drag = .{ .win = win, .items = &.{ .{ .mime = .uri_list, .data = big }, .{ .mime = .zigguro_internal, .data = "tab:3" } }, .allowed = .{ .copy = true, .move = true } } });
    _ = try rig.peer.waitFor(wl.wl_data_source, .set_actions, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 3), rig.peer.last_actions);
    _ = try rig.peer.waitFor(wl.wl_data_device, .start_drag, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 9), rig.peer.last_serial);

    // The target reads 1 MiB: written in pieces off the UI thread.
    const src = rig.peer.id(wl.wl_data_source);
    const sp = try pipe_transfer.pipe();
    defer _ = linux.close(sp[0]);
    try wl.wl_data_source.server.send(fc, src, "text/uri-list", sp[1]);
    _ = linux.close(sp[1]);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try readAllPipe(sp[0], &got);
    try testing.expectEqualSlices(u8, big, got.items);

    try wl.wl_data_source.server.action(fc, src, .{ .move = true });
    try wl.wl_data_source.server.dndDropPerformed(fc, src);
    try wl.wl_data_source.server.dndFinished(fc, src);
    const fin = try expectDrop(p, .source_finished);
    try testing.expectEqual(win, fin.win);
    try testing.expectEqual(clipboard.DragActions{ .move = true }, fin.allowed);
    _ = try rig.peer.waitFor(wl.wl_data_source, .destroy, std.time.ns_per_s);

    // A second drag that the compositor cancels finishes with no action.
    try p.submit(.{ .start_drag = .{ .win = win, .items = &.{.{ .mime = .text_utf8, .data = "x" }}, .allowed = .{ .copy = true } } });
    _ = try rig.peer.waitFor(wl.wl_data_device, .start_drag, std.time.ns_per_s);
    try wl.wl_data_source.server.cancelled(fc, rig.peer.id(wl.wl_data_source));
    const cn = try expectDrop(p, .source_finished);
    try testing.expectEqual(clipboard.DragActions{}, cn.allowed);
}

test "dnd: a private type round-trips between our own windows" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &selection_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    rig.peer.keep_fds = true;
    try p.submit(.{ .start_drag = .{ .win = win, .items = &.{.{ .mime = .zigguro_internal, .data = "tab:7" }}, .allowed = .{ .move = true } } });
    _ = try rig.peer.waitFor(wl.wl_data_device, .start_drag, std.time.ns_per_s);
    const src = rig.peer.id(wl.wl_data_source);

    // The compositor offers our own source back to us.
    const offer_id: u32 = 0xff000002;
    try enterDrag(&rig, offer_id, &.{"application/x-zigguro-internal"});
    const en = try expectDrop(p, .enter);
    try testing.expectEqual(@intFromEnum(clipboard.MimeId.zigguro_internal), std.mem.readInt(u16, p.payload(en.mimes)[0..2], .little));
    try p.submit(.{ .set_drop_effect = .{ .win = win, .accept = .zigguro_internal, .effect = .{ .move = true } } });
    _ = try rig.peer.waitFor(wl.wl_data_offer, .set_actions, std.time.ns_per_s);
    try wl.wl_data_offer.server.action(fc, @enumFromInt(offer_id), .{ .move = true });
    try wl.wl_data_device.server.drop(fc, rig.peer.id(wl.wl_data_device));
    _ = try rig.peer.waitFor(wl.wl_data_offer, .receive, std.time.ns_per_s);
    const rfd = rig.peer.kept_fd.?;
    rig.peer.kept_fd = null;
    // Play the compositor: hand the target's pipe to our source.
    try wl.wl_data_source.server.send(fc, src, "application/x-zigguro-internal", rfd);
    _ = linux.close(rfd);
    const dr = try expectDrop(p, .drop);
    try testing.expectEqualStrings("tab:7", p.payload(dr.data));
    try testing.expectEqual(clipboard.DragActions{ .move = true }, dr.allowed);
    try wl.wl_data_source.server.dndFinished(fc, src);
    _ = try expectDrop(p, .source_finished);
}

/// `seat_globals` and the text input manager.
const ime_globals = seat_globals ++ [_]fake.Global{.{ .name = 10, .interface = "zwp_text_input_manager_v3", .version = 1 }};

/// IME events, with their texts copied.
const ImeSeen = struct { tag: Event.Tag, text: [16]u8 = undefined, len: usize = 0, a: i32 = 0, b: i32 = 0 };

/// Collects `n` IME events (`ime_preedit`, `text_input`,
/// `ime_delete_surrounding`) in order.
fn collectIme(p: Platform, out: []ImeSeen) !void {
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 2 * std.time.ns_per_s;
    var got: usize = 0;
    var evs: [32]Event = undefined;
    while (got < out.len) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| {
            var s: ImeSeen = .{ .tag = std.meta.activeTag(e) };
            const text: []const u8 = switch (e) {
                .ime_preedit => |x| blk: {
                    s.a = x.cursor_begin;
                    s.b = x.cursor_end;
                    break :blk p.payload(x.text);
                },
                .text_input => |x| p.payload(x.text),
                .ime_delete_surrounding => |x| blk: {
                    s.a = @intCast(x.before_bytes);
                    s.b = @intCast(x.after_bytes);
                    break :blk "";
                },
                else => continue,
            };
            s.len = @min(text.len, s.text.len);
            @memcpy(s.text[0..s.len], text[0..s.len]);
            if (got == out.len) return error.TooManyEvents;
            out[got] = s;
            got += 1;
        }
        if (got >= out.len) break;
        if (@as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) >= deadline) return error.Timeout;
        p.waitEvents(deadline);
    }
}

fn countRequests(peer: *const Peer, comptime tag: std.meta.Tag(wl.zwp_text_input_v3.Request)) usize {
    var n: usize = 0;
    for (peer.log.items) |s| {
        if (std.mem.eql(u8, s.iface, wl.zwp_text_input_v3.name) and s.opcode == @intFromEnum(tag)) n += 1;
    }
    return n;
}

test "text input: enable on enter, done order, serial mismatch resend, leave, disable" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &ime_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 320, .h = 240 });
    const fc = rig.peer.fc;
    const ti = rig.peer.id(wl.zwp_text_input_v3);
    const surf = rig.peer.id(wl.wl_surface);
    const S = wl.zwp_text_input_v3.server;

    // Before the text input enters the window nothing is sent.
    try p.submit(.{ .set_ime_state = .{ .win = win, .enabled = true, .purpose = .password, .caret_rect_px = .{ .x = 30, .y = 40, .w = 2, .h = 20 }, .surrounding = .{ .text = "héllo", .cursor_byte = 3, .anchor_byte = 3 } } });
    try testing.expectEqual(null, try rig.peer.next(50 * std.time.ns_per_ms));

    // Enter: enable, the state, commit 1.
    try S.enter(fc, ti, surf);
    _ = try rig.peer.waitFor(wl.zwp_text_input_v3, .commit, std.time.ns_per_s);
    try testing.expectEqual(1, countRequests(&rig.peer, .enable));
    try testing.expectEqual(@intFromEnum(wl.zwp_text_input_v3.ContentPurpose.password), rig.peer.last_purpose.?);
    try testing.expectEqual(3, rig.peer.last_ime_cursor.?);
    try testing.expectEqual([2]i32{ 30, 40 }, rig.peer.last_rect);

    // A batch for our state: delete, commit, then the new preedit.
    try S.deleteSurroundingText(fc, ti, 1, 0);
    try S.commitString(fc, ti, "你");
    try S.preeditString(fc, ti, "hao", 0, 3);
    try S.done(fc, ti, 1);
    var seen: [3]ImeSeen = undefined;
    try collectIme(p, &seen);
    try testing.expectEqual(Event.Tag.ime_delete_surrounding, seen[0].tag);
    try testing.expectEqual(1, seen[0].a);
    try testing.expectEqual(Event.Tag.text_input, seen[1].tag);
    try testing.expectEqualStrings("你", seen[1].text[0..seen[1].len]);
    try testing.expectEqual(Event.Tag.ime_preedit, seen[2].tag);
    try testing.expectEqualStrings("hao", seen[2].text[0..seen[2].len]);
    try testing.expectEqual(3, seen[2].b);

    // A stale serial: the commit still applies, the preedit ends, and the
    // state goes out again without a second enable.
    try S.commitString(fc, ti, "好");
    try S.done(fc, ti, 0);
    var two: [2]ImeSeen = undefined;
    try collectIme(p, &two);
    try testing.expectEqual(Event.Tag.text_input, two[0].tag);
    try testing.expectEqual(Event.Tag.ime_preedit, two[1].tag);
    try testing.expectEqual(0, two[1].len);
    _ = try rig.peer.waitFor(wl.zwp_text_input_v3, .commit, std.time.ns_per_s);
    try testing.expectEqual(1, countRequests(&rig.peer, .enable));
    try testing.expectEqual(2, countRequests(&rig.peer, .commit));

    // Leave clears a shown preedit.
    try S.preeditString(fc, ti, "x", 1, 1);
    try S.done(fc, ti, 2);
    var one: [1]ImeSeen = undefined;
    try collectIme(p, &one);
    try S.leave(fc, ti, surf);
    try collectIme(p, &one);
    try testing.expectEqual(Event.Tag.ime_preedit, one[0].tag);
    try testing.expectEqual(0, one[0].len);

    // Entering again enables again; disabling sends disable and commit.
    try S.enter(fc, ti, surf);
    _ = try rig.peer.waitFor(wl.zwp_text_input_v3, .commit, std.time.ns_per_s);
    try testing.expectEqual(2, countRequests(&rig.peer, .enable));
    try p.submit(.{ .set_ime_state = .{ .win = win, .enabled = false, .purpose = .normal, .caret_rect_px = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .surrounding = null } });
    _ = try rig.peer.waitFor(wl.zwp_text_input_v3, .disable, std.time.ns_per_s);
    _ = try rig.peer.waitFor(wl.zwp_text_input_v3, .commit, std.time.ns_per_s);
    try testing.expectEqual(4, countRequests(&rig.peer, .commit));
}

/// The globals without a decoration manager (client-side decorations),
/// with a seat.
const csd_globals = [_]fake.Global{
    .{ .name = 1, .interface = "wl_compositor", .version = 6 },
    .{ .name = 2, .interface = "xdg_wm_base", .version = 6 },
    .{ .name = 3, .interface = "wl_shm", .version = 1 },
    .{ .name = 4, .interface = "wp_viewporter", .version = 1 },
    .{ .name = 5, .interface = "wp_fractional_scale_manager_v1", .version = 1 },
    .{ .name = 6, .interface = "wl_output", .version = 4 },
    .{ .name = 7, .interface = "wl_seat", .version = 9 },
};

/// Waits for `window_decorations` and the `window_configure` after it.
fn expectDecorated(p: Platform, win: WindowId) !struct { client: bool, margins: [4]u32, size: PxSize } {
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 2 * std.time.ns_per_s;
    var deco: ?@FieldType(Event, "window_decorations") = null;
    var evs: [32]Event = undefined;
    while (true) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| switch (e) {
            .window_decorations => |d| if (d.win == win) {
                deco = d;
            },
            .window_configure => |cf| if (cf.win == win) if (deco) |d| return .{ .client = d.client, .margins = d.margins_px, .size = cf.size },
            else => {},
        };
        if (@as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) >= deadline) return error.Timeout;
        p.waitEvents(deadline);
    }
}

fn countIn(peer: *const Peer, comptime I: type, comptime tag: std.meta.Tag(I.Request)) usize {
    var n: usize = 0;
    for (peer.log.items) |s| {
        if (std.mem.eql(u8, s.iface, I.name) and s.opcode == @intFromEnum(tag)) n += 1;
    }
    return n;
}

test "decorations: no decoration global → client mode, geometry inside margins, tiled edges drop them" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &csd_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 400, .h = 300 });

    _ = try rig.peer.configure(400, 300, &.{});
    const d = try expectDecorated(p, win);
    try testing.expect(d.client);
    try testing.expectEqual([4]u32{ 12, 12, 12, 12 }, d.margins);
    try testing.expectEqual(PxSize{ .w = 424, .h = 324 }, d.size);
    _ = try rig.peer.waitFor(wl.wl_surface, .set_input_region, std.time.ns_per_s);
    try testing.expectEqual([4]i32{ 12, 12, 400, 300 }, rig.peer.last_geometry);

    // Tiled to the left half: only the right edge keeps its margin.
    _ = try rig.peer.configure(500, 600, &.{ .tiled_left, .tiled_top, .tiled_bottom });
    const t = try expectDecorated(p, win);
    try testing.expectEqual([4]u32{ 0, 0, 12, 0 }, t.margins);
    try testing.expectEqual(PxSize{ .w = 512, .h = 600 }, t.size);
    _ = try rig.peer.waitFor(wl.wl_surface, .set_input_region, std.time.ns_per_s);
    try testing.expectEqual([4]i32{ 0, 0, 500, 600 }, rig.peer.last_geometry);

    // Maximized: no margins.
    _ = try rig.peer.configure(800, 600, &.{.maximized});
    const m = try expectDecorated(p, win);
    try testing.expectEqual([4]u32{ 0, 0, 0, 0 }, m.margins);
    try testing.expectEqual(PxSize{ .w = 800, .h = 600 }, m.size);
}

test "decorations: server mode → set_mode(server_side), no margins, no geometry" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &all_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 400, .h = 300 });
    try testing.expectEqual(@as(?u32, @intFromEnum(wl.zxdg_toplevel_decoration_v1.Mode.server_side)), rig.peer.last_mode);
    try wl.zxdg_toplevel_decoration_v1.server.configure(rig.peer.fc, rig.peer.id(wl.zxdg_toplevel_decoration_v1), .server_side);
    _ = try rig.peer.configure(400, 300, &.{});
    const d = try expectDecorated(p, win);
    try testing.expect(!d.client);
    try testing.expectEqual([4]u32{ 0, 0, 0, 0 }, d.margins);
    try testing.expectEqual(PxSize{ .w = 400, .h = 300 }, d.size);
    try testing.expectEqual(0, countIn(&rig.peer, wl.xdg_surface, .set_window_geometry));

    // The compositor insists on client-side: margins appear, and the mode
    // is not sent again.
    try wl.zxdg_toplevel_decoration_v1.server.configure(rig.peer.fc, rig.peer.id(wl.zxdg_toplevel_decoration_v1), .client_side);
    _ = try rig.peer.configure(400, 300, &.{});
    const c = try expectDecorated(p, win);
    try testing.expect(c.client);
    try testing.expectEqual(PxSize{ .w = 424, .h = 324 }, c.size);
    try testing.expectEqual(1, countIn(&rig.peer, wl.zxdg_toplevel_decoration_v1, .set_mode));
}

test "decorations: title-bar press moves with its serial, margins resize, double click maximizes" {
    var rig: Rig = undefined;
    try rig.startWith(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{}, &csd_globals, null);
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 400, .h = 300 });
    _ = try rig.peer.configure(400, 300, &.{});
    _ = try expectDecorated(p, win);
    const Caption = struct {
        // A 30 px title bar under the 12 px top margin.
        fn hit(_: *anyopaque, pt: types.PxPoint) types.HitRegion {
            return if (pt.y < 42) .caption else .client;
        }
    };
    var dummy: u8 = 0;
    try p.submit(.{ .set_hit_test = .{ .win = win, .f = Caption.hit, .ctx = &dummy } });
    const fc = rig.peer.fc;
    const ptr = rig.peer.id(wl.wl_pointer);
    const P = wl.wl_pointer.server;
    const left = seat_mod.BTN.left;

    try P.enter(fc, ptr, 50, rig.peer.id(wl.wl_surface), .fromInt(100), .fromInt(20));
    try P.button(fc, ptr, 77, 0, left, .pressed);
    try P.frame(fc, ptr);
    _ = try rig.peer.waitFor(wl.xdg_toplevel, .move, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 77), rig.peer.last_serial);
    try P.button(fc, ptr, 78, 0, left, .released);
    try P.frame(fc, ptr);

    // A second press there soon after: maximize instead of a move.
    try P.button(fc, ptr, 79, 0, left, .pressed);
    try P.frame(fc, ptr);
    _ = try rig.peer.waitFor(wl.xdg_toplevel, .set_maximized, std.time.ns_per_s);
    try P.button(fc, ptr, 80, 0, left, .released);
    try P.frame(fc, ptr);

    // In the left margin: resize from the left edge.
    try P.motion(fc, ptr, 0, .fromInt(5), .fromInt(150));
    try P.button(fc, ptr, 81, 0, left, .pressed);
    try P.frame(fc, ptr);
    _ = try rig.peer.waitFor(wl.xdg_toplevel, .resize, std.time.ns_per_s);
    try testing.expectEqual(@as(?u32, 81), rig.peer.last_serial);
    try testing.expectEqual(@as(?u32, 4), rig.peer.last_edges);
    try P.button(fc, ptr, 82, 0, left, .released);
    try P.frame(fc, ptr);

    // Content gets its presses; none of the above reached the app.
    try P.motion(fc, ptr, 0, .fromInt(100), .fromInt(200));
    try P.button(fc, ptr, 83, 0, left, .pressed);
    try P.frame(fc, ptr);
    const pb = try expectEvent(p, .pointer_button, win);
    try testing.expect(pb.pressed);
    try testing.expectEqual([2]f32{ 100, 200 }, pb.pos_px);
    try testing.expectEqual(@as(u8, 1), pb.clicks);
}

test "shm: buffers share a pool with 64-byte rows; a busy buffer is destroyed at its release" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{});
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 100, .h = 50 });
    const serial = try rig.peer.configure(100, 50, &.{});
    _ = try expectEvent(p, .window_configure, win);
    const pr = try p.cpuPresenter(win);
    const argb = @import("shm.zig").fourcc_argb8888;

    const a = try pr.allocCpuBuffer(100, 50, argb);
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .create_buffer, std.time.ns_per_s);
    try testing.expectEqual(448, a.stride);
    try testing.expectEqual(448 * 50, a.pixels.len);
    try testing.expectEqual([4]i32{ 0, 100, 50, 448 }, rig.peer.last_shm_buffer);
    try testing.expectEqual(@as(?i32, 3 * 448 * 50), rig.peer.last_pool_size);
    const bb = try pr.allocCpuBuffer(100, 50, argb);
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .create_buffer, std.time.ns_per_s);
    try testing.expectEqual([4]i32{ 448 * 50, 100, 50, 448 }, rig.peer.last_shm_buffer);
    try testing.expectEqual(1, countIn(&rig.peer, wl.wl_shm, .create_pool));
    @memset(a.pixels, 0xff);

    // Presented, then released by the app: kept until the compositor
    // releases it, and never reported back.
    try pr.present(a.handle, &.{}, .none, .{ .win = win, .serial = serial });
    _ = try rig.peer.waitFor(wl.wl_surface, .commit, std.time.ns_per_s);
    const a_obj = rig.peer.id(wl.wl_buffer);
    _ = a_obj;
    pr.releaseBuffer(a.handle);
    try testing.expectEqual(0, countIn(&rig.peer, wl.wl_buffer, .destroy));
    var first: ?u32 = null;
    var it = rig.peer.ids.iterator();
    while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, wl.wl_buffer.name)) {
        if (first == null or e.key_ptr.* < first.?) first = e.key_ptr.*;
    };
    try wl.wl_buffer.server.release(rig.peer.fc, @enumFromInt(first.?));
    _ = try rig.peer.waitFor(wl.wl_buffer, .destroy, std.time.ns_per_s);
    var got: [4]surface.BufferHandle = undefined;
    try testing.expectEqual(0, pr.pollReleased(&got));
    // An idle buffer goes at once.
    pr.releaseBuffer(bb.handle);
    _ = try rig.peer.waitFor(wl.wl_buffer, .destroy, std.time.ns_per_s);
}

test "shm: an empty pool grows in place; one with live buffers is replaced" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{});
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 100, .h = 50 });
    const pr = try p.cpuPresenter(win);
    const argb = @import("shm.zig").fourcc_argb8888;
    var bufs: [3]surface.CpuBuffer = undefined;
    for (&bufs) |*x| x.* = try pr.allocCpuBuffer(100, 50, argb);
    for (bufs) |x| pr.releaseBuffer(x.handle);
    // Empty: the next, larger buffer resizes the same pool.
    const big = try pr.allocCpuBuffer(200, 100, argb);
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .resize, std.time.ns_per_s);
    try testing.expectEqual(@as(?i32, 3 * 832 * 100), rig.peer.last_pool_size);
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .create_buffer, std.time.ns_per_s);
    try testing.expectEqual([4]i32{ 0, 200, 100, 832 }, rig.peer.last_shm_buffer);
    try testing.expectEqual(1, countIn(&rig.peer, wl.wl_shm, .create_pool));
    // Not empty: a bigger one needs a new pool; the old one goes with its
    // last buffer.
    const huge = try pr.allocCpuBuffer(400, 300, argb);
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .create_buffer, std.time.ns_per_s);
    try testing.expectEqual(2, countIn(&rig.peer, wl.wl_shm, .create_pool));
    pr.releaseBuffer(big.handle);
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .destroy, std.time.ns_per_s);
    pr.releaseBuffer(huge.handle);
}

test "shm: importBuffer(.shm) wraps the caller's memfd" {
    var rig: Rig = undefined;
    try rig.start(.{ .ack_timeout_ns = 10 * std.time.ns_per_s }, &.{});
    defer rig.stop();
    const p = rig.b.platform();
    const win = try rig.window(.{ .w = 64, .h = 32 });
    const pr = try p.cpuPresenter(win);
    var m = try memfd.Memfd.create("zg-test", 4096 + 256 * 32);
    defer m.deinit();
    const h = try pr.importBuffer(&.{ .width = 64, .height = 32, .fourcc = @import("shm.zig").fourcc_xrgb8888, .modifier = 0, .kind = .shm, .planes = &.{.{ .fd = m.fd, .offset = 4096, .stride = 256 }} });
    _ = try rig.peer.waitFor(wl.wl_shm_pool, .create_buffer, std.time.ns_per_s);
    try testing.expectEqual([4]i32{ 4096, 64, 32, 256 }, rig.peer.last_shm_buffer);
    try testing.expectEqual(@as(?i32, 4096 + 256 * 32), rig.peer.last_pool_size);
    pr.releaseBuffer(h);
}
