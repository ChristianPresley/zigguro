const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const text = b.dependency("zg_text", f.args()).module("zg_text");
    const workspace = b.dependency("zg_workspace", f.args()).module("zg_workspace");
    const regex = b.dependency("zg_regex", f.args()).module("zg_regex");
    const ai_proto = b.dependency("zg_ai", f.args()).module("zg_ai_proto");
    // zg_frontmatter: the frontmatter parser and writer alone (std and
    // zg_core), for other packages' Markdown files with properties.
    const frontmatter = b.addModule("zg_frontmatter", .{
        .root_source_file = b.path("src/fm/root.zig"),
        .target = f.target,
        .imports = &.{.{ .name = "zg_core", .module = core }},
    });
    const mod = zg_build.addPackage(b, f, .{
        .name = "zg_notes",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_frontmatter", .module = frontmatter },
            .{ .name = "zg_text", .module = text },
            .{ .name = "zg_workspace", .module = workspace },
            .{ .name = "zg_regex", .module = regex },
        },
        .bench = "bench/main.zig",
    });

    // zg_notes_ui: the notes sidebar, properties editor, vault setup and
    // note search view over zg_gui, a module of its own so headless
    // consumers (zg, agents) never import a GUI package.
    const ui = b.addModule("zg_notes_ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = f.target,
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_notes", .module = mod },
            .{ .name = "zg_gui", .module = b.dependency("zg_gui", f.args()).module("zg_gui") },
            .{ .name = "zg_ai_proto", .module = ai_proto },
        },
    });
    ui.addImport("zg_options", zg_build.optionsModule(b, f));
    const ui_tests = b.addRunArtifact(b.addTest(.{ .name = "zg_notes_ui", .root_module = zg_build.testModule(b, f, ui) }));
    ui_tests.skip_foreign_checks = true;
    b.step("test-ui", "Run the zg_notes_ui tests").dependOn(&ui_tests.step);
    b.top_level_steps.get("test").?.step.dependOn(&ui_tests.step);

    // The search view's model is headless (no zg_gui): the bench drives
    // it directly (`notes/search_view`).
    const search_model = b.createModule(.{
        .root_source_file = b.path("src/ui/search_view_model.zig"),
        .target = f.target,
        .imports = &.{
            .{ .name = "zg_notes", .module = mod },
            .{ .name = "zg_ai_proto", .module = ai_proto },
        },
    });
    for (b.top_level_steps.get("bench").?.step.dependencies.items) |d| {
        const run = d.cast(std.Build.Step.Run) orelse continue;
        if (run.producer) |exe| exe.root_module.addImport("notes_search_model", search_model);
    }
}
