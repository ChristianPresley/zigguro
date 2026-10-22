//! Root build: composes every package in `build/packages.zig` as a path
//! dependency, builds the `zigguro` GUI app and the `zg` headless CLI, and
//! defines the top-level steps every agent and CI uses.
//!
//! Rule: every `b.dependency()` call passes `f.args()` unchanged (see
//! `packages/build/build.zig` and `docs/build-options.md`).

const std = @import("std");
const zg_build = @import("zg_build");
const packages = @import("build/packages.zig");

/// Tier-1 cross targets built by `zig build cross`.
const cross_targets = [_][]const u8{
    "x86_64-linux",
    "aarch64-linux",
    "x86_64-windows",
    "aarch64-windows",
};

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);

    // Root-only options: never forwarded to b.dependency().
    const bench_quick = b.option(bool, "bench-quick", "Run benchmarks in quick mode") orelse false;
    const bench_filter = b.option([]const u8, "bench-filter", "Only run benchmarks whose name contains this");
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this");
    const new_name = b.option([]const u8, "name", "new-package: package name, e.g. zg_demo");
    const new_dir = b.option([]const u8, "dir", "new-package: directory under packages/, e.g. demo");
    const new_layer = b.option(u8, "layer", "new-package: layer number (see tools/pkgtool/layers.zon)");
    const zig_version = b.option([]const u8, "zig-version", "zig-pin: Zig release to pin") orelse "0.16.0";

    const test_filters: []const []const u8 = if (test_filter) |t| b.dupeStrings(&.{t}) else &.{};

    // Package modules for the host configuration.
    var mods: [packages.all.len]*std.Build.Module = undefined;
    var deps: [packages.all.len]*std.Build.Dependency = undefined;
    inline for (packages.all, 0..) |p, i| {
        deps[i] = b.dependency(p.name, f.args());
        mods[i] = deps[i].module(p.name);
    }
    const options = zg_build.optionsModule(b, f);

    // Apps.
    const zigguro_exe = addApp(b, "zigguro", f.target, f.optimize, &mods, options);
    const zg_exe = addApp(b, "zg", f.target, f.optimize, &mods, options);
    b.installArtifact(zigguro_exe);
    b.installArtifact(zg_exe);

    const run_zigguro = b.addRunArtifact(zigguro_exe);
    const run_zg = b.addRunArtifact(zg_exe);
    if (b.args) |a| {
        run_zigguro.addArgs(a);
        run_zg.addArgs(a);
    }
    b.step("run", "Run the zigguro app").dependOn(&run_zigguro.step);
    b.step("run-zg", "Run the zg headless CLI").dependOn(&run_zg.step);

    // Tests: `test` runs every package; `test-<short>` runs one.
    const test_step = b.step("test", "Run the tests of every package and tool");
    const fuzz_step = b.step("fuzz", "Run every test (use with --fuzz to fuzz `fuzz:` tests)");
    inline for (packages.all, 0..) |p, i| {
        const t = b.addTest(.{ .name = p.name, .root_module = zg_build.testModule(b, f, mods[i]), .filters = test_filters });
        const run = b.addRunArtifact(t);
        run.skip_foreign_checks = true;
        const one = b.step("test-" ++ comptime p.short(), "Run the " ++ p.name ++ " tests");
        one.dependOn(&run.step);
        test_step.dependOn(&run.step);
        fuzz_step.dependOn(&run.step);
    }

    // Repository tools (std-only Zig programs under tools/).
    const tools_test_step = b.step("test-tools", "Run the tests of tools/*");
    test_step.dependOn(tools_test_step);
    const pkgtool = addTool(b, "pkgtool", "tools/pkgtool/main.zig", test_filters, tools_test_step);
    const prlint = addTool(b, "prlint", "tools/prlint/main.zig", test_filters, tools_test_step);
    const fuzz_list = addTool(b, "fuzz-list", "tools/fuzz-list/main.zig", test_filters, tools_test_step);
    const zig_verify = addTool(b, "zig-verify", "tools/zig-verify/main.zig", test_filters, tools_test_step);

    const zig_pin = b.addRunArtifact(zig_verify);
    zig_pin.setCwd(b.path("."));
    zig_pin.addArgs(&.{ "pin", "--version", zig_version, "--out", ".github/zig-toolchain.txt" });
    zig_pin.has_side_effects = true;
    b.step("zig-pin", "Download, verify and pin the Zig toolchain (-Dzig-version=0.16.0)").dependOn(&zig_pin.step);

    // setup-zig.sh against a loopback fixture mirror (Linux; skipped elsewhere).
    const ci_opts = b.addOptions();
    ci_opts.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    const ci_test = b.addTest(.{
        .name = "test-ci-scripts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zig-verify/ci_scripts_test.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "ci_test_options", .module = ci_opts.createModule() }},
        }),
    });
    const ci_test_run = b.addRunArtifact(ci_test);
    ci_test_run.has_side_effects = true;
    b.step("test-ci-scripts", "Run setup-zig.sh against a fixture mirror (Linux)").dependOn(&ci_test_run.step);

    const check_layers = b.addRunArtifact(pkgtool);
    check_layers.addArgs(&.{ "check-layers", "--root" });
    check_layers.addDirectoryArg(b.path("."));
    check_layers.has_side_effects = true;
    b.step("check-layers", "Check the package graph against tools/pkgtool/layers.zon").dependOn(&check_layers.step);

    const new_pkg = b.addRunArtifact(pkgtool);
    new_pkg.addArgs(&.{ "new", "--root" });
    new_pkg.addDirectoryArg(b.path("."));
    new_pkg.addArgs(&.{ "--zig", b.graph.zig_exe });
    new_pkg.addArgs(&.{ "--name", new_name orelse "" });
    new_pkg.addArgs(&.{ "--dir", new_dir orelse "" });
    new_pkg.addArgs(&.{ "--layer", b.fmt("{d}", .{new_layer orelse 255}) });
    new_pkg.has_side_effects = true;
    b.step("new-package", "Scaffold a package: -Dname=zg_demo -Ddir=demo -Dlayer=4").dependOn(&new_pkg.step);

    const prlint_run = b.addRunArtifact(prlint);
    prlint_run.addArgs(&.{"--root"});
    prlint_run.addDirectoryArg(b.path("."));
    if (b.args) |a| prlint_run.addArgs(a);
    prlint_run.has_side_effects = true;
    b.step("prlint", "Lint branch, PR title, commits and docs (args after --)").dependOn(&prlint_run.step);

    const fuzz_list_run = b.addRunArtifact(fuzz_list);
    fuzz_list_run.addArgs(&.{"--root"});
    fuzz_list_run.addDirectoryArg(b.path("."));
    fuzz_list_run.has_side_effects = true;
    b.step("fuzz-list", "Print every `fuzz:` test target as JSON").dependOn(&fuzz_list_run.step);

    // Build-graph self test: spawns `zig build` (guarded by -Dslow-tests).
    const test_build_opts = b.addOptions();
    test_build_opts.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    test_build_opts.addOption([]const u8, "repo_root", b.pathFromRoot("."));
    test_build_opts.addOption(bool, "slow_tests", f.slow_tests);
    const test_build = b.addTest(.{
        .name = "test-build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/test_build.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "test_build_options", .module = test_build_opts.createModule() }},
        }),
    });
    const test_build_run = b.addRunArtifact(test_build);
    test_build_run.has_side_effects = true;
    b.step("test-build", "Self-test the build graph (spawns zig build)").dependOn(&test_build_run.step);

    // Benchmarks: each package's `<name>-bench` writes zig-out/bench-results/<name>.json.
    const bench_step = b.step("bench", "Run every package benchmark (-Dbench-quick, -Dbench-filter)");
    inline for (packages.all, 0..) |p, i| {
        if (p.has_bench) {
            const run = b.addRunArtifact(deps[i].artifact(p.name ++ "-bench"));
            run.has_side_effects = true;
            run.addArgs(&.{ "--package", p.name });
            if (bench_quick) run.addArg("--quick");
            if (bench_filter) |flt| run.addArgs(&.{ "--filter", flt });
            run.addArg("--out");
            const out = run.addOutputFileArg(p.name ++ ".json");
            const install = b.addInstallFileWithDir(out, .prefix, "bench-results/" ++ p.name ++ ".json");
            bench_step.dependOn(&install.step);
        }
    }

    // Formatting.
    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "build", "packages", "apps", "tools" }, .check = true });
    b.step("fmt-check", "Fail if any file is not zig fmt clean").dependOn(&fmt.step);

    // Cross compilation of both apps for the tier-1 targets (ReleaseFast).
    const cross_step = b.step("cross", "Build both apps for every tier-1 target into zig-out/cross/<triple>/");
    for (cross_targets) |triple| {
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable);
        var a = f.args();
        a.target = target;
        a.optimize = .ReleaseFast;
        var cmods: [packages.all.len]*std.Build.Module = undefined;
        inline for (packages.all, 0..) |p, i| cmods[i] = b.dependency(p.name, a).module(p.name);
        inline for (.{ "zigguro", "zg" }) |app| {
            const exe = addApp(b, app, target, .ReleaseFast, &cmods, options);
            const install = b.addInstallArtifact(exe, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("cross/{s}", .{triple}) } },
                .pdb_dir = .disabled,
            });
            cross_step.dependOn(&install.step);
        }
    }

    // Autodocs for the E00 runtime packages.
    const docs_step = b.step("docs", "Emit autodocs into zig-out/docs/<package>");
    inline for (packages.all, 0..) |p, i| {
        const lib = b.addLibrary(.{ .name = p.name, .root_module = mods[i] });
        const install = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs/" ++ p.name,
        });
        docs_step.dependOn(&install.step);
    }
}

fn addApp(
    b: *std.Build,
    comptime name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mods: []const *std.Build.Module,
    options: *std.Build.Module,
) *std.Build.Step.Compile {
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.append(b.allocator, .{ .name = "zg_options", .module = options }) catch @panic("OOM");
    inline for (packages.all, 0..) |p, i| imports.append(b.allocator, .{ .name = p.name, .module = mods[i] }) catch @panic("OOM");
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/" ++ name ++ "/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports.items,
        }),
    });
}

fn addTool(
    b: *std.Build,
    comptime name: []const u8,
    comptime root: []const u8,
    filters: []const []const u8,
    tests_step: *std.Build.Step,
) *std.Build.Step.Compile {
    // Tools see the package table and the zg_build API (for comptime checks).
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zg_packages", .module = b.createModule(.{ .root_source_file = b.path("build/packages.zig") }) },
            .{ .name = "zg_build_api", .module = b.createModule(.{ .root_source_file = b.path("packages/build/build.zig") }) },
        },
    });
    const t = b.addTest(.{ .name = name, .root_module = mod, .filters = filters });
    tests_step.dependOn(&b.addRunArtifact(t).step);
    return b.addExecutable(.{ .name = name, .root_module = mod });
}
