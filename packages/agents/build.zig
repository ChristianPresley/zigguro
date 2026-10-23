const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const ai_dep = b.dependency("zg_ai", f.args());
    const jsonrpc = b.dependency("zg_jsonrpc", f.args()).module("zg_jsonrpc");
    const platform = b.dependency("zg_platform", f.args()).module("zg_platform");
    const text = b.dependency("zg_text", f.args()).module("zg_text");
    // Task files reuse the notes frontmatter parser and writer (E13.F03).
    const frontmatter = b.dependency("zg_notes", f.args()).module("zg_frontmatter");
    const mod = zg_build.addPackage(b, f, .{
        .name = "zg_agents",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_ai", .module = ai_dep.module("zg_ai") },
            .{ .name = "zg_ai_proto", .module = ai_dep.module("zg_ai_proto") },
            .{ .name = "zg_jsonrpc", .module = jsonrpc },
            .{ .name = "zg_platform", .module = platform },
            .{ .name = "zg_text", .module = text },
            .{ .name = "zg_frontmatter", .module = frontmatter },
        },
        .bench = "bench/main.zig",
    });

    // zg_agents_ui: Mission Control over zg_gui, a module of its own so
    // headless consumers (zg, the agent host) never import a GUI package.
    const ui = b.addModule("zg_agents_ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = f.target,
        .imports = &.{
            .{ .name = "zg_agents", .module = mod },
            .{ .name = "zg_gui", .module = b.dependency("zg_gui", f.args()).module("zg_gui") },
            .{ .name = "zg_ai_proto", .module = ai_dep.module("zg_ai_proto") },
        },
    });
    ui.addImport("zg_options", zg_build.optionsModule(b, f));
    const ui_tests = b.addRunArtifact(b.addTest(.{ .name = "zg_agents_ui", .root_module = zg_build.testModule(b, f, ui) }));
    ui_tests.skip_foreign_checks = true;
    b.step("test-ui", "Run the zg_agents_ui tests").dependOn(&ui_tests.step);
    b.top_level_steps.get("test").?.step.dependOn(&ui_tests.step);
}
