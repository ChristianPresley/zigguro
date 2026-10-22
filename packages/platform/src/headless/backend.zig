//! The headless backend: windows without a display, a virtual clock with a
//! 60 Hz virtual vsync, in-memory clipboard, scripted dialogs and CPU
//! presentation into readable frames. Tests drive it with `inject*`; the
//! `zg` CLI uses it because it opens no window. It is the reference that
//! every OS backend is checked against (`testing/conformance.zig`).
//!
//! There is no platform thread: commands run synchronously inside
//! `submit`, under one mutex, so every result is deterministic.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const types = @import("../api/types.zig");
const event_api = @import("../api/event.zig");
const window_api = @import("../api/window.zig");
const surface = @import("../api/surface.zig");
const clipboard = @import("../api/clipboard.zig");
const native_api = @import("../api/native.zig");
const platform_api = @import("../api/platform.zig");
const PayloadArena = @import("../queue/payload_arena.zig").PayloadArena;
const arena_mod = @import("../queue/payload_arena.zig");
const Wake = @import("../queue/wake.zig").Wake;
const trace = @import("trace.zig");

const Event = event_api.Event;
const Command = window_api.Command;
const WindowId = types.WindowId;
const PayloadSlice = types.PayloadSlice;
const PxSize = types.PxSize;
const Platform = platform_api.Platform;
const Error = platform_api.Error;

/// DRM fourcc `AR24`: bytes B, G, R, A in memory.
pub const fourcc_argb8888: u32 = 0x34325241;
/// DRM fourcc `AB24`: bytes R, G, B, A in memory.
pub const fourcc_abgr8888: u32 = 0x34324241;

/// A scripted answer to the next `Command.open_dialog`.
pub const DialogAnswer = struct {
    /// Paths to return.
    paths: []const []const u8 = &.{},
    /// Report the dialog as cancelled.
    cancelled: bool = false,
};

/// Options for `Headless.init`.
pub const HeadlessOptions = struct {
    /// Block in `waitEvents` on real time instead of advancing the virtual
    /// clock to the deadline.
    real_time: bool = false,
    /// Virtual refresh period.
    refresh_ns: u32 = 16_666_667,
    /// Size of the single virtual monitor.
    monitor_size: PxSize = .{ .w = 1920, .h = 1080 },
    /// Scale of the virtual monitor.
    scale: types.Scale = .{},
    /// Answers for successive dialog requests; cancelled once exhausted.
    dialog_script: []const DialogAnswer = &.{},
    /// When set, every delivered event is recorded here as a `.zgtrace`
    /// (the header is written by `init`).
    record: ?*Io.Writer = null,
};

/// A presented frame, as RGBA8 rows.
pub const FrameImage = struct {
    /// Width in pixels.
    width: u32,
    /// Height in pixels.
    height: u32,
    /// Bytes per row (`width * 4`).
    stride: u32,
    /// `stride * height` bytes, valid until the next present to the window.
    pixels: []const u8,
};

const CpuBuf = struct {
    w: u32,
    h: u32,
    stride: u32,
    fourcc: u32,
    pixels: []u8,
};

const WinPresenter = struct {
    presenter: surface.Presenter,
    h: *Headless,
    win: WindowId,
    buffers: std.AutoArrayHashMapUnmanaged(u32, CpuBuf) = .empty,
    released: std.ArrayList(surface.BufferHandle) = .empty,
    next: u32 = 1,
};

const Win = struct {
    title: []u8,
    size: PxSize,
    restore_size: PxSize,
    min_size: ?PxSize,
    state: window_api.WindowState = .{ .activated = true },
    cursor: @import("../api/cursor.zig").CursorShape = .default,
    ime_enabled: bool = false,
    wants_frame: bool = true,
    frame: ?CpuBuf = null,
    presenter: *WinPresenter,
};

const ClipItemOwned = struct { mime: clipboard.MimeId, data: []u8 };

/// The headless backend.
pub const Headless = struct {
    gpa: Allocator,
    io: Io,
    opts: HeadlessOptions,
    mutex: Io.Mutex = .init,
    events: std.Deque(Event) = .empty,
    arena: PayloadArena,
    large: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    next_large: u32 = 0,
    windows: std.AutoArrayHashMapUnmanaged(u32, Win) = .empty,
    next_win: u32 = 1,
    serial: u32 = 0,
    focused: ?WindowId = null,
    clock_ns: u64 = 0,
    next_vsync: u64,
    present_seq: u64 = 0,
    record_clock: u64 = 0,
    clip: [2][]ClipItemOwned = .{ &.{}, &.{} },
    dialog_index: usize = 0,
    wake_pending: std.atomic.Value(bool) = .init(false),
    wake_obj: Wake,
    sink: surface.HeadlessSink,
    hooks: native_api.NativeHooks,
    /// URIs passed to `Command.open_uri`, for tests.
    opened_uris: std.ArrayList([]u8) = .empty,
    /// Number of `Command.request_attention` calls.
    attention_requests: u32 = 0,

    /// Creates a headless platform.
    pub fn init(gpa: Allocator, io: Io, opts: HeadlessOptions) !*Headless {
        const h = try gpa.create(Headless);
        errdefer gpa.destroy(h);
        var arena = try PayloadArena.init(gpa);
        errdefer arena.deinit(gpa);
        var wake_obj = try Wake.init(io);
        errdefer wake_obj.deinit();
        h.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .arena = arena,
            .next_vsync = opts.refresh_ns,
            .wake_obj = wake_obj,
            .sink = .{ .ptr = h, .write = sinkWrite },
            .hooks = .{
                .ptr = h,
                .win32SetMessageHook = noHook,
                .win32CreateMessageWindow = noMsgWindow,
                .win32DestroyMessageWindow = noDestroy,
                .windowHandle = windowHandle,
            },
        };
        if (opts.record) |w| try trace.writeHeader(w);
        return h;
    }

    /// The type-erased interface.
    pub fn platform(h: *Headless) Platform {
        return Platform.fromImpl(Headless, h);
    }

    // ---- Platform.VTable ----

    /// See `Platform.VTable.createWindow`.
    pub fn createWindow(h: *Headless, opts: window_api.WindowOptions) Error!WindowId {
        h.lock();
        defer h.unlock();
        const id: WindowId = @enumFromInt(h.next_win);
        const owned_title = try h.gpa.dupe(u8, opts.title);
        errdefer h.gpa.free(owned_title);
        const wp = try h.gpa.create(WinPresenter);
        errdefer h.gpa.destroy(wp);
        wp.* = .{ .presenter = .{ .ptr = wp, .vtable = &presenter_vtable }, .h = h, .win = id };
        try h.windows.put(h.gpa, @intFromEnum(id), .{ .title = owned_title, .size = opts.size, .restore_size = opts.size, .min_size = opts.min_size, .presenter = wp });
        h.next_win += 1;
        const prev = h.focused;
        h.focused = id;
        if (prev) |p| if (h.windows.getPtr(@intFromEnum(p))) |pw| {
            pw.state.activated = false;
            try h.pushEvent(.{ .window_focus = .{ .win = p, .focused = false } });
        };
        try h.configure(id);
        try h.pushEvent(.{ .window_focus = .{ .win = id, .focused = true } });
        return id;
    }

    /// See `Platform.VTable.destroyWindow`.
    pub fn destroyWindow(h: *Headless, win: WindowId) void {
        h.lock();
        defer h.unlock();
        var kv = h.windows.fetchSwapRemove(@intFromEnum(win)) orelse return;
        h.freeWindow(&kv.value);
        if (h.focused == win) h.focused = null;
    }

    /// See `Platform.VTable.submit`. Runs the command at once.
    pub fn submit(h: *Headless, cmd: Command) Error!void {
        h.lock();
        defer h.unlock();
        try h.run(cmd);
    }

    /// See `Platform.VTable.surfaceTarget`: frames written to the sink
    /// become `lastFrame`.
    pub fn surfaceTarget(h: *Headless, win: WindowId) Error!surface.SurfaceTarget {
        h.lock();
        defer h.unlock();
        if (!h.windows.contains(@intFromEnum(win))) return error.InvalidWindow;
        return .{ .headless = &h.sink };
    }

    /// See `Platform.VTable.cpuPresenter`.
    pub fn cpuPresenter(h: *Headless, win: WindowId) Error!*surface.Presenter {
        h.lock();
        defer h.unlock();
        const w = h.windows.getPtr(@intFromEnum(win)) orelse return error.InvalidWindow;
        return &w.presenter.presenter;
    }

    /// See `Platform.VTable.native`: every hook is unsupported.
    pub fn native(h: *Headless) *const native_api.NativeHooks {
        return &h.hooks;
    }

    /// See `Platform.VTable.payload`.
    pub fn payload(h: *Headless, s: PayloadSlice) []const u8 {
        if (!s.large) return h.arena.get(s);
        h.lock();
        defer h.unlock();
        return h.large.get(s.off) orelse &.{};
    }

    /// See `Platform.VTable.release`.
    pub fn release(h: *Headless, s: PayloadSlice) void {
        if (!s.large) return;
        h.lock();
        defer h.unlock();
        if (h.large.fetchRemove(s.off)) |kv| h.gpa.free(kv.value);
    }

    /// See `Platform.VTable.monitors`: one virtual monitor.
    pub fn monitors(h: *Headless, out: []types.MonitorInfo) usize {
        if (out.len > 0) {
            const sz = h.opts.monitor_size;
            out[0] = .{
                .id = 1,
                .rect_px = .{ .x = 0, .y = 0, .w = sz.w, .h = sz.h },
                .work_px = .{ .x = 0, .y = 0, .w = sz.w, .h = sz.h },
                .scale = h.opts.scale,
                .refresh_mhz = @intCast(@divTrunc(@as(u64, 1_000_000_000_000), h.opts.refresh_ns)),
                .primary = true,
            };
            const name = "HEADLESS-1";
            @memcpy(out[0].name_buf[0..name.len], name);
            out[0].name_len = name.len;
        }
        return 1;
    }

    /// See `Platform.VTable.pollEvents`.
    pub fn pollEvents(h: *Headless, out: []Event) usize {
        h.lock();
        defer h.unlock();
        _ = h.arena.flip();
        if (h.wake_pending.swap(false, .acquire)) h.pushEvent(.wake) catch {};
        var n: usize = 0;
        while (n < out.len) : (n += 1) {
            const ev = h.events.popFront() orelse break;
            h.arena.retire(&ev);
            out[n] = ev;
        }
        return n;
    }

    /// See `Platform.VTable.waitEvents`. In virtual time it never sleeps:
    /// with nothing pending it advances the clock to `deadline_ns`.
    pub fn waitEvents(h: *Headless, deadline_ns: ?u64) void {
        if (h.opts.real_time) return h.waitReal(deadline_ns);
        h.lock();
        defer h.unlock();
        if (h.events.len > 0 or h.wake_pending.load(.acquire)) return;
        if (deadline_ns) |d| if (d > h.clock_ns) h.advance(d - h.clock_ns) catch {};
    }

    fn waitReal(h: *Headless, deadline_ns: ?u64) void {
        while (true) {
            h.lock();
            const ready = h.events.len > 0 or h.wake_pending.load(.acquire);
            h.unlock();
            if (ready) return;
            var timeout: ?u64 = null;
            if (deadline_ns) |d| {
                const t: u64 = @intCast(@max(0, Io.Clock.awake.now(h.io).nanoseconds));
                if (t >= d) return;
                timeout = d - t;
            }
            if (h.wake_obj.wait(timeout)) h.wake_obj.consume() else return;
        }
    }

    /// See `Platform.VTable.wake`.
    pub fn wake(h: *Headless) void {
        h.wake_pending.store(true, .release);
        h.wake_obj.signal();
    }

    /// See `Platform.VTable.deinit`.
    pub fn deinit(h: *Headless) void {
        const gpa = h.gpa;
        for (h.windows.values()) |*w| h.freeWindow(w);
        h.windows.deinit(gpa);
        var it = h.large.valueIterator();
        while (it.next()) |v| gpa.free(v.*);
        h.large.deinit(gpa);
        for (&h.clip) |items| freeClip(gpa, items);
        for (h.opened_uris.items) |u| gpa.free(u);
        h.opened_uris.deinit(gpa);
        h.events.deinit(gpa);
        h.arena.deinit(gpa);
        h.wake_obj.deinit();
        gpa.destroy(h);
    }

    // ---- test driver ----

    /// Queues `ev` as if the OS produced it. Its payload slices must come
    /// from `putPayload` on this backend.
    pub fn inject(h: *Headless, ev: Event) !void {
        h.lock();
        defer h.unlock();
        try h.pushEvent(ev);
    }

    /// Queues `ev` with its payload slices rewritten to `bytes`, which holds
    /// every slice's bytes concatenated in field order (lengths from `ev`).
    pub fn injectPayload(h: *Headless, ev: Event, bytes: []const u8) !void {
        h.lock();
        defer h.unlock();
        var e = ev;
        var ctx: Rewrite = .{ .h = h, .bytes = bytes };
        arena_mod.forEachPayloadPtr(&e, &ctx, Rewrite.one);
        if (ctx.err) |err| return err;
        if (ctx.used != bytes.len) return error.PayloadLengthMismatch;
        try h.pushEvent(e);
    }

    const Rewrite = struct {
        h: *Headless,
        bytes: []const u8,
        used: usize = 0,
        err: ?anyerror = null,
        fn one(c: *Rewrite, s: *PayloadSlice) void {
            if (c.used + s.len > c.bytes.len) {
                c.err = error.PayloadLengthMismatch;
                return;
            }
            const part = c.bytes[c.used..][0..s.len];
            c.used += s.len;
            s.* = c.h.putPayloadLocked(part) catch |e| {
                c.err = e;
                return;
            };
        }
    };

    /// Queues committed text for `win` (`Event.text_input`). Invalid UTF-8
    /// is replaced with U+FFFD.
    pub fn injectText(h: *Headless, win: WindowId, utf8: []const u8) !void {
        h.lock();
        defer h.unlock();
        const s = h.arena.putUtf8(utf8) catch try h.putLarge(utf8);
        try h.pushEvent(.{ .text_input = .{ .win = win, .text = s } });
    }

    /// Copies `bytes` into payload storage for an event built by a test.
    pub fn putPayload(h: *Headless, bytes: []const u8) !PayloadSlice {
        h.lock();
        defer h.unlock();
        return h.putPayloadLocked(bytes);
    }

    fn putPayloadLocked(h: *Headless, bytes: []const u8) !PayloadSlice {
        return h.arena.put(bytes) catch h.putLarge(bytes);
    }

    fn putLarge(h: *Headless, bytes: []const u8) !PayloadSlice {
        const copy = try h.gpa.dupe(u8, bytes);
        errdefer h.gpa.free(copy);
        const id = h.next_large;
        try h.large.put(h.gpa, id, copy);
        h.next_large = (h.next_large + 1) & std.math.maxInt(u30);
        return .{ .off = @intCast(id), .large = true, .len = @intCast(bytes.len) };
    }

    /// Replaces a selection as if another application copied `bytes`, and
    /// queues `Event.clipboard_changed`.
    pub fn setClipboard(h: *Headless, which: clipboard.Selection, mime: clipboard.MimeId, bytes: []const u8) !void {
        h.lock();
        defer h.unlock();
        const items = try h.gpa.alloc(ClipItemOwned, 1);
        errdefer h.gpa.free(items);
        items[0] = .{ .mime = mime, .data = try h.gpa.dupe(u8, bytes) };
        freeClip(h.gpa, h.clip[@intFromEnum(which)]);
        h.clip[@intFromEnum(which)] = items;
        try h.pushEvent(.{ .clipboard_changed = which });
    }

    /// The last frame presented to `win`, or null before the first.
    pub fn lastFrame(h: *Headless, win: WindowId) ?FrameImage {
        h.lock();
        defer h.unlock();
        const w = h.windows.getPtr(@intFromEnum(win)) orelse return null;
        const f = w.frame orelse return null;
        return .{ .width = f.w, .height = f.h, .stride = f.stride, .pixels = f.pixels };
    }

    /// The title of `win`, or null if it does not exist.
    pub fn title(h: *Headless, win: WindowId) ?[]const u8 {
        h.lock();
        defer h.unlock();
        return if (h.windows.getPtr(@intFromEnum(win))) |w| w.title else null;
    }

    /// Advances the virtual clock by `ns`, emitting `Event.frame` at each
    /// virtual vsync for windows that asked for a frame or presented.
    pub fn tick(h: *Headless, ns: u64) !void {
        h.lock();
        defer h.unlock();
        try h.advance(ns);
    }

    /// The virtual clock.
    pub fn now(h: *Headless) u64 {
        h.lock();
        defer h.unlock();
        return h.clock_ns;
    }

    /// Replays a `.zgtrace`: advances the clock by each record's delta and
    /// queues its event with the recorded payload.
    pub fn replay(h: *Headless, r: *Io.Reader) !void {
        try trace.readHeader(r);
        while (try trace.next(r, h.gpa)) |rec| {
            defer h.gpa.free(rec.payload);
            try h.tick(rec.t_ns_rel);
            try h.injectPayload(rec.ev, rec.payload);
        }
    }

    // ---- internals (mutex held) ----

    fn lock(h: *Headless) void {
        h.mutex.lockUncancelable(h.io);
    }

    fn unlock(h: *Headless) void {
        h.mutex.unlock(h.io);
    }

    fn pushEvent(h: *Headless, ev: Event) error{OutOfMemory}!void {
        try h.events.pushBack(h.gpa, ev);
        if (h.opts.record) |w| {
            var parts: [4][]const u8 = undefined;
            var ctx: Collect = .{ .h = h, .parts = &parts };
            arena_mod.forEachPayload(&ev, &ctx, Collect.one);
            trace.record(w, h.clock_ns - h.record_clock, ev, parts[0..ctx.n]) catch {
                // A failing trace writer must not break input; stop recording.
                std.log.scoped(.zg_platform).warn("trace recording failed; recording stopped", .{});
                h.opts.record = null;
            };
            h.record_clock = h.clock_ns;
        }
    }

    const Collect = struct {
        h: *Headless,
        parts: *[4][]const u8,
        n: usize = 0,
        fn one(c: *Collect, s: PayloadSlice) void {
            c.parts[c.n] = if (s.large) c.h.large.get(s.off) orelse &.{} else c.h.arena.get(s);
            c.n += 1;
        }
    };

    fn advance(h: *Headless, ns: u64) error{OutOfMemory}!void {
        const target = h.clock_ns + ns;
        while (h.next_vsync <= target) {
            h.clock_ns = h.next_vsync;
            h.next_vsync += h.opts.refresh_ns;
            for (h.windows.keys(), h.windows.values()) |id, *w| {
                if (!w.wants_frame) continue;
                w.wants_frame = false;
                try h.pushEvent(.{ .frame = .{ .win = @enumFromInt(id), .target_ns = h.next_vsync, .refresh_ns = h.opts.refresh_ns } });
            }
        }
        h.clock_ns = target;
    }

    fn configure(h: *Headless, win: WindowId) error{OutOfMemory}!void {
        const w = h.windows.getPtr(@intFromEnum(win)) orelse return;
        h.serial +%= 1;
        try h.pushEvent(.{ .window_configure = .{ .win = win, .size = w.size, .scale = h.opts.scale, .state = w.state, .serial = h.serial, .screen_origin_px = .{ .x = 0, .y = 0 } } });
    }

    fn freeWindow(h: *Headless, w: *Win) void {
        h.gpa.free(w.title);
        if (w.frame) |f| h.gpa.free(f.pixels);
        for (w.presenter.buffers.values()) |b| h.gpa.free(b.pixels);
        w.presenter.buffers.deinit(h.gpa);
        w.presenter.released.deinit(h.gpa);
        h.gpa.destroy(w.presenter);
    }

    fn run(h: *Headless, cmd: Command) Error!void {
        switch (cmd) {
            .set_title => |c| {
                const w = try h.lookup(c.win);
                const t = try h.gpa.dupe(u8, c.title);
                h.gpa.free(w.title);
                w.title = t;
            },
            .set_cursor => |c| (try h.lookup(c.win)).cursor = c.shape,
            .set_ime_state => |c| (try h.lookup(c.win)).ime_enabled = c.enabled,
            .set_min_size => |c| {
                const w = try h.lookup(c.win);
                w.min_size = c.size;
                if (w.size.w < c.size.w or w.size.h < c.size.h) {
                    w.size = .{ .w = @max(w.size.w, c.size.w), .h = @max(w.size.h, c.size.h) };
                    try h.configure(c.win);
                }
            },
            .request_state => |c| {
                const w = try h.lookup(c.win);
                switch (c.op) {
                    .show => {},
                    .minimize => try h.pushEvent(.{ .window_occluded = .{ .win = c.win, .occluded = true } }),
                    .maximize, .fullscreen => {
                        if (!w.state.maximized and !w.state.fullscreen) w.restore_size = w.size;
                        if (c.op == .maximize) w.state.maximized = true else w.state.fullscreen = true;
                        w.size = h.opts.monitor_size;
                        try h.configure(c.win);
                    },
                    .unmaximize, .unfullscreen => {
                        if (c.op == .unmaximize) w.state.maximized = false else w.state.fullscreen = false;
                        if (!w.state.maximized and !w.state.fullscreen) w.size = w.restore_size;
                        try h.configure(c.win);
                    },
                }
            },
            .begin_move, .show_window_menu, .set_hit_test, .set_drop_effect, .start_drag => {},
            .begin_resize => |c| _ = try h.lookup(c.win),
            .clipboard_write => |c| {
                const items = try h.gpa.alloc(ClipItemOwned, c.items.len);
                var done: usize = 0;
                errdefer {
                    for (items[0..done]) |it| h.gpa.free(it.data);
                    h.gpa.free(items);
                }
                for (c.items, 0..) |it, i| {
                    items[i] = .{ .mime = it.mime, .data = try h.gpa.dupe(u8, it.data) };
                    done = i + 1;
                }
                freeClip(h.gpa, h.clip[@intFromEnum(c.which)]);
                h.clip[@intFromEnum(c.which)] = items;
            },
            .clipboard_read => |c| {
                var data: PayloadSlice = .empty;
                for (h.clip[@intFromEnum(c.which)]) |it| {
                    if (it.mime == c.mime) {
                        data = try h.putPayloadLocked(it.data);
                        break;
                    }
                }
                try h.pushEvent(.{ .clipboard_data = .{ .request = c.request, .data = data, .mime = c.mime } });
            },
            .request_frame => |win| (try h.lookup(win)).wants_frame = true,
            .activate => |c| {
                _ = try h.lookup(c.win);
                if (h.focused != c.win) {
                    if (h.focused) |p| if (h.windows.getPtr(@intFromEnum(p))) |pw| {
                        pw.state.activated = false;
                        try h.pushEvent(.{ .window_focus = .{ .win = p, .focused = false } });
                    };
                    h.focused = c.win;
                    (try h.lookup(c.win)).state.activated = true;
                    try h.pushEvent(.{ .window_focus = .{ .win = c.win, .focused = true } });
                }
            },
            .open_dialog => |d| {
                const answer: DialogAnswer = if (h.dialog_index < h.opts.dialog_script.len) h.opts.dialog_script[h.dialog_index] else .{ .cancelled = true };
                h.dialog_index += 1;
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(h.gpa);
                for (answer.paths, 0..) |p, i| {
                    if (i > 0) try buf.append(h.gpa, 0);
                    try buf.appendSlice(h.gpa, p);
                }
                const paths = try h.putPayloadLocked(buf.items);
                try h.pushEvent(.{ .dialog_result = .{ .request = d.request, .paths = paths, .cancelled = answer.cancelled } });
            },
            .open_uri => |u| {
                const copy = try h.gpa.dupe(u8, u);
                errdefer h.gpa.free(copy);
                try h.opened_uris.append(h.gpa, copy);
            },
            .request_attention => |win| {
                _ = try h.lookup(win);
                h.attention_requests += 1;
            },
        }
    }

    fn lookup(h: *Headless, id: WindowId) Error!*Win {
        return h.windows.getPtr(@intFromEnum(id)) orelse error.InvalidWindow;
    }

    fn storeFrame(h: *Headless, id: WindowId, width: u32, height: u32, src: []const u8, src_stride: u32, bgra: bool) !void {
        const w = try h.lookup(id);
        const stride = width * 4;
        const need = @as(usize, stride) * height;
        var f = w.frame orelse CpuBuf{ .w = 0, .h = 0, .stride = 0, .fourcc = fourcc_abgr8888, .pixels = &.{} };
        if (f.pixels.len != need) {
            const px = try h.gpa.alloc(u8, need);
            h.gpa.free(f.pixels);
            f.pixels = px;
        }
        f.w = width;
        f.h = height;
        f.stride = stride;
        for (0..height) |y| {
            const s = src[y * src_stride ..][0..stride];
            const d = f.pixels[y * stride ..][0..stride];
            if (!bgra) {
                @memcpy(d, s);
                continue;
            }
            var x: usize = 0;
            while (x < stride) : (x += 4) {
                d[x] = s[x + 2];
                d[x + 1] = s[x + 1];
                d[x + 2] = s[x];
                d[x + 3] = s[x + 3];
            }
        }
        w.frame = f;
        w.wants_frame = true;
    }

    fn sinkWrite(ctx: *anyopaque, id: WindowId, damage: []const types.PxRect, pixels: []const u8, stride: u32) void {
        _ = damage;
        const h: *Headless = @ptrCast(@alignCast(ctx));
        h.lock();
        defer h.unlock();
        const w = h.lookup(id) catch return;
        const width = @min(w.size.w, stride / 4);
        const height: u32 = if (stride == 0) 0 else @intCast(@min(w.size.h, pixels.len / stride));
        h.storeFrame(id, width, height, pixels, stride, true) catch {};
    }

    fn noHook(_: *anyopaque, _: WindowId, _: []const u32, _: ?native_api.Win32MsgHook, _: *anyopaque) error{Unsupported}!void {
        return error.Unsupported;
    }

    fn noMsgWindow(_: *anyopaque, _: native_api.Win32MsgHook, _: *anyopaque) error{ Unsupported, SystemResources }!*anyopaque {
        return error.Unsupported;
    }

    fn noDestroy(_: *anyopaque, _: *anyopaque) void {}

    fn windowHandle(_: *anyopaque, _: WindowId) native_api.NativeWindow {
        return .headless;
    }
};

fn freeClip(gpa: Allocator, items: []ClipItemOwned) void {
    for (items) |it| gpa.free(it.data);
    gpa.free(items);
}

const presenter_vtable: surface.PresenterVTable = .{
    .drmDevice = pDrmDevice,
    .formats = pFormats,
    .syncMode = pSyncMode,
    .importBuffer = pImport,
    .present = pPresent,
    .releaseBuffer = pRelease,
    .pollReleased = pPollReleased,
    .allocCpuBuffer = pAlloc,
};

fn presOf(ctx: *anyopaque) *WinPresenter {
    return @ptrCast(@alignCast(ctx));
}

fn pDrmDevice(_: *anyopaque) ?surface.DrmDevice {
    return null;
}

fn pFormats(_: *anyopaque, out: []surface.FormatModifier) usize {
    const all = [_]surface.FormatModifier{ .{ .fourcc = fourcc_argb8888, .modifier = 0 }, .{ .fourcc = fourcc_abgr8888, .modifier = 0 } };
    const n = @min(out.len, all.len);
    @memcpy(out[0..n], all[0..n]);
    return all.len;
}

fn pSyncMode(_: *anyopaque) surface.SyncMode {
    return .cpu_only;
}

fn pImport(_: *anyopaque, _: *const surface.BufferDesc) anyerror!surface.BufferHandle {
    return error.Unsupported;
}

fn pAlloc(ctx: *anyopaque, w: u32, h: u32, fourcc: u32) anyerror!surface.CpuBuffer {
    if (fourcc != fourcc_argb8888 and fourcc != fourcc_abgr8888) return error.UnsupportedFormat;
    const p = presOf(ctx);
    const hl = p.h;
    hl.lock();
    defer hl.unlock();
    const stride = w * 4;
    const px = try hl.gpa.alloc(u8, @as(usize, stride) * h);
    errdefer hl.gpa.free(px);
    @memset(px, 0);
    const id = p.next;
    try p.buffers.put(hl.gpa, id, .{ .w = w, .h = h, .stride = stride, .fourcc = fourcc, .pixels = px });
    p.next += 1;
    return .{ .handle = @enumFromInt(id), .pixels = px, .stride = stride };
}

fn pPresent(ctx: *anyopaque, buf: surface.BufferHandle, damage: []const types.PxRect, acquire: surface.SyncPoint, ack: ?surface.ConfigureAck) anyerror!void {
    _ = damage;
    _ = acquire;
    _ = ack;
    const p = presOf(ctx);
    const hl = p.h;
    hl.lock();
    defer hl.unlock();
    const b = p.buffers.get(@intFromEnum(buf)) orelse return error.InvalidBuffer;
    try hl.storeFrame(p.win, b.w, b.h, b.pixels, b.stride, b.fourcc == fourcc_argb8888);
    try p.released.append(hl.gpa, buf);
    hl.present_seq += 1;
    try hl.pushEvent(.{ .present_feedback = .{ .win = p.win, .presented_ns = hl.clock_ns, .seq = hl.present_seq, .flags = event_api.PresentFlags.vsync } });
}

fn pRelease(ctx: *anyopaque, buf: surface.BufferHandle) void {
    const p = presOf(ctx);
    const hl = p.h;
    hl.lock();
    defer hl.unlock();
    if (p.buffers.fetchSwapRemove(@intFromEnum(buf))) |kv| hl.gpa.free(kv.value.pixels);
}

fn pPollReleased(ctx: *anyopaque, out: []surface.BufferHandle) usize {
    const p = presOf(ctx);
    const hl = p.h;
    hl.lock();
    defer hl.unlock();
    const n = @min(out.len, p.released.items.len);
    @memcpy(out[0..n], p.released.items[0..n]);
    p.released.replaceRangeAssumeCapacity(0, n, &.{});
    return n;
}

const testing = std.testing;
const conformance = @import("../testing/conformance.zig");

const Harness = struct {
    io: Io,
    last: ?*Headless = null,

    /// Conformance hook: a fresh headless platform.
    pub fn create(hn: *Harness) !Platform {
        const h = try Headless.init(testing.allocator, hn.io, .{});
        hn.last = h;
        return h.platform();
    }

    /// Conformance hook: a synthetic key event.
    pub fn injectKey(hn: *Harness, win: WindowId, key: @import("../api/keys.zig").Key, action: @import("../api/keys.zig").KeyAction) !void {
        try hn.last.?.inject(.{ .key = .{ .win = win, .ev = .{ .key = key, .keysym = 0, .codepoint = 0, .mods = .{}, .action = action, .text = .empty, .native_scancode = 0, .time_ns = hn.last.?.clock_ns } } });
    }

    /// Conformance hook: a synthetic close request.
    pub fn requestClose(hn: *Harness, win: WindowId) !void {
        try hn.last.?.inject(.{ .window_close_requested = win });
    }
};

test "headless conformance" {
    var hn: Harness = .{ .io = testing.io };
    try conformance.runConformance(Harness, &hn);
}

fn collectEncoded(gpa: Allocator, p: Platform, out: *std.ArrayList(u8)) !usize {
    var evs: [64]Event = undefined;
    var total: usize = 0;
    while (true) {
        const n = p.pollEvents(&evs);
        if (n == 0) return total;
        total += n;
        for (evs[0..n]) |e| {
            var aw: Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try aw.writer.writeByte(@intFromEnum(std.meta.activeTag(e)));
            try trace.encodeEvent(&aw.writer, e);
            const Ctx = struct { p: Platform, w: *Io.Writer, err: bool = false };
            var ctx: Ctx = .{ .p = p, .w = &aw.writer };
            arena_mod.forEachPayload(&e, &ctx, struct {
                fn f(c: *Ctx, s: PayloadSlice) void {
                    c.w.writeAll(c.p.payload(s)) catch {
                        c.err = true;
                    };
                }
            }.f);
            try out.appendSlice(gpa, aw.written());
        }
    }
}

test "trace roundtrip" {
    const gpa = testing.allocator;
    var rec: Io.Writer.Allocating = .init(gpa);
    defer rec.deinit();
    const a = try Headless.init(gpa, testing.io, .{ .record = &rec.writer });
    defer a.deinit();
    var prng: std.Random.DefaultPrng = .init(1000);
    const rand = prng.random();
    var bytes: [256]u8 = undefined;
    for (0..1000) |i| {
        var ev = trace.randomEvent(rand, 40);
        var total: usize = 0;
        arena_mod.forEachPayload(&ev, &total, struct {
            fn f(t: *usize, s: PayloadSlice) void {
                t.* += s.len;
            }
        }.f);
        rand.bytes(bytes[0..total]);
        try a.injectPayload(ev, bytes[0..total]);
        if (i % 97 == 0) try a.tick(rand.uintLessThan(u64, 50_000_000));
    }
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    const n_a = try collectEncoded(gpa, a.platform(), &want);

    const b = try Headless.init(gpa, testing.io, .{});
    defer b.deinit();
    var r: Io.Reader = .fixed(rec.written());
    try b.replay(&r);
    try testing.expectEqual(a.now(), b.now());
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    const n_b = try collectEncoded(gpa, b.platform(), &got);
    try testing.expectEqual(@as(usize, 1000), n_a);
    try testing.expectEqual(n_a, n_b);
    try testing.expectEqualSlices(u8, want.items, got.items);
}

test "virtual vsync frame cadence" {
    const h = try Headless.init(testing.allocator, testing.io, .{});
    defer h.deinit();
    const p = h.platform();
    const win = try p.createWindow(.{ .title = "t", .size = .{ .w = 8, .h = 8 } });
    var evs: [16]Event = undefined;
    _ = p.pollEvents(&evs);
    var frames: u32 = 0;
    var last_target: u64 = 0;
    for (0..60) |_| {
        try h.tick(h.opts.refresh_ns);
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == .frame) {
            frames += 1;
            if (last_target != 0) try testing.expectEqual(last_target + h.opts.refresh_ns, e.frame.target_ns);
            last_target = e.frame.target_ns;
        };
        try p.submit(.{ .request_frame = win });
    }
    try testing.expectEqual(@as(u32, 60), frames);
    // No request, no frame: idle windows cost nothing.
    try h.tick(h.opts.refresh_ns);
    _ = p.pollEvents(&evs);
    try h.tick(10 * @as(u64, h.opts.refresh_ns));
    try testing.expectEqual(0, p.pollEvents(&evs));
}

test "cpuPresenter writes lastFrame as RGBA" {
    const h = try Headless.init(testing.allocator, testing.io, .{});
    defer h.deinit();
    const p = h.platform();
    const win = try p.createWindow(.{ .title = "t", .size = .{ .w = 2, .h = 1 } });
    const pr = try p.cpuPresenter(win);
    try testing.expectEqual(surface.SyncMode.cpu_only, pr.syncMode());
    const buf = try pr.allocCpuBuffer(2, 1, fourcc_argb8888);
    @memcpy(buf.pixels, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }); // B G R A
    try testing.expectEqual(null, h.lastFrame(win));
    try pr.present(buf.handle, &.{}, .none, null);
    const f = h.lastFrame(win).?;
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4, 7, 6, 5, 8 }, f.pixels);
    var rel: [4]surface.BufferHandle = undefined;
    try testing.expectEqual(1, pr.pollReleased(&rel));
    try testing.expectEqual(buf.handle, rel[0]);
    pr.releaseBuffer(buf.handle);
}

test "headless sink stores frames from the renderer" {
    const h = try Headless.init(testing.allocator, testing.io, .{});
    defer h.deinit();
    const p = h.platform();
    const win = try p.createWindow(.{ .title = "t", .size = .{ .w = 1, .h = 2 } });
    const target = try p.surfaceTarget(win);
    target.headless.write(target.headless.ptr, win, &.{}, &.{ 10, 20, 30, 255, 40, 50, 60, 255 }, 4);
    try testing.expectEqualSlices(u8, &.{ 30, 20, 10, 255, 60, 50, 40, 255 }, h.lastFrame(win).?.pixels);
}

test "commands: clipboard, dialog, state and large payloads" {
    const h = try Headless.init(testing.allocator, testing.io, .{ .dialog_script = &.{.{ .paths = &.{ "/a", "/b" } }} });
    defer h.deinit();
    const p = h.platform();
    const win = try p.createWindow(.{ .title = "t", .size = .{ .w = 100, .h = 50 } });
    var evs: [16]Event = undefined;
    _ = p.pollEvents(&evs);

    const big = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(big);
    @memset(big, 'z');
    try h.setClipboard(.clipboard, .text_utf8, big);
    try p.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = 5 } });
    try p.submit(.{ .open_dialog = .{ .request = 9, .kind = .open_files } });
    try p.submit(.{ .open_dialog = .{ .request = 10, .kind = .open_file } });
    try p.submit(.{ .request_state = .{ .win = win, .op = .maximize } });
    try p.submit(.{ .set_title = .{ .win = win, .title = "new" } });
    try p.submit(.{ .open_uri = "https://ziglang.org" });
    const n = p.pollEvents(&evs);
    try testing.expectEqual(5, n);
    try testing.expectEqual(clipboard.Selection.clipboard, evs[0].clipboard_changed);
    const data = evs[1].clipboard_data;
    try testing.expect(data.data.large);
    try testing.expectEqual(@as(usize, 100_000), p.payload(data.data).len);
    p.release(data.data);
    try testing.expectEqualStrings("/a\x00/b", p.payload(evs[2].dialog_result.paths));
    try testing.expect(evs[3].dialog_result.cancelled);
    try testing.expectEqual(h.opts.monitor_size, evs[4].window_configure.size);
    try testing.expect(evs[4].window_configure.state.maximized);
    try testing.expectEqualStrings("new", h.title(win).?);
    try testing.expectEqualStrings("https://ziglang.org", h.opened_uris.items[0]);
    try testing.expectError(error.InvalidWindow, p.submit(.{ .set_title = .{ .win = @enumFromInt(99), .title = "x" } }));
}

test "real-time waitEvents returns on wake from another thread" {
    const h = try Headless.init(testing.allocator, testing.io, .{ .real_time = true });
    defer h.deinit();
    const p = h.platform();
    const t = try std.Thread.spawn(.{}, Platform.wake, .{p});
    p.waitEvents(null);
    t.join();
    var evs: [4]Event = undefined;
    try testing.expectEqual(1, p.pollEvents(&evs));
    try testing.expect(evs[0] == .wake);
}

test "fixture trace replays and re-records byte-identically" {
    const gpa = testing.allocator;
    const fixture = @embedFile("../testing/fixtures/random200.zgtrace");
    var rec: Io.Writer.Allocating = .init(gpa);
    defer rec.deinit();
    const h = try Headless.init(gpa, testing.io, .{ .record = &rec.writer });
    defer h.deinit();
    var r: Io.Reader = .fixed(fixture);
    try h.replay(&r);
    try testing.expectEqualSlices(u8, fixture, rec.written());
    var evs: [256]Event = undefined;
    try testing.expectEqual(200, h.platform().pollEvents(&evs));
}
