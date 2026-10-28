//! Startup timing (E14.F05): phase marks from process creation to the
//! first interactive frame, the startup report and its history.
//! docs/perf/startup.md says who marks what.

/// `StartupTimeline`, `Phase` and `Summary`.
pub const timeline = @import("startup/timeline.zig");
/// The OS's process creation time.
pub const process_start = @import("startup/process_start.zig");
/// `writeReport`, `persist` and the startup.json history.
pub const report = @import("startup/report.zig");
/// The startup benchmark's per-launch records and percentiles.
pub const bench = @import("startup/bench.zig");

/// See `timeline.Phase`.
pub const Phase = timeline.Phase;
/// See `timeline.StartupTimeline`.
pub const StartupTimeline = timeline.StartupTimeline;
/// See `timeline.Summary`.
pub const Summary = timeline.Summary;
/// See `timeline.StartupTimeline.global`.
pub const global = StartupTimeline.global;

/// Marks `p` on the process's timeline.
pub fn mark(p: Phase) void {
    StartupTimeline.global().mark(p);
}
/// `Lazy(T)`: init on first use.
pub const lazy = @import("startup/lazy.zig");
/// `InitRegistry`: services by phase.
pub const registry = @import("startup/registry.zig");
/// See `lazy.Lazy`.
pub const Lazy = lazy.Lazy;
/// See `registry.InitRegistry`.
pub const InitRegistry = registry.InitRegistry;
/// See `registry.InitPhase`.
pub const InitPhase = registry.InitPhase;
/// The critical-path allowlist.
pub const allowlist = @import("startup/allowlist.zig");
