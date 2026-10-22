//! Crash test helper: `crasher --state-dir <dir> --crash=<kind>` installs
//! zg_crash exactly like the apps do, then crashes in `crashHere`.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_crash = @import("zg_crash");

pub const std_options: std.Options = .{
    // std's Windows handler is a vectored one that would run first.
    .enable_segfault_handler = builtin.os.tag != .windows,
    .signal_stack_size = 256 * 1024,
};
pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);
pub const debug = struct {
    pub const handleSegfault = zg_crash.handleSegfault;
};

pub const Kind = enum {
    null_deref,
    stack_overflow,
    panic,
    @"unreachable",
    ill,
    breakpoint,
    abort,
    div_by_zero,
    sigsys,
    two_threads,
    /// Stack overflow on a `std.Thread`.
    stack_overflow_thread,
    /// Windows: an access violation in a thread made with raw `CreateThread`.
    foreign_thread,
    /// Windows: an access violation a vectored handler continues from;
    /// must exit 0 without a report.
    handled_first_chance,
};

var zero: usize = 0;
var dividend: usize = 12345;

pub fn main(init: std.process.Init.Minimal) u8 {
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) return 0;
    var state_dir: ?[]const u8 = null;
    var kind: ?Kind = null;
    // Windows needs an allocator to split the command line.
    var arg_mem: [16 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arg_mem);
    var it = init.args.iterateAllocator(fba.allocator()) catch return 2;
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--state-dir")) {
            state_dir = it.next();
        } else if (std.mem.startsWith(u8, a, "--crash=")) {
            kind = std.meta.stringToEnum(Kind, a["--crash=".len..]);
        }
    }
    var crash_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sd = state_dir orelse return 2;
    zg_crash.install(.{
        .crash_dir = zg_crash.paths.crashDir(sd, &crash_buf) orelse return 2,
        .state_dir = sd,
        .product = "crasher",
        .announce = false,
    }) catch return 3;
    zg_crash.annotations.set("ui.view", "crasher");
    zg_crash.annotations.set("boot_pending", "1");
    crashHere(kind orelse return 2);
    return 0;
}

noinline fn crashHere(kind: Kind) void {
    switch (kind) {
        .null_deref => {
            const p: *volatile u32 = @ptrFromInt(16 + zero);
            p.* = 1;
        },
        .stack_overflow => std.mem.doNotOptimizeAway(recurse(1)),
        .panic => @panic("crasher: panic"),
        .@"unreachable" => if (builtin.mode == .ReleaseSafe or builtin.mode == .Debug) {
            if (zero == 0) unreachable;
        } else @trap(),
        .ill => @trap(),
        .breakpoint => @breakpoint(),
        .abort => std.process.abort(),
        .div_by_zero => {
            // Both operands opaque: LLVM rewrites `1 / x` as `x == 1`.
            const x: *volatile usize = &zero;
            const y: *volatile usize = &dividend;
            std.mem.doNotOptimizeAway(@divTrunc(y.*, x.*));
        },
        .sigsys => if (builtin.os.tag == .linux) {
            _ = std.os.linux.kill(std.os.linux.getpid(), .SYS);
        },
        .stack_overflow_thread => {
            const t = std.Thread.spawn(.{}, overflowThread, .{}) catch return;
            t.join();
        },
        .foreign_thread => if (builtin.os.tag == .windows) {
            const h = w32.CreateThread(null, 0, foreignThread, null, 0, null) orelse return;
            _ = w32.WaitForSingleObject(h, std.math.maxInt(u32));
        },
        .handled_first_chance => if (builtin.os.tag == .windows) {
            _ = w32.AddVectoredExceptionHandler(1, continueRaised);
            w32.RaiseException(raised_code, 0, 0, null);
            std.process.exit(0);
        },
        .two_threads => {
            var ts: [2]std.Thread = undefined;
            for (&ts) |*t| t.* = std.Thread.spawn(.{}, crashThread, .{}) catch return;
            for (ts) |t| t.join();
        },
    }
    // Signals are asynchronous; give them a moment, then fail loudly
    // instead of hanging the test. Windows exceptions are synchronous.
    if (builtin.os.tag == .linux) {
        for (0..50) |_| _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = 100 * std.time.ns_per_ms }, null);
        std.os.linux.exit_group(99);
    }
    std.process.exit(99);
}

fn crashThread() void {
    crashHere(.null_deref);
}

fn overflowThread() void {
    std.mem.doNotOptimizeAway(recurse(1));
}

/// An access-violation code raised by hand: the handler can continue.
const raised_code: u32 = 0xC0000005;

const w32 = struct {
    const windows = std.os.windows;
    extern "kernel32" fn CreateThread(attrs: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, param: ?*anyopaque, flags: u32, tid: ?*u32) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn WaitForSingleObject(h: windows.HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn AddVectoredExceptionHandler(first: u32, handler: windows.VECTORED_EXCEPTION_HANDLER) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn RaiseException(code: u32, flags: u32, n: u32, args: ?[*]const usize) callconv(.winapi) void;
};

fn foreignThread(_: ?*anyopaque) callconv(.winapi) u32 {
    crashHere(.null_deref);
    return 0;
}

/// Continues from the raised exception, like a driver's `__except` would.
fn continueRaised(info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    if (info.ExceptionRecord.ExceptionCode != raised_code) return 0;
    return -1; // EXCEPTION_CONTINUE_EXECUTION
}

noinline fn recurse(n: u64) u64 {
    var buf: [1024]u8 = undefined;
    const v: *volatile [1024]u8 = &buf;
    v[n % 1024] = @truncate(n);
    return recurse(n + 1) +% v[(n * 7) % 1024];
}
