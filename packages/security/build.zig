const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const mod = zg_build.addPackage(b, f, .{
        .name = "zg_security",
        .imports = &.{.{ .name = "zg_core", .module = core }},
        .bench = "bench/main.zig",
    });

    // zg_security_ui: approval and workspace-trust dialogs over zg_gui, a
    // module of its own so headless consumers never import a GUI package.
    const ui = b.addModule("zg_security_ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = f.target,
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_security", .module = mod },
            .{ .name = "zg_gui", .module = b.dependency("zg_gui", f.args()).module("zg_gui") },
        },
    });
    ui.addImport("zg_options", zg_build.optionsModule(b, f));
    const ui_tests = b.addRunArtifact(b.addTest(.{ .name = "zg_security_ui", .root_module = zg_build.testModule(b, f, ui) }));
    ui_tests.skip_foreign_checks = true;
    b.step("test-ui", "Run the zg_security_ui tests").dependOn(&ui_tests.step);
    b.top_level_steps.get("test").?.step.dependOn(&ui_tests.step);
}
