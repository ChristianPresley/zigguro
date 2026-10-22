//! zg_core: allocators, containers, runtime, logging, tracing, time, UTF-8
//! helpers, the bench harness and the test kit. Depends only on `std`.

const std = @import("std");

/// Build options forwarded by zg_build (`-Dtracing`, `-Dgpa`, ...).
pub const options = @import("zg_options");
pub const alloc = @import("alloc.zig");
pub const containers = @import("containers.zig");
pub const time = @import("time.zig");
pub const trace = @import("trace.zig");
pub const runtime = @import("runtime.zig");
pub const log = @import("log.zig");
pub const report = @import("report.zig");
pub const utf8 = @import("utf8.zig");
pub const bench = @import("bench.zig");
pub const testkit = @import("testkit.zig");
/// Line-start table of a text snapshot.
pub const LineIndex = @import("line_index.zig").LineIndex;
/// The process runtime (see `runtime`).
pub const Runtime = runtime.Runtime;

test {
    std.testing.refAllDecls(@This());
}
