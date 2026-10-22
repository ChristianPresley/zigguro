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
    const conformance_strict = b.option(bool, "terminal_conformance_strict", "Fail when a terminal conformance category is under its minimum") orelse false;
    inline for (packages.all, 0..) |p, i| {
        deps[i] = if (comptime std.mem.eql(u8, p.name, "zg_terminal"))
            b.dependency(p.name, argsWith(f, .{ .terminal_conformance_strict = conformance_strict }))
        else
            b.dependency(p.name, f.args());
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
        const tm = zg_build.testModule(b, f, mods[i]);
        zg_build.addTestExes(b, deps[i], p.name, tm);
        const t = b.addTest(.{ .name = p.name, .root_module = tm, .filters = test_filters });
        const run = b.addRunArtifact(t);
        run.skip_foreign_checks = true;
        const one = b.step("test-" ++ comptime p.short(), "Run the " ++ p.name ++ " tests");
        one.dependOn(&run.step);
        test_step.dependOn(&run.step);
        fuzz_step.dependOn(&run.step);
        if (comptime std.mem.eql(u8, p.name, "zg_platform")) {
            // The Wayland decoder fuzz test alone (`zig build fuzz-wl --fuzz`).
            const wl_fuzz = b.addTest(.{ .name = "fuzz-wl", .root_module = zg_build.testModule(b, f, mods[i]), .filters = &.{"fuzz: wayland"} });
            b.step("fuzz-wl", "Run the Wayland decoder fuzz test (use with --fuzz)").dependOn(&b.addRunArtifact(wl_fuzz).step);
        }
        if (comptime std.mem.eql(u8, p.name, "zg_vulkan")) {
            // The golden scene corpus alone (E02.F07.S02.T02).
            const golden = b.addTest(.{ .name = "test-golden", .root_module = zg_build.testModule(b, f, mods[i]), .filters = &.{"scene:"} });
            b.step("test-golden", "Render the zg_vulkan scene corpus against its golden images").dependOn(&b.addRunArtifact(golden).step);
            // The system Vulkan loader needs libc (ADR-E02-001), so the GPU
            // tests get their own libc-linked binary (E02.F01.S02.T01).
            const gpu_mod = zg_build.testModule(b, f, mods[i]);
            gpu_mod.link_libc = true;
            const gpu = b.addTest(.{ .name = "test-vulkan-gpu", .root_module = gpu_mod, .filters = &.{"gpu:"} });
            b.step("test-vulkan-gpu", "Run the zg_vulkan tests that need a Vulkan loader (skipped without one)").dependOn(&b.addRunArtifact(gpu).step);
            // Every generated binding on the three tier-1 64-bit targets.
            const check_vk = b.step("check-vk-gen", "Compile all of the generated vk.zig for x86_64-windows, x86_64-linux-gnu and aarch64-linux-gnu");
            for ([_][]const u8{ "x86_64-windows", "x86_64-linux-gnu", "aarch64-linux-gnu" }) |triple| {
                const target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable);
                const vt = b.addTest(.{ .name = b.fmt("check-vk-{s}", .{triple}), .root_module = b.createModule(.{
                    .root_source_file = b.path("packages/vulkan/src/vk/check.zig"),
                    .target = target,
                    .optimize = .Debug,
                }) });
                check_vk.dependOn(&vt.step);
            }
            test_step.dependOn(check_vk);
        }
        // zg_ai also exports the zg_ai_proto leaf module, tested with it.
        if (comptime std.mem.eql(u8, p.name, "zg_ai")) {
            const pt = b.addTest(.{ .name = "zg_ai_proto", .root_module = zg_build.testModule(b, f, deps[i].module("zg_ai_proto")), .filters = test_filters });
            const prun = b.addRunArtifact(pt);
            prun.skip_foreign_checks = true;
            one.dependOn(&prun.step);
            test_step.dependOn(&prun.step);
            fuzz_step.dependOn(&prun.step);
        }
    }
    // zg_mcp's stdio tests spawn a fixture server, so they are a separate
    // test binary defined by the package's build.zig.
    {
        const mcp = comptime packages.indexOf("zg_mcp");
        const stdio = @import("zg_mcp").addStdioTests(b, f, mods[mcp], mods[comptime packages.indexOf("zg_core")], "packages/mcp/");
        const run = b.addRunArtifact(stdio);
        run.skip_foreign_checks = true;
        b.top_level_steps.get("test-mcp").?.step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    // `zg agent` end to end: spawns the built zg (E10.F10.S01.T02).
    {
        const fx = b.addOptions();
        fx.addOptionPath("zg", zg_exe.getEmittedBin());
        fx.addOptionPath("cassette", b.path("apps/zg/testdata/cassettes/two_turns.jsonl"));
        const e2e = b.addTest(.{ .name = "zg-agent-e2e", .root_module = b.createModule(.{
            .root_source_file = b.path("apps/zg/test/agent_e2e_test.zig"),
            .target = f.target,
            .optimize = f.optimize,
            .imports = &.{.{ .name = "zg_e2e", .module = fx.createModule() }},
        }), .filters = test_filters });
        const run = b.addRunArtifact(e2e);
        run.skip_foreign_checks = true;
        b.step("test-zg", "Run the zg CLI end-to-end tests").dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    // INV-01: every consumer against a deny-all engine (E16.F02.S01.T04).
    inline for (packages.all, 0..) |p, i| {
        if (comptime std.mem.eql(u8, p.name, "zg_security")) {
            const t = b.addTest(.{ .name = "enforcement", .root_module = zg_build.testModule(b, f, mods[i]), .filters = &.{"INV-01 enforcement"} });
            b.step("test-enforcement", "Prove every consumer denies under a deny-all engine (INV-01)").dependOn(&b.addRunArtifact(t).step);
        }
    }

    // Repository tools (std-only Zig programs under tools/).
    const tools_test_step = b.step("test-tools", "Run the tests of tools/*");
    test_step.dependOn(tools_test_step);
    const pkgtool = addTool(b, "pkgtool", "tools/pkgtool/main.zig", test_filters, f.optimize, tools_test_step);
    const prlint = addTool(b, "prlint", "tools/prlint/main.zig", test_filters, f.optimize, tools_test_step);
    const fuzz_list = addTool(b, "fuzz-list", "tools/fuzz-list/main.zig", test_filters, f.optimize, tools_test_step);
    const zig_verify = addTool(b, "zig-verify", "tools/zig-verify/main.zig", test_filters, f.optimize, tools_test_step);
    _ = addTool(b, "wayland-scanner", "packages/build/wayland_scanner/main.zig", test_filters, f.optimize, tools_test_step);
    const keysym_gen = addTool(b, "keysym-gen", "tools/keysym_gen/main.zig", test_filters, f.optimize, tools_test_step);
    const lspgen = addTool(b, "lspgen", "tools/lspgen/main.zig", test_filters, f.optimize, tools_test_step);
    const dapgen = addTool(b, "dapgen", "tools/dapgen/main.zig", test_filters, f.optimize, tools_test_step);
    const vkgen = addTool(b, "vkgen", "tools/vkgen/main.zig", test_filters, f.optimize, tools_test_step);
    // zg-transcript shares its core with zg_lsp (a std-only file).
    const transcript = addToolImports(b, "zg-transcript", "tools/transcript/main.zig", test_filters, f.optimize, tools_test_step, &.{
        .{ .name = "zg_transcript", .module = b.createModule(.{ .root_source_file = b.path("packages/lsp/src/client/transcript.zig") }) },
    });
    // zg-release (E17) links zg_release built for the host.
    var host_args = f.args();
    host_args.target = b.graph.host;
    const release_host = b.dependency("zg_release", host_args).module("zg_release");
    const release_tool = addToolImports(b, "zg-release", "tools/release/src/main.zig", test_filters, f.optimize, tools_test_step, &.{
        .{ .name = "zg_release", .module = release_host },
    });
    b.installArtifact(release_tool);
    const release_run = b.addRunArtifact(release_tool);
    if (b.args) |a| release_run.addArgs(a);
    release_run.has_side_effects = true;
    b.step("release-tool", "Run tools/release (zg-release <command> ...; args after --)").dependOn(&release_run.step);

    // Third-party data notices are checked by `zig build test`.
    const notices_check = b.addRunArtifact(release_tool);
    notices_check.setCwd(b.path("."));
    notices_check.addArgs(&.{ "notices", "--check", "true" });
    notices_check.has_side_effects = true;
    const notices_check_step = b.step("notices-check", "Fail if a third-party data file has no packaging/notices entry");
    notices_check_step.dependOn(&notices_check.step);
    test_step.dependOn(notices_check_step);

    // `zig build package -Dtarget=<t> -Doptimize=ReleaseFast -Dversion=<v>
    // -Dsource-date-epoch=<s>`: dist tree in zig-out/dist/<t>, archives in
    // zig-out/release.
    const dist_target = b.fmt("{s}-{s}", .{ @tagName(f.target.result.cpu.arch), @tagName(f.target.result.os.tag) });
    const dist_dir = b.fmt("dist/{s}", .{dist_target});
    const package_step = b.step("package", "Build zig-out/dist/<t> and package it into zig-out/release (E17)");
    const package_run = b.addRunArtifact(release_tool);
    package_run.has_side_effects = true;
    package_run.setCwd(b.path("."));
    package_run.addArgs(&.{ "package", "--target", dist_target, "--version", zg_build.versionWithMetadata(b, f), "--epoch", b.fmt("{d}", .{f.source_date_epoch}), "--channel", @tagName(f.channel), "--commit", f.commit, "--release-target", zg_build.releaseTarget(b, f.target.result) });
    package_run.addArg("--dist");
    package_run.addArg(b.getInstallPath(.prefix, dist_dir));
    package_run.addArg("--out");
    package_run.addArg(b.getInstallPath(.prefix, "release"));
    if (f.target.result.os.tag == .windows) package_run.addArgs(&.{ "--portable", "true" });
    inline for (.{ zigguro_exe, zg_exe }) |exe| {
        const inst = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = dist_dir } }, .pdb_dir = .disabled });
        package_run.step.dependOn(&inst.step);
    }
    package_step.dependOn(&package_run.step);

    const transcript_run = b.addRunArtifact(transcript);
    if (b.args) |args| transcript_run.addArgs(args);
    b.step("zg-transcript", "Run zg-transcript (pass arguments after --)").dependOn(&transcript_run.step);

    // Generated protocol bindings: `zig build lspgen` / `dapgen` regenerate
    // the checked-in files; `zig build test` fails when one is stale.
    const check_gen_step = b.step("check-gen", "Fail if a generated protocol file is out of date");
    test_step.dependOn(check_gen_step);
    const generators = .{
        .{ lspgen, "lspgen", "tools/lspgen/data/metaModel-3.18.json", "packages/lsp/src/gen/protocol.zig" },
        .{ dapgen, "dapgen", "tools/dapgen/data/debugAdapterProtocol.json", "packages/dap/src/gen/protocol.zig" },
        .{ vkgen, "vkgen", "tools/vkgen/data/vk.xml", "packages/vulkan/src/vk/vk.zig" },
    };
    inline for (generators) |g| {
        inline for (.{ false, true }) |check| {
            const run = b.addRunArtifact(g[0]);
            run.addFileArg(b.path(g[2]));
            run.addArg(b.pathFromRoot(g[3]));
            run.has_side_effects = true;
            if (check) {
                run.addArg("--check");
                check_gen_step.dependOn(&run.step);
            } else {
                b.step(g[1], "Regenerate " ++ g[3]).dependOn(&run.step);
            }
        }
    }
    // The vkgen golden for its mini registry (checked by `test-tools`).
    const vkgen_mini = b.addRunArtifact(vkgen);
    vkgen_mini.addFileArg(b.path("tools/vkgen/testdata/mini.xml"));
    vkgen_mini.addArg(b.pathFromRoot("tools/vkgen/testdata/golden/mini_vk.zig"));
    vkgen_mini.addArgs(&.{ "--max-version", "1.1", "--extensions", "VK_KHR_mini", "--no-helpers" });
    vkgen_mini.has_side_effects = true;
    b.step("vkgen-mini", "Regenerate tools/vkgen/testdata/golden/mini_vk.zig").dependOn(&vkgen_mini.step);

    const supply_chain = addTool(b, "check-supply-chain", "tools/check-supply-chain/main.zig", test_filters, f.optimize, tools_test_step);

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

    const supply_chain_run = b.addRunArtifact(supply_chain);
    supply_chain_run.addArgs(&.{"--root"});
    supply_chain_run.addDirectoryArg(b.path("."));
    supply_chain_run.has_side_effects = true;
    b.step("check-supply-chain", "Fail on any third-party code: URL deps, @cImport, libc, C sources (E16.F01.S02.T01)").dependOn(&supply_chain_run.step);

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

    const keysym_gen_run = b.addRunArtifact(keysym_gen);
    keysym_gen_run.addArgs(&.{"--root"});
    keysym_gen_run.addDirectoryArg(b.path("."));
    if (b.args) |a| keysym_gen_run.addArgs(a);
    keysym_gen_run.has_side_effects = true;
    b.step("keysym-gen", "Regenerate the XKB keysym tables (-- --check to verify)").dependOn(&keysym_gen_run.step);

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

    // Generated terminal reference tables (packages/terminal/docs/).
    inline for (packages.all, 0..) |p, i| {
        if (comptime std.mem.eql(u8, p.name, "zg_terminal")) {
            const gen = b.addRunArtifact(deps[i].artifact("zg_terminal-docs"));
            gen.addArg(b.pathFromRoot("packages/terminal/docs"));
            b.step("docs-terminal-modes", "Regenerate packages/terminal/docs/{modes,xtgettcap}.md").dependOn(&gen.step);
            const conf = b.addTest(.{ .name = "zg_terminal-conformance", .root_module = zg_build.testModule(b, f, mods[i]), .filters = &.{"conformance"} });
            const run_conf = b.addRunArtifact(conf);
            run_conf.skip_foreign_checks = true;
            b.step("test-terminal-conformance", "Run the terminal .vtt conformance corpus").dependOn(&run_conf.step);
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
    // Crash reports (E17.F05) need frame pointers and a GNU build id, and
    // the self-hosted aarch64 backend traps before the segfault hook runs.
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/" ++ name ++ "/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports.items,
            .omit_frame_pointer = false,
        }),
        .use_llvm = if (target.result.cpu.arch == .aarch64) true else null,
    });
    if (target.result.ofmt == .elf) exe.build_id = .sha1;
    return exe;
}

fn addTool(
    b: *std.Build,
    comptime name: []const u8,
    comptime root: []const u8,
    filters: []const []const u8,
    test_optimize: std.builtin.OptimizeMode,
    tests_step: *std.Build.Step,
) *std.Build.Step.Compile {
    return addToolImports(b, name, root, filters, test_optimize, tests_step, &.{});
}

/// `addTool` with extra module imports for the tool and its tests.
fn addToolImports(
    b: *std.Build,
    comptime name: []const u8,
    comptime root: []const u8,
    filters: []const []const u8,
    test_optimize: std.builtin.OptimizeMode,
    tests_step: *std.Build.Step,
    extra: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    // Tests follow -Doptimize (the 0.16.0 test runner does not compile
    // under Debug --fuzz); the tool binaries stay Debug.
    const t = b.addTest(.{ .name = name, .root_module = toolModule(b, root, test_optimize, extra), .filters = filters });
    tests_step.dependOn(&b.addRunArtifact(t).step);
    return b.addExecutable(.{ .name = name, .root_module = toolModule(b, root, .Debug, extra) });
}

/// Tools see the package table and the zg_build API (for comptime checks).
fn toolModule(b: *std.Build, comptime root: []const u8, optimize: std.builtin.OptimizeMode, extra: []const std.Build.Module.Import) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zg_packages", .module = b.createModule(.{ .root_source_file = b.path("build/packages.zig") }) },
            .{ .name = "zg_build_api", .module = b.createModule(.{ .root_source_file = b.path("packages/build/build.zig") }) },
        },
    });
    for (extra) |i| mod.addImport(i.name, i.module);
    return mod;
}

/// `f.args()` plus the fields of `extra`, for a package with its own options.
fn argsWith(f: zg_build.Flags, extra: anytype) ArgsWith(@TypeOf(extra)) {
    var out: ArgsWith(@TypeOf(extra)) = undefined;
    const base = f.args();
    inline for (@typeInfo(@TypeOf(base)).@"struct".fields) |fl| @field(out, fl.name) = @field(base, fl.name);
    inline for (@typeInfo(@TypeOf(extra)).@"struct".fields) |fl| @field(out, fl.name) = @field(extra, fl.name);
    return out;
}

fn ArgsWith(comptime E: type) type {
    const a = @typeInfo(zg_build.Args).@"struct".fields;
    const e = @typeInfo(E).@"struct".fields;
    var names: [a.len + e.len][]const u8 = undefined;
    var types: [a.len + e.len]type = undefined;
    for (a, 0..) |fl, i| {
        names[i] = fl.name;
        types[i] = fl.type;
    }
    for (e, a.len..) |fl, i| {
        names[i] = fl.name;
        types[i] = fl.type;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}
