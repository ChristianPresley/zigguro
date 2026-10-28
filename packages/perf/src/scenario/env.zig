//! Benchmark environment capture and stabilisation (E14.F06.S01.T02).
//!
//! `captureEnv` records what affects the numbers: CPU model, logical CPUs,
//! frequency governor, turbo boost, AC or battery, OS and kernel. The
//! caller fills in the git SHA, refresh rate, corpus version and machine
//! class. `warnings` lists what Google Benchmark's variance guide warns
//! about (governor not `performance`, boost on, battery); they are
//! reported, never fatal. `stabilize` pins the calling thread to one core
//! and raises its priority, best effort.

const std = @import("std");
const builtin = @import("builtin");

pub const Power = enum { ac, battery, unknown };

pub const Env = struct {
    cpu_model: []const u8 = "",
    logical_cpus: u16 = 0,
    governor: ?[]const u8 = null,
    boost: ?bool = null,
    power: Power = .unknown,
    os: []const u8 = @tagName(builtin.os.tag),
    kernel: []const u8 = "",
    zig: []const u8 = builtin.zig_version_string,
    git_sha: []const u8 = "",
    refresh_hz: ?f32 = null,
    corpus_version: u32 = 0,
    machine_class: []const u8 = "",

    pub fn writeJson(e: Env, w: *std.Io.Writer) !void {
        try std.json.Stringify.value(e, .{}, w);
    }
};

/// Captures the environment; strings are allocated with `gpa` (use an
/// arena). Fields it cannot read stay at their defaults.
pub fn captureEnv(io: std.Io, gpa: std.mem.Allocator) !Env {
    var e: Env = .{ .logical_cpus = @intCast(@min(std.Thread.getCpuCount() catch 0, std.math.maxInt(u16))) };
    switch (builtin.os.tag) {
        .linux => {
            if (readSmall(io, gpa, "/proc/cpuinfo", 1 << 20)) |t| e.cpu_model = parseCpuModel(t) orelse "";
            if (readSmall(io, gpa, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", 256)) |t| e.governor = trim(t);
            if (readSmall(io, gpa, "/sys/devices/system/cpu/cpufreq/boost", 64)) |t| {
                e.boost = parseFlag(t);
            } else if (readSmall(io, gpa, "/sys/devices/system/cpu/intel_pstate/no_turbo", 64)) |t| {
                if (parseFlag(t)) |no_turbo| e.boost = !no_turbo;
            }
            if (readSmall(io, gpa, "/proc/sys/kernel/osrelease", 256)) |t| e.kernel = trim(t);
            e.power = linuxPower(io, gpa);
        },
        .windows => {
            e.cpu_model = win.cpuName(gpa) catch "";
            e.power = win.power();
            e.kernel = win.version(gpa) catch "";
        },
        else => {},
    }
    if (e.cpu_model.len == 0) e.cpu_model = builtin.cpu.model.name;
    return e;
}

/// Streams the file: procfs files report size 0, so `readFileAlloc`
/// returns nothing for them.
fn readSmall(io: std.Io, gpa: std.mem.Allocator, path: []const u8, limit: usize) ?[]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    return r.interface.allocRemaining(gpa, .limited(limit)) catch null;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// The first `model name` of a /proc/cpuinfo text (ARM kernels may only
/// have `Hardware` or `CPU part`; then null).
pub fn parseCpuModel(cpuinfo: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cpuinfo, '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = trim(line[0..colon]);
        if (std.mem.eql(u8, key, "model name") or std.mem.eql(u8, key, "Hardware")) return trim(line[colon + 1 ..]);
    }
    return null;
}

/// "1"/"0" (sysfs flags).
pub fn parseFlag(text: []const u8) ?bool {
    const t = trim(text);
    if (std.mem.eql(u8, t, "1")) return true;
    if (std.mem.eql(u8, t, "0")) return false;
    return null;
}

/// From `(type, online)` pairs of /sys/class/power_supply/*: AC when a
/// mains supply is online, battery when one is present but none is
/// online, unknown without a mains supply (desktops and VMs often have
/// none).
pub const Supply = struct { kind: []const u8, online: ?bool };

pub fn powerFrom(supplies: []const Supply) Power {
    var mains = false;
    for (supplies) |s| if (std.mem.eql(u8, s.kind, "Mains")) {
        mains = true;
        if (s.online orelse false) return .ac;
    };
    return if (mains) .battery else .unknown;
}

fn linuxPower(io: std.Io, gpa: std.mem.Allocator) Power {
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/power_supply", .{ .iterate = true }) catch return .unknown;
    defer dir.close(io);
    var list: [16]Supply = undefined;
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (n == list.len) break;
        var buf: [256]u8 = undefined;
        const tp = std.fmt.bufPrint(&buf, "{s}/type", .{entry.name}) catch continue;
        const kind = dir.readFileAlloc(io, tp, gpa, .limited(64)) catch continue;
        const op = std.fmt.bufPrint(&buf, "{s}/online", .{entry.name}) catch continue;
        const online = if (dir.readFileAlloc(io, op, gpa, .limited(16))) |t| parseFlag(t) else |_| null;
        list[n] = .{ .kind = trim(kind), .online = online };
        n += 1;
    }
    return powerFrom(list[0..n]);
}

/// Variance warnings for `e`, one line each, into `w`. Returns how many.
pub fn warnings(e: Env, w: *std.Io.Writer) !usize {
    var n: usize = 0;
    if (e.governor) |g| if (!std.mem.eql(u8, g, "performance")) {
        try w.print("warning: CPU governor is '{s}', not 'performance': timings will vary\n", .{g});
        n += 1;
    };
    if (e.boost orelse false) {
        try w.writeAll("warning: CPU turbo boost is on: timings will vary\n");
        n += 1;
    }
    if (e.power == .battery) {
        try w.writeAll("warning: running on battery: timings will vary\n");
        n += 1;
    }
    return n;
}

pub const StabilizeOptions = struct {
    /// Pin the calling thread to this logical CPU (null: no pinning;
    /// scenarios use many threads and are not pinned).
    pin_cpu: ?u16 = 0,
    raise_priority: bool = true,
};

pub const StabilizeResult = struct {
    pinned_cpu: ?u16 = null,
    priority_raised: bool = false,

    pub fn describe(r: StabilizeResult, w: *std.Io.Writer) !void {
        if (r.pinned_cpu) |c| try w.print("pinned to CPU {d}", .{c}) else try w.writeAll("not pinned");
        try w.writeAll(if (r.priority_raised) ", priority raised\n" else ", normal priority\n");
    }
};

/// Pins and raises priority where allowed, and reports what it did.
pub fn stabilize(opts: StabilizeOptions) StabilizeResult {
    var r: StabilizeResult = .{};
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            if (opts.pin_cpu) |cpu| {
                var set: linux.cpu_set_t = @splat(0);
                const bits = @bitSizeOf(usize);
                if (cpu / bits < set.len) {
                    set[cpu / bits] = @as(usize, 1) << @intCast(cpu % bits);
                    if (linux.sched_setaffinity(0, &set)) |_| {
                        r.pinned_cpu = cpu;
                    } else |_| {}
                }
            }
            if (opts.raise_priority) {
                // setpriority(PRIO_PROCESS, 0 = this thread's tid, -5):
                // needs CAP_SYS_NICE; ignored otherwise.
                const rc = linux.syscall3(.setpriority, 0, 0, @bitCast(@as(isize, -5)));
                r.priority_raised = linux.errno(rc) == .SUCCESS;
            }
        },
        .windows => {
            const h = win.GetCurrentThread();
            if (opts.pin_cpu) |cpu| if (cpu < @bitSizeOf(usize)) {
                if (win.SetThreadAffinityMask(h, @as(usize, 1) << @intCast(cpu)) != 0) r.pinned_cpu = cpu;
            };
            if (opts.raise_priority) r.priority_raised = win.SetThreadPriority(h, 2) != .FALSE; // THREAD_PRIORITY_HIGHEST
        },
        else => {},
    }
    return r;
}

const win = struct {
    const windows = std.os.windows;
    extern "kernel32" fn GetCurrentThread() callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn SetThreadAffinityMask(h: windows.HANDLE, mask: usize) callconv(.winapi) usize;
    extern "kernel32" fn SetThreadPriority(h: windows.HANDLE, priority: c_int) callconv(.winapi) windows.BOOL;
    const SYSTEM_POWER_STATUS = extern struct { ac_line: u8, battery_flag: u8, battery_life_percent: u8, system_status_flag: u8, battery_life_time: u32, battery_full_life_time: u32 };
    extern "kernel32" fn GetSystemPowerStatus(s: *SYSTEM_POWER_STATUS) callconv(.winapi) windows.BOOL;
    const HKEY_LOCAL_MACHINE: usize = 0x80000002;
    const RRF_RT_REG_SZ: u32 = 0x00000002;
    extern "advapi32" fn RegGetValueW(key: usize, sub_key: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

    fn power() Power {
        var s: SYSTEM_POWER_STATUS = undefined;
        if (GetSystemPowerStatus(&s) == .FALSE) return .unknown;
        return switch (s.ac_line) {
            0 => .battery,
            1 => .ac,
            else => .unknown,
        };
    }

    fn cpuName(gpa: std.mem.Allocator) ![]const u8 {
        var buf: [256]u16 = undefined;
        var size: u32 = @sizeOf(@TypeOf(buf));
        const rc = RegGetValueW(HKEY_LOCAL_MACHINE, std.unicode.utf8ToUtf16LeStringLiteral("HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0"), std.unicode.utf8ToUtf16LeStringLiteral("ProcessorNameString"), RRF_RT_REG_SZ, null, &buf, &size);
        if (rc != 0) return error.Unavailable;
        const units = std.mem.sliceTo(buf[0 .. size / 2], 0);
        return trim(try std.unicode.utf16LeToUtf8Alloc(gpa, units));
    }

    fn version(gpa: std.mem.Allocator) ![]const u8 {
        var v: windows.RTL_OSVERSIONINFOW = undefined;
        v.dwOSVersionInfoSize = @sizeOf(windows.RTL_OSVERSIONINFOW);
        if (windows.ntdll.RtlGetVersion(&v) != .SUCCESS) return error.Unavailable;
        return std.fmt.allocPrint(gpa, "{d}.{d}.{d}", .{ v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber });
    }
};

test "env: parse cpuinfo/governor fixtures" {
    const x86 = "processor\t: 0\nvendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 9 7950X 16-Core Processor\ncpu MHz\t\t: 4500.000\n\nprocessor\t: 1\nmodel name\t: AMD Ryzen 9 7950X 16-Core Processor\n";
    try std.testing.expectEqualStrings("AMD Ryzen 9 7950X 16-Core Processor", parseCpuModel(x86).?);
    try std.testing.expect(parseCpuModel("processor\t: 0\nBogoMIPS\t: 48.00\n") == null);
    try std.testing.expectEqual(@as(?bool, true), parseFlag("1\n"));
    try std.testing.expectEqual(@as(?bool, false), parseFlag("0"));
    try std.testing.expectEqual(@as(?bool, null), parseFlag("x"));
    try std.testing.expectEqual(Power.ac, powerFrom(&.{ .{ .kind = "Battery", .online = null }, .{ .kind = "Mains", .online = true } }));
    try std.testing.expectEqual(Power.battery, powerFrom(&.{ .{ .kind = "Battery", .online = null }, .{ .kind = "Mains", .online = false } }));
    try std.testing.expectEqual(Power.unknown, powerFrom(&.{}));

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, 3), try warnings(.{ .governor = "powersave", .boost = true, .power = .battery }, &w));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "powersave") != null);
    w = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, 0), try warnings(.{ .governor = "performance", .boost = false, .power = .ac }, &w));
}

test "env: capture on this machine" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const e = try captureEnv(std.testing.io, arena.allocator());
    try std.testing.expect(e.cpu_model.len > 0);
    try std.testing.expect(e.logical_cpus > 0);
    if (builtin.os.tag == .linux) try std.testing.expect(e.kernel.len > 0);
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try e.writeJson(&aw.writer);
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), "{\"cpu_model\":"));
}
