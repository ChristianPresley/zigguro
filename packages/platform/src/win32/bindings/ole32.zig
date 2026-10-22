//! ole32: OLE initialization, drag & drop registration and COM creation.
//!
//! planned: E01.F02.S04 (drag & drop), E01.F07.S01.T03 (file dialogs).

const t = @import("types.zig");

/// `CLSCTX_INPROC_SERVER`.
pub const CLSCTX_INPROC_SERVER: t.DWORD = 0x1;
/// `DROPEFFECT_NONE`.
pub const DROPEFFECT_NONE: t.DWORD = 0;
/// `DROPEFFECT_COPY`.
pub const DROPEFFECT_COPY: t.DWORD = 1;
/// `DROPEFFECT_MOVE`.
pub const DROPEFFECT_MOVE: t.DWORD = 2;
/// `DROPEFFECT_LINK`.
pub const DROPEFFECT_LINK: t.DWORD = 4;
/// `TYMED_HGLOBAL`.
pub const TYMED_HGLOBAL: t.DWORD = 1;

/// Initializes OLE (STA) on this thread.
pub extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) t.HRESULT;
/// Uninitializes OLE.
pub extern "ole32" fn OleUninitialize() callconv(.winapi) void;
/// Registers a window as a drop target.
pub extern "ole32" fn RegisterDragDrop(t.HWND, target: *anyopaque) callconv(.winapi) t.HRESULT;
/// Revokes a drop target.
pub extern "ole32" fn RevokeDragDrop(t.HWND) callconv(.winapi) t.HRESULT;
/// Runs a modal drag from this window.
pub extern "ole32" fn DoDragDrop(data: *anyopaque, source: *anyopaque, ok_effects: t.DWORD, effect: *t.DWORD) callconv(.winapi) t.HRESULT;
/// Frees a storage medium.
pub extern "ole32" fn ReleaseStgMedium(*t.STGMEDIUM) callconv(.winapi) void;
/// Creates a COM object.
pub extern "ole32" fn CoCreateInstance(clsid: *const t.GUID, outer: ?*anyopaque, ctx: t.DWORD, iid: *const t.GUID, out: *?*anyopaque) callconv(.winapi) t.HRESULT;
/// Frees COM task memory (strings from `GetDisplayName`).
pub extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
/// `COINIT_APARTMENTTHREADED`.
pub const COINIT_APARTMENTTHREADED: t.DWORD = 0x2;
/// `COINIT_DISABLE_OLE1DDE`.
pub const COINIT_DISABLE_OLE1DDE: t.DWORD = 0x4;
/// Initializes COM on the calling thread.
pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: t.DWORD) callconv(.winapi) t.HRESULT;
/// Ends COM on the calling thread.
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
