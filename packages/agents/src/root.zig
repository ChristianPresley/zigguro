//! zg_agents: agentic work beyond code (E13): agent runs and Mission
//! Control, automations, the task board, document/research/data modes,
//! artifacts, workflows and projects. Headless models; GUI views live in
//! the `zg_agents_ui` module.

const std = @import("std");

pub const runs = @import("runs/root.zig");
pub const mission = @import("mission/root.zig");

test {
    _ = runs;
    _ = mission;
}
