//! OS trace bridges (E14.F02.S03.T01): ftrace markers on Linux and an ETW
//! TraceLogging provider on Windows.

/// The common bridge and its zone hook.
pub const os_trace = @import("os/os_trace.zig");
/// Linux `trace_marker` records.
pub const linux_trace_marker = @import("os/linux_trace_marker.zig");
/// The ETW provider.
pub const etw = @import("os/etw.zig");
/// TraceLogging metadata blobs.
pub const etw_metadata = @import("os/etw_metadata.zig");

/// See `os_trace.OsTrace`.
pub const OsTrace = os_trace.OsTrace;
/// See `os_trace.frame`.
pub const frame = os_trace.frame;
/// See `os_trace.enableForCurrentThread`.
pub const enableForCurrentThread = os_trace.enableForCurrentThread;
