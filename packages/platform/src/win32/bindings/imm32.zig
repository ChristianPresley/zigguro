//! imm32: composition strings and candidate placement.
//!
//! planned: E01.F02.S03 (IME).

const t = @import("types.zig");

/// `GCS_COMPSTR`: the composition (preedit) string.
pub const GCS_COMPSTR: t.DWORD = 0x0008;
/// `GCS_RESULTSTR`: the committed string.
pub const GCS_RESULTSTR: t.DWORD = 0x0800;
/// `GCS_CURSORPOS`: the caret within the composition.
pub const GCS_CURSORPOS: t.DWORD = 0x0080;
/// `CFS_POINT`: place the composition window at `ptCurrentPos`.
pub const CFS_POINT: t.DWORD = 0x0002;
/// `CFS_EXCLUDE`: keep the candidate window off `rcArea`.
pub const CFS_EXCLUDE: t.DWORD = 0x0080;

/// The window's input context.
pub extern "imm32" fn ImmGetContext(t.HWND) callconv(.winapi) ?t.HIMC;
/// Releases `ImmGetContext`.
pub extern "imm32" fn ImmReleaseContext(t.HWND, t.HIMC) callconv(.winapi) t.BOOL;
/// Reads a composition string (bytes, or an index for GCS_CURSORPOS).
pub extern "imm32" fn ImmGetCompositionStringW(t.HIMC, index: t.DWORD, buf: ?*anyopaque, len: t.DWORD) callconv(.winapi) i32;
/// Places the composition window.
pub extern "imm32" fn ImmSetCompositionWindow(t.HIMC, *const t.COMPOSITIONFORM) callconv(.winapi) t.BOOL;
/// Places the candidate window.
pub extern "imm32" fn ImmSetCandidateWindow(t.HIMC, *const t.CANDIDATEFORM) callconv(.winapi) t.BOOL;
/// Sends an IME action (cancel or complete the composition).
pub extern "imm32" fn ImmNotifyIME(t.HIMC, action: t.DWORD, index: t.DWORD, value: t.DWORD) callconv(.winapi) t.BOOL;
/// Associates or disables the default context.
pub extern "imm32" fn ImmAssociateContextEx(t.HWND, ?t.HIMC, flags: t.DWORD) callconv(.winapi) t.BOOL;
