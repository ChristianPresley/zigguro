const std = @import("std");
const zg_build = @import("zg_build");

pub fn build(b: *std.Build) void {
    const f = zg_build.flags(b);
    const core = b.dependency("zg_core", f.args()).module("zg_core");
    // E05's document model (ChangeSet, PendingChange); the review core uses
    // only `zg_editor.model`, never the view.
    const editor = b.dependency("zg_editor", f.args()).module("zg_editor");
    // E10's leaf types (AgentRef), not zg_ai itself.
    const proto = b.dependency("zg_ai", f.args()).module("zg_ai_proto");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_review",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_editor", .module = editor },
            .{ .name = "zg_ai_proto", .module = proto },
        },
        .bench = "bench/main.zig",
    });
}
