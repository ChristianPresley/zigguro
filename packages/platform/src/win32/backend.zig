//! The Win32 backend (E01.F02.S01.T02, first part, with the input basics of
//! E01.F02.S02.T01): a platform thread that owns every window and runs the
//! message pump, Per-Monitor V2 DPI, `window_configure` from `WM_SIZE` and
//! `WM_DPICHANGED`, focus, close requests, keyboard and mouse input,
//! monitors from `EnumDisplayMonitors`, and frames paced by a refresh
//! timer while requested. Frames reach the window through the DIB-section
//! presenter in `cpu_present.zig`.
//!
//! Threads: windows are created and destroyed on the platform thread
//! (`createWindow` and `destroyWindow` use `SendMessageW` to the hidden
//! message window). The window procedure stages events under the backend
//! mutex and signals the UI thread's `Wake`. Calls that send to a window
//! (`SetWindowTextW`, `ShowWindow`) never run under the mutex, because the
//! window procedure takes it.
//!
//! The refresh period comes from `DwmGetCompositionTimingInfo` (re-read on
//! `WM_DISPLAYCHANGE`); monitor scales from shcore's `GetDpiForMonitor`.
//! Inside the modal size/move loop a `WM_TIMER` keeps frames flowing.
//!
//! Not yet here: the custom frame and hit-testing (#219), raw input, pen
//! and touch (#222), IME (#226), clipboard (#230; `clipboard_read`
//! answers from our own `clipboard_write`), drag and drop (#232), cursors
//! and cloaking until the first present.

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
const Wake = @import("../queue/wake.zig").Wake;

const t = @import("bindings/types.zig");
const user32 = @import("bindings/user32.zig");
const kernel32 = @import("bindings/kernel32.zig");
const dwmapi = @import("bindings/dwmapi.zig");
const msgs = @import("msgs.zig");
const WM = msgs.WM;
const wkeys = @import("keys.zig");
const dpi = @import("dpi.zig");
const L = @import("wide.zig").L;
const wide = @import("wide.zig");
const CpuPresenter = @import("cpu_present.zig").CpuPresenter;

const Event = event_api.Event;
const Command = window_api.Command;
const WindowId = types.WindowId;
const PxSize = types.PxSize;
const Platform = platform_api.Platform;
const Error = platform_api.Error;

const log = std.log.scoped(.win32);

/// Options for `Win32Backend.init`.
pub const InitOptions = struct {
    /// Frame interval while frames are requested; null reads it from DWM
    /// (60 Hz when DWM cannot tell).
    refresh_ns: ?u32 = null,
};

/// shcore's `GetDpiForMonitor`, loaded at runtime (Windows 8.1+).
const GetDpiForMonitorFn = *const fn (t.HMONITOR, u32, *u32, *u32) callconv(t.winapi) t.HRESULT;

/// Private messages to the message window and to top-level windows.
const WM_APP_CREATE = WM.APP + 1;
const WM_APP_DESTROY = WM.APP + 2;
const WM_APP_WAKE = WM.APP + 3;
const WM_APP_QUIT = WM.APP + 4;

const class_name = L("zigguro.window");
const msg_class_name = L("zigguro.message");

const double_click_ns: u64 = 500 * std.time.ns_per_ms;
const double_click_px: f32 = 4;

/// One window and its presenter.
const Window = struct {
    b: *Win32Backend,
    id: WindowId,
    hwnd: ?t.HWND = null,
    size: PxSize = .{ .w = 0, .h = 0 },
    dpi: u32 = msgs.default_dpi,
    serial: u32 = 0,
    presenter: CpuPresenter,
    frame_requested: bool = false,
    last_frame_ns: u64 = 0,
    occluded: bool = false,
    maximized: bool = false,
    focused: bool = false,
    tracking_leave: bool = false,
    min_size: ?PxSize = null,
    last_click_ns: u64 = 0,
    last_click_pos: [2]f32 = .{ -100, -100 },
    last_click_button: types.Button = .left,
    clicks: u8 = 0,
};

/// A `createWindow` request carried by `WM_APP_CREATE`.
const CreateRequest = struct {
    w: *Window,
    title: [:0]const u16,
    size: PxSize,
    ok: bool = false,
};

const ClipItemOwned = struct { mime: clipboard.MimeId, data: []u8 };

/// The Win32 backend.
pub const Win32Backend = struct {
    gpa: Allocator,
    io: Io,
    opts: InitOptions,
    hinstance: t.HINSTANCE,

    mutex: Io.Mutex = .init,
    windows: std.ArrayList(*Window) = .empty,
    next_win: u32 = 1,
    staged: std.ArrayList(Event) = .empty,
    clip: [2][]ClipItemOwned = .{ &.{}, &.{} },

    arena: PayloadArena,
    ui_wake: Wake,
    wake_pending: std.atomic.Value(bool) = .init(false),

    thread: ?std.Thread = null,
    ready: Io.Event = .unset,
    start_failed: bool = false,
    msg_hwnd: ?t.HWND = null,
    hooks: native_api.NativeHooks,
    /// The frame interval in use (see `InitOptions.refresh_ns`).
    refresh_ns: std.atomic.Value(u32) = .init(16_666_667),
    get_dpi_for_monitor: ?GetDpiForMonitorFn = null,

    /// Starts the platform thread and waits until its message window exists.
    pub fn init(gpa: Allocator, io: Io, opts: InitOptions) !*Win32Backend {
        var arena = try PayloadArena.init(gpa);
        errdefer arena.deinit(gpa);
        var ui_wake = try Wake.init(io);
        errdefer ui_wake.deinit();
        const b = try gpa.create(Win32Backend);
        errdefer gpa.destroy(b);
        b.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .hinstance = kernel32.GetModuleHandleW(null) orelse return error.SystemResources,
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
        b.thread = try std.Thread.spawn(.{}, threadMain, .{b});
        b.ready.waitUncancelable(io);
        if (b.start_failed) {
            b.thread.?.join();
            return error.BackendUnavailable;
        }
        return b;
    }

    /// The type-erased interface.
    pub fn platform(b: *Win32Backend) Platform {
        return Platform.fromImpl(Win32Backend, b);
    }

    fn lock(b: *Win32Backend) void {
        b.mutex.lockUncancelable(b.io);
    }
    fn unlock(b: *Win32Backend) void {
        b.mutex.unlock(b.io);
    }

    fn nowNs(b: *Win32Backend) u64 {
        return @intCast(@max(0, Io.Clock.awake.now(b.io).nanoseconds));
    }

    fn find(b: *Win32Backend, id: WindowId) ?*Window {
        for (b.windows.items) |w| if (w.id == id) return w;
        return null;
    }

    /// Stages `ev` and wakes the UI thread. Mutex held.
    fn stage(b: *Win32Backend, ev: Event) void {
        b.staged.append(b.gpa, ev) catch {
            log.warn("event dropped: out of memory", .{});
            return;
        };
        b.ui_wake.signal();
    }

    // ---- Platform.VTable ----

    /// See `Platform.VTable.createWindow`. `opts.size` is the client size
    /// in physical pixels.
    pub fn createWindow(b: *Win32Backend, opts: window_api.WindowOptions) Error!WindowId {
        const title = wide.toWideAlloc(b.gpa, opts.title) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidUtf8 => error.Unsupported,
        };
        defer b.gpa.free(title);
        const w = b.gpa.create(Window) catch return error.OutOfMemory;
        b.lock();
        const id: WindowId = @enumFromInt(b.next_win);
        b.next_win += 1;
        b.unlock();
        w.* = .{ .b = b, .id = id, .presenter = .init(b.gpa, b.io), .min_size = opts.min_size };
        w.presenter.bind();
        w.presenter.on_present = .{ .ctx = w, .f = onPresented };
        var req: CreateRequest = .{ .w = w, .title = title, .size = .{ .w = std.math.clamp(opts.size.w, 1, 16384), .h = std.math.clamp(opts.size.h, 1, 16384) } };
        _ = user32.SendMessageW(b.msg_hwnd.?, WM_APP_CREATE, 0, @bitCast(@intFromPtr(&req)));
        if (!req.ok) {
            w.presenter.deinit();
            b.gpa.destroy(w);
            return error.SystemResources;
        }
        return id;
    }

    /// See `Platform.VTable.destroyWindow`.
    pub fn destroyWindow(b: *Win32Backend, win: WindowId) void {
        _ = user32.SendMessageW(b.msg_hwnd.?, WM_APP_DESTROY, @intFromEnum(win), 0);
    }

    /// See `Platform.VTable.submit`.
    pub fn submit(b: *Win32Backend, cmd: Command) Error!void {
        switch (cmd) {
            .set_title => |c| {
                const hwnd = try b.hwndOf(c.win);
                const title = wide.toWideAlloc(b.gpa, c.title) catch return error.OutOfMemory;
                defer b.gpa.free(title);
                _ = user32.SetWindowTextW(hwnd, title.ptr);
            },
            .set_cursor => |c| _ = try b.hwndOf(c.win),
            .set_ime_state => |c| _ = try b.hwndOf(c.win),
            .set_hit_test => |c| _ = try b.hwndOf(c.win),
            .set_min_size => |c| {
                b.lock();
                defer b.unlock();
                const w = b.find(c.win) orelse return error.InvalidWindow;
                w.min_size = c.size;
            },
            .request_state => |c| {
                const hwnd = try b.hwndOf(c.win);
                _ = user32.ShowWindow(hwnd, switch (c.op) {
                    .show, .unmaximize, .unfullscreen => msgs.SW_RESTORE,
                    .maximize, .fullscreen => msgs.SW_MAXIMIZE,
                    .minimize => msgs.SW_SHOWMINIMIZED,
                });
            },
            .request_frame => |win| {
                {
                    b.lock();
                    defer b.unlock();
                    const w = b.find(win) orelse return error.InvalidWindow;
                    w.frame_requested = true;
                }
                _ = user32.PostMessageW(b.msg_hwnd, WM_APP_WAKE, 0, 0);
            },
            .clipboard_write => |c| {
                const items = b.gpa.alloc(ClipItemOwned, c.items.len) catch return error.OutOfMemory;
                var done: usize = 0;
                errdefer {
                    for (items[0..done]) |it| b.gpa.free(it.data);
                    b.gpa.free(items);
                }
                for (c.items, 0..) |it, i| {
                    items[i] = .{ .mime = it.mime, .data = b.gpa.dupe(u8, it.data) catch return error.OutOfMemory };
                    done = i + 1;
                }
                b.lock();
                defer b.unlock();
                freeClip(b.gpa, b.clip[@intFromEnum(c.which)]);
                b.clip[@intFromEnum(c.which)] = items;
            },
            .clipboard_read => |c| {
                // Only our own selection until the Win32 clipboard (E01.F02.S04.T01).
                b.lock();
                defer b.unlock();
                var data: types.PayloadSlice = .empty;
                for (b.clip[@intFromEnum(c.which)]) |it| if (it.mime == c.mime) {
                    data = b.arena.put(it.data) catch .empty;
                    break;
                };
                b.stage(.{ .clipboard_data = .{ .request = c.request, .data = data, .mime = c.mime } });
            },
            .begin_move, .begin_resize, .show_window_menu, .start_drag, .set_drop_effect, .activate, .request_attention, .open_dialog, .open_uri => return error.Unsupported,
        }
    }

    fn hwndOf(b: *Win32Backend, win: WindowId) Error!t.HWND {
        b.lock();
        defer b.unlock();
        const w = b.find(win) orelse return error.InvalidWindow;
        return w.hwnd orelse error.InvalidWindow;
    }

    /// See `Platform.VTable.surfaceTarget`: E02 creates its swapchain on
    /// the HWND. The software renderer uses `cpuPresenter` instead.
    pub fn surfaceTarget(b: *Win32Backend, win: WindowId) Error!surface.SurfaceTarget {
        const hwnd = try b.hwndOf(win);
        return .{ .win32 = .{ .hinstance = @ptrCast(b.hinstance), .hwnd = @ptrCast(hwnd) } };
    }

    /// See `Platform.VTable.cpuPresenter`.
    pub fn cpuPresenter(b: *Win32Backend, win: WindowId) Error!*surface.Presenter {
        b.lock();
        defer b.unlock();
        const w = b.find(win) orelse return error.InvalidWindow;
        return &w.presenter.presenter;
    }

    /// See `Platform.VTable.native`.
    pub fn native(b: *Win32Backend) *const native_api.NativeHooks {
        return &b.hooks;
    }

    /// See `Platform.VTable.payload`.
    pub fn payload(b: *Win32Backend, s: types.PayloadSlice) []const u8 {
        if (s.large) return &.{};
        return b.arena.get(s);
    }

    /// See `Platform.VTable.release`. No large payloads yet.
    pub fn release(_: *Win32Backend, _: types.PayloadSlice) void {}

    /// After each CPU present: `Event.present_feedback` stamped now (GDI
    /// gives no scanout time).
    fn onPresented(ctx: *anyopaque, seq: u64) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        const b = w.b;
        b.lock();
        defer b.unlock();
        b.stage(.{ .present_feedback = .{ .win = w.id, .presented_ns = b.nowNs(), .seq = seq, .flags = 0 } });
    }

    /// Reads the refresh period from DWM unless `InitOptions` fixed it.
    fn readRefresh(b: *Win32Backend) void {
        if (b.opts.refresh_ns) |r| return b.refresh_ns.store(r, .release);
        var ti: t.DWM_TIMING_INFO = .{};
        var ns: ?u32 = null;
        if (dwmapi.DwmGetCompositionTimingInfo(null, &ti) >= 0) {
            ns = dpi.refreshNsFromRatio(ti.rateRefresh.uiNumerator, ti.rateRefresh.uiDenominator);
            if (ns == null) {
                var freq: i64 = 0;
                _ = kernel32.QueryPerformanceFrequency(&freq);
                ns = dpi.refreshNsFromQpc(ti.qpcRefreshPeriod, freq);
            }
        }
        b.refresh_ns.store(ns orelse 16_666_667, .release);
    }

    fn refreshNs(b: *const Win32Backend) u32 {
        return b.refresh_ns.load(.acquire);
    }

    /// The effective DPI of `hmon`, or null without shcore.
    fn monitorDpi(b: *const Win32Backend, hmon: t.HMONITOR) ?u32 {
        const f = b.get_dpi_for_monitor orelse return null;
        var x: u32 = 0;
        var y: u32 = 0;
        if (f(hmon, msgs.MDT_EFFECTIVE_DPI, &x, &y) < 0 or x == 0) return null;
        return x;
    }

    /// See `Platform.VTable.monitors`. Scales come from each monitor's
    /// effective DPI; every monitor reports the DWM refresh rate.
    pub fn monitors(b: *Win32Backend, out: []types.MonitorInfo) usize {
        var ctx: MonitorEnum = .{ .b = b, .out = out };
        _ = user32.EnumDisplayMonitors(null, null, MonitorEnum.callback, @bitCast(@intFromPtr(&ctx)));
        return ctx.n;
    }

    const MonitorEnum = struct {
        b: *Win32Backend,
        out: []types.MonitorInfo,
        n: usize = 0,

        fn callback(hmon: t.HMONITOR, _: ?t.HDC, _: *t.RECT, lp: t.LPARAM) callconv(t.winapi) t.BOOL {
            const self: *MonitorEnum = @ptrFromInt(@as(usize, @bitCast(lp)));
            var mi: t.MONITORINFOEXW = .{};
            if (user32.GetMonitorInfoW(hmon, &mi) == 0) return t.TRUE;
            if (self.n < self.out.len) {
                const mdpi = self.b.monitorDpi(hmon) orelse msgs.default_dpi;
                const refresh_mhz: u32 = @intCast(@as(u64, std.time.ns_per_s) * 1000 / self.b.refreshNs());
                var m: types.MonitorInfo = .{ .id = @truncate(@intFromPtr(hmon)), .rect_px = rectOf(mi.rcMonitor), .work_px = rectOf(mi.rcWork), .scale = .{ .factor = dpi.scaleOf(mdpi) }, .refresh_mhz = refresh_mhz, .primary = mi.dwFlags & 1 != 0 };
                const name = wide.fromWide(&m.name_buf, mi.szDevice[0..wide.len(@ptrCast(&mi.szDevice))]) catch "";
                m.name_len = @intCast(name.len);
                self.out[self.n] = m;
            }
            self.n += 1;
            return t.TRUE;
        }
    };

    /// See `Platform.VTable.pollEvents`.
    pub fn pollEvents(b: *Win32Backend, out: []Event) usize {
        if (out.len == 0) return 0;
        _ = b.arena.flip();
        var n: usize = 0;
        if (b.wake_pending.swap(false, .acquire)) {
            out[0] = .wake;
            n = 1;
        }
        b.lock();
        defer b.unlock();
        const take = @min(out.len - n, b.staged.items.len);
        for (b.staged.items[0..take], 0..) |e, i| {
            out[n + i] = e;
            b.arena.retire(&e);
        }
        b.staged.replaceRangeAssumeCapacity(0, take, &.{});
        return n + take;
    }

    /// See `Platform.VTable.waitEvents`.
    pub fn waitEvents(b: *Win32Backend, deadline_ns: ?u64) void {
        while (true) {
            {
                b.lock();
                defer b.unlock();
                if (b.staged.items.len > 0) return;
            }
            if (b.wake_pending.load(.acquire)) return;
            var timeout: ?u64 = null;
            if (deadline_ns) |d| {
                const now = b.nowNs();
                if (now >= d) return;
                timeout = d - now;
            }
            if (!b.ui_wake.wait(timeout)) return;
        }
    }

    /// See `Platform.VTable.wake`.
    pub fn wake(b: *Win32Backend) void {
        b.wake_pending.store(true, .release);
        b.ui_wake.signal();
    }

    /// See `Platform.VTable.deinit`.
    pub fn deinit(b: *Win32Backend) void {
        _ = user32.PostMessageW(b.msg_hwnd, WM_APP_QUIT, 0, 0);
        if (b.thread) |th| th.join();
        b.staged.deinit(b.gpa);
        for (&b.clip) |items| freeClip(b.gpa, items);
        b.windows.deinit(b.gpa);
        b.arena.deinit(b.gpa);
        b.ui_wake.deinit();
        b.gpa.destroy(b);
    }

    // ---- the platform thread ----

    fn threadMain(b: *Win32Backend) void {
        // Before any window exists; fails harmlessly when a manifest set it.
        _ = user32.SetProcessDpiAwarenessContext(user32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        if (kernel32.LoadLibraryExW(L("shcore.dll"), null, msgs.LOAD_LIBRARY_SEARCH_SYSTEM32)) |shcore| {
            if (kernel32.GetProcAddress(shcore, "GetDpiForMonitor")) |f| b.get_dpi_for_monitor = @ptrCast(@alignCast(f));
        }
        b.readRefresh();
        const wc: t.WNDCLASSEXW = .{
            .lpfnWndProc = wndProc,
            .hInstance = b.hinstance,
            .hCursor = user32.LoadCursorW(null, user32.makeIntResource(msgs.IDC_ARROW)),
            .lpszClassName = class_name,
        };
        const mc: t.WNDCLASSEXW = .{ .lpfnWndProc = msgProc, .hInstance = b.hinstance, .lpszClassName = msg_class_name };
        // A second backend in the same process finds the classes registered.
        _ = user32.RegisterClassExW(&wc);
        _ = user32.RegisterClassExW(&mc);
        b.msg_hwnd = user32.CreateWindowExW(0, msg_class_name, null, 0, 0, 0, 0, 0, user32.HWND_MESSAGE, null, b.hinstance, b);
        if (b.msg_hwnd == null) {
            log.err("cannot create the message window (error {d})", .{kernel32.GetLastError()});
            b.start_failed = true;
            b.ready.set(b.io);
            return;
        }
        b.ready.set(b.io);

        var msg: t.MSG = undefined;
        loop: while (true) {
            const ms = b.waitMs();
            _ = user32.MsgWaitForMultipleObjectsEx(0, null, ms, msgs.QS_ALLINPUT, msgs.MWMO_INPUTAVAILABLE);
            while (user32.PeekMessageW(&msg, null, 0, 0, msgs.PM_REMOVE) != 0) {
                if (msg.message == WM_APP_QUIT) break :loop;
                _ = user32.TranslateMessage(&msg);
                _ = user32.DispatchMessageW(&msg);
            }
            b.dueFrames();
        }
        // Destroy every window on the thread that owns them.
        while (true) {
            b.lock();
            const w = if (b.windows.items.len > 0) b.windows.items[0] else null;
            b.unlock();
            b.destroyOnThread(w orelse break);
        }
        _ = user32.DestroyWindow(b.msg_hwnd.?);
    }

    /// Milliseconds until the next due frame, or INFINITE.
    fn waitMs(b: *Win32Backend) u32 {
        b.lock();
        defer b.unlock();
        var next: ?u64 = null;
        for (b.windows.items) |w| if (w.frame_requested) {
            const due = w.last_frame_ns + b.refreshNs();
            next = if (next) |x| @min(x, due) else due;
        };
        const due = next orelse return msgs.INFINITE;
        const now = b.nowNs();
        if (due <= now) return 0;
        return @intCast(@min((due - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms, msgs.INFINITE - 1));
    }

    fn dueFrames(b: *Win32Backend) void {
        b.lock();
        defer b.unlock();
        const now = b.nowNs();
        const refresh = b.refreshNs();
        for (b.windows.items) |w| {
            if (!w.frame_requested or now < w.last_frame_ns + refresh) continue;
            w.frame_requested = false;
            w.last_frame_ns = now;
            b.stage(.{ .frame = .{ .win = w.id, .target_ns = now + refresh, .refresh_ns = refresh } });
        }
    }

    fn createOnThread(b: *Win32Backend, req: *CreateRequest) void {
        const w = req.w;
        // The outer size for the client size at the primary monitor's DPI;
        // WM_DPICHANGED corrects it if the window lands elsewhere.
        const style = msgs.WS.OVERLAPPEDWINDOW | msgs.WS.CLIPCHILDREN;
        var r: t.RECT = .{ .left = 0, .top = 0, .right = @intCast(req.size.w), .bottom = @intCast(req.size.h) };
        _ = user32.AdjustWindowRectExForDpi(&r, style, t.FALSE, msgs.WS.EX_APPWINDOW, msgs.default_dpi);
        const hwnd = user32.CreateWindowExW(msgs.WS.EX_APPWINDOW, class_name, req.title.ptr, style, msgs.CW_USEDEFAULT, msgs.CW_USEDEFAULT, r.right - r.left, r.bottom - r.top, null, null, b.hinstance, w) orelse {
            log.err("CreateWindowExW failed (error {d})", .{kernel32.GetLastError()});
            return;
        };
        const wdpi = @max(user32.GetDpiForWindow(hwnd), 1);
        {
            b.lock();
            defer b.unlock();
            b.windows.append(b.gpa, w) catch {
                _ = user32.DestroyWindow(hwnd);
                return;
            };
            w.dpi = wdpi;
        }
        // Created on another monitor's DPI: size the frame for this one
        // while the window is still hidden, so the client size is exact.
        if (wdpi != msgs.default_dpi) {
            var rd: t.RECT = .{ .left = 0, .top = 0, .right = @intCast(req.size.w), .bottom = @intCast(req.size.h) };
            _ = user32.AdjustWindowRectExForDpi(&rd, style, t.FALSE, msgs.WS.EX_APPWINDOW, wdpi);
            _ = user32.SetWindowPos(hwnd, null, 0, 0, rd.right - rd.left, rd.bottom - rd.top, msgs.SWP_NOZORDER | msgs.SWP_NOACTIVATE | msgs.SWP_NOMOVE);
        }
        _ = user32.ShowWindow(hwnd, msgs.SW_SHOWNORMAL);
        var cr: t.RECT = undefined;
        _ = user32.GetClientRect(hwnd, &cr);
        b.lock();
        defer b.unlock();
        // Report the client size even if WM_SIZE came before the append.
        b.configure(w, .{ .w = @intCast(@max(1, cr.right - cr.left)), .h = @intCast(@max(1, cr.bottom - cr.top)) }, true);
        req.ok = true;
    }

    fn destroyOnThread(b: *Win32Backend, w: *Window) void {
        b.lock();
        for (b.windows.items, 0..) |x, i| if (x == w) {
            _ = b.windows.swapRemove(i);
            break;
        };
        const hwnd = w.hwnd;
        w.presenter.hwnd = null;
        b.unlock();
        if (hwnd) |h| {
            _ = user32.SetWindowLongPtrW(h, msgs.GWLP_USERDATA, 0);
            _ = user32.DestroyWindow(h);
        }
        w.presenter.deinit();
        b.gpa.destroy(w);
    }

    /// Stages `window_configure` when the size or scale changed (or
    /// `force`). Mutex held.
    fn configure(b: *Win32Backend, w: *Window, size: PxSize, force: bool) void {
        if (size.w == 0 or size.h == 0) return;
        if (!force and size.w == w.size.w and size.h == w.size.h) return;
        w.size = size;
        w.serial +%= 1;
        b.stage(.{ .window_configure = .{ .win = w.id, .size = size, .scale = .{ .factor = dpi.scaleOf(w.dpi) }, .state = .{ .maximized = w.maximized, .activated = w.focused }, .serial = w.serial, .screen_origin_px = null } });
    }

    fn setOccluded(b: *Win32Backend, w: *Window, occluded: bool) void {
        if (w.occluded == occluded) return;
        w.occluded = occluded;
        b.stage(.{ .window_occluded = .{ .win = w.id, .occluded = occluded } });
    }

    fn msgProc(hwnd: t.HWND, msg: t.UINT, wp: t.WPARAM, lp: t.LPARAM) callconv(t.winapi) t.LRESULT {
        if (msg == WM.NCCREATE) {
            const cs: *const msgs.CREATESTRUCTW_prefix = @ptrFromInt(@as(usize, @bitCast(lp)));
            _ = user32.SetWindowLongPtrW(hwnd, msgs.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
            return user32.DefWindowProcW(hwnd, msg, wp, lp);
        }
        const raw: usize = @bitCast(user32.GetWindowLongPtrW(hwnd, msgs.GWLP_USERDATA));
        if (raw == 0) return user32.DefWindowProcW(hwnd, msg, wp, lp);
        const b: *Win32Backend = @ptrFromInt(raw);
        switch (msg) {
            WM_APP_CREATE => b.createOnThread(@ptrFromInt(@as(usize, @bitCast(lp)))),
            WM_APP_DESTROY => {
                b.lock();
                const w = b.find(@enumFromInt(@as(u32, @intCast(wp))));
                b.unlock();
                if (w) |x| b.destroyOnThread(x);
            },
            WM_APP_WAKE => {},
            else => return user32.DefWindowProcW(hwnd, msg, wp, lp),
        }
        return 0;
    }

    fn wndProc(hwnd: t.HWND, msg: t.UINT, wp: t.WPARAM, lp: t.LPARAM) callconv(t.winapi) t.LRESULT {
        if (msg == WM.NCCREATE) {
            const cs: *const msgs.CREATESTRUCTW_prefix = @ptrFromInt(@as(usize, @bitCast(lp)));
            const w: *Window = @ptrCast(@alignCast(cs.lpCreateParams.?));
            w.hwnd = hwnd;
            w.presenter.hwnd = hwnd;
            _ = user32.SetWindowLongPtrW(hwnd, msgs.GWLP_USERDATA, @bitCast(@intFromPtr(w)));
            return user32.DefWindowProcW(hwnd, msg, wp, lp);
        }
        const raw: usize = @bitCast(user32.GetWindowLongPtrW(hwnd, msgs.GWLP_USERDATA));
        if (raw == 0) return user32.DefWindowProcW(hwnd, msg, wp, lp);
        const w: *Window = @ptrFromInt(raw);
        const b = w.b;
        switch (msg) {
            WM.ERASEBKGND => return 1,
            WM.PAINT => {
                var ps: t.PAINTSTRUCT = undefined;
                const hdc = user32.BeginPaint(hwnd, &ps) orelse return 0;
                w.presenter.paint(hdc, ps.rcPaint);
                _ = user32.EndPaint(hwnd, &ps);
                return 0;
            },
            WM.CLOSE => {
                b.lock();
                defer b.unlock();
                b.stage(.{ .window_close_requested = w.id });
                return 0;
            },
            WM.SIZE => {
                b.lock();
                defer b.unlock();
                if (wp == msgs.SIZE_MINIMIZED) {
                    b.setOccluded(w, true);
                    return 0;
                }
                b.setOccluded(w, false);
                w.maximized = wp == msgs.SIZE_MAXIMIZED;
                const l: usize = @bitCast(lp);
                b.configure(w, .{ .w = @intCast(l & 0xffff), .h = @intCast((l >> 16) & 0xffff) }, false);
                return 0;
            },
            WM.DPICHANGED => {
                const new_dpi: u32 = @intCast((wp >> 16) & 0xffff);
                const r: *const t.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
                {
                    b.lock();
                    defer b.unlock();
                    w.dpi = @max(new_dpi, 1);
                }
                _ = user32.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, msgs.SWP_NOZORDER | msgs.SWP_NOACTIVATE);
                var cr: t.RECT = undefined;
                _ = user32.GetClientRect(hwnd, &cr);
                b.lock();
                defer b.unlock();
                b.configure(w, .{ .w = @intCast(@max(1, cr.right - cr.left)), .h = @intCast(@max(1, cr.bottom - cr.top)) }, true);
                b.stage(.monitors_changed);
                return 0;
            },
            WM.DISPLAYCHANGE => {
                b.readRefresh();
                b.lock();
                defer b.unlock();
                b.stage(.monitors_changed);
                return user32.DefWindowProcW(hwnd, msg, wp, lp);
            },
            WM.ENTERSIZEMOVE => {
                // DispatchMessage does not return until the drag ends; the
                // timer runs the frame pacing meanwhile.
                _ = user32.SetTimer(hwnd, msgs.modal_timer_id, msgs.USER_TIMER_MINIMUM, null);
                return 0;
            },
            WM.EXITSIZEMOVE => {
                _ = user32.KillTimer(hwnd, msgs.modal_timer_id);
                return 0;
            },
            WM.TIMER => {
                if (wp != msgs.modal_timer_id) return user32.DefWindowProcW(hwnd, msg, wp, lp);
                b.dueFrames();
                return 0;
            },
            WM.GETMINMAXINFO => {
                b.lock();
                defer b.unlock();
                if (w.min_size) |m| {
                    const mmi: *t.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
                    var r: t.RECT = .{ .left = 0, .top = 0, .right = @intCast(m.w), .bottom = @intCast(m.h) };
                    _ = user32.AdjustWindowRectExForDpi(&r, msgs.WS.OVERLAPPEDWINDOW, t.FALSE, 0, w.dpi);
                    mmi.ptMinTrackSize = .{ .x = r.right - r.left, .y = r.bottom - r.top };
                }
                return 0;
            },
            WM.SETFOCUS, WM.KILLFOCUS => {
                b.lock();
                defer b.unlock();
                const focused = msg == WM.SETFOCUS;
                if (w.focused != focused) {
                    w.focused = focused;
                    b.stage(.{ .window_focus = .{ .win = w.id, .focused = focused } });
                }
                return 0;
            },
            WM.KEYDOWN, WM.SYSKEYDOWN, WM.KEYUP, WM.SYSKEYUP => {
                b.onKey(w, hwnd, msg == WM.KEYDOWN or msg == WM.SYSKEYDOWN, @intCast(wp & 0xffff), lp);
                // Let DefWindowProc see Alt+F4 and the system menu keys.
                if (msg == WM.SYSKEYDOWN or msg == WM.SYSKEYUP) return user32.DefWindowProcW(hwnd, msg, wp, lp);
                return 0;
            },
            WM.CHAR, WM.SYSCHAR => return 0, // consumed with their WM_KEYDOWN
            WM.MOUSEMOVE => {
                if (!w.tracking_leave) {
                    var tme: t.TRACKMOUSEEVENT = .{ .dwFlags = msgs.TME_LEAVE, .hwndTrack = hwnd };
                    if (user32.TrackMouseEvent(&tme) != 0) {
                        w.tracking_leave = true;
                        b.lock();
                        defer b.unlock();
                        b.stage(.{ .pointer_enter_leave = .{ .win = w.id, .entered = true } });
                    }
                }
                b.lock();
                defer b.unlock();
                b.stage(.{ .pointer_move = .{ .win = w.id, .pos_px = posOf(lp), .mods = modsNow(), .time_ns = b.nowNs() } });
                return 0;
            },
            WM.MOUSELEAVE => {
                w.tracking_leave = false;
                b.lock();
                defer b.unlock();
                b.stage(.{ .pointer_enter_leave = .{ .win = w.id, .entered = false } });
                return 0;
            },
            WM.LBUTTONDOWN, WM.LBUTTONUP => b.onButton(w, hwnd, .left, msg == WM.LBUTTONDOWN, lp),
            WM.RBUTTONDOWN, WM.RBUTTONUP => b.onButton(w, hwnd, .right, msg == WM.RBUTTONDOWN, lp),
            WM.MBUTTONDOWN, WM.MBUTTONUP => b.onButton(w, hwnd, .middle, msg == WM.MBUTTONDOWN, lp),
            WM.XBUTTONDOWN, WM.XBUTTONUP => {
                const which = (wp >> 16) & 0xffff;
                b.onButton(w, hwnd, if (which == 1) .back else .forward, msg == WM.XBUTTONDOWN, lp);
                return 1; // XBUTTON messages return TRUE
            },
            WM.MOUSEWHEEL, WM.MOUSEHWHEEL => {
                const delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
                const notches = @as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(msgs.WHEEL_DELTA));
                const vertical = msg == WM.MOUSEWHEEL;
                b.lock();
                defer b.unlock();
                // Wheel forward (positive) scrolls towards the start: negative dy.
                b.stage(.{ .scroll = .{ .win = w.id, .dx = if (vertical) 0 else notches, .dy = if (vertical) -notches else 0, .unit = .lines, .source = .wheel, .phase = .none } });
                return 0;
            },
            else => return user32.DefWindowProcW(hwnd, msg, wp, lp),
        }
        return 0;
    }

    fn onKey(b: *Win32Backend, w: *Window, hwnd: t.HWND, pressed: bool, vk: u16, lp: t.LPARAM) void {
        const sc = wkeys.scancodeOf(lp);
        // TranslateMessage has queued the key's WM_CHAR(s); take them now so
        // the text travels with the key event.
        var text_buf: [16]u8 = undefined;
        var text_len: usize = 0;
        var cp: u21 = 0;
        if (pressed) {
            var m: t.MSG = undefined;
            var high: u16 = 0;
            while (user32.PeekMessageW(&m, hwnd, WM.CHAR, WM.CHAR, msgs.PM_REMOVE) != 0 or
                user32.PeekMessageW(&m, hwnd, WM.SYSCHAR, WM.SYSCHAR, msgs.PM_REMOVE) != 0)
            {
                const unit: u16 = @truncate(m.wParam);
                var c: u21 = unit;
                if (unit >= 0xd800 and unit < 0xdc00) {
                    high = unit;
                    continue;
                }
                if (unit >= 0xdc00 and unit < 0xe000 and high != 0) {
                    c = 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (unit - 0xdc00);
                    high = 0;
                }
                if (c < 0x20 or c == 0x7f) continue; // control characters carry no text
                if (cp == 0) cp = c;
                const n = std.unicode.utf8Encode(c, text_buf[text_len..]) catch break;
                text_len += n;
                if (text_len + 4 > text_buf.len) break;
            }
        }
        const mods = modsNow();
        b.lock();
        defer b.unlock();
        const text = b.arena.put(text_buf[0..text_len]) catch types.PayloadSlice.empty;
        b.stage(.{ .key = .{ .win = w.id, .ev = .{
            .key = wkeys.keyOf(sc, vk),
            .keysym = wkeys.keysymOf(vk, if (mods.ctrl and !mods.alt_gr) 0 else cp),
            .codepoint = if (mods.ctrl and !mods.alt_gr) 0 else cp,
            .mods = mods,
            .action = if (!pressed) .release else if (wkeys.isRepeat(lp)) .repeat else .press,
            .text = if (mods.ctrl and !mods.alt_gr) .empty else text,
            .native_scancode = sc,
            .native_vk = vk,
            .time_ns = b.nowNs(),
        } } });
    }

    fn onButton(b: *Win32Backend, w: *Window, hwnd: t.HWND, button: types.Button, pressed: bool, lp: t.LPARAM) void {
        const pos = posOf(lp);
        const now = b.nowNs();
        // Keep receiving the release when it happens outside the window.
        if (pressed) _ = user32.SetCapture(hwnd) else _ = user32.ReleaseCapture();
        b.lock();
        defer b.unlock();
        if (pressed) {
            const near = @abs(pos[0] - w.last_click_pos[0]) <= double_click_px and @abs(pos[1] - w.last_click_pos[1]) <= double_click_px;
            if (button == w.last_click_button and near and now - w.last_click_ns <= double_click_ns and w.clicks < 3) w.clicks += 1 else w.clicks = 1;
            w.last_click_ns = now;
            w.last_click_pos = pos;
            w.last_click_button = button;
        }
        b.stage(.{ .pointer_button = .{ .win = w.id, .button = button, .pressed = pressed, .pos_px = pos, .mods = modsNow(), .clicks = if (pressed) w.clicks else 0, .time_ns = now } });
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
        const b: *Win32Backend = @ptrCast(@alignCast(ctx));
        const hwnd = b.hwndOf(win) catch return .headless;
        return .{ .win32 = @ptrCast(hwnd) };
    }
};

fn freeClip(gpa: Allocator, items: []ClipItemOwned) void {
    for (items) |it| gpa.free(it.data);
    gpa.free(items);
}

fn rectOf(r: t.RECT) types.PxRect {
    return .{ .x = r.left, .y = r.top, .w = @intCast(@max(0, r.right - r.left)), .h = @intCast(@max(0, r.bottom - r.top)) };
}

/// The client position in a mouse message's lParam (signed 16-bit each).
fn posOf(lp: t.LPARAM) [2]f32 {
    const l: usize = @bitCast(lp);
    const x: i16 = @bitCast(@as(u16, @truncate(l)));
    const y: i16 = @bitCast(@as(u16, @truncate(l >> 16)));
    return .{ @floatFromInt(x), @floatFromInt(y) };
}

fn keyDown(_: void, vk: u16) bool {
    return user32.GetKeyState(vk) < 0;
}
fn keyToggled(_: void, vk: u16) bool {
    return user32.GetKeyState(vk) & 1 != 0;
}
fn modsNow() @import("../api/keys.zig").Mods {
    return wkeys.modsFrom({}, keyDown, keyToggled);
}

// ---- tests (Windows, or wine64 with `-fwine`) ----

const testing = std.testing;
const conformance = @import("../testing/conformance.zig");
const gdi32 = @import("bindings/gdi32.zig");

const Harness = struct {
    io: Io,
    current: ?*Win32Backend = null,

    /// A fresh backend.
    pub fn create(h: *Harness) !Platform {
        const b = try Win32Backend.init(testing.allocator, testing.io, .{});
        h.current = b;
        return b.platform();
    }

    /// Posts WM_CLOSE, as the title bar's close button would.
    pub fn requestClose(h: *Harness, win: WindowId) !void {
        const hwnd = try h.current.?.hwndOf(win);
        if (user32.PostMessageW(hwnd, WM.CLOSE, 0, 0) == 0) return error.PostFailed;
    }

    /// Posts a key message with `key`'s set-1 scancode.
    pub fn injectKey(h: *Harness, win: WindowId, key: @import("../api/keys.zig").Key, action: @import("../api/keys.zig").KeyAction) !void {
        const hwnd = try h.current.?.hwndOf(win);
        // Set-1 scancodes below 0x59 equal evdev codes.
        var sc: usize = 1;
        while (sc < 0x59 and wkeys.keyOf(@intCast(sc), 0) != key) sc += 1;
        if (sc == 0x59) return error.Unsupported;
        const up = action == .release;
        const lp: usize = 1 | (sc << 16) | (if (up) @as(usize, 0xC000_0000) else 0);
        if (user32.PostMessageW(hwnd, if (up) WM.KEYUP else WM.KEYDOWN, 0, @bitCast(lp)) == 0) return error.PostFailed;
    }
};

test "win32 conformance" {
    var h: Harness = .{ .io = testing.io };
    try conformance.runConformance(Harness, &h);
}

fn waitFor(p: Platform, comptime kind: Event.Tag, win: WindowId) !Event {
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 3 * std.time.ns_per_s;
    var evs: [64]Event = undefined;
    while (true) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == kind and e.window() == win) return e;
        if (@as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) >= deadline) return error.Timeout;
        p.waitEvents(deadline);
    }
}

test "win32: a presented buffer reaches the window and WM_PAINT replays it" {
    const b = try Win32Backend.init(testing.allocator, testing.io, .{});
    defer b.deinit();
    const p = b.platform();
    // Windows keeps a top-level window at least as wide as its caption
    // buttons, so test at a size every system allows.
    const win = try p.createWindow(.{ .title = "zg present", .size = .{ .w = 320, .h = 200 } });
    const cf = try waitFor(p, .window_configure, win);
    try testing.expectEqual(PxSize{ .w = 320, .h = 200 }, cf.window_configure.size);
    try p.submit(.{ .request_frame = win });
    _ = try waitFor(p, .frame, win);
    const target = try p.surfaceTarget(win);
    try testing.expect(target == .win32);

    const pr = try p.cpuPresenter(win);
    const buf = try pr.allocCpuBuffer(64, 48, @import("cpu_present.zig").fourcc_argb8888);
    var y: usize = 0;
    while (y < 48) : (y += 1) {
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const c: [4]u8 = if (i < 32) .{ 0x10, 0x80, 0xf0, 0xff } else .{ 0x90, 0x90, 0x10, 0xff };
            @memcpy(buf.pixels[y * buf.stride + i * 4 ..][0..4], &c);
        }
    }
    try pr.present(buf.handle, &.{}, .none, null);
    const hwnd = try b.hwndOf(win);
    const hdc = user32.GetDC(hwnd) orelse return error.NoDc;
    defer _ = user32.ReleaseDC(hwnd, hdc);
    // GetPixel answers 0x00BBGGRR.
    try testing.expectEqual(@as(u32, 0x0010_80f0), gdi32.GetPixel(hdc, 2, 2));
    try testing.expectEqual(@as(u32, 0x0090_9010) & 0x00ff_ffff, gdi32.GetPixel(hdc, 60, 40) & 0x00ff_ffff);
    // Invalidate and repaint: WM_PAINT draws the same pixels again.
    _ = user32.InvalidateRect(hwnd, null, t.TRUE);
    _ = user32.UpdateWindow(hwnd);
    try testing.expectEqual(@as(u32, 0x0010_80f0), gdi32.GetPixel(hdc, 2, 2));
    p.destroyWindow(win);
}

test "win32: a newer present releases the older buffer" {
    const b = try Win32Backend.init(testing.allocator, testing.io, .{});
    defer b.deinit();
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg release", .size = .{ .w = 16, .h = 16 } });
    const pr = try p.cpuPresenter(win);
    const fourcc = @import("cpu_present.zig").fourcc_argb8888;
    const a = try pr.allocCpuBuffer(16, 16, fourcc);
    const c = try pr.allocCpuBuffer(16, 16, fourcc);
    try pr.present(a.handle, &.{}, .none, null);
    var got: [4]surface.BufferHandle = undefined;
    try testing.expectEqual(@as(usize, 0), pr.pollReleased(&got));
    try pr.present(c.handle, &.{.{ .x = 0, .y = 0, .w = 4, .h = 4 }}, .none, null);
    try testing.expectEqual(@as(usize, 1), pr.pollReleased(&got));
    try testing.expectEqual(a.handle, got[0]);
}

test "win32: presents report feedback; WM_DISPLAYCHANGE reports monitors" {
    const b = try Win32Backend.init(testing.allocator, testing.io, .{});
    defer b.deinit();
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg feedback", .size = .{ .w = 320, .h = 200 } });
    const pr = try p.cpuPresenter(win);
    const buf = try pr.allocCpuBuffer(32, 32, @import("cpu_present.zig").fourcc_argb8888);
    try pr.present(buf.handle, &.{}, .none, null);
    const fb = (try waitFor(p, .present_feedback, win)).present_feedback;
    try testing.expectEqual(@as(u64, 1), fb.seq);
    try testing.expect(fb.presented_ns > 0);

    const hwnd = try b.hwndOf(win);
    _ = user32.SendMessageW(hwnd, WM.DISPLAYCHANGE, 32, 0);
    const deadline = @as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) + 3 * std.time.ns_per_s;
    var evs: [64]Event = undefined;
    var seen = false;
    while (!seen) {
        const n = p.pollEvents(&evs);
        for (evs[0..n]) |e| if (e == .monitors_changed) {
            seen = true;
        };
        if (@as(u64, @intCast(Io.Clock.awake.now(testing.io).nanoseconds)) >= deadline) return error.Timeout;
        if (!seen) p.waitEvents(deadline);
    }
    var mons: [8]types.MonitorInfo = undefined;
    const n = p.monitors(&mons);
    try testing.expect(n >= 1);
    try testing.expect(mons[0].refresh_mhz >= 5000 and mons[0].refresh_mhz <= 1_000_000);
    try testing.expect(mons[0].scale.factor >= 1.0);
    p.destroyWindow(win);
}

test "win32: InitOptions.refresh_ns fixes the frame interval" {
    const b = try Win32Backend.init(testing.allocator, testing.io, .{ .refresh_ns = 8_000_000 });
    defer b.deinit();
    const p = b.platform();
    const win = try p.createWindow(.{ .title = "zg refresh", .size = .{ .w = 320, .h = 200 } });
    try p.submit(.{ .request_frame = win });
    const fr = (try waitFor(p, .frame, win)).frame;
    try testing.expectEqual(@as(u32, 8_000_000), fr.refresh_ns);
    p.destroyWindow(win);
}
