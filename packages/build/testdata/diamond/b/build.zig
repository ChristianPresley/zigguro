const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const c = b.dependency("diamond_c", f.args()).module("diamond_c");
    _ = zg_build.addPackage(b, f, .{ .name = "diamond_b", .imports = &.{.{ .name = "diamond_c", .module = c }} });
}
