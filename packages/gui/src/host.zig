//! `Host`: runs zg_gui windows on a real platform and renderer. It owns
//! the platform windows, a `Renderer` per window and the event pump:
//!
//! - each window renders on its own `RenderThread` (E02.F04.S03): the UI
//!   thread records a `DrawList` and posts it, never waiting for the GPU;
//!   the frame and configure events are forwarded to the thread's
//!   `FramePacer`. A Vulkan renderer with a swapchain paces on present
//!   waits (its `pacerCaps` pick the mode, its `presentWaiter` blocks);
//!   others pace on the platform's frame events. Without concurrency
//!   (`std.Io` that cannot spawn) or with `Options.render_thread = false`,
//!   the UI thread renders itself;
//! - platform events are routed to their window (`handlePlatformEvent`);
//! - a window that wants a frame asks the platform with `request_frame`
//!   and records when the platform's `frame` event arrives (frame pacing
//!   comes from the compositor, so idle windows cost nothing);
//! - a render thread that lost layer content wakes the UI, which repaints
//!   that window in full;
//! - appearance changes switch the app theme;
//! - the app clipboard is kept in sync with the system clipboard (local
//!   writes go out as `clipboard_write`; a `clipboard_changed` is read
//!   back into `App.clipboard`), and `App.primary` with the PRIMARY
//!   selection the same way when the desktop has one;
//! - `App.now_ms` is refreshed from the awake clock on every pump;
//! - with a runtime attached to the app (`App.attachRuntime`), the Host
//!   binds the UI thread with a waker that wakes the platform, and drains
//!   the mailbox (worker results) on every pump;
//! - window timers run on every pump, and `run` sleeps until the earliest;
//! - on Windows each window gets a UI Automation bridge (E04.F09.S01.T02),
//!   and on Linux the app gets an AT-SPI2 bridge (E04.F09.S01.T03) when a
//!   session bus address is given; either turns the accessibility trees on
//!   only when a screen reader asks;
//! - with a `FontText`, the glyph atlas is uploaded to every window's
//!   renderer (one texture per atlas page) before it renders; uploads go
//!   through the render thread's queue, ahead of the list that uses them.
//!
//! The app (`apps/zigguro`) creates the platform and calls `run`; tests
//! drive `pump` against the headless backend.

const std = @import("std");
const builtin = @import("builtin");
const zg_platform = @import("zg_platform");
const zg_vulkan = @import("zg_vulkan");
const geom = @import("core/geom.zig");
const app_mod = @import("core/app.zig");
const window_mod = @import("core/window.zig");
const view_mod = @import("core/view.zig");
const text = @import("paint/text.zig");
const DrawListCanvas = @import("paint/draw_list.zig").DrawListCanvas;
const image_textures = @import("image/textures.zig");
const FontText = @import("paint/font_text.zig").FontText;
const chrome = @import("dock/chrome.zig");
const hit_map = @import("dock/hit_map.zig");
const floating = @import("dock/floating.zig");
const uia = @import("a11y/uia/root.zig");
const atspi = @import("a11y/root.zig").atspi;
const is_linux = builtin.os.tag == .linux;
const zg_text = @import("zg_text");
const zg_core = @import("zg_core");
const zg_perf = @import("zg_perf");

const r2d = zg_vulkan.r2d;
const RenderThread = zg_vulkan.present.RenderThread;
const FramePacer = zg_vulkan.present.FramePacer;
const Platform = zg_platform.Platform;
const WindowId = zg_platform.types.WindowId;
const Event = zg_platform.event.Event;
const Window = window_mod.Window;

/// Creates a renderer for a platform window (defaults to
/// `zg_vulkan.createRenderer`, which falls back to software).
pub const RendererFactory = *const fn (gpa: std.mem.Allocator, io: std.Io, opts: r2d.RendererOptions) anyerror!r2d.Renderer;

/// Where a window's lists go.
pub const Output = union(enum) {
    /// Rendered on the UI thread.
    direct: r2d.Renderer,
    /// Posted to a render thread that owns the renderer.
    thread: *RenderThread,
};

/// One platform window and what draws it.
pub const HostWindow = struct {
    id: WindowId,
    win: *Window,
    /// The list being recorded: `own_list`, or one from the render thread.
    list: *r2d.DrawList,
    /// The list of a `.direct` output.
    own_list: r2d.DrawList,
    dlc: DrawListCanvas,
    out: Output,
    /// A `request_frame` is outstanding.
    frame_requested: bool = false,
    /// The platform reported the window fully hidden.
    occluded: bool = false,
    frames: u64 = 0,
    /// The `Window.ime.serial` last sent to the platform.
    ime_sent: u32 = 0,
    /// The chrome hit map the platform's hit test reads.
    chrome: hit_map.ChromeState,
    hit_rects: std.ArrayList(hit_map.HitMap.Entry) = .empty,
    /// The renderer texture of each glyph atlas page.
    pages: std.ArrayList(r2d.TextureId) = .empty,
    /// This renderer's copy of the app images (`App.images`).
    images: image_textures.Mirror = .{},
    /// The UI Automation bridge (Windows).
    uia: ?*uia.Bridge = null,

    fn createTexture(hw: *HostWindow, desc: r2d.TextureDesc) !r2d.TextureId {
        return switch (hw.out) {
            .direct => |r| r.createTexture(desc),
            .thread => |rt| rt.createTexture(desc),
        };
    }

    fn updateTexture(hw: *HostWindow, id: r2d.TextureId, rect: r2d.PxRect, pixels: []const u8, row_pitch: u32) !void {
        return switch (hw.out) {
            .direct => |r| r.updateTexture(id, rect, pixels, row_pitch),
            .thread => |rt| rt.updateTexture(id, rect, pixels, row_pitch),
        };
    }

    fn destroyTexture(hw: *HostWindow, id: r2d.TextureId) void {
        switch (hw.out) {
            .direct => |r| r.destroyTexture(id),
            .thread => |rt| rt.destroyTexture(id),
        }
    }

    fn imageOps(hw: *HostWindow) image_textures.Mirror.Ops {
        const Ops = struct {
            fn create(ctx: *anyopaque, w: u32, h: u32) anyerror!u32 {
                const x: *HostWindow = @ptrCast(@alignCast(ctx));
                return @intFromEnum(try x.createTexture(.{ .width = w, .height = h, .format = .rgba8 }));
            }
            fn update(ctx: *anyopaque, tex: u32, w: u32, h: u32, pixels: []const u8) anyerror!void {
                const x: *HostWindow = @ptrCast(@alignCast(ctx));
                try x.updateTexture(@enumFromInt(tex), .{ .x = 0, .y = 0, .w = w, .h = h }, pixels, w * 4);
            }
            fn destroy(ctx: *anyopaque, tex: u32) void {
                const x: *HostWindow = @ptrCast(@alignCast(ctx));
                x.destroyTexture(@enumFromInt(tex));
            }
        };
        return .{ .ctx = hw, .create = Ops.create, .update = Ops.update, .destroy = Ops.destroy };
    }

    /// Mirrors the app images into this window's renderer and points the
    /// canvas at the textures.
    fn syncImages(hw: *HostWindow, gpa: std.mem.Allocator, destroy: bool) !image_textures.Mirror.Change {
        const change = try hw.images.sync(gpa, &hw.win.app.images, hw.imageOps(), destroy);
        hw.dlc.images = @ptrCast(hw.images.tex.items);
        return change;
    }

    fn resize(hw: *HostWindow, size: r2d.Size, scale: f32) void {
        switch (hw.out) {
            .direct => |r| r.resize(size, scale),
            .thread => |rt| rt.onPlatformFrame(.{ .configure = .{ .size = size, .scale = scale } }),
        }
    }

    /// Renders or posts the recorded list.
    fn submit(hw: *HostWindow) !void {
        switch (hw.out) {
            .direct => |r| _ = try r.render(hw.list),
            .thread => |rt| {
                hw.list = rt.post(hw.list);
                hw.dlc.list = hw.list;
            },
        }
    }

    /// Waits until the posted frames have rendered (false on timeout).
    pub fn flush(hw: *HostWindow, timeout_ns: u64) bool {
        return switch (hw.out) {
            .direct => true,
            .thread => |rt| rt.waitIdle(timeout_ns),
        };
    }

    fn deinitOutput(hw: *HostWindow) void {
        switch (hw.out) {
            .direct => |r| {
                for (hw.pages.items) |t| if (t != .none) r.destroyTexture(t);
                hw.images.destroyAll(hw.imageOps());
                r.deinit();
            },
            // The renderer goes with its textures.
            .thread => |rt| rt.shutdown(),
        }
    }
};

/// The request id of the Host's own clipboard reads.
const clipboard_request: u32 = 0x4704_0001;
/// The request id of the Host's PRIMARY selection reads.
const primary_request: u32 = 0x4704_0002;
/// Widget clipboard reads: this tag ORed with the window id's low bits.
const widget_request_tag: u32 = 0x4710_0000;

/// Drives windows of one `App` on one `Platform`.
pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *app_mod.App,
    platform: Platform,
    text_sys: text.TextSystem,
    make_renderer: RendererFactory,
    windows: std.ArrayList(*HostWindow) = .empty,
    events: [256]Event = undefined,
    /// The font text system whose atlas the Host uploads (when `text_sys`
    /// is a `FontText`).
    fonts: ?*FontText = null,
    seen_evictions: u32 = 0,
    /// The app's runtime was bound to this thread.
    rt_bound: bool = false,
    atlas_updates: std.ArrayList(zg_text.cache.AtlasUpdate) = .empty,
    render_thread: bool,
    a11y: Accessibility = .{},
    /// The UI stall watchdog `run` feeds (E14.F01.S02.T01), if any.
    watchdog: ?*zg_perf.StallWatchdog = null,
    /// When `run` last handled input (`.awake` ns), for the activity signal.
    last_input_ns: u64 = 0,
    /// The AT-SPI2 bridge, made with the first window (Linux).
    atspi_bridge: if (is_linux) ?*atspi.Bridge else void = if (is_linux) null else {},

    /// Screen reader support.
    pub const Accessibility = struct {
        /// The session bus address the AT-SPI2 bridge starts from
        /// (Linux); null leaves windows invisible to screen readers there.
        session_address: ?[]const u8 = null,
        /// The version `Application.Version` reports.
        version: []const u8 = "0",
    };

    /// Options for `init`.
    pub const Options = struct {
        renderer: RendererFactory = zg_vulkan.createRenderer,
        /// Set when `text_sys` is this `FontText`'s system.
        fonts: ?*FontText = null,
        /// Render on a thread per window (falls back to the UI thread when
        /// the `Io` cannot spawn one).
        render_thread: bool = true,
        a11y: Accessibility = .{},
        /// A stall watchdog for the UI thread (`run` calls its heartbeat
        /// and enterWait).
        watchdog: ?*zg_perf.StallWatchdog = null,
    };

    /// A host for `app` on `platform`; text goes through `text_sys`. The
    /// Host must not move once a window is open.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, app: *app_mod.App, platform: Platform, text_sys: text.TextSystem, opts: Options) Host {
        if (zg_perf.runtime.activity.global.io == null) zg_perf.runtime.activity.global.install(io);
        return .{ .gpa = gpa, .io = io, .app = app, .platform = platform, .text_sys = text_sys, .make_renderer = opts.renderer, .fonts = opts.fonts, .render_thread = opts.render_thread, .a11y = opts.a11y, .watchdog = opts.watchdog };
    }

    /// Closes every window.
    pub fn deinit(h: *Host) void {
        while (h.windows.items.len > 0) h.close(h.windows.items[h.windows.items.len - 1]);
        if (is_linux) if (h.atspi_bridge) |b| b.deinit();
        h.windows.deinit(h.gpa);
        h.atlas_updates.deinit(h.gpa);
    }

    /// The primary monitor's scale (1 when unknown).
    fn monitorScale(h: *Host) f32 {
        var mons: [8]zg_platform.types.MonitorInfo = undefined;
        const n = @min(h.platform.monitors(&mons), mons.len);
        for (mons[0..n]) |m| if (m.primary) return m.scale.factor;
        return if (n > 0) mons[0].scale.factor else 1;
    }

    /// Options for `open`.
    pub const OpenOptions = struct {
        title: []const u8 = "zigguro",
        /// Initial content size in logical pixels.
        size: geom.Size = .{ .w = 1280, .h = 800 },
        root: ?view_mod.AnyView = null,
        /// The outer top-left corner on the virtual screen (physical
        /// pixels); null lets the system place it. Ignored on Wayland.
        position: ?zg_platform.types.PxPoint = null,
        /// Keep it above normal windows (floating tool windows).
        always_on_top: bool = false,
    };

    /// Opens a platform window showing `opts.root`.
    pub fn open(h: *Host, opts: OpenOptions) !*HostWindow {
        // Windows are created in physical pixels; the first configure
        // event reports the real size and scale.
        const scale = h.monitorScale();
        const id = try h.platform.createWindow(.{
            .title = opts.title,
            .size = .{ .w = @intFromFloat(@max(1, @round(opts.size.w * scale))), .h = @intFromFloat(@max(1, @round(opts.size.h * scale))) },
            .position = opts.position,
            .always_on_top = opts.always_on_top,
        });
        errdefer h.platform.destroyWindow(id);
        const hw = try h.gpa.create(HostWindow);
        errdefer h.gpa.destroy(hw);
        hw.* = .{ .id = id, .win = undefined, .list = undefined, .own_list = .init(h.gpa), .dlc = undefined, .out = undefined, .chrome = .init(h.gpa) };
        errdefer hw.own_list.deinit();
        const renderer = h.make_renderer(h.gpa, h.io, .{ .target = try h.platform.surfaceTarget(id), .window = id }) catch |err| switch (err) {
            // The software renderer cannot draw to a native target such as
            // a Win32 HWND (that needs a swapchain): use the platform's CPU
            // presenter instead.
            error.Unsupported => try h.make_renderer(h.gpa, h.io, .{ .target = .{ .external = try h.platform.cpuPresenter(id) }, .window = id }),
            else => return err,
        };
        hw.out = .{ .direct = renderer };
        if (h.render_thread) {
            const notify: RenderThread.Notify = .{ .ctx = &h.platform, .wake_ui = wakeFromRenderer };
            const pace = pacingFor(renderer);
            if (RenderThread.spawn(h.gpa, h.io, renderer, .{ .pacing = pace.mode, .waiter = pace.waiter, .notify = notify })) |rt| {
                hw.out = .{ .thread = rt };
            } else |err| switch (err) {
                error.ConcurrencyUnavailable => {},
                else => {
                    renderer.deinit();
                    return err;
                },
            }
        }
        errdefer hw.deinitOutput();
        hw.list = switch (hw.out) {
            .direct => &hw.own_list,
            .thread => |rt| rt.firstList(),
        };
        hw.dlc = .init(hw.list);
        hw.win = try h.app.openWindow(.{ .size = opts.size, .scale = scale, .root = opts.root, .text = h.text_sys, .canvas = hw.dlc.canvas() });
        errdefer h.app.closeWindow(hw.win);
        try h.windows.append(h.gpa, hw);
        if (builtin.os.tag == .windows) h.openUia(hw);
        if (is_linux) h.openAtspi(hw);
        // The new renderer has none of the atlas yet.
        if (h.fonts) |ft| ft.reuploadAll();
        return hw;
    }

    /// Opens floating dock windows on this Host (`dock.floating`).
    pub fn windowOpener(h: *Host) floating.WindowOpener {
        return .{ .ctx = h, .open = openForFloat, .open_placed = openPlacedForFloat, .set_always_on_top = aboveForFloat, .monitors = monitorsForFloat };
    }

    fn openForFloat(ctx: *anyopaque, title: []const u8, size: geom.Size, root: view_mod.AnyView) anyerror!*Window {
        return openPlacedForFloat(ctx, title, size, root, .{});
    }

    fn openPlacedForFloat(ctx: *anyopaque, title: []const u8, size: geom.Size, root: view_mod.AnyView, at: floating.Placement) anyerror!*Window {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const hw = try h.open(.{ .title = title, .size = size, .root = root, .position = at.position, .always_on_top = at.always_on_top });
        return hw.win;
    }

    fn aboveForFloat(ctx: *anyopaque, w: *Window, on: bool) bool {
        const h: *Host = @ptrCast(@alignCast(ctx));
        for (h.windows.items) |hw| if (hw.win == w) {
            h.platform.submit(.{ .set_always_on_top = .{ .win = hw.id, .on = on } }) catch return false;
            return true;
        };
        return false;
    }

    fn monitorsForFloat(ctx: *anyopaque, out: []zg_platform.types.MonitorInfo) usize {
        const h: *Host = @ptrCast(@alignCast(ctx));
        return h.platform.monitors(out);
    }

    /// Hooks a UI Automation bridge to `hw`; without one the window is
    /// just not accessible, so failures are ignored.
    fn openUia(h: *Host, hw: *HostWindow) void {
        const b = uia.Bridge.create(h.gpa, uia.Api.windows(), hw.win, @intFromEnum(hw.id)) catch return;
        b.install(h.platform.native(), hw.id) catch {
            b.close();
            return;
        };
        hw.uia = b;
    }

    /// Exposes `hw` through the AT-SPI2 bridge, starting it with the first
    /// window. Without a session bus the window just isn't accessible.
    fn openAtspi(h: *Host, hw: *HostWindow) void {
        const b = h.atspi_bridge orelse blk: {
            const addr = h.a11y.session_address orelse return;
            const b = atspi.Bridge.init(h.gpa, h.io, .{ .session_address = addr, .version = h.a11y.version }) catch return;
            h.atspi_bridge = b;
            break :blk b;
        };
        b.addWindow(hw.win, @intFromEnum(hw.id)) catch {};
    }

    /// Closes `hw` and its platform window.
    pub fn close(h: *Host, hw: *HostWindow) void {
        for (h.windows.items, 0..) |x, i| if (x == hw) {
            _ = h.windows.swapRemove(i);
            break;
        };
        // Before the window goes: the bridge detaches its tree from it.
        if (hw.uia) |b| b.close();
        if (is_linux) if (h.atspi_bridge) |b| b.removeWindow(hw.win);
        h.app.closeWindow(hw.win);
        hw.deinitOutput();
        hw.pages.deinit(h.gpa);
        hw.images.deinit(h.gpa);
        hw.own_list.deinit();
        h.platform.destroyWindow(hw.id);
        // The platform no longer asks the destroyed window's hit test.
        hw.chrome.deinit();
        hw.hit_rects.deinit(h.gpa);
        h.gpa.destroy(hw);
    }

    /// Publishes `hw`'s chrome hit map when it changed, installing the hit
    /// test the first time the window is client-decorated.
    fn updateHitMap(h: *Host, hw: *HostWindow) !void {
        if (!hw.win.chrome.client and !hw.chrome.installed) return;
        const m = try chrome.buildHitMap(hw.win, h.gpa, &hw.hit_rects);
        _ = try hw.chrome.publish(m);
        if (!hw.chrome.installed) {
            try h.platform.submit(.{ .set_hit_test = .{ .win = hw.id, .f = hit_map.ChromeState.hitTestFn(), .ctx = &hw.chrome } });
            hw.chrome.installed = true;
        }
    }

    /// The host window for platform window `id`.
    pub fn find(h: *const Host, id: WindowId) ?*HostWindow {
        for (h.windows.items) |hw| if (hw.id == id) return hw;
        return null;
    }

    /// Handles every pending event without blocking, renders windows the
    /// platform asked to draw and requests frames for dirty windows.
    /// Returns the number of events handled.
    pub fn pump(h: *Host) !usize {
        h.app.now_ms = @intCast(@max(0, @divFloor(std.Io.Clock.awake.now(h.io).nanoseconds, std.time.ns_per_ms)));
        if (h.app.rt) |rt| if (!h.rt_bound) {
            // The Host must not move after its first pump.
            rt.bindUiThread(.{ .ctx = &h.platform, .wakeFn = wakePlatform });
            h.rt_bound = true;
        };
        var total: usize = h.app.drainMessages();
        while (true) {
            const n = h.platform.pollEvents(&h.events);
            for (h.events[0..n]) |ev| try h.handle(ev);
            total += n;
            if (n < h.events.len) break;
        }
        for (h.windows.items) |hw| hw.win.tick(h.app.now_ms);
        h.app.flushEffects();
        try h.flushClipboard(&h.app.clipboard, .clipboard);
        if (h.app.has_primary) try h.flushClipboard(&h.app.primary, .primary);
        for (h.windows.items) |hw| {
            for (hw.win.window_ops.items) |op| try h.platform.submit(.{ .request_state = .{ .win = hw.id, .op = op } });
            if (hw.win.clip_read.send) |r| {
                hw.win.clip_read.send = null;
                hw.win.clip_read.wait = r;
                try h.platform.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = r.mime, .request = widget_request_tag | (@intFromEnum(hw.id) & 0xffff) } });
            }
            if (hw.win.drop.pending) |accept| {
                hw.win.drop.pending = null;
                const mime = hw.win.drop.mime;
                const effect: zg_platform.clipboard.DragActions = if (mime == .zigguro_internal) .{ .move = true } else .{ .copy = true };
                try h.platform.submit(.{ .set_drop_effect = .{ .win = hw.id, .accept = if (accept) mime else null, .effect = if (accept) effect else .{} } });
            }
            if (hw.win.drag_out) |bytes| {
                hw.win.drag_out = null;
                defer h.gpa.free(bytes);
                const items = [_]zg_platform.clipboard.ClipItem{.{ .mime = .zigguro_internal, .data = bytes }};
                // Without platform drags, end it at once: nothing took it.
                h.platform.submit(.{ .start_drag = .{ .win = hw.id, .items = &items, .allowed = .{ .move = true } } }) catch hw.win.dragFinished(.{});
            }
            hw.win.window_ops.clearRetainingCapacity();
            try h.updateHitMap(hw);
        }
        for (h.windows.items) |hw| if (hw.win.ime.serial != hw.ime_sent) {
            hw.ime_sent = hw.win.ime.serial;
            const im = &hw.win.ime;
            try h.platform.submit(.{ .set_ime_state = .{
                .win = hw.id,
                .enabled = im.enabled,
                .purpose = im.purpose,
                .caret_rect_px = pxRect(im.caret, hw.win.scale),
                .surrounding = im.surrounding(),
            } });
        };
        var i: usize = 0;
        while (i < h.windows.items.len) {
            const hw = h.windows.items[i];
            if (hw.win.close_requested) {
                h.close(hw);
                continue;
            }
            if (hw.out == .thread and hw.out.thread.takeRedraw()) hw.win.themeChanged(false);
            if (!hw.frame_requested and !hw.occluded and hw.win.wantsFrame()) {
                try h.platform.submit(.{ .request_frame = hw.id });
                hw.frame_requested = true;
            }
            i += 1;
        }
        return total;
    }

    fn flushClipboard(h: *Host, c: *app_mod.Clipboard, which: zg_platform.clipboard.Selection) !void {
        if (!c.pending_write) return;
        c.pending_write = false;
        const items = [_]zg_platform.clipboard.ClipItem{.{ .mime = .text_utf8, .data = c.get() }};
        try h.platform.submit(.{ .clipboard_write = .{ .which = which, .items = &items } });
    }

    fn wakePlatform(ctx: ?*anyopaque) void {
        const p: *Platform = @ptrCast(@alignCast(ctx.?));
        p.wake();
    }

    fn wakeFromRenderer(ctx: *anyopaque) void {
        wakePlatform(ctx);
    }

    /// Waits until every window's posted frames have rendered (tests and
    /// screenshots). False when `timeout_ns` passed first.
    pub fn flush(h: *Host, timeout_ns: u64) bool {
        var ok = true;
        for (h.windows.items) |hw| ok = hw.flush(timeout_ns) and ok;
        return ok;
    }

    fn handle(h: *Host, ev: Event) !void {
        switch (ev) {
            .appearance_changed => |a| {
                h.app.onAppearance(a);
                return;
            },
            .clipboard_changed => |which| {
                switch (which) {
                    .clipboard => try h.platform.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = clipboard_request } }),
                    .primary => if (h.app.has_primary) try h.platform.submit(.{ .clipboard_read = .{ .which = .primary, .mime = .text_utf8, .request = primary_request } }),
                }
                return;
            },
            .clipboard_data => |d| {
                if (d.mime == .text_utf8) switch (d.request) {
                    clipboard_request => h.app.clipboard.replace(h.gpa, h.platform.payload(d.data)),
                    primary_request => h.app.primary.replace(h.gpa, h.platform.payload(d.data)),
                    else => {},
                };
                if (d.request & 0xffff_0000 == widget_request_tag) for (h.windows.items) |hw| {
                    if (@intFromEnum(hw.id) & 0xffff == d.request & 0xffff) hw.win.clipboardArrived(d.mime, h.platform.payload(d.data));
                };
                if (d.data.large) h.platform.release(d.data);
                return;
            },
            else => {},
        }
        const id = ev.window() orelse return;
        const hw = h.find(id) orelse return;
        hw.win.handlePlatformEvent(ev, h.platform);
        switch (ev) {
            .window_configure => |c| hw.resize(.{ .w = c.size.w, .h = c.size.h }, c.scale.factor),
            .window_occluded => |o| hw.occluded = o.occluded,
            .frame => {
                hw.frame_requested = false;
                if (hw.out == .thread) hw.out.thread.onPlatformFrame(.frame);
                if (h.fonts) |ft| {
                    ft.scale = hw.win.scale;
                    ft.frame +%= 1;
                }
                // Glyph quads are mapped to textures as they are recorded,
                // so the page textures must exist first. A frame that
                // opened a new atlas page is painted again once the page
                // has its texture.
                const pages_before = hw.pages.items.len;
                hw.list.setGlyphPages(hw.pages.items);
                _ = try hw.syncImages(h.gpa, true);
                var st = hw.win.frame();
                // Images are mapped to textures as they are recorded too:
                // one the frame put on the GPU is painted again once its
                // texture exists (new pixels in a mapped one just upload).
                if (try hw.syncImages(h.gpa, false) == .created) {
                    hw.win.themeChanged(false);
                    const again = hw.win.frame();
                    st.presented = st.presented or again.presented;
                }
                if (h.fonts != null) {
                    try h.uploadGlyphs();
                    if (hw.pages.items.len != pages_before) {
                        hw.list.setGlyphPages(hw.pages.items);
                        hw.win.themeChanged(false);
                        const again = hw.win.frame();
                        st.presented = st.presented or again.presented;
                    }
                }
                if (st.presented) {
                    try hw.submit();
                    hw.frames += 1;
                }
            },
            else => {},
        }
    }

    /// Uploads the atlas regions rasterized since the last call to every
    /// window's renderer, creating a texture per new page.
    fn uploadGlyphs(h: *Host) !void {
        const ft = h.fonts.?;
        if (ft.evictions != h.seen_evictions) {
            h.seen_evictions = ft.evictions;
            for (h.windows.items) |hw| hw.win.themeChanged(false);
        }
        h.atlas_updates.clearRetainingCapacity();
        try ft.takeUpdates(&h.atlas_updates);
        if (h.atlas_updates.items.len == 0) return;
        for (h.windows.items) |hw| {
            for (h.atlas_updates.items) |u| {
                while (hw.pages.items.len <= u.page) try hw.pages.append(h.gpa, .none);
                if (hw.pages.items[u.page] == .none) {
                    hw.pages.items[u.page] = try hw.createTexture(.{
                        .width = u.page_size,
                        .height = u.page_size,
                        .format = if (u.format == .r8) .r8 else .rgba8,
                    });
                }
                try hw.updateTexture(hw.pages.items[u.page], .{ .x = u.rect.x, .y = u.rect.y, .w = u.rect.w, .h = u.rect.h }, u.pixels, u.row_pitch);
            }
        }
    }

    /// Runs until every window is closed, sleeping between events.
    pub fn run(h: *Host) !void {
        const signal = &zg_perf.runtime.activity.global;
        while (h.windows.items.len > 0) {
            if (h.watchdog) |w| w.heartbeat();
            // Background schedulers yield while the frame is built
            // (E14.F01.S02.T02); idle is derived from last_input_ns.
            const start = zg_core.time.nowNs(h.io);
            signal.publish(.frame_busy, start);
            const handled = try h.pump();
            if (handled > 0) h.last_input_ns = start;
            signal.publish(.interactive, h.last_input_ns);
            if (h.windows.items.len == 0) break;
            // Sleep until the next event or the earliest window timer.
            var deadline: ?u64 = null;
            for (h.windows.items) |hw| if (hw.win.nextDeadline()) |d| {
                deadline = if (deadline) |x| @min(x, d) else d;
            };
            if (h.watchdog) |w| w.enterWait();
            h.platform.waitEvents(if (deadline) |d| d *| std.time.ns_per_ms else null);
        }
    }
};

/// A render thread's pacing mode and present waiter.
pub const Pacing = struct { mode: FramePacer.Mode, waiter: ?FramePacer.PresentWaiter };

/// How a render thread paces `r`: present waits for a Vulkan swapchain
/// that supports them, else the platform's frame events.
pub fn pacingFor(r: zg_vulkan.r2d.Renderer) Pacing {
    const vk = zg_vulkan.vulkanPacing(r) orelse return .{ .mode = .platform_frame, .waiter = null };
    const mode = FramePacer.selectMode(vk.caps);
    return switch (mode) {
        .present_wait, .present_wait2 => if (vk.waiter) |w| .{ .mode = mode, .waiter = w } else .{ .mode = .platform_frame, .waiter = null },
        .platform_frame, .immediate => .{ .mode = mode, .waiter = null },
        // A swapchain without present waits: the compositor's frame events
        // still pace best.
        else => .{ .mode = .platform_frame, .waiter = null },
    };
}

/// `r` (logical) in physical pixels.
fn pxRect(r: geom.Rect, scale: f32) zg_platform.types.PxRect {
    return .{
        .x = @intFromFloat(@round(r.x * scale)),
        .y = @intFromFloat(@round(r.y * scale)),
        .w = @intFromFloat(@max(0, @round(r.w * scale))),
        .h = @intFromFloat(@max(0, @round(r.h * scale))),
    };
}
