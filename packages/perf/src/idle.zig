//! Idle discipline (E14.F05.S02): wakeup attribution, CPU time and the
//! idle monitor. docs/perf/threading.md lists the wake call sites.

/// `noteWake`, `WakeReason` and per-thread wake snapshots.
pub const wake_count = @import("idle/wake_count.zig");
/// Process and thread CPU time.
pub const cpu_time = @import("idle/cpu_time.zig");
/// `IdleMonitor`: wakeups per second and CPU percent while observed.
pub const monitor = @import("idle/monitor.zig");

/// See `wake_count.WakeReason`.
pub const WakeReason = wake_count.WakeReason;
/// See `wake_count.noteWake`.
pub const noteWake = wake_count.noteWake;
/// See `wake_count.wakeSnapshot`.
pub const wakeSnapshot = wake_count.wakeSnapshot;
/// See `cpu_time.processCpuTimes`.
pub const processCpuTimes = cpu_time.processCpuTimes;
/// See `cpu_time.threadCpuTimes`.
pub const threadCpuTimes = cpu_time.threadCpuTimes;
/// See `monitor.IdleMonitor`.
pub const IdleMonitor = monitor.IdleMonitor;
