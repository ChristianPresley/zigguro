//! `Command.open_uri` on Windows: `ShellExecuteW(open)` on a short-lived
//! thread, since the shell may block while it starts the handler. Only
//! web and mail URIs are passed on; E16's URI policy can narrow that
//! further before the command is submitted.

const std = @import("std");
const builtin = @import("builtin");

/// Schemes `open_uri` passes to the shell.
pub const allowed_schemes = [_][]const u8{ "http", "https", "mailto" };

/// Whether `uri` has an allowed scheme and no characters the shell would
/// treat specially (controls, quotes).
pub fn allowed(uri: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    const scheme = uri[0..colon];
    var ok = false;
    for (allowed_schemes) |s| if (std.ascii.eqlIgnoreCase(scheme, s)) {
        ok = true;
    };
    if (!ok) return false;
    for (uri) |c| if (c < 0x20 or c == 0x7f or c == '"') return false;
    return true;
}

/// Opens `uri` with its handler, on a detached thread that owns a copy.
pub fn open(gpa: std.mem.Allocator, uri: []const u8) error{ Unsupported, OutOfMemory, SystemResources }!void {
    if (!allowed(uri)) return error.Unsupported;
    const w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, uri) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unsupported,
    };
    const th = std.Thread.spawn(.{}, run, .{ gpa, w }) catch {
        gpa.free(w);
        return error.SystemResources;
    };
    th.detach();
}

fn run(gpa: std.mem.Allocator, uri: [:0]u16) void {
    defer gpa.free(uri);
    if (builtin.os.tag != .windows) return;
    const ole32 = @import("bindings/ole32.zig");
    const shell32 = @import("bindings/shell32.zig");
    const L = @import("wide.zig").L;
    const hr = ole32.CoInitializeEx(null, ole32.COINIT_APARTMENTTHREADED | ole32.COINIT_DISABLE_OLE1DDE);
    defer if (hr >= 0) ole32.CoUninitialize();
    const r = shell32.ShellExecuteW(null, L("open"), uri, null, null, 1); // SW_SHOWNORMAL
    if (@intFromPtr(r) <= 32) std.log.scoped(.win32).warn("ShellExecuteW failed ({d})", .{@intFromPtr(r)});
}

test "allowed URIs" {
    try std.testing.expect(allowed("https://ziglang.org/"));
    try std.testing.expect(allowed("HTTP://example.com/a?b=c"));
    try std.testing.expect(allowed("mailto:someone@example.com"));
    try std.testing.expect(!allowed("file:///C:/Windows/System32/calc.exe"));
    try std.testing.expect(!allowed("ms-settings:"));
    try std.testing.expect(!allowed("C:\\tools\\x.exe"));
    try std.testing.expect(!allowed("https://example.com/\"x"));
    try std.testing.expect(!allowed("no-scheme"));
}
