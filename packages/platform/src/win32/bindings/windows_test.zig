//! Binding tests that call into Windows (run on the Windows CI cells).

const std = @import("std");
const kernel32 = @import("kernel32.zig");
const user32 = @import("user32.zig");
const L = @import("../wide.zig").L;

test "LoadLibraryExW/GetProcAddress resolves GetDpiForWindow" {
    const m = kernel32.LoadLibraryExW(L("user32.dll"), null, kernel32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return error.LoadFailed;
    defer _ = kernel32.FreeLibrary(m);
    try std.testing.expect(kernel32.GetProcAddress(m, "GetDpiForWindow") != null);
    try std.testing.expect(kernel32.GetProcAddress(m, "NoSuchExportZigguro") == null);
}

test "the declared imports link and run" {
    var freq: i64 = 0;
    try std.testing.expect(kernel32.QueryPerformanceFrequency(&freq) != 0 and freq > 0);
    try std.testing.expect(user32.GetDoubleClickTime() > 0);
    try std.testing.expect(kernel32.GetModuleHandleW(null) != null);
}
