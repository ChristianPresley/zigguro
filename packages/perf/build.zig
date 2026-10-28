const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    // The budget registry sits outside src/ (E14.F01.S01.T01); the typed
    // `@import("budgets.zon")` in src/budget/registry.zig resolves here.
    const budgets_zon = b.createModule(.{ .root_source_file = b.path("budgets.zon") });
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_perf",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "budgets.zon", .module = budgets_zon },
        },
        .bench = "bench/main.zig",
    });
}
