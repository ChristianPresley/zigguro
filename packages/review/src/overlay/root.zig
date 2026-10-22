//! Read-your-own-pending views over the workspace (E12.F02.S01).

pub const overlay_fs = @import("overlay_fs.zig");
pub const agent_view = @import("agent_view.zig");

pub const OverlayFs = overlay_fs.OverlayFs;
pub const ViewSpec = overlay_fs.ViewSpec;
pub const Read = overlay_fs.Read;
pub const AgentView = agent_view.AgentView;
pub const agentView = agent_view.agentView;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("overlay_test.zig");
}
