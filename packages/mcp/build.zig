const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const jsonrpc = b.dependency("zg_jsonrpc", f.args()).module("zg_jsonrpc");
    const net = b.dependency("zg_net", f.args()).module("zg_net");
    const regex = b.dependency("zg_regex", f.args()).module("zg_regex");
    const mod = zg_build.addPackage(b, f, .{
        .name = "zg_mcp",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_jsonrpc", .module = jsonrpc },
            .{ .name = "zg_net", .module = net },
            .{ .name = "zg_regex", .module = regex },
        },
        .bench = "bench/main.zig",
    });
    b.top_level_steps.get("test").?.step.dependOn(&b.addRunArtifact(addStdioTests(b, f, mod, core, "")).step);
}

/// The stdio transport tests, which spawn `test/fixtures/echo_server.zig`.
/// They live outside the module's own tests because they need the fixture's
/// path. The root build calls this too (with `prefix` = "packages/mcp/").
pub fn addStdioTests(b: *std.Build, f: zg_build.Flags, mcp: *std.Build.Module, core: *std.Build.Module, prefix: []const u8) *std.Build.Step.Compile {
    const echo = b.addExecutable(.{
        .name = "mcp-echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}test/fixtures/echo_server.zig", .{prefix})),
            .target = f.target,
            .optimize = f.optimize,
        }),
    });
    const fixtures = b.addOptions();
    fixtures.addOptionPath("echo_server", echo.getEmittedBin());
    return b.addTest(.{
        .name = "zg_mcp-stdio",
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}test/stdio_test.zig", .{prefix})),
            .target = f.target,
            .optimize = f.optimize,
            .imports = &.{
                .{ .name = "zg_mcp", .module = mcp },
                .{ .name = "zg_core", .module = core },
                .{ .name = "mcp_fixtures", .module = fixtures.createModule() },
            },
        }),
    });
}
