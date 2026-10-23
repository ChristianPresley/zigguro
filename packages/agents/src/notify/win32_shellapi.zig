//! The bits of shellapi.h the Windows notification backend needs
//! (E13.F01.S03.T03): `NOTIFYICONDATAW` laid out as documented, its
//! constants, and `Shell_NotifyIconW` (Windows only).

const std = @import("std");
const builtin = @import("builtin");

pub const HWND = *anyopaque;
pub const HICON = *anyopaque;

pub const GUID = extern struct {
    Data1: u32 = 0,
    Data2: u16 = 0,
    Data3: u16 = 0,
    Data4: [8]u8 = @splat(0),
};

pub const NOTIFYICONDATAW = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: ?HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u16 = @splat(0),
    u: extern union { uTimeout: u32, uVersion: u32 } = .{ .uVersion = 0 },
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: u32 = 0,
    guidItem: GUID = .{},
    hBalloonIcon: ?HICON = null,
};

comptime {
    // As documented for 64-bit Windows (x86_64 and aarch64).
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(NOTIFYICONDATAW) == 976);
        std.debug.assert(@offsetOf(NOTIFYICONDATAW, "szInfo") == 304);
    }
}

pub const NIM_ADD: u32 = 0;
pub const NIM_MODIFY: u32 = 1;
pub const NIM_DELETE: u32 = 2;
pub const NIM_SETVERSION: u32 = 4;

pub const NIF_MESSAGE: u32 = 0x01;
pub const NIF_ICON: u32 = 0x02;
pub const NIF_TIP: u32 = 0x04;
pub const NIF_INFO: u32 = 0x10;
pub const NIF_SHOWTIP: u32 = 0x80;

pub const NIIF_NONE: u32 = 0;
pub const NIIF_INFO: u32 = 1;
pub const NIIF_WARNING: u32 = 2;
pub const NIIF_ERROR: u32 = 3;
/// Do not show while the user is in quiet time (Focus Assist).
pub const NIIF_RESPECT_QUIET_TIME: u32 = 0x80;

pub const NOTIFYICON_VERSION_4: u32 = 4;

pub const WM_USER: u32 = 0x0400;
pub const WM_APP: u32 = 0x8000;
pub const NIN_BALLOONSHOW: u32 = WM_USER + 2;
pub const NIN_BALLOONHIDE: u32 = WM_USER + 3;
pub const NIN_BALLOONTIMEOUT: u32 = WM_USER + 4;
pub const NIN_BALLOONUSERCLICK: u32 = WM_USER + 5;

/// `Shell_NotifyIconW` from shell32 (Windows only).
pub const Shell_NotifyIconW = if (builtin.os.tag == .windows) struct {
    extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, lpData: *NOTIFYICONDATAW) callconv(.winapi) i32;
}.Shell_NotifyIconW else @compileError("Shell_NotifyIconW is Windows only");

test "windows_struct_layout" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 976), @sizeOf(NOTIFYICONDATAW));
    try std.testing.expectEqual(@as(usize, 304), @offsetOf(NOTIFYICONDATAW, "szInfo"));
    try std.testing.expectEqual(@as(usize, 816), @offsetOf(NOTIFYICONDATAW, "u"));
    try std.testing.expectEqual(@as(usize, 820), @offsetOf(NOTIFYICONDATAW, "szInfoTitle"));
    try std.testing.expectEqual(@as(usize, 968), @offsetOf(NOTIFYICONDATAW, "hBalloonIcon"));
}
