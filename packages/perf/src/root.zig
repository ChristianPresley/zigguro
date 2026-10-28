//! zg_perf: performance budgets, trace capture and export, frame timing,
//! memory accounting, startup and idle discipline and threading guardrails
//! (E14). Layer 1: depends only on zg_core, so every package may import it.

const std = @import("std");

/// Budget registry, evaluation and bench binding (E14.F01.S01).
pub const budget = @import("budget.zig");
/// Stall watchdog, zone shadow stacks and the activity signal (E14.F01.S02).
pub const runtime = @import("runtime.zig");
/// Trace categories, the async span taxonomy and the async span API (E14.F02).
pub const trace = @import("trace.zig");
/// Frame records, the frame timeline and latency histograms (E14.F03).
pub const frame = @import("frame.zig");
/// Perfetto and Chrome trace export.
pub const @"export" = @import("export.zig");
/// ftrace and ETW bridges.
pub const os = @import("os.zig");
/// Memory tags, the tracked allocator and GPU memory (E14.F04).
pub const mem = @import("mem.zig");
/// Startup timing (E14.F05).
pub const startup = @import("startup.zig");
/// The compiled code samples of docs/perf/threading.md.
pub const docs_examples = @import("docs_examples.zig");

/// See `runtime.StallWatchdog`.
pub const StallWatchdog = runtime.StallWatchdog;
/// See `runtime.ActivitySignal`.
pub const ActivitySignal = runtime.ActivitySignal;

/// A probe for `zig build check-frame-pointers`: its code must start with
/// the frame setup when frame pointers are kept (E14.F02.S03.T02).
export fn zg_perf_fp_probe(x: u64) callconv(.c) u64 {
    @setRuntimeSafety(false);
    return fpProbeInner(x) +% 1;
}

noinline fn fpProbeInner(x: u64) u64 {
    return x *% 0x9e37_79b9_7f4a_7c15;
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(budget);
    std.testing.refAllDecls(runtime);
    std.testing.refAllDecls(trace);
    std.testing.refAllDecls(frame);
    std.testing.refAllDecls(@"export");
    std.testing.refAllDecls(os);
    std.testing.refAllDecls(mem);
    std.testing.refAllDecls(startup);
}
