//! zg_build: the build-time-only helper every zigguro `build.zig` imports.
//!
//! Usage from any package or the root:
//!
//! ```zig
//! const zg_build = @import("zg_build");
//! pub fn build(b: *std.Build) void {
//!     const f = zg_build.flags(b); // exactly once per build.zig
//!     const core = b.dependency("zg_core", f.args()).module("zg_core");
//!     _ = zg_build.addPackage(b, f, .{ .name = "zg_net", .imports = &.{.{ .name = "zg_core", .module = core }} });
//! }
//! ```
//!
//! The identical-args invariant: every `b.dependency()` call in the graph must
//! pass `f.args()` unchanged. When a diamond (root -> core, root -> jsonrpc ->
//! core) passes different args, Zig 0.16 instantiates the package twice and the
//! compile fails with "file exists in modules 'zg_core' and 'zg_core0'".
//! Because every package calls `flags()`, every forwarded option is declared in
//! every builder, so the tuple always maps onto valid `-D` options.
//!
//! This file contains no runtime code and is never linked into a binary.

const std = @import("std");

/// Tracing level for `zg_core.trace` (`-Dtracing`).
pub const Tracing = enum { off, zones, full };

/// General-purpose allocator selection (`-Dgpa`). `.auto` picks
/// `std.heap.DebugAllocator` in Debug/ReleaseSafe and `smp_allocator` otherwise.
pub const GpaKind = enum { auto, debug, smp };

/// Release channel (`-Dchannel`, E17). Mirrors `zg_release.Channel`.
pub const Channel = enum { dev, insiders, rc, stable };

/// Update mode baked into the binary (`-Dupdate-mode`, E17). Mirrors
/// `zg_release.UpdateMode`.
pub const UpdateMode = enum { managed_or_notify, notify_only, disabled };

/// The resolved shared flag set of one builder.
pub const Flags = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tracing: Tracing = .off,
    /// Build the Wayland backend on Linux (E01).
    wayland: bool = true,
    /// Build the X11 backend on Linux (E01).
    x11: bool = true,
    /// Enable Vulkan validation layers when present (E02).
    vk_validation: bool = false,
    /// Debug assertions that blocking helpers never run on the UI thread.
    assert_ui_thread: bool,
    gpa: GpaKind = .auto,
    version: []const u8 = default_version,
    /// Rewrite golden files instead of comparing (E00.F07).
    update_golden: bool = false,
    /// Enable tests that reach the internet.
    network_tests: bool = false,
    /// Enable slow integration tests (e.g. ones that spawn `zig build`).
    slow_tests: bool = false,
    /// Release channel (E17).
    channel: Channel = .dev,
    /// Commit hash the build is made from; CI passes it (the build never runs git).
    commit: []const u8 = "unknown",
    /// Reproducible-build timestamp (commit time, seconds since the epoch).
    source_date_epoch: i64 = 0,
    /// Update mode baked into the binary; `distro` forces `.disabled`.
    update_mode: UpdateMode = .managed_or_notify,
    /// Distro packaging build (FHS layout, updates disabled).
    distro: bool = false,

    /// The single tuple every package passes to `b.dependency()`. It MUST be
    /// passed unchanged; field names equal the `-D` option names.
    pub fn args(f: Flags) Args {
        return .{
            .target = f.target,
            .optimize = f.optimize,
            .tracing = f.tracing,
            .wayland = f.wayland,
            .x11 = f.x11,
            .vk_validation = f.vk_validation,
            .assert_ui_thread = f.assert_ui_thread,
            .gpa = f.gpa,
            .version = f.version,
            .@"update-golden" = f.update_golden,
            .@"network-tests" = f.network_tests,
            .@"slow-tests" = f.slow_tests,
            .channel = f.channel,
            .commit = f.commit,
            .@"source-date-epoch" = f.source_date_epoch,
            .@"update-mode" = f.update_mode,
            .distro = f.distro,
        };
    }
};

/// Dependency argument tuple. Field names are the `-D` option names, which is
/// what `b.dependency()` maps them onto, so dashed options use `@"..."` names.
pub const Args = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tracing: Tracing,
    wayland: bool,
    x11: bool,
    vk_validation: bool,
    assert_ui_thread: bool,
    gpa: GpaKind,
    version: []const u8,
    @"update-golden": bool,
    @"network-tests": bool,
    @"slow-tests": bool,
    channel: Channel,
    commit: []const u8,
    @"source-date-epoch": i64,
    @"update-mode": UpdateMode,
    distro: bool,
};

/// Default `-Dversion`.
pub const default_version = "0.0.0-dev";

/// Declares every forwarded option on `b` and returns the resolved flags.
/// Each `b.option` may be declared only once per builder, so call this exactly
/// once per `build.zig`.
pub fn flags(b: *std.Build) Flags {
    const optimize = b.standardOptimizeOption(.{});
    const distro = b.option(bool, "distro", "Distro packaging build; forces update-mode=disabled (default: false)") orelse false;
    // Always declared, so the forwarded tuple stays valid in every builder.
    const update_mode = b.option(UpdateMode, "update-mode", "Update mode: managed_or_notify (default), notify_only, disabled") orelse .managed_or_notify;
    return .{
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
        .tracing = b.option(Tracing, "tracing", "Trace zones: off (default), zones, full") orelse .off,
        .wayland = b.option(bool, "wayland", "Build the Wayland backend on Linux (default: true)") orelse true,
        .x11 = b.option(bool, "x11", "Build the X11 backend on Linux (default: true)") orelse true,
        .vk_validation = b.option(bool, "vk_validation", "Enable Vulkan validation layers (default: false)") orelse false,
        .assert_ui_thread = b.option(bool, "assert_ui_thread", "Assert no blocking I/O on the UI thread (default: Debug only)") orelse (optimize == .Debug),
        .gpa = b.option(GpaKind, "gpa", "General-purpose allocator: auto (default), debug, smp") orelse .auto,
        .version = b.option([]const u8, "version", "Version string (default: " ++ default_version ++ ")") orelse default_version,
        .update_golden = b.option(bool, "update-golden", "Rewrite golden files instead of comparing") orelse false,
        .network_tests = b.option(bool, "network-tests", "Enable tests that reach the internet") orelse false,
        .slow_tests = b.option(bool, "slow-tests", "Enable slow integration tests") orelse false,
        .channel = b.option(Channel, "channel", "Release channel: dev (default), insiders, rc, stable") orelse .dev,
        .commit = b.option([]const u8, "commit", "Commit hash of the build (default: unknown)") orelse "unknown",
        .source_date_epoch = b.option(i64, "source-date-epoch", "Reproducible-build timestamp (default: 0)") orelse 0,
        .update_mode = if (distro) .disabled else update_mode,
        .distro = distro,
    };
}

const OptionsCache = std.AutoHashMapUnmanaged(*std.Build, *std.Build.Module);
var options_cache: OptionsCache = .empty;

/// Returns the `zg_options` module for `b`, creating it on first use. One
/// module per builder; `package_root` is that builder's package directory.
pub fn optionsModule(b: *std.Build, f: Flags) *std.Build.Module {
    if (options_cache.get(b)) |m| return m;
    const o = b.addOptions();
    o.addOption(Tracing, "tracing", f.tracing);
    o.addOption(bool, "wayland", f.wayland);
    o.addOption(bool, "x11", f.x11);
    o.addOption(bool, "vk_validation", f.vk_validation);
    o.addOption(bool, "assert_ui_thread", f.assert_ui_thread);
    o.addOption(GpaKind, "gpa", f.gpa);
    o.addOption([]const u8, "version", f.version);
    o.addOption(bool, "update_golden", f.update_golden);
    o.addOption(bool, "network_tests", f.network_tests);
    o.addOption(bool, "slow_tests", f.slow_tests);
    o.addOption(Channel, "channel", f.channel);
    o.addOption([]const u8, "commit", f.commit);
    o.addOption(i64, "source_date_epoch", f.source_date_epoch);
    o.addOption(UpdateMode, "update_mode", f.update_mode);
    o.addOption(bool, "distro", f.distro);
    o.addOption([]const u8, "release_target", releaseTarget(b, f.target.result));
    o.addOption([]const u8, "package_root", absPackageRoot(b));
    const m = o.createModule();
    options_cache.put(b.graph.arena, b, m) catch @panic("OOM");
    return m;
}

/// `-Dversion` with build metadata, the same rule as
/// `zg_release.build_info.versionString`: unchanged when it has `+`, else
/// `+g<12 hex commit>`, or `+local` when the commit is unknown.
pub fn versionWithMetadata(b: *std.Build, f: Flags) []const u8 {
    if (std.mem.indexOfScalar(u8, f.version, '+') != null) return f.version;
    if (f.commit.len == 0 or std.mem.eql(u8, f.commit, "unknown")) return b.fmt("{s}+local", .{f.version});
    return b.fmt("{s}+g{s}", .{ f.version, f.commit[0..@min(12, f.commit.len)] });
}

/// `{arch}-{os}-{abi}`, plus `.{major}.{minor}` of the glibc version on
/// Linux gnu, e.g. `x86_64-linux-gnu.2.28`. Stable across Zig's default OS
/// version ranges, unlike `Target.zigTriple`.
pub fn releaseTarget(b: *std.Build, t: std.Target) []const u8 {
    const base = b.fmt("{s}-{s}-{s}", .{ @tagName(t.cpu.arch), @tagName(t.os.tag), @tagName(t.abi) });
    if (t.os.tag == .linux and t.abi.isGnu()) {
        if (t.os.versionRange().gnuLibCVersion()) |g| return b.fmt("{s}.{d}.{d}", .{ base, g.major, g.minor });
    }
    return base;
}

fn absPackageRoot(b: *std.Build) []const u8 {
    const p = b.pathFromRoot(".");
    if (std.fs.path.isAbsolute(p)) return p;
    return b.pathResolve(&.{ b.graph.cache.cwd, p });
}

/// Describes one package for `addPackage`.
pub const PackageSpec = struct {
    /// Package and root module name, e.g. "zg_net".
    name: []const u8,
    root: []const u8 = "src/root.zig",
    imports: []const std.Build.Module.Import = &.{},
    /// Bench entry point, e.g. "bench/main.zig".
    bench: ?[]const u8 = null,
    /// Must stay false: zigguro packages never link libc.
    link_libc: bool = false,
    /// Helper executables that only tests run (fake servers, fake
    /// adapters). Built for the package target when a test needs them;
    /// tests read their paths from `@import("zg_test_exes").<name>`.
    test_exes: []const TestExe = &.{},
};

/// A helper executable for tests (see `PackageSpec.test_exes`).
pub const TestExe = struct {
    /// Executable name and `zg_test_exes` field name.
    name: []const u8,
    /// Root source file, relative to the package.
    root: []const u8,
    /// Extra imports; the package module itself is always importable
    /// under the package name.
    imports: []const std.Build.Module.Import = &.{},
};

/// Suffix of the module name under which a package exposes its test
/// executables, e.g. `zg_lsp_test_exes`.
pub const test_exes_suffix = "_test_exes";

/// Adds the `zg_test_exes` import of package `name` (built by `dep`, or by
/// `b` itself when `dep` is null) to test module `tm`, if the package
/// declares test executables. Root builds call this for every package.
pub fn addTestExes(b: *std.Build, dep: ?*std.Build.Dependency, name: []const u8, tm: *std.Build.Module) void {
    const owner = if (dep) |d| d.builder else b;
    if (owner.modules.get(b.fmt("{s}{s}", .{ name, test_exes_suffix }))) |m| tm.addImport("zg_test_exes", m);
}

/// Creates the public module `spec.name` (importing `zg_options` and, when the
/// package has `fuzz/corpus/`, `zg_corpus`), a `test` step, and, if
/// `spec.bench` is set, a `bench` step plus an installed `<name>-bench`
/// artifact the root fetches with `dep.artifact()`.
pub fn addPackage(b: *std.Build, f: Flags, spec: PackageSpec) *std.Build.Module {
    if (spec.link_libc) @panic("zigguro packages must not link libc");
    // The public module leaves `optimize` unset so it inherits the mode of
    // whatever compilation imports it: tests use -Doptimize, benches
    // ReleaseFast, apps their own mode.
    const mod = b.addModule(spec.name, .{
        .root_source_file = b.path(spec.root),
        .target = f.target,
        .imports = spec.imports,
    });
    mod.addImport("zg_options", optionsModule(b, f));
    mod.addImport("zg_corpus", corpusModule(b));

    if (spec.test_exes.len > 0) {
        const o = b.addOptions();
        for (spec.test_exes) |te| {
            const exe = b.addExecutable(.{
                .name = te.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(te.root),
                    .target = f.target,
                    .optimize = f.optimize,
                    .imports = te.imports,
                }),
            });
            exe.root_module.addImport(spec.name, mod);
            o.addOptionPath(te.name, exe.getEmittedBin());
        }
        b.modules.put(b.graph.arena, b.fmt("{s}{s}", .{ spec.name, test_exes_suffix }), o.createModule()) catch @panic("OOM");
    }
    const tm = testModule(b, f, mod);
    addTestExes(b, null, spec.name, tm);
    const tests = b.addTest(.{ .name = spec.name, .root_module = tm });
    const run_tests = b.addRunArtifact(tests);
    run_tests.skip_foreign_checks = true;
    b.step("test", "Run this package's unit tests").dependOn(&run_tests.step);

    if (spec.bench) |bench_root| {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path(bench_root),
            .target = f.target,
            // Benches are always ReleaseFast; a per-package optimize option
            // would have to be forwarded and would break the invariant.
            .optimize = .ReleaseFast,
        });
        // Benches see the package and everything the package imports.
        bench_mod.addImport(spec.name, mod);
        for (spec.imports) |imp| bench_mod.addImport(imp.name, imp.module);
        const exe = b.addExecutable(.{ .name = b.fmt("{s}-bench", .{spec.name}), .root_module = bench_mod });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.has_side_effects = true;
        if (b.args) |a| run.addArgs(a);
        b.step("bench", "Run this package's benchmarks").dependOn(&run.step);
    }
    return mod;
}

/// A copy of package module `mod` (same root file and imports) with
/// `f.optimize`, for use as the root module of a test compilation. Use it
/// instead of `mod` itself, whose mode is inherited from the importer.
pub fn testModule(b: *std.Build, f: Flags, mod: *std.Build.Module) *std.Build.Module {
    const t = b.createModule(.{
        .root_source_file = mod.root_source_file,
        .target = f.target,
        .optimize = f.optimize,
    });
    var it = mod.import_table.iterator();
    while (it.next()) |e| t.addImport(e.key_ptr.*, e.value_ptr.*);
    return t;
}

/// Generates the `zg_corpus` module: `pub const <target> = &.{ @embedFile(..), .. };`
/// for every directory under `fuzz/corpus/`. Files are copied next to the
/// generated source so the embeds stay inside the module's package.
fn corpusModule(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    const gpa = b.allocator;
    src.appendSlice(gpa, "//! Generated by zg_build: embedded fuzz seed corpora.\n") catch @panic("OOM");
    var corpus_dir = b.build_root.handle.openDir(io, "fuzz/corpus", .{ .iterate = true }) catch {
        _ = wf.add("zg_corpus.zig", src.items);
        return b.createModule(.{ .root_source_file = wf.getDirectory().path(b, "zg_corpus.zig") });
    };
    defer corpus_dir.close(io);
    var targets: std.ArrayList([]const u8) = .empty;
    var it = corpus_dir.iterate();
    while (it.next(io) catch @panic("cannot read fuzz/corpus")) |entry| {
        if (entry.kind == .directory) targets.append(gpa, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, targets.items, {}, lessThan);
    for (targets.items) |target| {
        var files: std.ArrayList([]const u8) = .empty;
        var tdir = corpus_dir.openDir(io, target, .{ .iterate = true }) catch @panic("cannot open corpus dir");
        defer tdir.close(io);
        var tit = tdir.iterate();
        while (tit.next(io) catch @panic("cannot read corpus dir")) |entry| {
            if (entry.kind == .file) files.append(gpa, b.dupe(entry.name)) catch @panic("OOM");
        }
        std.mem.sort([]const u8, files.items, {}, lessThan);
        src.print(gpa, "pub const @\"{f}\": []const []const u8 = &.{{\n", .{std.zig.fmtString(target)}) catch @panic("OOM");
        for (files.items) |file| {
            const rel = b.fmt("corpus/{s}/{s}", .{ target, file });
            _ = wf.addCopyFile(b.path(b.fmt("fuzz/corpus/{s}/{s}", .{ target, file })), rel);
            src.print(gpa, "    @embedFile(\"{f}\"),\n", .{std.zig.fmtString(rel)}) catch @panic("OOM");
        }
        src.appendSlice(gpa, "};\n") catch @panic("OOM");
    }
    _ = wf.add("zg_corpus.zig", src.items);
    return b.createModule(.{ .root_source_file = wf.getDirectory().path(b, "zg_corpus.zig") });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Builds the host tools other packages run at build time. Declares the
/// shared options so that `b.dependency("zg_build", f.args())` works.
pub fn build(b: *std.Build) void {
    _ = flags(b);
    const scanner = b.addExecutable(.{
        .name = "wayland_scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("wayland_scanner/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(scanner);
}

/// Runs `wayland_scanner` over `xml` (paths relative to the calling
/// package) and returns the generated module, to be imported as `wl_gen`.
/// Regenerates whenever an XML file changes (the run step hashes inputs).
pub fn waylandModule(b: *std.Build, f: Flags, xml: []const []const u8) *std.Build.Module {
    const dep = b.dependency("zg_build", f.args());
    const run = b.addRunArtifact(dep.artifact("wayland_scanner"));
    run.addArg("--out");
    const out = run.addOutputFileArg("wayland.zig");
    for (xml) |x| run.addFileArg(b.path(x));
    return b.createModule(.{ .root_source_file = out });
}
