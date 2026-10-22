//! Toasts and the notification center popover (E04.F05.S04.T02).
//!
//! `toast(app, t)` records `t` in `App.notifications` and shows it in every
//! window: a non-modal overlay at layer `toast` in the bottom-right corner
//! (12 px in and clear of the status bar, cards at most 420 px wide, 8 px apart, newest on top, at most
//! three). A card shows a severity mark, the title, the body, a progress
//! bar and its action buttons; an action runs through the window's
//! `ActionHandler` and dismisses the toast. Auto-dismiss waits while the
//! pointer is over a card (1.5 s grace after it leaves).
//!
//! `openCenter` lists every kept notification newest first, grouped by
//! source, with Clear all and Do not disturb, and marks them read.
//!
//! Open: the enter animation (E04.F08.S03.T01), Markdown bodies
//! (E04.F06.S01.T02) and the a11y announcement of approval toasts
//! (E04.F09).

const std = @import("std");
const app_mod = @import("../core/app.zig");
const window_mod = @import("../core/window.zig");
const ui_mod = @import("../core/ui.zig");
const ids = @import("../core/ids.zig");
const overlay = @import("overlay.zig");
const controls = @import("controls.zig");
const nc_mod = @import("notification_center.zig");
const tokens = @import("../theme/tokens.zig");

const App = app_mod.App;
const Window = window_mod.Window;
const Ui = ui_mod.Ui;
const NodeId = ids.NodeId;
const Toast = nc_mod.Toast;
const ToastId = nc_mod.ToastId;
const Entry = nc_mod.Entry;
const Severity = nc_mod.Severity;
const NotificationCenter = nc_mod.NotificationCenter;

/// Pixels between the stack and the window corner.
pub const corner_margin: f32 = 12;
/// The widest card.
pub const max_width: f32 = 420;
/// Room left under the stack for a status bar.
pub const bottom_clearance: f32 = 24;
/// How long a hovered toast stays after its deadline, per check.
pub const hover_grace_ms: u64 = 1500;

/// Shows `t` as a toast in every window; returns its id (`.none` when it
/// could not be recorded).
pub fn toast(app: *App, t: Toast) ToastId {
    const id = app.notifications.post(t, app.now_ms) catch return .none;
    for (app.windows.items) |w| _ = hostFor(app, w);
    refresh(app);
    return id;
}

/// Replaces a toast's content (progress updates).
pub fn updateToast(app: *App, id: ToastId, t: Toast) void {
    app.notifications.update(id, t, app.now_ms) catch {};
    refresh(app);
}

/// Hides a toast (it stays in the notification center).
pub fn dismissToast(app: *App, id: ToastId) void {
    app.notifications.dismiss(id);
    refresh(app);
}

/// Rebuilds every window's toast stack and re-arms auto-dismiss.
pub fn refresh(app: *App) void {
    for (app.toast_hosts.items) |h| {
        h.arm();
        h.win.markAllDirty();
    }
}

fn hostFor(app: *App, w: *Window) ?*Host {
    for (app.toast_hosts.items) |h| if (h.win == w) return h;
    const h = app.gpa.create(Host) catch return null;
    h.* = .{ .app = app, .win = w };
    h.overlay = w.openOverlay(.of(h), .{
        .layer = .toast,
        .anchor = .{ .corner = corner_margin },
        .light_dismiss = false,
        .restore_focus = false,
        .chrome = false,
        .label = "Notifications",
        .test_id = "toasts",
        .on_close = .{ .ctx = h, .f = Host.onClose },
    }) catch {
        app.gpa.destroy(h);
        return null;
    };
    app.toast_hosts.append(app.gpa, h) catch {
        w.closeOverlay(h.overlay);
        return null;
    };
    return h;
}

/// A window's toast stack (the overlay's view).
pub const Host = struct {
    app: *App,
    win: *Window,
    overlay: overlay.OverlayId = .none,
    timer: Window.TimerId = .none,
    /// The cards of the last build, for hover checks.
    cards: [NotificationCenter.max_visible]struct { id: ToastId, node: NodeId } = undefined,
    ncards: usize = 0,

    pub fn build(h: *Host, ui: *Ui) void {
        const th = ui.theme();
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .align_items = .end, .margin = .{ .b = bottom_clearance } } });
        defer ui.close();
        var buf: [NotificationCenter.max_visible]*Entry = undefined;
        h.ncards = 0;
        for (h.app.notifications.visible(&buf)) |e| {
            ui.open(.{
                .style = .{ .dir = .row, .w = .{ .px = max_width }, .max_w = max_width, .bg = .{ .token = .bg_elevated }, .border = .{ .token = .border }, .border_w = 1, .radius = th.dim(.radius_md) },
                .role = .status,
                .label = e.toast.title,
                .test_id = "toast",
                .hit = true,
            });
            h.cards[h.ncards] = .{ .id = e.id, .node = ui.current() };
            h.ncards += 1;
            // The severity bar.
            ui.open(.{ .style = .{ .w = .{ .px = 4 }, .bg = .{ .token = severityToken(e.toast.severity) }, .radius = th.dim(.radius_md) } });
            ui.close();
            h.card(ui, e);
            ui.close();
        }
    }

    fn card(h: *Host, ui: *Ui, e: *Entry) void {
        const th = ui.theme();
        const t = &e.toast;
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .gap = th.dim(.space_sm), .padding = .xy(th.dim(.space_md), th.dim(.space_sm)) } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
        ui.text(severityMark(t.severity), .{ .color = severityToken(t.severity), .wrap = false });
        ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
        ui.text(t.title, .{});
        ui.close();
        if (controls.button(ui, .{ .label = "\u{00d7}", .variant = .ghost }).clicked) h.app.notifications.dismiss(e.id);
        ui.close();
        if (t.body_md.len > 0) ui.text(t.body_md, .{ .color = .fg_muted });
        if (t.progress) |p| progressBar(ui, p);
        if (t.source.len > 0 or t.actions.len > 0) {
            ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
            defer ui.close();
            if (t.source.len > 0) ui.text(t.source, .{ .color = .fg_muted, .wrap = false });
            controls.spacer(ui);
            for (t.actions) |a| {
                if (controls.button(ui, .{ .label = a.label, .variant = if (a.primary) .primary else .secondary }).clicked) {
                    _ = h.win.dispatchAction(a.action, a.arg);
                    h.app.notifications.dismiss(e.id);
                }
            }
        }
        if (!e.popup) refresh(h.app);
    }

    /// Whether the pointer is over `e`'s card in this window.
    fn hovers(h: *const Host, e: *const Entry) bool {
        const hot = h.win.hot;
        if (hot.isNone()) return false;
        for (h.cards[0..h.ncards]) |c| {
            if (c.id != e.id) continue;
            if (hot.eql(c.node) or h.win.store.isAncestor(c.node, hot)) return true;
        }
        return false;
    }

    /// Schedules the next auto-dismiss check.
    fn arm(h: *Host) void {
        if (h.timer != .none) h.win.cancelTimer(h.timer);
        h.timer = .none;
        const at = h.app.notifications.nextDeadline() orelse return;
        h.timer = h.win.setTimer(at, .{ .ctx = h, .f = onTimer }) catch .none;
    }

    const AnyHover = struct {
        app: *App,
        pub fn isHovered(s: AnyHover, e: *Entry) bool {
            for (s.app.toast_hosts.items) |x| if (x.hovers(e)) return true;
            return false;
        }
    };

    fn onTimer(ctx: *anyopaque, _: *Window) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.timer = .none;
        _ = h.app.notifications.tick(h.app.now_ms, AnyHover{ .app = h.app }, hover_grace_ms);
        refresh(h.app);
    }

    fn onClose(ctx: *anyopaque, _: overlay.OverlayId) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const app = h.app;
        for (app.toast_hosts.items, 0..) |x, i| if (x == h) {
            _ = app.toast_hosts.swapRemove(i);
            break;
        };
        app.gpa.destroy(h);
    }
};

fn severityToken(s: Severity) tokens.Token {
    return switch (s) {
        .info => .info,
        .success => .success,
        .warning => .warning,
        .error_ => .danger,
        .approval => .accent,
    };
}

fn severityMark(s: Severity) []const u8 {
    return switch (s) {
        .info => "i",
        .success => "\u{2713}",
        .warning => "!",
        .error_ => "\u{00d7}",
        .approval => "?",
    };
}

/// A determinate bar for 0..1, or a fixed third for NaN (indeterminate).
fn progressBar(ui: *Ui, p: f32) void {
    const frac = if (std.math.isNan(p)) 0.33 else std.math.clamp(p, 0, 1);
    ui.open(.{ .style = .{ .h = .{ .px = 4 }, .bg = .{ .token = .track }, .radius = 2 }, .role = .progressbar, .label = "Progress" });
    ui.open(.{ .style = .{ .w = .{ .pct = frac * 100 }, .bg = .{ .token = .accent }, .radius = 2 } });
    ui.close();
    ui.close();
}

// -- notification center -------------------------------------------------------

/// Opens the notification center above `anchor` (the status bar bell) and
/// marks everything read. Returns the overlay.
pub fn openCenter(win: *Window, anchor: NodeId) !overlay.OverlayId {
    const app = win.app;
    const v = try app.gpa.create(Center);
    errdefer app.gpa.destroy(v);
    v.* = .{ .app = app, .win = win };
    v.id = try win.openOverlay(.of(v), .{
        .layer = .popover,
        .anchor = .{ .node = anchor },
        .placement = .{ .side = .above, .alignment = .end },
        .take_focus = true,
        .title = "Notifications",
        .label = "Notification center",
        .test_id = "notification_center",
        .width = max_width,
        .on_close = .{ .ctx = v, .f = Center.onClose },
    });
    app.notifications.markAllRead();
    app.notifications.center_open = true;
    refresh(app);
    return v.id;
}

const Center = struct {
    app: *App,
    win: *Window,
    id: overlay.OverlayId = .none,
    dnd: bool = false,

    pub fn build(c: *Center, ui: *Ui) void {
        const nc = &c.app.notifications;
        const th = ui.theme();
        ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_sm) } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
        c.dnd = nc.dnd;
        if (controls.checkbox(ui, "Do not disturb", &c.dnd).changed) {
            nc.setDoNotDisturb(c.dnd);
            refresh(c.app);
        }
        controls.spacer(ui);
        if (controls.button(ui, .{ .label = "Clear all", .variant = .ghost }).clicked) {
            nc.clear();
            refresh(c.app);
        }
        ui.close();
        if (nc.entries.items.len == 0) {
            ui.text("No notifications", .{ .color = .fg_muted });
            return;
        }
        // Grouped by source in order of each source's newest entry.
        var seen: [32][]const u8 = undefined;
        var nseen: usize = 0;
        var i = nc.entries.items.len;
        while (i > 0) {
            i -= 1;
            const src = nc.entries.items[i].toast.source;
            var dup = false;
            for (seen[0..nseen]) |s| dup = dup or std.mem.eql(u8, s, src);
            if (dup) continue;
            if (nseen < seen.len) {
                seen[nseen] = src;
                nseen += 1;
            }
            ui.text(if (src.len > 0) src else "General", .{ .color = .fg_muted, .wrap = false });
            var j = nc.entries.items.len;
            while (j > 0) {
                j -= 1;
                const e = nc.entries.items[j];
                if (!std.mem.eql(u8, e.toast.source, src)) continue;
                ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .padding = .xy(th.dim(.space_sm), 2) }, .role = .listitem, .label = e.toast.title });
                ui.text(severityMark(e.toast.severity), .{ .color = severityToken(e.toast.severity), .wrap = false });
                ui.text(e.toast.title, .{});
                ui.close();
            }
        }
    }

    fn onClose(ctx: *anyopaque, _: overlay.OverlayId) void {
        const c: *Center = @ptrCast(@alignCast(ctx));
        const app = c.app;
        app.gpa.destroy(c);
        app.notifications.center_open = false;
        refresh(app);
    }
};
