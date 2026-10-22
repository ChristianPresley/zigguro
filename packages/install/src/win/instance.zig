//! Named mutexes that tell the installer what is running (E17.F02.S01.T03):
//! the app holds `Local\dev.zigguro.zigguro.instance` for its lifetime, and
//! setup holds `Local\dev.zigguro.zigguro.setup` so only one setup runs.
//! The OS releases a mutex when its holder exits, crashes included.
//! Windows only; elsewhere every call is a no-op.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("bindings.zig");

/// The app's mutex.
pub const app_mutex = "Local\\dev.zigguro.zigguro.instance";
/// Setup's single-instance mutex.
pub const setup_mutex = "Local\\dev.zigguro.zigguro.setup";

/// A held mutex handle; `release` closes it.
pub const Held = struct {
    handle: ?*anyopaque,
    /// False when another process already created the mutex.
    first: bool,

    /// Closes the handle.
    pub fn release(h: Held) void {
        if (builtin.os.tag != .windows) return;
        if (h.handle) |x| _ = w.CloseHandle(x);
    }
};

/// Creates (or opens) the mutex `name` and keeps it open until `release`.
pub fn hold(comptime name: []const u8) Held {
    if (builtin.os.tag != .windows) return .{ .handle = null, .first = true };
    const h = w.CreateMutexW(null, 0, std.unicode.utf8ToUtf16LeStringLiteral(name));
    const first = h == null or w.GetLastError() != w.ERROR_ALREADY_EXISTS;
    return .{ .handle = h, .first = first };
}

/// True while some process holds the mutex `name` open.
pub fn exists(comptime name: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    const h = w.OpenMutexW(w.SYNCHRONIZE, 0, std.unicode.utf8ToUtf16LeStringLiteral(name)) orelse return false;
    _ = w.CloseHandle(h);
    return true;
}

test "instance: hold, exists, release" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const name = "Local\\dev.zigguro.zigguro.instance-test";
    try std.testing.expect(!exists(name));
    const a = hold(name);
    try std.testing.expect(a.first);
    try std.testing.expect(exists(name));
    const b = hold(name);
    try std.testing.expect(!b.first);
    b.release();
    a.release();
    try std.testing.expect(!exists(name));
}
