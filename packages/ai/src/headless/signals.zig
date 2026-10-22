//! SIGINT/SIGTERM for headless runs (E10.F10.S01.T01). The handler only
//! sets atomic flags; a watcher task polls them and cancels the turn from
//! normal context, so no Io call ever runs inside a handler. A second
//! SIGINT exits at once with 130.
//!
//! Windows has no signals: a console control handler maps Ctrl-C to
//! SIGINT and Ctrl-Break, closing the console, logoff and shutdown to
//! SIGTERM. `std.os.windows` has no binding for SetConsoleCtrlHandler, so
//! it is declared here (kernel32 is part of the OS).

const std = @import("std");
const builtin = @import("builtin");
const exit_codes = @import("exit_codes.zig");

const Io = std.Io;

pub const Kind = exit_codes.Outcome.Signal;

pub const Signals = struct {
    /// Bit 0: an interrupt is pending; bit 1: a terminate is pending.
    pending: std.atomic.Value(u8) = .init(0),
    /// The first signal of the run (0 none, 1 interrupt, 2 terminate).
    first: std.atomic.Value(u8) = .init(0),
    interrupts: std.atomic.Value(u32) = .init(0),
    /// Exit the process on the second interrupt (off in tests).
    exit_on_second: bool = true,

    /// Async-signal-safe.
    pub fn raise(s: *Signals, k: Kind) void {
        const bit: u8 = switch (k) {
            .interrupt => 1,
            .terminate => 2,
        };
        _ = s.first.cmpxchgStrong(0, bit, .acq_rel, .acquire);
        _ = s.pending.fetchOr(bit, .acq_rel);
        if (k == .interrupt and s.interrupts.fetchAdd(1, .acq_rel) >= 1 and s.exit_on_second) hardExit(exit_codes.ExitCode.interrupted.code());
    }

    /// The pending signals, cleared; terminate wins.
    pub fn take(s: *Signals) ?Kind {
        const p = s.pending.swap(0, .acq_rel);
        if (p & 2 != 0) return .terminate;
        if (p & 1 != 0) return .interrupt;
        return null;
    }

    /// The first signal received, for the exit code.
    pub fn received(s: *const Signals) ?Kind {
        return switch (s.first.load(.acquire)) {
            1 => .interrupt,
            2 => .terminate,
            else => null,
        };
    }
};

fn hardExit(code: u8) noreturn {
    if (builtin.os.tag == .linux) std.os.linux.exit_group(code);
    std.process.exit(code);
}

var installed: ?*Signals = null;

/// Routes the process's SIGINT and SIGTERM (or console events) to `s`.
pub fn install(s: *Signals) void {
    installed = s;
    switch (builtin.os.tag) {
        .windows => _ = SetConsoleCtrlHandler(ctrlHandler, 1),
        .wasi, .freestanding => {},
        else => {
            const act: std.posix.Sigaction = .{
                .handler = .{ .handler = posixHandler },
                .mask = std.posix.sigemptyset(),
                .flags = std.posix.SA.RESTART,
            };
            std.posix.sigaction(.INT, &act, null);
            std.posix.sigaction(.TERM, &act, null);
        },
    }
}

fn posixHandler(sig: std.posix.SIG) callconv(.c) void {
    const s = installed orelse return;
    s.raise(if (sig == .TERM) .terminate else .interrupt);
}

const BOOL = c_int;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;

pub const CTRL_C_EVENT: u32 = 0;
pub const CTRL_BREAK_EVENT: u32 = 1;
pub const CTRL_CLOSE_EVENT: u32 = 2;
pub const CTRL_LOGOFF_EVENT: u32 = 5;
pub const CTRL_SHUTDOWN_EVENT: u32 = 6;

/// The signal a console control event stands for.
pub fn fromCtrlEvent(event: u32) ?Kind {
    return switch (event) {
        CTRL_C_EVENT => .interrupt,
        CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT => .terminate,
        else => null,
    };
}

fn ctrlHandler(event: u32) callconv(.winapi) BOOL {
    return handleCtrl(event);
}

// The body of `ctrlHandler`, callable from tests on every target: a
// `.winapi` function can't be compiled for aarch64 Linux.
fn handleCtrl(event: u32) BOOL {
    const s = installed orelse return 0;
    const k = fromCtrlEvent(event) orelse return 0;
    s.raise(k);
    return 1;
}

/// Calls `on_signal` from a normal task whenever a signal is pending,
/// until `stop` is set. Poll interval 20 ms.
pub const Watcher = struct {
    signals: *Signals,
    ctx: *anyopaque,
    on_signal: *const fn (ctx: *anyopaque, k: Kind) void,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn run(w: *Watcher, io: Io) void {
        while (!w.stop.load(.acquire)) {
            if (w.signals.take()) |k| w.on_signal(w.ctx, k);
            io.sleep(.fromMilliseconds(20), .awake) catch return;
        }
    }
};

test "console events map to signals" {
    const t = std.testing;
    try t.expectEqual(Kind.interrupt, fromCtrlEvent(CTRL_C_EVENT).?);
    try t.expectEqual(Kind.terminate, fromCtrlEvent(CTRL_BREAK_EVENT).?);
    try t.expectEqual(Kind.terminate, fromCtrlEvent(CTRL_CLOSE_EVENT).?);
    try t.expectEqual(@as(?Kind, null), fromCtrlEvent(99));
}

test "windows ctrl-c maps to sigint" {
    const t = std.testing;
    var s: Signals = .{ .exit_on_second = false };
    const prev = installed;
    defer installed = prev;
    installed = &s;
    try t.expectEqual(@as(BOOL, 1), handleCtrl(CTRL_C_EVENT));
    try t.expectEqual(Kind.interrupt, s.take().?);
    try t.expectEqual(@as(BOOL, 1), handleCtrl(CTRL_CLOSE_EVENT));
    try t.expectEqual(Kind.terminate, s.take().?);
    try t.expectEqual(@as(BOOL, 0), handleCtrl(42));
}

test "flags" {
    const t = std.testing;
    var s: Signals = .{ .exit_on_second = false };
    try t.expectEqual(@as(?Kind, null), s.take());
    s.raise(.interrupt);
    s.raise(.terminate);
    try t.expectEqual(Kind.terminate, s.take().?);
    try t.expectEqual(@as(?Kind, null), s.take());
    try t.expectEqual(Kind.interrupt, s.received().?);
    s.raise(.interrupt);
    try t.expectEqual(@as(u32, 2), s.interrupts.load(.acquire));
}
