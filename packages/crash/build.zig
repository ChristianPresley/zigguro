const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const release = b.dependency("zg_release", f.args()).module("zg_release");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_crash",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_release", .module = release },
        },
        .bench = "bench/main.zig",
    });
}
