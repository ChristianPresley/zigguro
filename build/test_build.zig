//! Build-graph self tests (`zig build test-build`). They spawn `zig build`,
//! so they are slow; the diamond fixture runs only with `-Dslow-tests`.

const std = @import("std");
const cfg = @import("test_build_options");

/// Must match `step_names` in the root build.zig.
const step_names = [_][]const u8{
    "install",      "run",      "run-zg",        "test",   "test-tools", "test-build", "test-core",
    "test-jsonrpc", "test-net", "test-platform", "bench",  "fuzz",       "fmt-check",  "check-layers",
    "new-package",  "cross",    "docs",          "prlint", "fuzz-list",
};

fn zigBuild(gpa: std.mem.Allocator, cwd: []const u8, extra: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ cfg.zig_exe, "build" });
    try argv.appendSlice(gpa, extra);
    return std.process.run(gpa, std.testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
}

test "build: every documented step appears in zig build --help" {
    const gpa = std.testing.allocator;
    const r = try zigBuild(gpa, cfg.repo_root, &.{"--help"});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
    for (step_names) |name| {
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "  {s} ", .{name});
        if (std.mem.indexOf(u8, r.stdout, needle) == null) {
            std.debug.print("missing step: {s}\n", .{name});
            return error.MissingStep;
        }
    }
}

test "build: diamond fixture deduplicates with every flag combination" {
    if (!cfg.slow_tests) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const dir = try std.fs.path.join(gpa, &.{ cfg.repo_root, "packages", "build", "testdata", "diamond", "a" });
    defer gpa.free(dir);
    const combos = [_][]const []const u8{
        &.{ "-Dtracing=off", "-Doptimize=Debug" },
        &.{ "-Dtracing=zones", "-Doptimize=Debug" },
        &.{ "-Dtracing=full", "-Doptimize=ReleaseFast" },
        &.{ "-Dgpa=smp", "-Dupdate-golden", "-Dnetwork-tests" },
    };
    for (combos) |c| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.append(gpa, "test");
        try args.appendSlice(gpa, c);
        const r = try zigBuild(gpa, dir, args.items);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!(r.term == .exited and r.term.exited == 0)) {
            std.debug.print("diamond failed with {s}:\n{s}\n", .{ c[0], r.stderr });
            return error.DiamondFailed;
        }
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "file exists in modules") == null);
    }
}
