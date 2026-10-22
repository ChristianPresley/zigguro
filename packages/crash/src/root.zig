//! zg_crash: local crash capture and reports (E17.F05).
//!
//! - `format`: the `.zgcrash` v1 writer (no allocation) and tolerant reader.
//! - `annotations`: lock-free key/value table snapshotted by the crash path.
//! - `store`: list, prune and "unseen" queries over `<state>/crashes`.
//! - `timefmt`: allocation-free UTC report names.

const std = @import("std");

/// `.zgcrash` v1 format.
pub const format = @import("format.zig");
/// Crash annotations.
pub const annotations = @import("annotations.zig");
/// Report store.
pub const store = @import("store.zig");
/// Report names and civil time.
pub const timefmt = @import("timefmt.zig");

test {
    std.testing.refAllDecls(@This());
    _ = format;
    _ = annotations;
    _ = store;
    _ = timefmt;
}
