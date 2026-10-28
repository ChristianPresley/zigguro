//! Runtime guardrails that keep the UI thread responsive (E14.F01.S02).

/// The per-thread shadow stack of open trace zones.
pub const shadow_stack = @import("runtime/shadow_stack.zig");
/// The UI stall watchdog.
pub const watchdog = @import("runtime/watchdog.zig");
/// The UI activity signal for background schedulers.
pub const activity = @import("runtime/activity.zig");

/// See `watchdog.StallWatchdog`.
pub const StallWatchdog = watchdog.StallWatchdog;
/// See `watchdog.StallReport`.
pub const StallReport = watchdog.StallReport;
/// See `activity.ActivitySignal`.
pub const ActivitySignal = activity.ActivitySignal;
/// See `shadow_stack.ShadowStack`.
pub const ShadowStack = shadow_stack.ShadowStack;
