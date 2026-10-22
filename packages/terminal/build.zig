const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_terminal",
        .imports = &.{.{ .name = "zg_core", .module = core }},
        .bench = "bench/main.zig",
    });
}
