//! zg_crash: local crash capture and reports (E17.F05).
//!
//! - `format`: the `.zgcrash` v1 writer (no allocation) and tolerant reader.
//! - `annotations`: lock-free key/value table snapshotted by the crash path.
//! - `store`: list, prune and "unseen" queries over `<state>/crashes`.
//! - `timefmt`: allocation-free UTC report names.
//! - `capture`: `install`, `handleSegfault` and the platform-independent
//!   report writer; `linux` and `windows` install the OS hooks.
//! - `pe`: PE CodeView (PDB 7.0) ids.
//!
//! App wiring:
//! ```zig
//! pub const std_options: std.Options = .{
//!     // std's Windows handler is a first-chance vectored handler; zg_crash replaces it.
//!     .enable_segfault_handler = builtin.os.tag != .windows,
//!     .signal_stack_size = 256 * 1024,
//!     ...
//! };
//! pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);
//! pub const debug = struct { pub const handleSegfault = zg_crash.handleSegfault; };
//! // first thing in main: zg_crash.install(.{ .crash_dir = ..., .state_dir = ... }) catch {};
//! ```

const std = @import("std");

/// `.zgcrash` v1 format.
pub const format = @import("format.zig");
/// Crash annotations.
pub const annotations = @import("annotations.zig");
/// Report store.
pub const store = @import("store.zig");
/// Report names and civil time.
pub const timefmt = @import("timefmt.zig");
/// Crash capture.
pub const capture = @import("capture.zig");
/// Linux crash-path primitives (maps, build ids, threads).
pub const linux = @import("linux.zig");
/// PE CodeView ids.
pub const pe = @import("pe.zig");
/// Default state and crash directories.
pub const paths = @import("paths.zig");

pub const Options = capture.Options;
pub const install = capture.install;
pub const handleSegfault = capture.handleSegfault;
pub const guardCurrentThread = capture.guardCurrentThread;

test {
    std.testing.refAllDecls(@This());
    _ = format;
    _ = annotations;
    _ = store;
    _ = timefmt;
    _ = capture;
    _ = linux;
    _ = paths;
    _ = pe;
    if (@import("builtin").os.tag == .windows) _ = @import("windows.zig");
    _ = @import("crash_test.zig");
}
