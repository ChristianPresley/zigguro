//! Process memory from the OS (E14.F04.S01.T02). Blocking: call it from
//! workers (the sampler) or explicit reports only.
//!
//! - Linux: `/proc/self/smaps_rollup` (private = Private_Clean +
//!   Private_Dirty, plus Rss, Pss and Anonymous), `/proc/self/status` for
//!   the peak (VmHWM) and the anon/file split, and `/proc/self/statm` when
//!   smaps_rollup is missing (kernels before 4.14).
//! - Windows: `K32GetProcessMemoryInfo` with `PROCESS_MEMORY_COUNTERS_EX2`
//!   (private = PrivateUsage), falling back to `_EX` on older systems.
//!
//! The budget `mem.idle_private` uses `private_bytes`. Some GPU drivers
//! count their allocations as private memory; reports show GPU numbers
//! next to it.

const std = @import("std");
const builtin = @import("builtin");

pub const ProcessMem = struct {
    private_bytes: u64 = 0,
    rss_bytes: u64 = 0,
    pss_bytes: ?u64 = null,
    peak_rss_bytes: u64 = 0,
    anon_bytes: ?u64 = null,
    file_bytes: ?u64 = null,
    commit_bytes: ?u64 = null,
};

/// The value in kB after `key:` on a /proc line, in bytes.
fn kbValue(rest: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    const v = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return v * 1024;
}

/// Fills `m` from /proc/self/smaps_rollup text; false when it holds no Rss.
pub fn parseSmapsRollup(text: []const u8, m: *ProcessMem) bool {
    var private: u64 = 0;
    var have_rss = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const v = kbValue(line[colon + 1 ..]) orelse continue;
        if (std.mem.eql(u8, key, "Rss")) {
            m.rss_bytes = v;
            have_rss = true;
        } else if (std.mem.eql(u8, key, "Pss")) m.pss_bytes = v else if (std.mem.eql(u8, key, "Private_Clean") or std.mem.eql(u8, key, "Private_Dirty")) private += v else if (std.mem.eql(u8, key, "Anonymous")) m.anon_bytes = v else if (std.mem.eql(u8, key, "Pss_File")) m.file_bytes = v;
    }
    m.private_bytes = private;
    return have_rss;
}

/// Fills the peak, RSS and anon/file split from /proc/self/status text
/// (only fields smaps_rollup did not set).
pub fn parseStatus(text: []const u8, m: *ProcessMem) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const v = kbValue(line[colon + 1 ..]) orelse continue;
        if (std.mem.eql(u8, key, "VmHWM")) m.peak_rss_bytes = v else if (std.mem.eql(u8, key, "VmRSS")) {
            if (m.rss_bytes == 0) m.rss_bytes = v;
        } else if (std.mem.eql(u8, key, "RssAnon")) {
            if (m.anon_bytes == null) m.anon_bytes = v;
        } else if (std.mem.eql(u8, key, "RssFile")) {
            if (m.file_bytes == null) m.file_bytes = v;
        }
    }
    m.peak_rss_bytes = @max(m.peak_rss_bytes, m.rss_bytes);
}

/// /proc/self/statm (`size resident shared text lib data dt`, in pages):
/// RSS, and resident minus shared as the private estimate.
pub fn parseStatm(text: []const u8, page_size: u64, m: *ProcessMem) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    _ = it.next() orelse return false;
    const resident = std.fmt.parseInt(u64, it.next() orelse return false, 10) catch return false;
    const shared = std.fmt.parseInt(u64, it.next() orelse return false, 10) catch return false;
    m.rss_bytes = resident * page_size;
    m.private_bytes = (resident -| shared) * page_size;
    return true;
}

/// Reads this process's memory. `scratch` holds the /proc files (8 KiB is
/// plenty for smaps_rollup and status).
pub fn readProcessMem(io: std.Io, scratch: []u8) !ProcessMem {
    return switch (builtin.os.tag) {
        .linux => readLinux(io, scratch),
        .windows => readWindows(),
        else => error.Unsupported,
    };
}

fn readLinux(io: std.Io, scratch: []u8) !ProcessMem {
    var m: ProcessMem = .{};
    const cwd = std.Io.Dir.cwd();
    const rollup_ok = if (cwd.readFile(io, "/proc/self/smaps_rollup", scratch)) |text|
        text.len < scratch.len and parseSmapsRollup(text, &m)
    else |_|
        false;
    if (!rollup_ok) {
        const text = try cwd.readFile(io, "/proc/self/statm", scratch);
        if (!parseStatm(text, std.heap.pageSize(), &m)) return error.Unparsable;
    }
    if (cwd.readFile(io, "/proc/self/status", scratch)) |text| parseStatus(text, &m) else |_| {}
    return m;
}

const win = struct {
    const PROCESS_MEMORY_COUNTERS_EX2 = extern struct {
        cb: u32,
        PageFaultCount: u32,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
        PrivateUsage: usize,
        PrivateWorkingSetSize: usize,
        SharedCommitUsage: u64,
    };
    /// `PROCESS_MEMORY_COUNTERS_EX`: EX2 without its last two fields.
    const ex_size = @offsetOf(PROCESS_MEMORY_COUNTERS_EX2, "PrivateWorkingSetSize");
    extern "kernel32" fn K32GetProcessMemoryInfo(process: std.os.windows.HANDLE, counters: *anyopaque, cb: u32) callconv(.winapi) std.os.windows.BOOL;
};

fn readWindows() !ProcessMem {
    var c = std.mem.zeroes(win.PROCESS_MEMORY_COUNTERS_EX2);
    const self = std.os.windows.GetCurrentProcess();
    var ex2 = true;
    c.cb = @sizeOf(win.PROCESS_MEMORY_COUNTERS_EX2);
    if (win.K32GetProcessMemoryInfo(self, &c, c.cb) == .FALSE) {
        ex2 = false;
        c.cb = win.ex_size;
        if (win.K32GetProcessMemoryInfo(self, &c, c.cb) == .FALSE) return error.Unavailable;
    }
    return .{
        .private_bytes = c.PrivateUsage,
        .commit_bytes = c.PrivateUsage,
        .rss_bytes = c.WorkingSetSize,
        .peak_rss_bytes = c.PeakWorkingSetSize,
        .anon_bytes = if (ex2) c.PrivateWorkingSetSize else null,
    };
}

test "sampler: parse smaps_rollup fixture" {
    var m: ProcessMem = .{};
    try std.testing.expect(parseSmapsRollup(@embedFile("testdata/smaps_rollup.txt"), &m));
    try std.testing.expectEqual(@as(u64, 61_440 * 1024), m.rss_bytes);
    try std.testing.expectEqual(@as(?u64, 40_100 * 1024), m.pss_bytes);
    try std.testing.expectEqual(@as(u64, (1_204 + 35_016) * 1024), m.private_bytes);
    try std.testing.expectEqual(@as(?u64, 33_800 * 1024), m.anon_bytes);
}

test "sampler: parse status fixture" {
    var m: ProcessMem = .{};
    parseStatus(@embedFile("testdata/proc_status.txt"), &m);
    try std.testing.expectEqual(@as(u64, 70_412 * 1024), m.peak_rss_bytes);
    try std.testing.expectEqual(@as(u64, 61_448 * 1024), m.rss_bytes);
    try std.testing.expectEqual(@as(?u64, 34_000 * 1024), m.anon_bytes);
    try std.testing.expectEqual(@as(?u64, 27_448 * 1024), m.file_bytes);
    // smaps_rollup values win.
    var r: ProcessMem = .{ .rss_bytes = 1, .anon_bytes = 2 };
    parseStatus(@embedFile("testdata/proc_status.txt"), &r);
    try std.testing.expectEqual(@as(u64, 1), r.rss_bytes);
    try std.testing.expectEqual(@as(?u64, 2), r.anon_bytes);
}

test "sampler: statm fallback" {
    var m: ProcessMem = .{};
    try std.testing.expect(parseStatm("25000 15000 6000 300 0 9000 0\n", 4096, &m));
    try std.testing.expectEqual(@as(u64, 15_000 * 4096), m.rss_bytes);
    try std.testing.expectEqual(@as(u64, 9_000 * 4096), m.private_bytes);
    try std.testing.expect(!parseStatm("garbage", 4096, &m));
}

test "sampler: live read returns non-zero" {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return error.SkipZigTest;
    var scratch: [8192]u8 = undefined;
    const m = try readProcessMem(std.testing.io, &scratch);
    try std.testing.expect(m.rss_bytes > 0);
    try std.testing.expect(m.private_bytes > 0);
    try std.testing.expect(m.peak_rss_bytes >= m.rss_bytes);
}
