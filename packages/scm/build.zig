const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    // The git bridge (src/gitbridge) works on git repositories through zg_git.
    const git = b.dependency("zg_git", f.args()).module("zg_git");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_scm",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_git", .module = git },
        },
        .bench = "bench/main.zig",
        .test_exes = &.{
            .{ .name = "store_writer", .root = "test/store_writer.zig" },
        },
    });
}
