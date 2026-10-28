//! Process and thread CPU time (E14.F05.S02.T01). Linux: getrusage
//! (RUSAGE_SELF / RUSAGE_THREAD), with voluntary and involuntary context
//! switches. Windows: GetProcessTimes / GetThreadTimes (100 ns units);
//! context switches are unknown there without performance counters.

const std = @import("std");
const builtin = @import("builtin");

pub const CpuTimes = struct {
    user_ns: u64 = 0,
    system_ns: u64 = 0,
    voluntary_ctx: ?u64 = null,
    involuntary_ctx: ?u64 = null,

    pub fn totalNs(c: CpuTimes) u64 {
        return c.user_ns + c.system_ns;
    }
};

/// This process's CPU time.
pub fn processCpuTimes() !CpuTimes {
    return switch (builtin.os.tag) {
        .linux => linuxUsage(std.os.linux.rusage.SELF),
        .windows => windowsTimes(true),
        else => error.Unsupported,
    };
}

/// The calling thread's CPU time.
pub fn threadCpuTimes() !CpuTimes {
    return switch (builtin.os.tag) {
        .linux => linuxUsage(std.os.linux.rusage.THREAD),
        .windows => windowsTimes(false),
        else => error.Unsupported,
    };
}

fn tvNs(tv: std.os.linux.timeval) u64 {
    return @as(u64, @intCast(tv.sec)) * std.time.ns_per_s + @as(u64, @intCast(tv.usec)) * std.time.ns_per_us;
}

fn linuxUsage(who: i32) !CpuTimes {
    const linux = std.os.linux;
    var ru: linux.rusage = undefined;
    if (linux.errno(linux.getrusage(who, &ru)) != .SUCCESS) return error.Unavailable;
    return .{
        .user_ns = tvNs(ru.utime),
        .system_ns = tvNs(ru.stime),
        .voluntary_ctx = @intCast(ru.nvcsw),
        .involuntary_ctx = @intCast(ru.nivcsw),
    };
}

const win = struct {
    const windows = std.os.windows;
    const FILETIME = extern struct { low: u32, high: u32 };
    extern "kernel32" fn GetProcessTimes(h: windows.HANDLE, c: *FILETIME, e: *FILETIME, k: *FILETIME, u: *FILETIME) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetThreadTimes(h: windows.HANDLE, c: *FILETIME, e: *FILETIME, k: *FILETIME, u: *FILETIME) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetCurrentThread() callconv(.winapi) windows.HANDLE;
    fn ns(ft: FILETIME) u64 {
        return ((@as(u64, ft.high) << 32) | ft.low) * 100;
    }
};

fn windowsTimes(process: bool) !CpuTimes {
    var c: win.FILETIME = undefined;
    var e: win.FILETIME = undefined;
    var k: win.FILETIME = undefined;
    var u: win.FILETIME = undefined;
    const ok = if (process)
        win.GetProcessTimes(std.os.windows.GetCurrentProcess(), &c, &e, &k, &u)
    else
        win.GetThreadTimes(win.GetCurrentThread(), &c, &e, &k, &u);
    if (ok == .FALSE) return error.Unavailable;
    return .{ .user_ns = win.ns(u), .system_ns = win.ns(k) };
}

test "cpu_time: monotonic and non-zero after busy loop" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    const a = try threadCpuTimes();
    var x: u64 = 0;
    var i: u64 = 0;
    // About 20 ms of work (well above the 1-4 ms tick of some kernels).
    const io = std.testing.io;
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    while (std.Io.Clock.awake.now(io).nanoseconds - t0 < 20 * std.time.ns_per_ms) : (i += 1) x +%= i *% 2654435761;
    std.mem.doNotOptimizeAway(x);
    const b = try threadCpuTimes();
    try std.testing.expect(b.totalNs() > a.totalNs());
    const p = try processCpuTimes();
    try std.testing.expect(p.totalNs() >= b.totalNs());
    if (builtin.os.tag == .linux) try std.testing.expect(p.voluntary_ctx != null);
}
