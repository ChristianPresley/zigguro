//! Startup timing (E14.F05): phase marks from process creation to the
//! first interactive frame, the startup report and its history.
//! docs/perf/startup.md says who marks what.

/// `StartupTimeline`, `Phase` and `Summary`.
pub const timeline = @import("startup/timeline.zig");
/// The OS's process creation time.
pub const process_start = @import("startup/process_start.zig");
/// `writeReport`, `persist` and the startup.json history.
pub const report = @import("startup/report.zig");

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
