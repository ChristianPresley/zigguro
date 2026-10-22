//! Floating and torn-off windows (E04.F07.S02.T02): any tab can leave the
//! main window for an OS window of its own and come back. All windows
//! share one `App`, theme and `DockModel`; each `DockModel.floating`
//! entry is shown by one window with its own `DockView` and tab strips.
//!
//! - Tear-off: dropping a tab outside every window (`DockView.cross`)
//!   moves it into a new floating window sized like the group it left,
//!   opened at the drop position minus the grab offset. The panel's last
//!   docked group is remembered for docking back.
//! - Between windows: a tab dragged out of a window becomes a platform
//!   drag offering `application/x-zigguro-internal` with `{token,
//!   PanelRef}` (`encodeTab`); another of our windows previews and takes
//!   the drop through `Window.internal_drop`. The same path is used on
//!   every platform: Wayland has no global positions, so screen
//!   coordinates cannot be compared. When the drag ends with nothing
//!   taking it (`source_finished` with no action, which is also how a
//!   Wayland drag over the desktop ends), the tab is torn off at the
//!   last position.
//! - Dock back: the window's "Dock back" button, or `dockBack` with any
//!   target. Closing a floating window docks its panels back to their
//!   last group (`FloatingPolicy.close_docks_back`), else closes them
//!   (each panel's `can_close` may keep the window open).
//! - Monitors: a floating window records its monitor's name and scale;
//!   `restoreRect` puts a saved rect back on that monitor, or centered on
//!   the primary one when the monitor is gone or the rect is off screen.
//!   A restored window opens at that place (Win32 and X11; Wayland
//!   compositors place windows themselves). A new tear-off is placed by
//!   the system: a window's own screen position is not known.
//! - `FloatingPolicy.always_on_top` keeps floating windows above normal
//!   ones where the platform can; `setAlwaysOnTop` changes it for open
//!   windows.
//!
//! Windows are opened through a `WindowOpener` (`Host.windowOpener` for
//! real ones); closing only asks (`Window.close_requested`), so a window
//! is never freed while it handles an event.

const std = @import("std");
const zg_platform = @import("zg_platform");
const geom = @import("../core/geom.zig");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const window_mod = @import("../core/window.zig");
const controls = @import("../widgets/controls.zig");
const model = @import("model.zig");
const view = @import("view.zig");

const Allocator = std.mem.Allocator;
const Ui = ui_mod.Ui;
const Window = window_mod.Window;
const Vec2 = geom.Vec2;
const DockModel = model.DockModel;
const DockView = view.DockView;
const PanelRef = model.PanelRef;
const GroupId = model.GroupId;
const FloatId = model.FloatId;
const DropTarget = model.DropTarget;
const Rect = model.Rect;

/// How floating windows behave.
pub const FloatingPolicy = struct {
    /// Closing a floating window docks its panels back (else closes them).
    close_docks_back: bool = true,
    /// Keep floating windows above the main window (when the platform
    /// can).
    always_on_top: bool = false,
};

/// Where a floating window opens.
pub const Placement = struct {
    /// Outer top-left corner on the virtual screen (physical pixels);
    /// null lets the system choose.
    position: ?zg_platform.types.PxPoint = null,
    always_on_top: bool = false,
};

/// Opens and closes the OS windows floating panels live in.
pub const WindowOpener = struct {
    ctx: *anyopaque,
    /// Opens a window of logical `size` showing `root`.
    open: *const fn (ctx: *anyopaque, title: []const u8, size: geom.Size, root: view_mod.AnyView) anyerror!*Window,
    /// Like `open`, placed; preferred when set.
    open_placed: ?*const fn (ctx: *anyopaque, title: []const u8, size: geom.Size, root: view_mod.AnyView, at: Placement) anyerror!*Window = null,
    /// Changes an open window's always-on-top state (false: cannot).
    set_always_on_top: ?*const fn (ctx: *anyopaque, w: *Window, on: bool) bool = null,
    /// The monitors (`Platform.monitors`); none when unknown.
    monitors: ?*const fn (ctx: *anyopaque, out: []zg_platform.types.MonitorInfo) usize = null,
};

/// The smallest floating window.
pub const min_size: geom.Size = .{ .w = 240, .h = 160 };

/// The bytes of a dragged tab (`application/x-zigguro-internal`).
pub const tab_magic = "zgtab1";
/// `encodeTab`'s length.
pub const tab_len = tab_magic.len + 8 + 4;

/// Encodes a dragged tab: the magic, this process's `token` and `p`.
pub fn encodeTab(token: u64, p: PanelRef) [tab_len]u8 {
    var b: [tab_len]u8 = undefined;
    @memcpy(b[0..tab_magic.len], tab_magic);
    std.mem.writeInt(u64, b[tab_magic.len..][0..8], token, .little);
    std.mem.writeInt(u32, b[tab_magic.len + 8 ..][0..4], @intFromEnum(p), .little);
    return b;
}

/// The panel in `bytes` when they are a tab from the process `token`.
pub fn decodeTab(token: u64, bytes: []const u8) ?PanelRef {
    if (bytes.len != tab_len or !std.mem.eql(u8, bytes[0..tab_magic.len], tab_magic)) return null;
    if (std.mem.readInt(u64, bytes[tab_magic.len..][0..8], .little) != token) return null;
    return @enumFromInt(std.mem.readInt(u32, bytes[tab_magic.len + 8 ..][0..4], .little));
}

/// Where a saved floating rect goes on the current monitors (logical
/// pixels): on its monitor when that is still connected and at least
/// 48 px of the window is on it (moved fully inside), else centered on
/// the primary monitor (the first one without a primary), clamped to its
/// work area. Without monitors the rect is kept.
pub fn restoreRect(r: Rect, monitor: []const u8, monitors: []const zg_platform.types.MonitorInfo) Rect {
    if (monitors.len == 0) return r;
    const visible = 48;
    for (monitors) |*m| if (monitor.len > 0 and std.mem.eql(u8, m.name(), monitor)) {
        const wa = workOf(m);
        const ox = @min(r.x + r.w, wa.x + wa.w) - @max(r.x, wa.x);
        const oy = @min(r.y + r.h, wa.y + wa.h) - @max(r.y, wa.y);
        if (ox >= visible and oy >= visible) return clampInto(r, wa);
    };
    var primary = &monitors[0];
    for (monitors) |*m| if (m.primary) {
        primary = m;
    };
    const wa = workOf(primary);
    const w = @min(r.w, wa.w);
    const h = @min(r.h, wa.h);
    return .{ .x = wa.x + (wa.w - w) / 2, .y = wa.y + (wa.h - h) / 2, .w = w, .h = h };
}

/// The physical top-left of logical `r` on the monitor named `monitor`
/// (the primary when it is gone).
fn physicalAt(r: Rect, monitor: []const u8, monitors: []const zg_platform.types.MonitorInfo) ?zg_platform.types.PxPoint {
    if (monitors.len == 0) return null;
    var m = &monitors[0];
    for (monitors) |*x| if (x.primary) {
        m = x;
    };
    for (monitors) |*x| if (std.mem.eql(u8, x.name(), monitor)) {
        m = x;
    };
    const s = if (m.scale.factor > 0) m.scale.factor else 1;
    return .{ .x = @intFromFloat(@round(r.x * s)), .y = @intFromFloat(@round(r.y * s)) };
}

fn workOf(m: *const zg_platform.types.MonitorInfo) Rect {
    const s = if (m.scale.factor > 0) m.scale.factor else 1;
    const p = m.work_px;
    return .{
        .x = @as(f32, @floatFromInt(p.x)) / s,
        .y = @as(f32, @floatFromInt(p.y)) / s,
        .w = @as(f32, @floatFromInt(p.w)) / s,
        .h = @as(f32, @floatFromInt(p.h)) / s,
    };
}

fn clampInto(r: Rect, a: Rect) Rect {
    const w = @min(r.w, a.w);
    const h = @min(r.h, a.h);
    return .{ .x = std.math.clamp(r.x, a.x, a.x + a.w - w), .y = std.math.clamp(r.y, a.y, a.y + a.h - h), .w = w, .h = h };
}

/// One floating window.
pub const FloatWin = struct {
    fl: *Floater,
    id: FloatId,
    win: *Window,
    dv: DockView,
    /// Closing: shows nothing until the Host closes the window.
    closed: bool = false,

    /// A "Dock back" bar over the float's tree.
    pub fn build(fw: *FloatWin, ui: *Ui) void {
        if (fw.closed) return;
        fw.dv.beginFrame(ui);
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .dir = .column, .align_items = .stretch, .bg = .{ .token = .bg_base } } });
        defer ui.close();
        defer fw.dv.dropOverlay(ui);
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .padding = .xy(6, 2), .bg = .{ .token = .bg_elevated } } });
        controls.spacer(ui);
        if (controls.button(ui, .{ .label = "Dock back", .variant = .ghost }).clicked) {
            ui.window().app.post(.{ .ctx = fw, .f = dockBackPosted }) catch {};
        }
        ui.close();
        fw.dv.dockFloat(ui, fw.id);
    }

    fn dockBackPosted(ctx: *anyopaque, _: *@import("../core/app.zig").App) void {
        const fw: *FloatWin = @ptrCast(@alignCast(ctx));
        if (!fw.closed) fw.fl.dockBackAll(fw.id);
    }
};

/// See the module doc. Must not move once attached.
pub const Floater = struct {
    gpa: Allocator,
    dock: *DockModel,
    host: view.PanelHost,
    opener: WindowOpener,
    policy: FloatingPolicy = .{},
    /// The main window's dock view.
    main: ?*DockView = null,
    wins: std.ArrayList(*FloatWin) = .empty,
    /// Windows asked to close, freed with the Floater.
    closed: std.ArrayList(*FloatWin) = .empty,
    /// Where each floating panel was docked last.
    last_group: std.AutoHashMapUnmanaged(PanelRef, GroupId) = .empty,
    /// Tells our drags from another process's.
    token: u64,
    /// The tab being dragged between windows, and its source.
    out: ?struct { p: PanelRef, from: *DockView, pos: Vec2, grab: Vec2 } = null,

    pub fn init(gpa: Allocator, dock: *DockModel, host: view.PanelHost, opener: WindowOpener, policy: FloatingPolicy) Floater {
        // Addresses differ between processes (ASLR); good enough to tell
        // our drags from another instance's.
        const seed = [2]usize{ @intFromPtr(dock), @intFromPtr(&init) };
        return .{ .gpa = gpa, .dock = dock, .host = host, .opener = opener, .policy = policy, .token = std.hash.Wyhash.hash(0x2163, std.mem.asBytes(&seed)) };
    }

    /// Frees every floating window's state. Their windows must be closed
    /// (or about to be) and not built again.
    /// Keeps floating windows above normal ones (or stops); open windows
    /// change too where the platform can.
    pub fn setAlwaysOnTop(fl: *Floater, on: bool) void {
        fl.policy.always_on_top = on;
        const f = fl.opener.set_always_on_top orelse return;
        for (fl.wins.items) |fw| _ = f(fl.opener.ctx, fw.win, on);
    }

    pub fn deinit(fl: *Floater) void {
        for (fl.wins.items) |fw| fl.freeWin(fw);
        for (fl.closed.items) |fw| fl.freeWin(fw);
        fl.wins.deinit(fl.gpa);
        fl.closed.deinit(fl.gpa);
        fl.last_group.deinit(fl.gpa);
    }

    fn freeWin(fl: *Floater, fw: *FloatWin) void {
        if (!fw.closed) {
            fw.win.internal_drop = null;
            fw.win.on_close = null;
        }
        fw.dv.deinit();
        fl.gpa.destroy(fw);
    }

    /// Hooks the main window's dock view: drags may leave it, drops from
    /// other windows land in it, and closing it docks every floating
    /// panel back and closes their windows.
    pub fn attachMain(fl: *Floater, w: *Window, dv: *DockView) void {
        fl.main = dv;
        fl.hook(w, dv);
        w.on_close = .{ .ctx = fl, .f = onMainClose };
    }

    fn hook(fl: *Floater, w: *Window, dv: *DockView) void {
        dv.floating = true;
        dv.cross = .{ .ctx = fl, .leave = onLeave, .float = onFloat };
        w.internal_drop = .{ .ctx = fl, .f = onInternalDrop };
    }

    /// The window that shows `p`: its floating window, else the main one.
    pub fn windowOf(fl: *const Floater, p: PanelRef) ?*Window {
        if (fl.dock.floatOf(p)) |f| if (fl.winOf(f)) |fw| return fw.win;
        const m = fl.main orelse return null;
        return m.win;
    }

    fn winOf(fl: *const Floater, f: FloatId) ?*FloatWin {
        for (fl.wins.items) |fw| if (fw.id == f) return fw;
        return null;
    }

    pub fn winByWindow(fl: *const Floater, w: *Window) ?*FloatWin {
        for (fl.wins.items) |fw| if (fw.win == w) return fw;
        return null;
    }

    fn viewOf(fl: *const Floater, w: *Window) ?*DockView {
        if (fl.winByWindow(w)) |fw| return &fw.dv;
        if (fl.main) |m| if (m.win == w) return m;
        return null;
    }

    /// Moves `p` into a new floating window of `size` (logical pixels;
    /// at least `min_size`) whose top-left is `screen_pos`, and opens it.
    pub fn tearOff(fl: *Floater, p: PanelRef, screen_pos: Vec2, size: geom.Size) !*Window {
        const before = fl.dock.groupOf(p);
        const r: Rect = .{ .x = screen_pos.x, .y = screen_pos.y, .w = @max(size.w, min_size.w), .h = @max(size.h, min_size.h) };
        try fl.dock.move(p, .{ .float = r });
        // Remember the group only when it was docked (not floating).
        if (before) |g| if (fl.docked(g)) try fl.last_group.put(fl.gpa, p, g);
        try fl.sync();
        const f = fl.dock.floatOf(p) orelse return error.NotFloating;
        return (fl.winOf(f) orelse return error.NotFloating).win;
    }

    fn docked(fl: *const Floater, g: GroupId) bool {
        const o = fl.dock.ownerOf(.{ .group = g }) orelse return fl.dock.group(g) != null;
        return o == .area;
    }

    /// Moves every panel of floating window `win` to `target`; the window
    /// closes once it is empty.
    pub fn dockBack(fl: *Floater, win: *Window, target: DropTarget) void {
        const fw = fl.winByWindow(win) orelse return;
        var ps: std.ArrayList(PanelRef) = .empty;
        defer ps.deinit(fl.gpa);
        const root = fl.dock.floatRoot(fw.id) orelse return;
        fl.dock.panelsIn(root, fl.gpa, &ps) catch return;
        for (ps.items) |p| {
            fl.dock.move(p, target) catch {};
            _ = fl.last_group.remove(p);
        }
        fl.sync() catch {};
    }

    /// Moves each panel of floating window `f` back to its last docked
    /// group (or the center).
    pub fn dockBackAll(fl: *Floater, f: FloatId) void {
        var ps: std.ArrayList(PanelRef) = .empty;
        defer ps.deinit(fl.gpa);
        const root = fl.dock.floatRoot(f) orelse return;
        fl.dock.panelsIn(root, fl.gpa, &ps) catch return;
        for (ps.items) |p| fl.dockHome(p);
        fl.sync() catch {};
    }

    fn dockHome(fl: *Floater, p: PanelRef) void {
        const target: DropTarget = if (fl.last_group.get(p)) |g|
            (if (fl.dock.group(g) != null and fl.docked(g)) .{ .group = .{ .g = g } } else .{ .area = .center })
        else
            .{ .area = .center };
        fl.dock.move(p, target) catch {};
        _ = fl.last_group.remove(p);
        if (fl.main) |m| m.changed();
    }

    /// Opens a window for each floating entry without one and closes the
    /// windows of entries that are gone.
    pub fn sync(fl: *Floater) !void {
        var i: usize = 0;
        while (i < fl.wins.items.len) {
            const fw = fl.wins.items[i];
            if (fl.dock.floatRoot(fw.id) == null) {
                _ = fl.wins.swapRemove(i);
                fl.retire(fw);
            } else {
                fw.win.markAllDirty();
                i += 1;
            }
        }
        for (fl.dock.floating.items) |*f| {
            if (fl.winOf(f.id) != null) continue;
            try fl.openFor(f);
        }
        if (fl.main) |m| m.changed();
    }

    fn retire(fl: *Floater, fw: *FloatWin) void {
        fw.closed = true;
        fw.dv.drag = null;
        fw.win.internal_drop = null;
        fw.win.on_close = null;
        fw.win.close_requested = true;
        fw.win.markAllDirty();
        fl.closed.append(fl.gpa, fw) catch {};
    }

    fn openFor(fl: *Floater, f: *model.Floating) !void {
        const fw = try fl.gpa.create(FloatWin);
        errdefer fl.gpa.destroy(fw);
        fw.* = .{ .fl = fl, .id = f.id, .win = undefined, .dv = .init(fl.gpa, fl.dock, fl.host) };
        errdefer fw.dv.deinit();
        var title: []const u8 = "zigguro";
        if (f.root) |r| if (fl.dock.firstGroup(r)) |g| if (fl.dock.group(g)) |gr| if (gr.tabs.items.len > 0) {
            title = fl.host.tab(fl.host.ctx, gr.tabs.items[gr.active]).title;
        };
        var at: Placement = .{ .always_on_top = fl.policy.always_on_top };
        if (fl.opener.monitors) |mf| {
            var mons: [8]zg_platform.types.MonitorInfo = undefined;
            const n = @min(mf(fl.opener.ctx, &mons), mons.len);
            // A saved window goes back on screen; a new one records the
            // monitor it opens on (the primary: positions are unknown).
            if (f.monitor.len > 0) {
                f.rect = restoreRect(f.rect, f.monitor.get(), mons[0..n]);
                at.position = physicalAt(f.rect, f.monitor.get(), mons[0..n]);
            }
            if (f.monitor.len == 0) for (mons[0..n]) |*m| if (m.primary or n == 1) {
                f.monitor.set(m.name());
                f.scale = m.scale.factor;
            };
        }
        const size: geom.Size = .{ .w = f.rect.w, .h = f.rect.h };
        fw.win = if (fl.opener.open_placed) |op|
            try op(fl.opener.ctx, title, size, view_mod.AnyView.of(fw), at)
        else
            try fl.opener.open(fl.opener.ctx, title, size, view_mod.AnyView.of(fw));
        try fl.wins.append(fl.gpa, fw);
        fl.hook(fw.win, &fw.dv);
        fw.win.on_close = .{ .ctx = fl, .f = onFloatClose };
    }

    fn onFloatClose(ctx: *anyopaque, w: *Window) void {
        const fl: *Floater = @ptrCast(@alignCast(ctx));
        const fw = fl.winByWindow(w) orelse {
            w.close_requested = true;
            return;
        };
        if (fl.policy.close_docks_back) return fl.dockBackAll(fw.id);
        var ps: std.ArrayList(PanelRef) = .empty;
        defer ps.deinit(fl.gpa);
        const root = fl.dock.floatRoot(fw.id) orelse return;
        fl.dock.panelsIn(root, fl.gpa, &ps) catch return;
        for (ps.items) |p| {
            if (fl.host.can_close) |cc| if (!cc(fl.host.ctx, p)) continue;
            fl.dock.close(p) catch {};
            _ = fl.last_group.remove(p);
        }
        fl.sync() catch {};
    }

    fn onMainClose(ctx: *anyopaque, w: *Window) void {
        const fl: *Floater = @ptrCast(@alignCast(ctx));
        fl.closeAll();
        w.close_requested = true;
    }

    /// Docks every floating panel back and closes their windows (the app
    /// is closing).
    pub fn closeAll(fl: *Floater) void {
        while (fl.wins.items.len > 0) {
            const fw = fl.wins.items[0];
            fl.dockBackAll(fw.id);
            // A panel that could not move keeps its window: drop it anyway.
            if (fl.wins.items.len > 0 and fl.wins.items[0] == fw) {
                _ = fl.wins.swapRemove(0);
                fl.retire(fw);
            }
        }
    }

    // -- drags --------------------------------------------------------------

    fn onLeave(ctx: *anyopaque, dv: *DockView, p: PanelRef, pos: Vec2) bool {
        const fl: *Floater = @ptrCast(@alignCast(ctx));
        const w = dv.win orelse return false;
        fl.out = .{ .p = p, .from = dv, .pos = pos, .grab = fl.grabOf(dv, p, pos) };
        const bytes = encodeTab(fl.token, p);
        w.startDrag(&bytes);
        return true;
    }

    /// The pointer's offset in the group `p` is in (kept on tear-off).
    fn grabOf(fl: *const Floater, dv: *DockView, p: PanelRef, pos: Vec2) Vec2 {
        const g = fl.dock.groupOf(p) orelse return .{};
        const r = groupRect(dv, g) orelse return .{};
        return .{ .x = std.math.clamp(pos.x - r.x, 0, r.w), .y = std.math.clamp(pos.y - r.y, 0, 24) };
    }

    fn groupRect(dv: *DockView, g: GroupId) ?Rect {
        var rs: std.ArrayList(model.GroupRect) = .empty;
        defer rs.deinit(dv.gpa);
        dv.groupRects(dv.gpa, &rs) catch return null;
        for (rs.items) |e| if (e.g == g) return e.rect;
        return null;
    }

    fn onFloat(ctx: *anyopaque, dv: *DockView, p: PanelRef, pos: Vec2) void {
        const fl: *Floater = @ptrCast(@alignCast(ctx));
        fl.tearOffFrom(dv, p, pos, fl.grabOf(dv, p, pos));
    }

    /// Tears `p` off from `dv`'s window, dropped at `pos` (that window's
    /// coordinates) with the pointer `grab` into the group.
    fn tearOffFrom(fl: *Floater, dv: *DockView, p: PanelRef, pos: Vec2, grab: Vec2) void {
        var size: geom.Size = .{ .w = 640, .h = 480 };
        if (fl.dock.groupOf(p)) |g| if (groupRect(dv, g)) |r| {
            size = .{ .w = r.w, .h = r.h };
        };
        // The window's own screen position is unknown: positions are in
        // its coordinates, which is what the platform can place by.
        const at: Vec2 = .{ .x = pos.x - grab.x, .y = pos.y - grab.y };
        _ = fl.tearOff(p, at, size) catch {};
    }

    fn onInternalDrop(ctx: *anyopaque, w: *Window, phase: zg_platform.clipboard.DropPhase, pos: Vec2, data: []const u8, allowed: zg_platform.clipboard.DragActions) bool {
        const fl: *Floater = @ptrCast(@alignCast(ctx));
        switch (phase) {
            .source_finished => {
                const o = fl.out orelse return false;
                fl.out = null;
                // The tab strip still holds the press: end its drag.
                const src = o.from.win orelse w;
                src.dispatch(.{ .pointer_up = .{ .pos = o.pos, .button = .left } });
                if (!allowed.move and !allowed.copy and fl.dock.groupOf(o.p) != null) {
                    fl.tearOffFrom(o.from, o.p, o.pos, o.grab);
                }
                return true;
            },
            .enter, .over => {
                const dv = fl.viewOf(w) orelse return false;
                const o = fl.out orelse return false;
                return dv.previewAt(o.p, pos);
            },
            .leave => {
                if (fl.viewOf(w)) |dv| dv.clearPreview();
                return false;
            },
            .drop => {
                const dv = fl.viewOf(w) orelse return false;
                const p = decodeTab(fl.token, data) orelse return false;
                if (!fl.dock.panels.contains(p)) return false;
                const ok = dv.dropAt(p, pos);
                if (ok) {
                    _ = fl.last_group.remove(p);
                    fl.sync() catch {};
                }
                return ok;
            },
        }
    }
};

test "tab payload round-trips and rejects other processes" {
    const p: PanelRef = @enumFromInt(42);
    const b = encodeTab(7, p);
    try std.testing.expectEqual(@as(?PanelRef, p), decodeTab(7, &b));
    try std.testing.expectEqual(@as(?PanelRef, null), decodeTab(8, &b));
    try std.testing.expectEqual(@as(?PanelRef, null), decodeTab(7, b[0 .. b.len - 1]));
}
