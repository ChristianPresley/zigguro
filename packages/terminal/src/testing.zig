//! Test support shared by the package's tests, fuzzers and downstream
//! packages: the `.vtt` conformance format and runner, exact screen dumps
//! and whole-terminal invariants.

/// The `.vtt` script format.
pub const vtt = @import("testing/vtt.zig");
/// Runs `.vtt` cases against a headless terminal.
pub const runner = @import("testing/runner.zig");
/// Exact-width screen and scrollback dumps.
pub const dump = @import("testing/dump.zig");
/// Whole-terminal invariants.
pub const invariants = @import("testing/invariants.zig");

test {
    _ = @import("testing/conformance_test.zig");
}
