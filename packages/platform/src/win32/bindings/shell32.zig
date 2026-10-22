//! shell32: file lists from `CF_HDROP`.
//!
//! planned: E01.F02.S04 (clipboard and drop file lists).

const t = @import("types.zig");

/// Reads a dropped file name (index 0xFFFFFFFF: the count).
pub extern "shell32" fn DragQueryFileW(t.HDROP, index: t.UINT, buf: ?[*]u16, len: t.UINT) callconv(.winapi) t.UINT;
