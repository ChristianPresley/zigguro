//! The performance HUD (E14.F03.S01.T02): a debug-layer overlay in a
//! window corner with the frame-time graph and text rows from
//! `hud_model`.
//!
//! Zero idle cost: the HUD never asks for frames on its own while nothing
//! else draws. A 4 Hz timer refreshes it while frames keep arriving; it is
//! armed by the timeline's frame listener and not re-armed once a tick
//! sees no frames besides the HUD's own repaint. The last refresh then
//! shows "idle" with the frozen values. Between refreshes the window
//! replays the HUD's cached paint, so other frames do not rebuild it.
//!
//! Self-measurement: the HUD's build runs in the zone `perf.hud`.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_perf = @import("zg_perf");
const model_mod = @import("hud_model.zig");
const graph = @import("hud_graph.zig");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const Ui = zg_gui.Ui;
const overlay = zg_gui.w.overlay;
const FrameTimeline = zg_perf.frame.FrameTimeline;
const FlightRecorder = zg_perf.trace.FlightRecorder;

/// How often the HUD refreshes while frames arrive.
pub const refresh_ms = 250;

pub const HudOptions = struct {
    position: overlay.Corner = .top_right,
    frames: u16 = 240,
    show_memory: bool = true,
    show_latency: bool = true,
    /// Background opacity.
    opacity: f32 = 0.85,
    /// Graph size in logical pixels.
    graph_w: f32 = 240,
    graph_h: f32 = 64,
    /// Wakeup and memory numbers, when their subsystems exist.
    sources: model_mod.Sources = .{},
};

/// Where bar clicks go: the flight recorder's `trigger(.manual, note)`.
pub const Recorder = struct {
    ctx: *anyopaque,
    trigger: *const fn (ctx: *anyopaque, note: []const u8) void,

    /// Bar clicks dump `fr`.
    pub fn flight(fr: *FlightRecorder) Recorder {
        return .{ .ctx = fr, .trigger = struct {
            fn f(ctx: *anyopaque, note: []const u8) void {
                const r: *FlightRecorder = @ptrCast(@alignCast(ctx));
                r.trigger(.manual, note);
            }
        }.f };
    }
};

pub const Hud = struct {
    pub const view_name = "perf_hud";

    gpa: Allocator,
    timeline: *FrameTimeline,
    opts: HudOptions,
    model: model_mod.Model,
    /// Bar clicks dump the flight recorder, when there is one.
    recorder: ?Recorder = null,
    win: ?*Window = null,
    overlay_id: overlay.OverlayId = .none,
    timer: Window.TimerId = .none,
    /// The view observes it; notifying it rebuilds the HUD.
    entity: zg_gui.core.EntityId = .none,
    /// `timeline.newest` expected after the last refresh's own repaint:
    /// anything newer is other activity.
    seen: u64 = 0,
    /// Refreshes so far (tests).
    refreshes: u32 = 0,

    pub fn init(gpa: Allocator, timeline: *FrameTimeline, opts: HudOptions) !*Hud {
        const h = try gpa.create(Hud);
        errdefer gpa.destroy(h);
        h.* = .{ .gpa = gpa, .timeline = timeline, .opts = opts, .model = try .init(gpa, opts.frames) };
        return h;
    }

    /// Hides the HUD and frees it. Not `deinit`: a view's `deinit` runs
    /// when the window unmounts it, and the HUD outlives its overlay.
    pub fn destroy(h: *Hud) void {
        if (h.win) |w| h.setVisible(w, false);
        h.model.deinit();
        h.gpa.destroy(h);
    }

    /// The HUD's view (for `openOverlay`).
    pub fn view(h: *Hud) zg_gui.AnyView {
        return .of(h);
    }

    pub fn isVisible(h: *const Hud) bool {
        return h.win != null;
    }

    /// Shows or hides the HUD in `win`.
    pub fn setVisible(h: *Hud, win: *Window, visible: bool) void {
        if (visible == h.isVisible()) return;
        if (!visible) {
            const w = h.win.?;
            if (h.timer != .none) w.cancelTimer(h.timer);
            h.timer = .none;
            h.timeline.setListener(null);
            w.closeOverlay(h.overlay_id);
            h.overlay_id = .none;
            if (!h.entity.isNone()) w.app.release(h.entity);
            h.entity = .none;
            h.win = null;
            return;
        }
        h.entity = (win.app.new(u8, 0) catch return).id;
        h.overlay_id = win.openOverlay(h.view(), .{
            .layer = .debug,
            .anchor = .{ .corner_at = .{ .corner = h.opts.position, .margin = 8 } },
            .light_dismiss = false,
            .restore_focus = false,
            .chrome = false,
            .label = "Performance HUD",
            .test_id = "perf.hud",
        }) catch {
            win.app.release(h.entity);
            h.entity = .none;
            return;
        };
        h.win = win;
        h.timeline.setListener(.{ .ctx = h, .f = onFrame });
        // The frame that shows the overlay arms the timer (the app clock
        // may not run yet).
        h.refresh(false);
    }

    /// Toggles the HUD in `win` (`perf.hud.toggle`).
    pub fn toggle(h: *Hud, win: *Window) void {
        h.setVisible(win, !h.isVisible());
    }

    fn arm(h: *Hud) void {
        const w = h.win orelse return;
        if (h.timer != .none) return;
        h.timer = w.setTimer(w.app.now_ms + refresh_ms, .{ .ctx = h, .f = onTimer }) catch .none;
    }

    /// Recomputes the model and rebuilds the view (one frame).
    fn refresh(h: *Hud, idle: bool) void {
        h.model.update(h.timeline, h.opts.sources, idle);
        h.seen = h.timeline.newest + 1;
        h.refreshes += 1;
        if (h.win) |w| w.app.notifyEntity(h.entity);
    }

    /// Refreshes at once (the bench; tests).
    pub fn refreshNow(h: *Hud) void {
        h.refresh(false);
    }

    fn onFrame(ctx: *anyopaque, _: *FrameTimeline) void {
        const h: *Hud = @ptrCast(@alignCast(ctx));
        h.arm();
    }

    fn onTimer(ctx: *anyopaque, _: *Window) void {
        const h: *Hud = @ptrCast(@alignCast(ctx));
        h.timer = .none;
        if (h.timeline.newest > h.seen) {
            h.refresh(false);
            h.arm();
        } else if (!h.model.idle) {
            // Nothing but the HUD drew: one last repaint says "idle".
            h.refresh(true);
        }
    }

    fn onBarClick(ctx: *anyopaque, seq: u64) void {
        const h: *Hud = @ptrCast(@alignCast(ctx));
        const r = h.recorder orelse return;
        var buf: [48]u8 = undefined;
        r.trigger(r.ctx, std.fmt.bufPrint(&buf, "hud click seq={d}", .{seq}) catch "hud click");
    }

    pub fn build(h: *Hud, ui: *Ui) void {
        const zone = zg_core.trace.zone(@src(), "perf.hud");
        defer zone.end();
        if (!h.entity.isNone()) ui.cx().observe(h.entity);
        const m = &h.model;
        var bg = ui.theme().color(.bg_overlay);
        bg.a = @intFromFloat(@round(std.math.clamp(h.opts.opacity, 0, 1) * 255));
        ui.open(.{ .role = .status, .label = "Performance HUD", .style = .{ .dir = .column, .gap = 3, .padding = .all(6), .bg = .{ .color = bg }, .radius = 4 } });
        defer ui.close();
        _ = ui.leaf(graph.Graph, .{
            .w = h.opts.graph_w,
            .h = h.opts.graph_h,
            .slots = @intCast(m.bars.len),
            .bars = m.bars[0..m.len],
            .scale_ns = m.scale_ns,
            .refresh_ns = m.refresh_ns,
            .click = .{ .ctx = h, .f = onBarClick },
            .hash = m.newest *% 0x9e37_79b9 +% m.len,
        });
        const st: zg_gui.paint.text.TextStyle = .{ .font = .mono, .size = 11 };
        for (0..model_mod.row_count) |i| {
            if (i == 3 and !h.opts.show_latency) continue;
            if (i == 5 and !h.opts.show_memory) continue;
            ui.text(m.row(i), .{ .style = st, .color = if (i == 0 and m.idle) .fg_muted else .fg, .wrap = false, .theme_size = false });
        }
    }
};
