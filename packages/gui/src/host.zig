//! `Host`: runs zg_gui windows on a real platform and renderer. It owns
//! the platform windows, one `r2d.DrawList` and `Renderer` per window, and
//! the event pump:
//!
//! - platform events are routed to their window (`handlePlatformEvent`);
//! - a window that wants a frame asks the platform with `request_frame`
//!   and renders when the platform's `frame` event arrives (frame pacing
//!   comes from the compositor, so idle windows cost nothing);
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
//!   renderer (one texture per atlas page) before it renders.
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
const Platform = zg_platform.Platform;
const WindowId = zg_platform.types.WindowId;
const Event = zg_platform.event.Event;
const Window = window_mod.Window;

/// Creates a renderer for a platform window (defaults to
/// `zg_vulkan.createRenderer`, which falls back to software).
pub const RendererFactory = *const fn (gpa: std.mem.Allocator, io: std.Io, opts: r2d.RendererOptions) anyerror!r2d.Renderer;

/// One platform window and what draws it.
pub const HostWindow = struct {
    id: WindowId,
    win: *Window,
    list: r2d.DrawList,
    dlc: DrawListCanvas,
    renderer: r2d.Renderer,
    /// A `request_frame` is outstanding.
    frame_requested: bool = false,
    /// The platform reported the window fully hidden.
    occluded: bool = false,
    frames: u64 = 0,
    /// The renderer texture of each glyph atlas page.
    pages: std.ArrayList(r2d.TextureId) = .empty,
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

    /// Options for `init`.
    pub const Options = struct {
        renderer: RendererFactory = zg_vulkan.createRenderer,
        /// Set when `text_sys` is this `FontText`'s system.
        fonts: ?*FontText = null,
    };

    /// A host for `app` on `platform`; text goes through `text_sys`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, app: *app_mod.App, platform: Platform, text_sys: text.TextSystem, opts: Options) Host {
        return .{ .gpa = gpa, .io = io, .app = app, .platform = platform, .text_sys = text_sys, .make_renderer = opts.renderer, .fonts = opts.fonts };
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
        hw.* = .{ .id = id, .win = undefined, .list = .init(h.gpa), .dlc = undefined, .renderer = undefined };
        errdefer hw.list.deinit();
        hw.dlc = .init(&hw.list);
        hw.renderer = h.make_renderer(h.gpa, h.io, .{ .target = try h.platform.surfaceTarget(id), .window = id }) catch |err| switch (err) {
            // The software renderer cannot draw to a native target such as
            // a Win32 HWND (that needs a swapchain): use the platform's CPU
            // presenter instead.
            error.Unsupported => try h.make_renderer(h.gpa, h.io, .{ .target = .{ .external = try h.platform.cpuPresenter(id) }, .window = id }),
            else => return err,
        };
        errdefer hw.renderer.deinit();
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
        for (hw.pages.items) |t| if (t != .none) hw.renderer.destroyTexture(t);
        hw.pages.deinit(h.gpa);
        hw.renderer.deinit();
        hw.list.deinit();
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
            .window_configure => |c| hw.renderer.resize(.{ .w = c.size.w, .h = c.size.h }, c.scale.factor),
            .window_occluded => |o| hw.occluded = o.occluded,
            .frame => {
                hw.frame_requested = false;
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
                    _ = try hw.renderer.render(&hw.list);
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
                    hw.pages.items[u.page] = try hw.renderer.createTexture(.{
                        .width = u.page_size,
                        .height = u.page_size,
                        .format = if (u.format == .r8) .r8 else .rgba8,
                    });
                }
                try hw.renderer.updateTexture(hw.pages.items[u.page], .{ .x = u.rect.x, .y = u.rect.y, .w = u.rect.w, .h = u.rect.h }, u.pixels, u.row_pitch);
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
