//! zg_agents_ui: the agent views over zg_gui (E13): Mission Control. A
//! module of its own so headless consumers never import zg_gui.

const std = @import("std");

/// The Mission Control panel.
pub const mission_control = @import("mission_control.zig");

pub const MissionControl = mission_control.MissionControl;
pub const missionControl = mission_control.missionControl;

test {
    std.testing.refAllDecls(@This());
    _ = @import("mission_control_test.zig");
}
