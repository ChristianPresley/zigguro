//! gdi32: only what the CPU presenter and cursor masks need.
//!
//! planned: E01.F02.S05.T01 (DIB sections, BitBlt), E01.F02.S01.T03
//! (cursor bitmaps).

const t = @import("types.zig");

/// `DIB_RGB_COLORS`.
pub const DIB_RGB_COLORS: t.UINT = 0;
/// `SRCCOPY` raster operation.
pub const SRCCOPY: t.DWORD = 0x00CC0020;

/// Creates a bitmap whose pixels the caller writes directly.
pub extern "gdi32" fn CreateDIBSection(?t.HDC, *const t.BITMAPINFO, usage: t.UINT, bits: *?*anyopaque, section: ?t.HANDLE, offset: t.DWORD) callconv(.winapi) ?t.HBITMAP;
/// Creates a memory device context.
pub extern "gdi32" fn CreateCompatibleDC(?t.HDC) callconv(.winapi) ?t.HDC;
/// Selects an object into a context, returning the previous one.
pub extern "gdi32" fn SelectObject(t.HDC, t.HGDIOBJ) callconv(.winapi) ?t.HGDIOBJ;
/// Copies pixels between contexts.
pub extern "gdi32" fn BitBlt(dst: t.HDC, x: i32, y: i32, w: i32, h: i32, src: ?t.HDC, sx: i32, sy: i32, rop: t.DWORD) callconv(.winapi) t.BOOL;
/// Deletes a GDI object.
pub extern "gdi32" fn DeleteObject(t.HGDIOBJ) callconv(.winapi) t.BOOL;
/// Deletes a memory context.
pub extern "gdi32" fn DeleteDC(t.HDC) callconv(.winapi) t.BOOL;
/// Creates a device-dependent bitmap (monochrome cursor masks).
pub extern "gdi32" fn CreateBitmap(w: i32, h: i32, planes: t.UINT, bpp: t.UINT, bits: ?*const anyopaque) callconv(.winapi) ?t.HBITMAP;
/// Reads one pixel of a context as `0x00BBGGRR` (tests).
pub extern "gdi32" fn GetPixel(t.HDC, x: i32, y: i32) callconv(.winapi) t.DWORD;
/// Flushes this thread's batched GDI calls.
pub extern "gdi32" fn GdiFlush() callconv(.winapi) t.BOOL;
