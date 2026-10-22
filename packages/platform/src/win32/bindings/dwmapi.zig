//! dwmapi: frame attributes, the extended frame and composition timing.
//!
//! planned: E01.F02.S01.T03 (custom frame, dark mode, backdrop),
//! E01.F02.S05.T01 (timer pacing).

const t = @import("types.zig");

/// `DWMWA_USE_IMMERSIVE_DARK_MODE`.
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: t.DWORD = 20;
/// `DWMWA_WINDOW_CORNER_PREFERENCE`.
pub const DWMWA_WINDOW_CORNER_PREFERENCE: t.DWORD = 33;
/// `DWMWA_SYSTEMBACKDROP_TYPE`.
pub const DWMWA_SYSTEMBACKDROP_TYPE: t.DWORD = 38;

/// Sets a window attribute.
pub extern "dwmapi" fn DwmSetWindowAttribute(t.HWND, attr: t.DWORD, value: *const anyopaque, size: t.DWORD) callconv(.winapi) t.HRESULT;
/// Extends the frame into the client area.
pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(t.HWND, *const t.MARGINS) callconv(.winapi) t.HRESULT;
/// Lets DWM hit-test the caption buttons (returns TRUE if it handled it).
pub extern "dwmapi" fn DwmDefWindowProc(t.HWND, t.UINT, t.WPARAM, t.LPARAM, *t.LRESULT) callconv(.winapi) t.BOOL;
/// Composition timing (null window: the whole desktop).
pub extern "dwmapi" fn DwmGetCompositionTimingInfo(?t.HWND, *t.DWM_TIMING_INFO) callconv(.winapi) t.HRESULT;
