//! `Wake` on Windows: an auto-reset event (`CreateEventW`). The UI thread
//! waits on it with `WaitForSingleObject`; the platform thread is woken by
//! `PostMessageW` to its message window instead (E01.F02.S01.T02).

const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = i32;
const INFINITE: u32 = 0xffff_ffff;
const WAIT_OBJECT_0: u32 = 0;

extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;

/// An auto-reset event.
pub const WindowsWake = struct {
    /// The event handle.
    event: HANDLE,

    /// Creates the event, initially unsignalled.
    pub fn init() error{SystemResources}!WindowsWake {
        return .{ .event = CreateEventW(null, 0, 0, null) orelse return error.SystemResources };
    }

    /// Closes the event.
    pub fn deinit(self: *WindowsWake) void {
        _ = CloseHandle(self.event);
        self.* = undefined;
    }

    /// Signals the event.
    pub fn signal(self: *WindowsWake) void {
        _ = SetEvent(self.event);
    }

    /// Clears a pending signal that `wait` did not observe.
    pub fn consume(self: *WindowsWake) void {
        _ = ResetEvent(self.event);
    }

    /// Waits until signalled or `timeout_ns` passes. A successful wait
    /// resets the event (auto-reset), so `consume` is not needed after it.
    pub fn wait(self: *WindowsWake, timeout_ns: ?u64) bool {
        const ms: u32 = if (timeout_ns) |ns| @intCast(@min((ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, INFINITE - 1)) else INFINITE;
        return WaitForSingleObject(self.event, ms) == WAIT_OBJECT_0;
    }
};
