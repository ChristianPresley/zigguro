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
//!   back into `App.clipboard`);
//! - `App.now_ms` is refreshed from the awake clock on every pump;
//! - with a runtime attached to the app (`App.attachRuntime`), the Host
//!   binds the UI thread with a waker that wakes the platform, and drains
//!   the mailbox (worker results) on every pump;
//! - window timers run on every pump, and `run` sleeps until the earliest;
//! - with a `FontText`, the glyph atlas is uploaded to every window's
//!   renderer (one texture per atlas page) before it renders; uploads go
//!   through the render thread's queue, ahead of the list that uses them.
//!
//! The app (`apps/zigguro`) creates the platform and calls `run`; tests
//! drive `pump` against the headless backend.

const std = @import("std");
const zg_platform = @import("zg_platform");
const zg_vulkan = @import("zg_vulkan");
const geom = @import("core/geom.zig");
const app_mod = @import("core/app.zig");
const window_mod = @import("core/window.zig");
const view_mod = @import("core/view.zig");
const text = @import("paint/text.zig");
const DrawListCanvas = @import("paint/draw_list.zig").DrawListCanvas;
const FontText = @import("paint/font_text.zig").FontText;
const zg_text = @import("zg_text");

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
    /// The renderer texture of each glyph atlas page.
    pages: std.ArrayList(r2d.TextureId) = .empty,

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
                r.deinit();
            },
            // The renderer goes with its textures.
            .thread => |rt| rt.shutdown(),
        }
    }
};

/// The request id of the Host's own clipboard reads.
const clipboard_request: u32 = 0x4704_0001;

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

    /// Options for `init`.
    pub const Options = struct {
        renderer: RendererFactory = zg_vulkan.createRenderer,
        /// Set when `text_sys` is this `FontText`'s system.
        fonts: ?*FontText = null,
        /// Render on a thread per window (falls back to the UI thread when
        /// the `Io` cannot spawn one).
        render_thread: bool = true,
    };

    /// A host for `app` on `platform`; text goes through `text_sys`. The
    /// Host must not move once a window is open.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, app: *app_mod.App, platform: Platform, text_sys: text.TextSystem, opts: Options) Host {
        return .{ .gpa = gpa, .io = io, .app = app, .platform = platform, .text_sys = text_sys, .make_renderer = opts.renderer, .fonts = opts.fonts, .render_thread = opts.render_thread };
    }

    /// Closes every window.
    pub fn deinit(h: *Host) void {
        while (h.windows.items.len > 0) h.close(h.windows.items[h.windows.items.len - 1]);
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
    };

    /// Opens a platform window showing `opts.root`.
    pub fn open(h: *Host, opts: OpenOptions) !*HostWindow {
        // Windows are created in physical pixels; the first configure
        // event reports the real size and scale.
        const scale = h.monitorScale();
        const id = try h.platform.createWindow(.{
            .title = opts.title,
            .size = .{ .w = @intFromFloat(@max(1, @round(opts.size.w * scale))), .h = @intFromFloat(@max(1, @round(opts.size.h * scale))) },
        });
        errdefer h.platform.destroyWindow(id);
        const hw = try h.gpa.create(HostWindow);
        errdefer h.gpa.destroy(hw);
        hw.* = .{ .id = id, .win = undefined, .list = undefined, .own_list = .init(h.gpa), .dlc = undefined, .out = undefined };
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
        // The new renderer has none of the atlas yet.
        if (h.fonts) |ft| ft.reuploadAll();
        return hw;
    }

    /// Closes `hw` and its platform window.
    pub fn close(h: *Host, hw: *HostWindow) void {
        for (h.windows.items, 0..) |x, i| if (x == hw) {
            _ = h.windows.swapRemove(i);
            break;
        };
        h.app.closeWindow(hw.win);
        hw.deinitOutput();
        hw.pages.deinit(h.gpa);
        hw.own_list.deinit();
        h.platform.destroyWindow(hw.id);
        h.gpa.destroy(hw);
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
        if (h.app.clipboard.pending_write) {
            h.app.clipboard.pending_write = false;
            const items = [_]zg_platform.clipboard.ClipItem{.{ .mime = .text_utf8, .data = h.app.clipboard.get() }};
            try h.platform.submit(.{ .clipboard_write = .{ .which = .clipboard, .items = &items } });
        }
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
                if (which == .clipboard) try h.platform.submit(.{ .clipboard_read = .{ .which = .clipboard, .mime = .text_utf8, .request = clipboard_request } });
                return;
            },
            .clipboard_data => |d| {
                if (d.request == clipboard_request and d.mime == .text_utf8) h.app.clipboard.replace(h.gpa, h.platform.payload(d.data));
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
                var st = hw.win.frame();
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
        while (h.windows.items.len > 0) {
            _ = try h.pump();
            if (h.windows.items.len == 0) break;
            // Sleep until the next event or the earliest window timer.
            var deadline: ?u64 = null;
            for (h.windows.items) |hw| if (hw.win.nextDeadline()) |d| {
                deadline = if (deadline) |x| @min(x, d) else d;
            };
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
