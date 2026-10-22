//! The few kernel32 calls setup makes beyond zg_install's. Windows only.

const std = @import("std");
const builtin = @import("builtin");

const HANDLE = *anyopaque;
const SYNCHRONIZE: u32 = 0x00100000;

extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

/// This process's id (0 off Windows).
pub fn currentPid() u32 {
    if (builtin.os.tag != .windows) return 0;
    return GetCurrentProcessId();
}

/// Waits up to `ms` for process `pid` to exit. True when it has exited
/// or no longer exists.
pub fn waitForExit(pid: u32, ms: u32) bool {
    if (builtin.os.tag != .windows) return true;
    const h = OpenProcess(SYNCHRONIZE, 0, pid) orelse return true;
    defer _ = CloseHandle(h);
    return WaitForSingleObject(h, ms) == 0;
}
