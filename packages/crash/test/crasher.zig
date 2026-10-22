//! Crash test helper: `crasher --state-dir <dir> --crash=<kind>` installs
//! zg_crash exactly like the apps do, then crashes in `crashHere`.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_crash = @import("zg_crash");

pub const std_options: std.Options = .{
    .enable_segfault_handler = true,
    .signal_stack_size = 256 * 1024,
};
pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);
pub const debug = struct {
    pub const handleSegfault = zg_crash.handleSegfault;
};

pub const Kind = enum { null_deref, stack_overflow, panic, @"unreachable", ill, breakpoint, abort, div_by_zero, sigsys, two_threads };

var zero: usize = 0;
var dividend: usize = 12345;

pub fn main(init: std.process.Init.Minimal) u8 {
    // Windows capture is E17.F05.S01.T03.
    if (builtin.os.tag != .linux) return 0;
    var state_dir: ?[]const u8 = null;
    var kind: ?Kind = null;
    var it = init.args.iterate();
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
        .sigsys => _ = std.os.linux.kill(std.os.linux.getpid(), .SYS),
        .two_threads => {
            var ts: [2]std.Thread = undefined;
            for (&ts) |*t| t.* = std.Thread.spawn(.{}, crashThread, .{}) catch return;
            for (ts) |t| t.join();
        },
    }
    // Signals are asynchronous; give them a moment, then fail loudly
    // instead of hanging the test.
    for (0..50) |_| _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = 100 * std.time.ns_per_ms }, null);
    std.os.linux.exit_group(99);
}

fn crashThread() void {
    crashHere(.null_deref);
}

noinline fn recurse(n: u64) u64 {
    var buf: [1024]u8 = undefined;
    const v: *volatile [1024]u8 = &buf;
    v[n % 1024] = @truncate(n);
    return recurse(n + 1) +% v[(n * 7) % 1024];
}
