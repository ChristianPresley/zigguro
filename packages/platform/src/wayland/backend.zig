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
//! Input, cursors, clipboard and drag-and-drop, IME, decorations and
//! activation come with their own tasks (E01.F04.S01.T02, E01.F04.S02,
//! E01.F04.S03); until then the related commands are accepted and ignored
//! (cursor, IME, hit test) or return `error.Unsupported`.

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
};

/// Ring capacity.
const ring_capacity = 4096;

/// Which interface a handler serves.
const Kind = enum { wm_base, xdg_surface, toplevel, surface, frac, frame, buffer, output };

/// A window and its presenter, allocated together so pointers stay put.
const Slot = struct {
    win: Window,
    presenter: ShmPresenter,
};

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

    mutex: Io.Mutex = .init,
    slots: std.ArrayList(*Slot) = .empty,
    outputs: std.ArrayList(*Output) = .empty,
    next_win: u32 = 1,
    /// Events produced under the mutex, moved to `ring` by the platform
    /// thread.
    staged: std.ArrayList(Event) = .empty,
    /// Our own selections, answering reads until the data device lands.
    clip: [2][]ClipItemOwned = .{ &.{}, &.{} },

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
        for (registry.globals.items) |g| if (std.mem.eql(u8, g.interface, wl.wl_output.name)) try b.addOutput(g);
        registry.onGlobalAdd(.{ .ctx = b, .on_add = onGlobalAdd });
        registry.onGlobalRemove(.{ .ctx = b, .on_remove = onGlobalRemove });
        // Outputs describe themselves in reply to the bind.
        try conn.roundtrip();

        const ep = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(ep) != .SUCCESS) return error.SystemResources;
        b.epfd = @intCast(ep);
        errdefer _ = linux.close(b.epfd);
        try b.watch(conn.pollFd(), 0);
        try b.watch(b.thread_wake.handle().fd, 1);
        b.thread = try std.Thread.spawn(.{}, threadMain, .{b});
        return b;
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
        const app_id = try b.gpa.dupeZ(u8, opts.app_id);
        defer b.gpa.free(app_id);
        try wl.xdg_toplevel.setAppId(c, tl, app_id);
        if (opts.min_size) |m| {
            w.min_logical = m;
            try wl.xdg_toplevel.setMinSize(c, tl, @intCast(m.w), @intCast(m.h));
        }
        if (opts.parent) |p| if (b.find(p)) |ps| try wl.xdg_toplevel.setParent(c, tl, ps.win.toplevel);
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
        if (w.frame_cb) |cb| c.setHandler(@intFromEnum(cb), null);
        if (w.frac) |f| wl.wp_fractional_scale_v1.destroy(c, f) catch {};
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
        if (s.large) return &.{};
        return b.arena.get(s);
    }

    /// See `Platform.VTable.release`. Large payloads come with the data
    /// device; nothing to free yet.
    pub fn release(_: *WaylandBackend, _: types.PayloadSlice) void {}

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
        b.lock();
        for (b.slots.items) |s| b.destroySlot(s);
        b.slots.clearRetainingCapacity();
        b.conn.flush() catch {};
        b.unlock();
        if (b.epfd >= 0) _ = linux.close(b.epfd);
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
        for (&b.clip) |items| freeClip(gpa, items);
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
            if (w.applied_destination == null or !std.meta.eql(w.applied_destination.?, w.logical)) {
                try wl.wp_viewport.setDestination(c, v, @intCast(w.logical.w), @intCast(w.logical.h));
                w.applied_destination = w.logical;
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
            .set_cursor => |t| _ = try b.lookup(t.win),
            .set_ime_state => |t| _ = try b.lookup(t.win),
            .set_hit_test => |t| _ = try b.lookup(t.win),
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
            },
            .clipboard_read => |t| {
                // Only our own selection until the data device (E01.F04.S03).
                var data: types.PayloadSlice = .empty;
                for (b.clip[@intFromEnum(t.which)]) |it| if (it.mime == t.mime) {
                    data = b.arena.put(it.data) catch .empty;
                    break;
                };
                try b.stage(.{ .clipboard_data = .{ .request = t.request, .data = data, .mime = t.mime } });
            },
            .begin_move, .begin_resize, .show_window_menu, .start_drag, .set_drop_effect, .activate, .request_attention, .open_dialog, .open_uri => return error.Unsupported,
        }
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
        var moving: std.ArrayList(Event) = .empty;
        defer moving.deinit(b.gpa);
        var evs: [4]linux.epoll_event = undefined;
        while (!b.stopping.load(.acquire)) {
            if (!b.dead.load(.acquire)) b.pump() catch |err| b.fail(err);
            // Move staged events out under the lock, push them without it.
            b.lock();
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
            for (evs[0..rc]) |e| if (e.data.u64 == 1) b.thread_wake.consume();
        }
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

    /// Milliseconds until the earliest overdue ack, or -1. Mutex held.
    fn nextTimeoutLocked(b: *WaylandBackend) i32 {
        var next: ?u64 = null;
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
                    try s.presenter.released.append(b.gpa, @enumFromInt(buf.handle));
                    return;
                };
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
        }
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
        try b.stage(.{ .window_configure = .{ .win = w.id, .size = cf.size, .scale = cf.scale, .state = cf.state, .serial = cf.serial, .screen_origin_px = null } });
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

    const Seen = struct { iface: []const u8, obj: u32, opcode: u16 };
    const OutputSpec = struct { w: i32, h: i32, refresh: i32, scale: i32, name: [:0]const u8 };

    fn init() !Peer {
        var p: Peer = .{ .fc = try fake.FakeCompositor.init(testing.allocator) };
        try p.ids.put(testing.allocator, 1, wl.wl_display.name);
        return p;
    }

    fn deinit(p: *Peer) void {
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
            if (comptime std.mem.eql(u8, f.name, "fd")) _ = linux.close(v);
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
                if (std.mem.eql(u8, s.iface, wl.wl_registry.name) and s.opcode == 0) {
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
};

/// A backend connected to a fresh `Peer`.
const Rig = struct {
    peer: Peer,
    b: *WaylandBackend,

    fn start(rig: *Rig, opts: InitOptions, outputs: []const Peer.OutputSpec) !void {
        rig.peer = try Peer.init();
        errdefer rig.peer.deinit();
        rig.peer.outputs = outputs;
        const t = try std.Thread.spawn(.{}, Peer.serveInitThread, .{ &rig.peer, &all_globals, 2 });
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
    const t = try std.Thread.spawn(.{}, Peer.serveInitThread, .{ &peer, &globals, 1 });
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
