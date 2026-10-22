//! Window chrome (E04.F07.S02.T03): the title bar and frame zigguro draws
//! when the platform reports client-side decorations (`Window.chrome`,
//! from E01's `window_decorations`: GNOME Wayland without
//! xdg-decoration).
//!
//! `begin` wraps a window's content: with client decorations it leaves
//! the invisible resize margins around the frame (the renderer clears to
//! transparent), draws a 1 px border unless maximized, and a title bar with
//! the title and caption buttons (Minimize, Maximize/Restore, Close);
//! otherwise it is a plain full-size column. The content goes between
//! `begin` and `end`.
//!
//! The builder records the title bar and its interactive nodes in
//! `Window.chrome`; after each frame the Host turns them into a `HitMap`
//! (`buildHitMap`) for the platform's hit test: the title bar is
//! `caption` (E01 turns presses there into move, double-click maximize
//! and the window menu), caption buttons are their button regions, and
//! interactive title-bar widgets are `client`. Caption button clicks go
//! through the UI (`Window.requestWindowOp`, `close_requested`).
//!
//! Not yet: the soft shadow in the margins, Windows-style buttons (Win32
//! keeps its native frame until the app asks for `.client`).

const std = @import("std");
const zg_platform = @import("zg_platform");
const geom = @import("../core/geom.zig");
const ui_mod = @import("../core/ui.zig");
const window_mod = @import("../core/window.zig");
const ids = @import("../core/ids.zig");
const hit_map = @import("hit_map.zig");

const Ui = ui_mod.Ui;
const Window = window_mod.Window;
const NodeId = ids.NodeId;
const HitMap = hit_map.HitMap;

/// Title bar height, logical pixels.
pub const title_h: f32 = 34;
/// Caption button size, logical pixels.
pub const button_size: f32 = 24;

pub const ChromeProps = struct {
    title: []const u8 = "",
};

/// Opens the window frame (see the module doc); close with `end`.
pub fn begin(ui: *Ui, p: ChromeProps) void {
    const w = ui.win;
    const c = &w.chrome;
    c.title_bar = .none;
    c.buttons = .{ .none, .none, .none };
    c.interactive.clearRetainingCapacity();
    if (!c.client) {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        return;
    }
    // The margins, then the visible frame.
    const m = if (c.maximized) geom.Insets{} else c.margins(w.scale);
    ui.open(.{ .style = .{ .dir = .column, .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .padding = m } });
    const framed = !c.maximized;
    ui.open(.{ .test_id = "window-frame", .style = .{
        .dir = .column,
        .grow = 1,
        .basis = .{ .px = 0 },
        .bg = .{ .token = .bg_base },
        .border = if (framed) .{ .token = .border_strong } else .none,
        .border_w = if (framed) 1 else 0,
    } });
    titleBar(ui, p);
    // Content.
    ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } } });
}

/// Closes what `begin` opened.
pub fn end(ui: *Ui) void {
    ui.close();
    if (ui.win.chrome.client) {
        ui.close();
        ui.close();
    }
}

/// Records `n` (the last node built) as an interactive part of the title
/// bar: clicks reach it instead of moving the window.
pub fn markInteractive(ui: *Ui, n: NodeId) void {
    ui.win.chrome.interactive.append(ui.win.gpa, n) catch {};
}

fn titleBar(ui: *Ui, p: ChromeProps) void {
    const c = &ui.win.chrome;
    ui.open(.{ .test_id = "title-bar", .role = .none, .style = .{ .dir = .row, .h = .{ .px = title_h }, .shrink = 0, .padding = .xy(10, 0), .gap = 8, .align_items = .center, .bg = .{ .token = .bg_elevated } } });
    defer ui.close();
    c.title_bar = ui.current();
    ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 } } });
    ui.text(p.title, .{ .color = if (c.focused) .fg else .fg_muted, .wrap = false });
    ui.close();
    const max_label = if (c.maximized) "Restore" else "Maximize";
    if (captionButton(ui, "Minimize", "\u{2013}", 0)) ui.win.requestWindowOp(.minimize);
    if (captionButton(ui, max_label, if (c.maximized) "\u{2750}" else "\u{25a1}", 1)) ui.win.requestWindowOp(if (c.maximized) .unmaximize else .maximize);
    if (captionButton(ui, "Close", "\u{2715}", 2)) ui.win.close_requested = true;
}

fn captionButton(ui: *Ui, name: []const u8, glyph: []const u8, slot: usize) bool {
    ui.open(.{ .role = .button, .label = name, .hit = true, .style = .{
        .w = .{ .px = button_size },
        .h = .{ .px = button_size },
        .radius = button_size / 2,
        .justify = .center,
        .align_items = .center,
        .bg = .{ .token = .bg_sunken },
    } });
    defer ui.close();
    const n = ui.current();
    ui.win.chrome.buttons[slot] = n;
    ui.text(glyph, .{ .color = if (ui.win.chrome.focused) .fg else .fg_muted, .wrap = false });
    return ui.response().clicked;
}

/// The hit map of `w`'s chrome (rects copied into `out`, which the map
/// borrows): resize borders in the margins (none when maximized), the
/// title bar as `caption`, caption buttons and interactive title-bar
/// nodes on top. Without client decorations the map is empty.
pub fn buildHitMap(w: *Window, gpa: std.mem.Allocator, out: *std.ArrayList(HitMap.Entry)) !HitMap {
    out.clearRetainingCapacity();
    const c = &w.chrome;
    const size: [2]u32 = .{ @intFromFloat(@round(w.size.w * w.scale)), @intFromFloat(@round(w.size.h * w.scale)) };
    if (!c.client) return .{ .size_px = size };
    const valid = struct {
        fn f(win: *Window, n: NodeId) bool {
            return !n.isNone() and win.store.valid(n);
        }
    }.f;
    if (valid(w, c.title_bar)) try out.append(gpa, .{ .rect = px(w.store.absRect(c.title_bar), w.scale), .region = .caption });
    for (c.interactive.items) |n| if (valid(w, n)) try out.append(gpa, .{ .rect = px(w.store.absRect(n), w.scale), .region = .client });
    const regions = [3]zg_platform.types.HitRegion{ .button_min, .button_max, .button_close };
    for (c.buttons, regions) |n, r| if (valid(w, n)) try out.append(gpa, .{ .rect = px(w.store.absRect(n), w.scale), .region = r });
    const m = c.margins_px;
    const border: u16 = if (c.maximized) 0 else @intCast(@max(@max(m[0], m[1]), @max(m[2], m[3])));
    return .{ .size_px = size, .resize_border_px = border, .rects = out.items };
}

fn px(r: geom.Rect, scale: f32) [4]i32 {
    return .{
        @intFromFloat(@round(r.x * scale)),
        @intFromFloat(@round(r.y * scale)),
        @intFromFloat(@round(r.w * scale)),
        @intFromFloat(@round(r.h * scale)),
    };
}

test {
    std.testing.refAllDecls(@This());
}
