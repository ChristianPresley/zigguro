//! `SHGetKnownFolderPath` for the folders the installer writes shortcuts
//! to, and the per-user program files folder it installs into. Windows
//! only.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const w = @import("bindings.zig");

pub const Folder = enum { programs, desktop, user_program_files };

/// The folder's path in UTF-8 without a trailing `\`, owned by the caller.
pub fn knownFolderPath(gpa: Allocator, f: Folder) error{ Unsupported, NotFound, OutOfMemory }![]u8 {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const id = switch (f) {
        .programs => &w.FOLDERID_Programs,
        .desktop => &w.FOLDERID_Desktop,
        .user_program_files => &w.FOLDERID_UserProgramFiles,
    };
    var p: ?w.LPWSTR = null;
    const hr = w.SHGetKnownFolderPath(id, 0, null, &p);
    defer w.CoTaskMemFree(p);
    if (hr < 0 or p == null) return error.NotFound;
    const s = std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(p.?, 0)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
    if (s.len > 3 and s[s.len - 1] == '\\') return gpa.realloc(s, s.len - 1) catch s[0 .. s.len - 1];
    return s;
}

test "knownFolderPath: programs ends with \\Start Menu\\Programs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const p = try knownFolderPath(std.testing.allocator, .programs);
    defer std.testing.allocator.free(p);
    try std.testing.expect(std.ascii.endsWithIgnoreCase(p, "\\Start Menu\\Programs"));
}

test "knownFolderPath: user program files ends with \\Programs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // Wine does not know this folder; setup falls back to %LOCALAPPDATA%.
    if (w.underWine()) return error.SkipZigTest;
    const p = try knownFolderPath(std.testing.allocator, .user_program_files);
    defer std.testing.allocator.free(p);
    try std.testing.expect(std.ascii.endsWithIgnoreCase(p, "\\Programs"));
}
