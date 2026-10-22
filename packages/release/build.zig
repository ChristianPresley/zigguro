const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    // packaging/product.zon is the single source of the product constants.
    const product_zon = b.createModule(.{ .root_source_file = b.path("../../packaging/product.zon") });
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_release",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_product_zon", .module = product_zon },
        },
        .bench = "bench/main.zig",
    });
}
