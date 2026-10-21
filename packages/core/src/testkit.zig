//! Shared test helpers: golden/snapshot files, line diffs and fuzzing
//! conventions (see `docs/testing.md`).

/// Golden (snapshot) file tests.
pub const golden = @import("testkit/golden.zig");
/// Myers line diff and unified output.
pub const diff = @import("testkit/diff.zig");
/// Fuzz-test helpers and corpus access.
pub const fuzz = @import("testkit/fuzz.zig");

test {
    _ = golden;
    _ = diff;
    _ = fuzz;
}
