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
    // E08's globs (the std-only zg_ignore leaf), not zg_workspace itself.
    const ignore = b.dependency("zg_workspace", f.args()).module("zg_ignore");
    // E16's contracts (ApprovalPort, ApprovalRequest, Answer) for the
    // approvals broker; never zg_security_ui.
    const security = b.dependency("zg_security", f.args()).module("zg_security");
    // E09's review contract (ReviewPort, Proposal), previews and the lane
    // landing queue, for the SCM proposal port.
    const scm = b.dependency("zg_scm", f.args()).module("zg_scm");
    // E00's HTTP client and SSE parser, for the FIM completion providers.
    const net = b.dependency("zg_net", f.args()).module("zg_net");
    _ = zg_build.addPackage(b, f, .{
        .name = "zg_review",
        .imports = &.{
            .{ .name = "zg_core", .module = core },
            .{ .name = "zg_editor", .module = editor },
            .{ .name = "zg_ai_proto", .module = proto },
            .{ .name = "zg_ignore", .module = ignore },
            .{ .name = "zg_security", .module = security },
            .{ .name = "zg_scm", .module = scm },
            .{ .name = "zg_net", .module = net },
        },
        .bench = "bench/main.zig",
    });
}
