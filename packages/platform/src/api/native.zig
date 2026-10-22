//! Hooks into the native windowing system for code that must talk to the
//! OS directly: E04 accessibility (UI Automation) and E13 notifications.
//! Backends fill these in (E01.F01.S03.T01); unsupported entries return
//! `error.Unsupported`.

const types = @import("types.zig");
const WindowId = types.WindowId;

/// A Win32 window message hook. Returns the `LRESULT`, or null when the
/// hook did not handle the message.
pub const Win32MsgHook = *const fn (ctx: *anyopaque, hwnd: *anyopaque, msg: u32, wp: usize, lp: isize) ?isize;

/// Native integration entry points, from `Platform.native`.
pub const NativeHooks = struct {
    /// Backend state.
    ptr: *anyopaque,
    /// Win32 only. Runs `hook` on the platform thread for `msgs` sent to
    /// `win`'s HWND, before zg_platform's own handling; null removes it.
    win32SetMessageHook: *const fn (*anyopaque, win: WindowId, msgs: []const u32, hook: ?Win32MsgHook, ctx: *anyopaque) error{Unsupported}!void,
    /// Win32 only: creates a message-only window (`HWND_MESSAGE` parent)
    /// owned by the platform thread, for `Shell_NotifyIconW` and similar.
    win32CreateMessageWindow: *const fn (*anyopaque, hook: Win32MsgHook, ctx: *anyopaque) error{ Unsupported, SystemResources }!*anyopaque,
    /// Win32 only: destroys a window from `win32CreateMessageWindow`.
    win32DestroyMessageWindow: *const fn (*anyopaque, hwnd: *anyopaque) void,
    /// The native handle of `win`, for OS APIs that need a parent window.
    windowHandle: *const fn (*anyopaque, win: WindowId) NativeWindow,
};

/// A native window handle; the tag matches the running backend.
pub const NativeWindow = union(enum) {
    /// An `HWND`.
    win32: *anyopaque,
    /// The `wl_surface` object id.
    wayland_surface: u32,
    /// The X11 window id.
    x11: u32,
    /// Headless windows have no native handle.
    headless: void,
    /// An `NSWindow` (later).
    cocoa: *anyopaque,
};
