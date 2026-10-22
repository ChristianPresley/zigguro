//! advapi32: registry reads for the theme (AppsUseLightTheme).
//!
//! planned: E01.F07.S01.T03 (theme).

const t = @import("types.zig");

/// `HKEY_CURRENT_USER`: `(HKEY)(ULONG_PTR)(LONG)0x80000001`, sign-extended.
pub const HKEY_CURRENT_USER: t.HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))))));
/// `RRF_RT_REG_DWORD`.
pub const RRF_RT_REG_DWORD: t.DWORD = 0x0000_0010;

/// Reads a registry value.
pub extern "advapi32" fn RegGetValueW(t.HKEY, subkey: ?t.LPCWSTR, value: ?t.LPCWSTR, flags: t.DWORD, kind: ?*t.DWORD, data: ?*anyopaque, size: ?*t.DWORD) callconv(.winapi) i32;
