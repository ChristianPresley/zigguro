//! When the OS created this process, on the `.awake` clock
//! (E14.F05.S01.T01).
//!
//! - Linux: `starttime` (field 22) of `/proc/self/stat`, in clock ticks
//!   since boot (usually 100 Hz, so 10 ms resolution), moved from the boot
//!   clock to the awake clock with a back-to-back pair of reads.
//! - Windows: the creation FILETIME from `GetProcessTimes` (100 ns units
//!   since 1601, wall clock), moved from the real clock to the awake clock.

const std = @import("std");
const builtin = @import("builtin");

/// A creation time and its resolution.
pub const ProcessStart = struct {
    /// `.awake` nanoseconds.
    created_ns: u64,
    resolution_ns: u64,
};

/// `starttime` from /proc/self/stat text, in clock ticks since boot.
/// Fields are counted after the last `)`, since the command name can
/// hold spaces and parentheses.
pub fn parseStatStarttime(text: []const u8) ?u64 {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeAny(u8, text[close + 1 ..], " \n");
    // Field 3 (state) is the first after the name; starttime is field 22.
    var field: u32 = 3;
    while (it.next()) |tok| : (field += 1) {
        if (field == 22) return std.fmt.parseInt(u64, tok, 10) catch null;
    }
    return null;
}

/// Moves a time on clock A to clock B given a pair of reads of both
/// (`now_a`, `now_b`) taken back to back. Saturates at zero.
pub fn rebase(t_a: u64, now_a: u64, now_b: u64) u64 {
    return now_b -| (now_a -| t_a);
}

/// A FILETIME (100 ns units since 1601-01-01) as Unix-epoch nanoseconds.
pub fn filetimeToUnixNs(ft: u64) i128 {
    return @as(i128, ft) * 100 + @as(i128, std.time.epoch.windows) * std.time.ns_per_s;
}

fn nowNs(io: std.Io, clock: std.Io.Clock) i128 {
    return clock.now(io).nanoseconds;
}

/// Reads `a` and `b` back to back three times and returns the pair with
/// the smallest gap, as `{ a, b }`.
fn clockPair(io: std.Io, a: std.Io.Clock, b: std.Io.Clock) [2]i128 {
    var best: [2]i128 = undefined;
    var best_gap: i128 = std.math.maxInt(i128);
    for (0..3) |_| {
        const b0 = nowNs(io, b);
        const av = nowNs(io, a);
        const b1 = nowNs(io, b);
        if (b1 - b0 < best_gap) {
            best_gap = b1 - b0;
            best = .{ av, @divTrunc(b0 + b1, 2) };
        }
    }
    return best;
}

/// This process's creation time on the `.awake` clock; null where the OS
/// does not say.
pub fn processCreatedNs(io: std.Io) ?ProcessStart {
    return switch (builtin.os.tag) {
        .linux => linuxStart(io),
        .windows => windowsStart(io),
        else => null,
    };
}

fn linuxStart(io: std.Io) ?ProcessStart {
    var buf: [1024]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, "/proc/self/stat", &buf) catch return null;
    const ticks = parseStatStarttime(text) orelse return null;
    // USER_HZ: AT_CLKTCK, which reads 0 when the aux vector is not
    // available (some static builds); /proc uses 100 on every
    // architecture then.
    const aux = std.os.linux.getauxval(std.elf.AT_CLKTCK);
    const hz: u64 = if (aux == 0) 100 else aux;
    const start_boot: u64 = ticks * (std.time.ns_per_s / hz);
    const p = clockPair(io, .boot, .awake);
    return .{
        .created_ns = rebase(start_boot, @intCast(@max(0, p[0])), @intCast(@max(0, p[1]))),
        .resolution_ns = std.time.ns_per_s / hz,
    };
}

const win = struct {
    const windows = std.os.windows;
    const FILETIME = extern struct { low: u32, high: u32 };
    extern "kernel32" fn GetProcessTimes(process: windows.HANDLE, creation: *FILETIME, exit: *FILETIME, kernel: *FILETIME, user: *FILETIME) callconv(.winapi) windows.BOOL;
};

fn windowsStart(io: std.Io) ?ProcessStart {
    var c: win.FILETIME = undefined;
    var e: win.FILETIME = undefined;
    var k: win.FILETIME = undefined;
    var u: win.FILETIME = undefined;
    if (win.GetProcessTimes(std.os.windows.GetCurrentProcess(), &c, &e, &k, &u) == .FALSE) return null;
    const created_unix = filetimeToUnixNs((@as(u64, c.high) << 32) | c.low);
    const p = clockPair(io, .real, .awake);
    const age = p[0] - created_unix;
    if (age < 0) return null;
    return .{ .created_ns = @intCast(@max(0, p[1] - age)), .resolution_ns = 100 };
}

test "startup: parse /proc/self/stat with spaces and parens in comm" {
    const text = @embedFile("testdata/proc_self_stat.txt");
    try std.testing.expectEqual(@as(?u64, 4_242_424), parseStatStarttime(text));
    try std.testing.expectEqual(@as(?u64, null), parseStatStarttime("12 (short) S 1"));
    try std.testing.expectEqual(@as(?u64, null), parseStatStarttime("no parens"));
}

test "startup: boottime to monotonic conversion math" {
    // Started 3.5 s after boot; boot clock now 10 s, awake clock now 7 s
    // (the machine slept 3 s before the process started).
    const s = std.time.ns_per_s;
    const ticks: u64 = 350; // 100 Hz
    const start_boot = ticks * (s / 100);
    try std.testing.expectEqual(@as(u64, 500 * std.time.ns_per_ms), rebase(start_boot, 10 * s, 7 * s));
    // Older than the awake clock's origin saturates at zero.
    try std.testing.expectEqual(@as(u64, 0), rebase(1, 10 * s, 2 * s));
}

test "startup: filetime conversion math" {
    // 1970-01-01T00:00:00Z as a FILETIME.
    try std.testing.expectEqual(@as(i128, 0), filetimeToUnixNs(116_444_736_000_000_000));
    // 2026-10-28T00:00:00Z.
    try std.testing.expectEqual(@as(i128, 1_793_145_600) * std.time.ns_per_s, filetimeToUnixNs(116_444_736_000_000_000 + 17_931_456_000_000_000));
}

test "startup: live process start is earlier than now and recent" {
    const io = std.testing.io;
    const ps = processCreatedNs(io) orelse return error.SkipZigTest;
    const now: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    try std.testing.expect(ps.created_ns <= now + ps.resolution_ns);
    // Test binaries start well within a minute of this test.
    try std.testing.expect(now - @min(now, ps.created_ns) < 60 * std.time.ns_per_s);
}
