//! Memory tags for the app's subsystems (E14.F04.S01.T01): the allocator
//! each subsystem gets charges its `zg_perf.mem.MemTag`, so
//! `--mem-report` and the HUD show where memory goes instead of counting
//! it all as untracked.
//!
//! `main` turns tagging on for the process gpa. Off (tests, tools), `of`
//! returns the allocator unchanged: `zg_perf.mem.tracked` keeps one
//! wrapper per tag and its first child, and tests pass many allocators.

const std = @import("std");
const zg_perf = @import("zg_perf");

/// Set once by `main`, before any subsystem is created.
pub var enabled = false;

/// `child` charging `tag` when tagging is on, else `child` itself. Free
/// with the same allocator the memory came from.
pub fn of(child: std.mem.Allocator, tag: zg_perf.mem.MemTag) std.mem.Allocator {
    return if (enabled) zg_perf.mem.tracked(tag, child) else child;
}

test "of passes the allocator through when tagging is off" {
    const a = of(std.testing.allocator, .editor);
    try std.testing.expectEqual(std.testing.allocator.ptr, a.ptr);
}
