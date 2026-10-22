//! The custom window frame for client-decorated windows (E01.F02.S01.T03):
//! hit-test codes, the resize border, the maximized inset and the DWM
//! attributes. The arithmetic is pure and tested on every OS; `applyDwm`,
//! `windowsBuild` and `borderPx` call into Windows.

const std = @import("std");
const types = @import("../api/types.zig");
const HitRegion = types.HitRegion;
const ResizeEdge = types.ResizeEdge;
const is_windows = @import("builtin").os.tag == .windows;

/// `WM_NCHITTEST` results.
pub const HT = struct {
    /// HTNOWHERE.
    pub const NOWHERE: u32 = 0;
    /// HTCLIENT.
    pub const CLIENT: u32 = 1;
    /// HTCAPTION.
    pub const CAPTION: u32 = 2;
    /// HTMINBUTTON.
    pub const MINBUTTON: u32 = 8;
    /// HTMAXBUTTON.
    pub const MAXBUTTON: u32 = 9;
    /// HTLEFT.
    pub const LEFT: u32 = 10;
    /// HTRIGHT.
    pub const RIGHT: u32 = 11;
    /// HTTOP.
    pub const TOP: u32 = 12;
    /// HTTOPLEFT.
    pub const TOPLEFT: u32 = 13;
    /// HTTOPRIGHT.
    pub const TOPRIGHT: u32 = 14;
    /// HTBOTTOM.
    pub const BOTTOM: u32 = 15;
    /// HTBOTTOMLEFT.
    pub const BOTTOMLEFT: u32 = 16;
    /// HTBOTTOMRIGHT.
    pub const BOTTOMRIGHT: u32 = 17;
    /// HTCLOSE.
    pub const CLOSE: u32 = 20;
};

/// The `WM_NCHITTEST` code for `r`.
pub fn htOf(r: HitRegion) u32 {
    return switch (r) {
        .client => HT.CLIENT,
        .caption => HT.CAPTION,
        .resize_top => HT.TOP,
        .resize_bottom => HT.BOTTOM,
        .resize_left => HT.LEFT,
        .resize_right => HT.RIGHT,
        .resize_top_left => HT.TOPLEFT,
        .resize_top_right => HT.TOPRIGHT,
        .resize_bottom_left => HT.BOTTOMLEFT,
        .resize_bottom_right => HT.BOTTOMRIGHT,
        .button_min => HT.MINBUTTON,
        .button_max => HT.MAXBUTTON,
        .button_close => HT.CLOSE,
    };
}

/// Whether `ht` is one of the caption buttons, which we draw (through
/// E04) and press ourselves.
pub fn isButton(ht: u32) bool {
    return ht == HT.MINBUTTON or ht == HT.MAXBUTTON or ht == HT.CLOSE;
}

/// The resize border in physical pixels at `dpi` when the system metrics
/// are not available: `SM_CXSIZEFRAME` (4) plus `SM_CXPADDEDBORDER` (4)
/// at 96 DPI, scaled.
pub fn defaultBorderPx(dpi: u32) i32 {
    return @intCast((8 * @as(u64, dpi) + 48) / 96);
}

/// The resize border in physical pixels at `dpi`.
pub fn borderPx(dpi: u32) i32 {
    if (!is_windows) return defaultBorderPx(dpi);
    const user32 = @import("bindings/user32.zig");
    const frame = user32.GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi);
    const pad = user32.GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    if (frame <= 0) return defaultBorderPx(dpi);
    return frame + @max(pad, 0);
}

/// `SM_CXSIZEFRAME`.
pub const SM_CXSIZEFRAME: i32 = 32;
/// `SM_CXPADDEDBORDER`.
pub const SM_CXPADDEDBORDER: i32 = 92;

/// The resize region at client point (`x`, `y`) of a `w`×`h` window with a
/// `border`-pixel resize band, or null inside it. Maximized windows have
/// no resize band. Corners take `border` along both edges.
pub fn edgeAt(x: i32, y: i32, w: i32, h: i32, border: i32, maximized: bool) ?HitRegion {
    if (maximized) return null;
    const left = x < border;
    const right = x >= w - border;
    const top = y < border;
    const bottom = y >= h - border;
    if (top and left) return .resize_top_left;
    if (top and right) return .resize_top_right;
    if (bottom and left) return .resize_bottom_left;
    if (bottom and right) return .resize_bottom_right;
    if (top) return .resize_top;
    if (bottom) return .resize_bottom;
    if (left) return .resize_left;
    if (right) return .resize_right;
    return null;
}

/// The app's hit-test callback (see `Command.set_hit_test`).
pub const AppHit = struct {
    f: *const fn (ctx: *anyopaque, p: types.PxPoint) HitRegion,
    ctx: *anyopaque,
};

/// The `WM_NCHITTEST` answer for client point (`x`, `y`): the resize band
/// first, then the app's map; without one, everything is client.
pub fn hitTest(x: i32, y: i32, w: i32, h: i32, border: i32, maximized: bool, app: ?AppHit) u32 {
    if (x < 0 or y < 0 or x >= w or y >= h) return HT.NOWHERE;
    if (edgeAt(x, y, w, h, border, maximized)) |e| return htOf(e);
    const a = app orelse return HT.CLIENT;
    return htOf(a.f(a.ctx, .{ .x = x, .y = y }));
}

/// A rectangle as `WM_NCCALCSIZE` passes it.
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// The client rectangle `WM_NCCALCSIZE` returns for proposed window
/// rectangle `r`. Normally the whole window. A maximized window is
/// oversized past the monitor by the resize border on every side, so it
/// is inset by `border`.
pub fn clientRect(r: Rect, border: i32, maximized: bool) Rect {
    if (!maximized) return r;
    return .{ .left = r.left + border, .top = r.top + border, .right = r.right - border, .bottom = r.bottom - border };
}

/// `WM_SYSCOMMAND` codes.
pub const SC = struct {
    /// SC_SIZE; plus a `WMSZ_*` edge it starts a resize.
    pub const SIZE: usize = 0xF000;
    /// SC_MOVE; plus `HTCAPTION` it starts a move with the mouse.
    pub const MOVE: usize = 0xF010;
    /// SC_MINIMIZE.
    pub const MINIMIZE: usize = 0xF020;
    /// SC_MAXIMIZE.
    pub const MAXIMIZE: usize = 0xF030;
    /// SC_CLOSE.
    pub const CLOSE: usize = 0xF060;
    /// SC_RESTORE.
    pub const RESTORE: usize = 0xF120;
};

/// The `WM_SYSCOMMAND` wParam that starts a mouse resize from `edge`
/// (`SC_SIZE | WMSZ_*`).
pub fn sizeCommand(edge: ResizeEdge) usize {
    return SC.SIZE | @as(usize, switch (edge) {
        .left => 1,
        .right => 2,
        .top => 3,
        .top_left => 4,
        .top_right => 5,
        .bottom => 6,
        .bottom_left => 7,
        .bottom_right => 8,
    });
}

/// The DWM system backdrop behind a window (Windows 11 22621+).
pub const Backdrop = enum(u32) {
    /// Let DWM decide (no backdrop for an opaque window).
    auto = 0,
    /// None.
    none = 1,
    /// Mica.
    mica = 2,
    /// Acrylic.
    acrylic = 3,
    /// Tabbed Mica.
    tabbed = 4,
};

/// `DWMWA_USE_IMMERSIVE_DARK_MODE` (20; 19 before build 18985).
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;
/// `DWMWA_WINDOW_CORNER_PREFERENCE`.
pub const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;
/// `DWMWA_SYSTEMBACKDROP_TYPE`.
pub const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38;
/// `DWMWCP_ROUND`.
pub const DWMWCP_ROUND: u32 = 2;

/// One `DwmSetWindowAttribute` call.
pub const Attr = struct { attr: u32, value: u32 };

/// The DWM attributes to set on Windows build `build`: dark mode where the
/// build has it, round corners on client-decorated windows (22000+) and
/// the backdrop (22621+). Unused slots are null.
pub fn dwmAttrs(build: u32, dark: bool, backdrop: Backdrop, custom: bool) [3]?Attr {
    var out: [3]?Attr = @splat(null);
    if (build >= 18985) {
        out[0] = .{ .attr = DWMWA_USE_IMMERSIVE_DARK_MODE, .value = @intFromBool(dark) };
    } else if (build >= 17763) {
        out[0] = .{ .attr = 19, .value = @intFromBool(dark) };
    }
    if (custom and build >= 22000) out[1] = .{ .attr = DWMWA_WINDOW_CORNER_PREFERENCE, .value = DWMWCP_ROUND };
    if (build >= 22621 and backdrop != .auto) out[2] = .{ .attr = DWMWA_SYSTEMBACKDROP_TYPE, .value = @intFromEnum(backdrop) };
    return out;
}

/// `OSVERSIONINFOW`.
const OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: u32 = @sizeOf(OSVERSIONINFOW),
    dwMajorVersion: u32 = 0,
    dwMinorVersion: u32 = 0,
    dwBuildNumber: u32 = 0,
    dwPlatformId: u32 = 0,
    szCSDVersion: [128]u16 = @splat(0),
};

/// The Windows build number from `RtlGetVersion` (which, unlike
/// `GetVersionEx`, ignores the manifest), or 0 when unknown.
pub fn windowsBuild() u32 {
    if (!is_windows) return 0;
    const kernel32 = @import("bindings/kernel32.zig");
    const L = @import("wide.zig").L;
    const ntdll = kernel32.GetModuleHandleW(L("ntdll.dll")) orelse return 0;
    const sym = kernel32.GetProcAddress(ntdll, "RtlGetVersion") orelse return 0;
    const RtlGetVersion: *const fn (*OSVERSIONINFOW) callconv(.winapi) i32 = @ptrCast(@alignCast(sym));
    var vi: OSVERSIONINFOW = .{};
    if (RtlGetVersion(&vi) != 0) return 0;
    return vi.dwBuildNumber;
}

/// Whether the user picked the dark app theme
/// (`HKCU\...\Themes\Personalize\AppsUseLightTheme` = 0).
pub fn systemDark() bool {
    if (!is_windows) return false;
    const advapi32 = @import("bindings/advapi32.zig");
    const t = @import("bindings/types.zig");
    const L = @import("wide.zig").L;
    const HKEY_CURRENT_USER: t.HKEY = @ptrFromInt(0x80000001);
    const RRF_RT_REG_DWORD: u32 = 0x10;
    var v: u32 = 1;
    var size: u32 = @sizeOf(u32);
    if (advapi32.RegGetValueW(HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), L("AppsUseLightTheme"), RRF_RT_REG_DWORD, null, &v, &size) != 0) return false;
    return v == 0;
}

/// Sets the DWM attributes `dwmAttrs` picks for this build; unsupported
/// ones are skipped, and failures are ignored (they only cost looks).
pub fn applyDwm(hwnd: anytype, build: u32, dark: bool, backdrop: Backdrop, custom: bool) void {
    if (!is_windows) return;
    const dwmapi = @import("bindings/dwmapi.zig");
    for (dwmAttrs(build, dark, backdrop, custom)) |a| if (a) |x| {
        _ = dwmapi.DwmSetWindowAttribute(hwnd, x.attr, &x.value, @sizeOf(u32));
    };
}

const testing = std.testing;

test "hit-test border thickness by DPI" {
    try testing.expectEqual(@as(i32, 8), defaultBorderPx(96));
    try testing.expectEqual(@as(i32, 12), defaultBorderPx(144));
    try testing.expectEqual(@as(i32, 16), defaultBorderPx(192));
    try testing.expectEqual(@as(i32, 10), defaultBorderPx(120));
    // The band follows the border it is given.
    try testing.expectEqual(@as(?HitRegion, .resize_left), edgeAt(11, 300, 800, 600, 12, false));
    try testing.expectEqual(@as(?HitRegion, null), edgeAt(12, 300, 800, 600, 12, false));
    try testing.expectEqual(@as(?HitRegion, .resize_right), edgeAt(788, 300, 800, 600, 12, false));
    try testing.expectEqual(@as(?HitRegion, null), edgeAt(787, 300, 800, 600, 12, false));
}

test "edges, corners and the app map" {
    const Stub = struct {
        fn hit(_: *anyopaque, p: types.PxPoint) HitRegion {
            if (p.y >= 32) return .client;
            if (p.x >= 700) return .button_close;
            if (p.x >= 650) return .button_max;
            if (p.x >= 600) return .button_min;
            return .caption;
        }
    };
    var dummy: u8 = 0;
    const app: AppHit = .{ .f = Stub.hit, .ctx = &dummy };
    try testing.expectEqual(HT.TOPLEFT, hitTest(0, 0, 800, 600, 8, false, app));
    try testing.expectEqual(HT.TOPRIGHT, hitTest(799, 3, 800, 600, 8, false, app));
    try testing.expectEqual(HT.BOTTOMLEFT, hitTest(2, 599, 800, 600, 8, false, app));
    try testing.expectEqual(HT.BOTTOMRIGHT, hitTest(795, 595, 800, 600, 8, false, app));
    try testing.expectEqual(HT.TOP, hitTest(300, 4, 800, 600, 8, false, app));
    try testing.expectEqual(HT.BOTTOM, hitTest(300, 596, 800, 600, 8, false, app));
    try testing.expectEqual(HT.CAPTION, hitTest(300, 20, 800, 600, 8, false, app));
    try testing.expectEqual(HT.MINBUTTON, hitTest(610, 20, 800, 600, 8, false, app));
    try testing.expectEqual(HT.MAXBUTTON, hitTest(660, 20, 800, 600, 8, false, app));
    try testing.expectEqual(HT.CLOSE, hitTest(750, 20, 800, 600, 8, false, app));
    try testing.expectEqual(HT.CLIENT, hitTest(300, 300, 800, 600, 8, false, app));
    // Maximized: no resize band, so the top row is the caption.
    try testing.expectEqual(HT.CAPTION, hitTest(300, 1, 800, 600, 8, true, app));
    try testing.expectEqual(HT.CLOSE, hitTest(799, 0, 800, 600, 8, true, app));
    // Without an app map everything inside the band is client.
    try testing.expectEqual(HT.CLIENT, hitTest(300, 20, 800, 600, 8, false, null));
    try testing.expectEqual(HT.NOWHERE, hitTest(-1, 20, 800, 600, 8, false, null));
    try testing.expect(isButton(HT.MAXBUTTON) and !isButton(HT.CAPTION));
}

test "maximized inset" {
    // A maximized window on a 1920x1080 monitor at 150%: Windows hands
    // us a rectangle 12 px past every edge.
    const r: Rect = .{ .left = -12, .top = -12, .right = 1932, .bottom = 1092 };
    const c = clientRect(r, 12, true);
    try testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 }, c);
    try testing.expectEqual(r, clientRect(r, 12, false));
}

test "every HitRegion maps to a distinct HT code" {
    var seen: [32]bool = @splat(false);
    for (std.enums.values(HitRegion)) |r| {
        const ht = htOf(r);
        try testing.expect(!seen[ht]);
        seen[ht] = true;
    }
}

test "DWM attributes by build" {
    const old = dwmAttrs(10240, true, .mica, true);
    try testing.expect(old[0] == null and old[1] == null and old[2] == null);
    const rs5 = dwmAttrs(17763, true, .mica, true);
    try testing.expectEqual(@as(u32, 19), rs5[0].?.attr);
    const w10 = dwmAttrs(19045, true, .mica, true);
    try testing.expectEqual(Attr{ .attr = 20, .value = 1 }, w10[0].?);
    try testing.expect(w10[1] == null and w10[2] == null);
    const w11 = dwmAttrs(22000, false, .mica, true);
    try testing.expectEqual(Attr{ .attr = 20, .value = 0 }, w11[0].?);
    try testing.expectEqual(Attr{ .attr = 33, .value = 2 }, w11[1].?);
    try testing.expect(w11[2] == null);
    const w11b = dwmAttrs(22621, true, .mica, false);
    try testing.expect(w11b[1] == null);
    try testing.expectEqual(Attr{ .attr = 38, .value = 2 }, w11b[2].?);
    try testing.expect(dwmAttrs(22621, true, .auto, true)[2] == null);
}

test "resize commands" {
    try testing.expectEqual(@as(usize, 0xF001), sizeCommand(.left));
    try testing.expectEqual(@as(usize, 0xF008), sizeCommand(.bottom_right));
    try testing.expectEqual(@as(usize, 0xF003), sizeCommand(.top));
}
