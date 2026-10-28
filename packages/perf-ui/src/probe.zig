//! The latency probe (E14.F03.S02.T03): a square in a window corner that
//! flips between black and white in the frame that applies each key
//! press, for a photodiode to time (docs/perf/latency.md section 3).
//!
//! The flip goes through the normal render path: the window's key tap
//! (`Window.key_tap`, called before the key is dispatched) notifies the
//! probe's entity, so the square is rebuilt, damaged, submitted and
//! presented with the keystroke's own effect. The square is a debug-layer
//! overlay with its own damage rect. Off, the probe costs nothing: no
//! overlay and no tap.

const std = @import("std");
const zg_gui = @import("zg_gui");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const Ui = zg_gui.Ui;
const overlay = zg_gui.w.overlay;

pub const ProbeOptions = struct {
    /// Side of the square in physical pixels.
    size_px: u32 = 64,
    corner: enum { top_left, bottom_left } = .bottom_left,
};

pub const Probe = struct {
    pub const view_name = "perf_latency_probe";

    gpa: Allocator,
    opts: ProbeOptions,
    win: ?*Window = null,
    overlay_id: overlay.OverlayId = .none,
    entity: zg_gui.core.EntityId = .none,
    /// The square is white.
    lit: bool = false,
    /// Key presses seen (tests).
    flips: u64 = 0,

    pub fn init(gpa: Allocator, opts: ProbeOptions) !*Probe {
        const p = try gpa.create(Probe);
        p.* = .{ .gpa = gpa, .opts = opts };
        return p;
    }

    /// Hides the probe and frees it. Not `deinit`: the window would call
    /// that when it unmounts the overlay.
    pub fn destroy(p: *Probe) void {
        if (p.win) |w| p.setVisible(w, false);
        p.gpa.destroy(p);
    }

    pub fn isVisible(p: *const Probe) bool {
        return p.win != null;
    }

    /// Shows or hides the probe in `win` (it takes the window's key tap).
    pub fn setVisible(p: *Probe, win: *Window, visible: bool) void {
        if (visible == p.isVisible()) return;
        if (!visible) {
            const w = p.win.?;
            w.key_tap = null;
            w.closeOverlay(p.overlay_id);
            p.overlay_id = .none;
            if (!p.entity.isNone()) w.app.release(p.entity);
            p.entity = .none;
            p.win = null;
            return;
        }
        p.entity = (win.app.new(u8, 0) catch return).id;
        p.overlay_id = win.openOverlay(.of(p), .{
            .layer = .debug,
            .anchor = .{ .corner_at = .{ .corner = if (p.opts.corner == .top_left) .top_left else .bottom_left, .margin = 0 } },
            .light_dismiss = false,
            .restore_focus = false,
            .chrome = false,
            .label = "Latency probe",
            .test_id = "perf.latencyProbe",
        }) catch {
            win.app.release(p.entity);
            p.entity = .none;
            return;
        };
        p.win = win;
        p.lit = false;
        win.key_tap = .{ .ctx = p, .f = onKey };
    }

    /// Toggles the probe in `win` (`perf.latencyProbe.toggle`).
    pub fn toggle(p: *Probe, win: *Window) void {
        p.setVisible(win, !p.isVisible());
    }

    fn onKey(ctx: *anyopaque, w: *Window) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.lit = !p.lit;
        p.flips += 1;
        w.app.notifyEntity(p.entity);
    }

    pub fn build(p: *Probe, ui: *Ui) void {
        if (!p.entity.isNone()) ui.cx().observe(p.entity);
        const scale = if (p.win) |w| w.scale else 1;
        const side = @as(f32, @floatFromInt(p.opts.size_px)) / scale;
        const c: zg_gui.core.geom.Color = if (p.lit) .{ .r = 255, .g = 255, .b = 255, .a = 255 } else .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        ui.open(.{ .role = .none, .style = .{ .w = .{ .px = side }, .h = .{ .px = side }, .bg = .{ .color = c } } });
        ui.close();
    }
};

const TestApp = zg_gui.testing.TestApp;

const Page = struct {
    pub fn build(_: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        ui.close();
    }
};

test "probe: square flips on key frame only" {
    const gpa = std.testing.allocator;
    var page: Page = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&page), .size = .{ .w = 400, .h = 300 } });
    defer t.deinit();
    const p = try Probe.init(gpa, .{});
    defer p.destroy();
    p.toggle(t.win);
    _ = t.settle();
    const r = try t.rectOf(.{ .test_id = "perf.latencyProbe" });
    // Bottom-left, 64 px square.
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 300), r.bottom(), 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 64), r.w, 0.5);
    try std.testing.expect(std.mem.indexOf(u8, t.rec.text(), "#000000ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.rec.text(), "#ffffffff") == null);

    // A key press: the next frame paints it white.
    t.win.handlePlatformEvent(.{ .key = .{ .win = @enumFromInt(1), .ev = .{ .key = .key_a, .keysym = 'a', .codepoint = 'a', .mods = .{}, .action = .press, .text = .empty, .native_scancode = 30, .time_ns = 0 } } }, NoPayload{});
    try std.testing.expect(t.frame().presented);
    try std.testing.expect(std.mem.indexOf(u8, t.rec.text(), "#ffffffff") != null);
    // A frame without a key leaves it alone; a release does not flip.
    t.win.handlePlatformEvent(.{ .key = .{ .win = @enumFromInt(1), .ev = .{ .key = .key_a, .keysym = 'a', .codepoint = 'a', .mods = .{}, .action = .release, .text = .empty, .native_scancode = 30, .time_ns = 0 } } }, NoPayload{});
    _ = t.settle();
    try std.testing.expectEqual(@as(u64, 1), p.flips);
    try std.testing.expect(p.lit);
    // Off: the tap is gone.
    p.toggle(t.win);
    _ = t.settle();
    try std.testing.expect(t.win.key_tap == null);
    try std.testing.expect(t.find(.{ .test_id = "perf.latencyProbe" }) == null);
}

const NoPayload = struct {
    pub fn payload(_: NoPayload, _: anytype) []const u8 {
        return "";
    }
};
