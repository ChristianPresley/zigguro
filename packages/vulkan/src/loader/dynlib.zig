//! Opening the OS Vulkan loader. Windows uses `LoadLibraryExW` restricted to
//! System32 (no DLL planting); Linux uses `dlopen`, which needs libc, so a
//! libc-free build reports `error.Unsupported` (ADR-E02-001: the GUI binary
//! links the system libc; `zg_vulkan` itself never sets `link_libc`).

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("zg_platform");

pub const Error = error{ NotFound, Unsupported, NameTooLong };

/// True if this build can open shared libraries at all.
pub const supported = builtin.os.tag == .windows or builtin.link_libc;

/// The loader's default file name on this OS.
pub const default_name: [:0]const u8 = switch (builtin.os.tag) {
    .windows => "vulkan-1.dll",
    .macos => "libvulkan.1.dylib",
    else => "libvulkan.so.1",
};

/// An open shared library.
pub const Lib = struct {
    handle: *anyopaque,

    /// Opens `name`. On Windows a bare file name is searched for in
    /// System32 only; a path (containing a separator) is opened as given.
    pub fn open(name: []const u8) Error!Lib {
        if (builtin.os.tag == .windows) {
            const k32 = platform.win32.kernel32;
            var buf: [512]u16 = undefined;
            if (name.len >= buf.len) return error.NameTooLong;
            const n = std.unicode.utf8ToUtf16Le(&buf, name) catch return error.NotFound;
            buf[n] = 0;
            const is_path = std.mem.indexOfAny(u8, name, "/\\") != null;
            const flags: u32 = if (is_path) 0 else k32.LOAD_LIBRARY_SEARCH_SYSTEM32;
            const h = k32.LoadLibraryExW(buf[0..n :0], null, flags) orelse return error.NotFound;
            return .{ .handle = @ptrCast(h) };
        }
        if (!builtin.link_libc) return error.Unsupported;
        var buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (name.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const h = std.c.dlopen(buf[0..name.len :0], .{ .NOW = true }) orelse return error.NotFound;
        return .{ .handle = h };
    }

    /// The address of symbol `name`, or null.
    pub fn lookup(self: Lib, name: [:0]const u8) ?*const anyopaque {
        if (builtin.os.tag == .windows) {
            return platform.win32.kernel32.GetProcAddress(@ptrCast(self.handle), name);
        }
        if (!builtin.link_libc) return null;
        return std.c.dlsym(self.handle, name);
    }

    pub fn close(self: *Lib) void {
        if (builtin.os.tag == .windows) {
            _ = platform.win32.kernel32.FreeLibrary(@ptrCast(self.handle));
        } else if (builtin.link_libc) {
            _ = std.c.dlclose(self.handle);
        }
        self.* = undefined;
    }
};

test "dynlib: a missing library is NotFound (or Unsupported without libc)" {
    const r = Lib.open("libzigguro-does-not-exist.so.7");
    if (supported) {
        try std.testing.expectError(error.NotFound, r);
    } else {
        try std.testing.expectError(error.Unsupported, r);
    }
}
