//! zg_perf: performance budgets, trace capture and export, frame timing,
//! memory accounting, startup and idle discipline and threading guardrails
//! (E14). Layer 1: depends only on zg_core, so every package may import it.

const std = @import("std");

/// Budget registry, evaluation and bench binding (E14.F01.S01).
pub const budget = @import("budget.zig");
/// Stall watchdog, zone shadow stacks and the activity signal (E14.F01.S02).
pub const runtime = @import("runtime.zig");
/// The compiled code samples of docs/perf/threading.md.
pub const docs_examples = @import("docs_examples.zig");

/// See `runtime.StallWatchdog`.
pub const StallWatchdog = runtime.StallWatchdog;
/// See `runtime.ActivitySignal`.
pub const ActivitySignal = runtime.ActivitySignal;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(budget);
    std.testing.refAllDecls(runtime);
}
