//! `Host`: runs zg_gui windows on a real platform and renderer. It owns
//! the platform windows, one `r2d.DrawList` and `Renderer` per window, and
//! the event pump:
//!
//! - platform events are routed to their window (`handlePlatformEvent`);
//! - a window that wants a frame asks the platform with `request_frame`
//!   and renders when the platform's `frame` event arrives (frame pacing
//!   comes from the compositor, so idle windows cost nothing);
//! - appearance changes switch the app theme.
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
};

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

    /// Options for `init`.
    pub const Options = struct {
        renderer: RendererFactory = zg_vulkan.createRenderer,
    };

    /// A host for `app` on `platform`; text goes through `text_sys`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, app: *app_mod.App, platform: Platform, text_sys: text.TextSystem, opts: Options) Host {
        return .{ .gpa = gpa, .io = io, .app = app, .platform = platform, .text_sys = text_sys, .make_renderer = opts.renderer };
    }

    /// Closes every window.
    pub fn deinit(h: *Host) void {
        while (h.windows.items.len > 0) h.close(h.windows.items[h.windows.items.len - 1]);
        h.windows.deinit(h.gpa);
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
        const id = try h.platform.createWindow(.{
            .title = opts.title,
            .size = .{ .w = @intFromFloat(@max(1, opts.size.w)), .h = @intFromFloat(@max(1, opts.size.h)) },
        });
        errdefer h.platform.destroyWindow(id);
        const hw = try h.gpa.create(HostWindow);
        errdefer h.gpa.destroy(hw);
        hw.* = .{ .id = id, .win = undefined, .list = .init(h.gpa), .dlc = undefined, .renderer = undefined };
        errdefer hw.list.deinit();
        hw.dlc = .init(&hw.list);
        hw.renderer = try h.make_renderer(h.gpa, h.io, .{ .target = try h.platform.surfaceTarget(id), .window = id });
        errdefer hw.renderer.deinit();
        hw.win = try h.app.openWindow(.{ .size = opts.size, .root = opts.root, .text = h.text_sys, .canvas = hw.dlc.canvas() });
        errdefer h.app.closeWindow(hw.win);
        try h.windows.append(h.gpa, hw);
        return hw;
    }

    /// Closes `hw` and its platform window.
    pub fn close(h: *Host, hw: *HostWindow) void {
        for (h.windows.items, 0..) |x, i| if (x == hw) {
            _ = h.windows.swapRemove(i);
            break;
        };
        h.app.closeWindow(hw.win);
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
        var total: usize = 0;
        while (true) {
            const n = h.platform.pollEvents(&h.events);
            for (h.events[0..n]) |ev| try h.handle(ev);
            total += n;
            if (n < h.events.len) break;
        }
        h.app.flushEffects();
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

    fn handle(h: *Host, ev: Event) !void {
        switch (ev) {
            .appearance_changed => |a| {
                h.app.onAppearance(a);
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
                const st = hw.win.frame();
                if (st.presented) {
                    _ = try hw.renderer.render(&hw.list);
                    hw.frames += 1;
                }
            },
            else => {},
        }
    }

    /// Runs until every window is closed, sleeping between events.
    pub fn run(h: *Host) !void {
        while (h.windows.items.len > 0) {
            _ = try h.pump();
            if (h.windows.items.len == 0) break;
            h.platform.waitEvents(null);
        }
    }
};
