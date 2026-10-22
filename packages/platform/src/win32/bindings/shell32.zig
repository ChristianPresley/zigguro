//! shell32: file lists from `CF_HDROP`, shell items and ShellExecute.
//!
//! planned: E01.F02.S04 (clipboard and drop file lists), E01.F07.S01
//! (dialogs, open-URI).

const t = @import("types.zig");

/// Reads a dropped file name (index 0xFFFFFFFF: the count).
pub extern "shell32" fn DragQueryFileW(t.HDROP, index: t.UINT, buf: ?[*]u16, len: t.UINT) callconv(.winapi) t.UINT;
/// A shell item for a file-system path (`IFileDialog.SetFolder`).
pub extern "shell32" fn SHCreateItemFromParsingName(path: t.LPCWSTR, bc: ?*anyopaque, riid: *const t.GUID, out: *?*anyopaque) callconv(.winapi) t.HRESULT;
/// Opens a document or URI with its registered handler; a result of 32 or
/// less is an error.
pub extern "shell32" fn ShellExecuteW(hwnd: ?t.HWND, op: ?t.LPCWSTR, file: t.LPCWSTR, params: ?t.LPCWSTR, dir: ?t.LPCWSTR, show: i32) callconv(.winapi) ?*anyopaque;
