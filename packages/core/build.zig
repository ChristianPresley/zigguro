const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    _ = zg_build.addPackage(b, f, .{ .name = "zg_core", .bench = "bench/main.zig" });
}
