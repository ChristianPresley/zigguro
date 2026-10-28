//! How `bench-latency` types a key: at the OS level (uinput on Linux,
//! `SendInput` on Windows) so the whole input path is measured.

const std = @import("std");
const builtin = @import("builtin");

/// Types keys (a..z, space, `keys.backspace`): press and release.
pub const Injector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        keyTap: *const fn (ptr: *anyopaque, ch: u8) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn keyTap(i: Injector, ch: u8) !void {
        return i.vtable.keyTap(i.ptr, ch);
    }

    pub fn deinit(i: Injector) void {
        i.vtable.deinit(i.ptr);
    }
};

/// The OS injector of this platform, or an error when there is none or
/// it is not permitted.
pub fn osInjector(gpa: std.mem.Allocator, io: std.Io) !Injector {
    return switch (builtin.os.tag) {
        .linux => @import("inject_uinput.zig").create(gpa, io),
        .windows => @import("inject_win32.zig").create(gpa),
        else => error.Unsupported,
    };
}
