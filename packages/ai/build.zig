const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    const net = b.dependency("zg_net", f.args()).module("zg_net");
    const regex = b.dependency("zg_regex", f.args()).module("zg_regex");

    // zg_ai_proto: the leaf module of canonical types (std + zg_core only),
    // importable by layer-4 packages without importing zg_ai.
    const proto = b.addModule("zg_ai_proto", .{
        .root_source_file = b.path("proto/root.zig"),
        .target = f.target,
        .imports = &.{.{ .name = "zg_core", .module = core }},
    });
    proto.addImport("zg_options", zg_build.optionsModule(b, f));
    const proto_tests = b.addTest(.{ .name = "zg_ai_proto", .root_module = zg_build.testModule(b, f, proto) });
    const run_proto = b.addRunArtifact(proto_tests);
    run_proto.skip_foreign_checks = true;

    _ = zg_build.addPackage(b, f, .{
        .name = "zg_ai",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_net", .module = net },
            .{ .name = "zg_ai_proto", .module = proto },
            .{ .name = "zg_regex", .module = regex },
        },
        .bench = "bench/main.zig",
    });
    b.getInstallStep().dependOn(&proto_tests.step);
    b.step("test-proto", "Run the zg_ai_proto tests").dependOn(&run_proto.step);
    b.top_level_steps.get("test").?.step.dependOn(&run_proto.step);
}
