//! Exit codes of `zg agent` (E10.F10.S01.T01). They are part of the CLI's
//! contract: scripts branch on them, so a code never changes meaning and
//! new outcomes get new numbers.

const std = @import("std");
const ev = @import("../loop/events.zig");

pub const ExitCode = enum(u8) {
    /// The run finished normally.
    ok = 0,
    /// The model or the harness failed (provider error, invalid structured
    /// output, refusal).
    failed = 1,
    /// Invalid flags or arguments.
    usage = 2,
    /// A budget ran out: turns, cost or time.
    budget = 3,
    /// A tool call needed an approval that could not be given (no prompt
    /// channel, a denied or timed-out streamed prompt).
    permission_required = 4,
    /// SIGINT or Ctrl-C.
    interrupted = 130,
    /// SIGTERM, Ctrl-Break or the console closing.
    terminated = 143,

    pub fn code(c: ExitCode) u8 {
        return @intFromEnum(c);
    }
};

/// The exit-code section of `zg agent --help`.
pub const help =
    \\Exit codes:
    \\  0    the run finished
    \\  1    the model or the harness failed
    \\  2    invalid flags or arguments
    \\  3    a budget ran out (--max-turns, --max-budget-usd, --max-time)
    \\  4    a tool call needed an approval that was not given
    \\  130  interrupted (SIGINT, Ctrl-C)
    \\  143  terminated (SIGTERM, Ctrl-Break, console closed)
    \\
;

/// What ended a run, as the runner saw it.
pub const Outcome = struct {
    finish: ?ev.FinishReason,
    /// Permission denials for want of an approval.
    denials: usize = 0,
    signal: ?Signal = null,
    /// Structured output failed validation after the repair turn.
    invalid_output: bool = false,

    pub const Signal = enum { interrupt, terminate };
};

/// The exit code of a run. A signal wins, then budgets, then failures,
/// then denials.
pub fn of(o: Outcome) ExitCode {
    if (o.signal) |s| return switch (s) {
        .interrupt => .interrupted,
        .terminate => .terminated,
    };
    const f = o.finish orelse return .failed;
    return switch (f) {
        .budget, .max_turns => .budget,
        .failed, .refusal, .blocked => .failed,
        .canceled => .interrupted,
        .end_turn, .max_tokens => if (o.invalid_output) .failed else if (o.denials > 0) .permission_required else .ok,
    };
}

test "every exit code" {
    const t = std.testing;
    try t.expectEqual(ExitCode.ok, of(.{ .finish = .end_turn }));
    try t.expectEqual(ExitCode.ok, of(.{ .finish = .max_tokens }));
    try t.expectEqual(ExitCode.failed, of(.{ .finish = .failed }));
    try t.expectEqual(ExitCode.failed, of(.{ .finish = .refusal }));
    try t.expectEqual(ExitCode.failed, of(.{ .finish = null }));
    try t.expectEqual(ExitCode.failed, of(.{ .finish = .end_turn, .invalid_output = true }));
    try t.expectEqual(ExitCode.budget, of(.{ .finish = .budget }));
    try t.expectEqual(ExitCode.budget, of(.{ .finish = .max_turns, .denials = 1 }));
    try t.expectEqual(ExitCode.permission_required, of(.{ .finish = .end_turn, .denials = 2 }));
    try t.expectEqual(ExitCode.interrupted, of(.{ .finish = .canceled }));
    try t.expectEqual(ExitCode.interrupted, of(.{ .finish = .end_turn, .signal = .interrupt }));
    try t.expectEqual(ExitCode.terminated, of(.{ .finish = .canceled, .signal = .terminate }));
    try t.expectEqual(@as(u8, 143), ExitCode.terminated.code());
}
