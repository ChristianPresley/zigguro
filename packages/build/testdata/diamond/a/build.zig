//! Diamond fixture: a -> b -> c and a -> c. Exercises the identical-args
//! invariant of zg_build (see build/test_build.zig).
const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const bm = b.dependency("diamond_b", f.args()).module("diamond_b");
    const cm = b.dependency("diamond_c", f.args()).module("diamond_c");
    _ = zg_build.addPackage(b, f, .{ .name = "diamond_a", .imports = &.{
        .{ .name = "diamond_b", .module = bm },
        .{ .name = "diamond_c", .module = cm },
    } });
}
