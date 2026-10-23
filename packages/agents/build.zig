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
    // regex_match in data queries (E13.F06.S02.T03).
    const regex = b.dependency("zg_regex", f.args()).module("zg_regex");
    // zg_diagram: diagrams from text (E13.F07.S02), std and zg_core only;
    // zg_agents draws its diagrams.
    const diagram = b.addModule("zg_diagram", .{
        .root_source_file = b.path("diagram/root.zig"),
        .target = f.target,
        .imports = &.{.{ .name = "zg_core", .module = core }},
    });
    diagram.addImport("zg_options", zg_build.optionsModule(b, f));
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
            .{ .name = "zg_regex", .module = regex },
            .{ .name = "zg_diagram", .module = diagram },
        },
        .bench = "bench/main.zig",
    });

    const diagram_tests = b.addRunArtifact(b.addTest(.{ .name = "zg_diagram", .root_module = zg_build.testModule(b, f, diagram) }));
    b.step("test-diagram", "Run the zg_diagram tests").dependOn(&diagram_tests.step);
    b.top_level_steps.get("test").?.step.dependOn(&diagram_tests.step);

    const programs = addProgramTests(b, f, mod, ai_dep.module("zg_ai"), "");
    const programs_run = b.addRunArtifact(programs);
    programs_run.skip_foreign_checks = true;
    b.top_level_steps.get("test").?.step.dependOn(&programs_run.step);

    // zg_agents_ui: Mission Control over zg_gui, a module of its own so
    // headless consumers (zg, the agent host) never import a GUI package.
    const gui = b.dependency("zg_gui", f.args()).module("zg_gui");
    const ui = b.addModule("zg_agents_ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = f.target,
        .imports = &.{
            .{ .name = "zg_agents", .module = mod },
            .{ .name = "zg_gui", .module = gui },
            .{ .name = "zg_ai_proto", .module = ai_dep.module("zg_ai_proto") },
            .{ .name = "zg_diagram", .module = diagram },
        },
    });
    ui.addImport("zg_options", zg_build.optionsModule(b, f));
    // The data grid's scroll bench drives the UI module headlessly.
    const bench_mod = zg_build.benchModule(b, "zg_agents").?;
    bench_mod.addImport("zg_agents_ui", ui);
    bench_mod.addImport("zg_gui", gui);
    bench_mod.addImport("zg_diagram", diagram);
    const ui_tests = b.addRunArtifact(b.addTest(.{ .name = "zg_agents_ui", .root_module = zg_build.testModule(b, f, ui) }));
    ui_tests.skip_foreign_checks = true;
    b.step("test-ui", "Run the zg_agents_ui tests").dependOn(&ui_tests.step);
    b.top_level_steps.get("test").?.step.dependOn(&ui_tests.step);
}

/// data_run_program's process tests (E13.F06.S02.T02): a separate test
/// binary because it needs the fixture program's path. The root build
/// calls this too (with `prefix` = "packages/agents/").
pub fn addProgramTests(b: *std.Build, f: zg_build.Flags, agents: *std.Build.Module, ai: *std.Build.Module, prefix: []const u8) *std.Build.Step.Compile {
    const program = b.addExecutable(.{
        .name = "zg-data-program",
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}test/fixtures/data_program.zig", .{prefix})),
            .target = f.target,
            .optimize = f.optimize,
        }),
    });
    const fixtures = b.addOptions();
    fixtures.addOptionPath("program", program.getEmittedBin());
    return b.addTest(.{
        .name = "zg_agents-programs",
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}test/program_test.zig", .{prefix})),
            .target = f.target,
            .optimize = f.optimize,
            .imports = &.{
                .{ .name = "zg_agents", .module = agents },
                .{ .name = "zg_ai", .module = ai },
                .{ .name = "agents_fixtures", .module = fixtures.createModule() },
            },
        }),
    });
}
