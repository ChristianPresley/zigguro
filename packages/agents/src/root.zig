//! zg_agents: agentic work beyond code (E13): agent runs and Mission
//! Control, automations, the task board, document/research/data modes,
//! artifacts, workflows and projects. Headless models; GUI views live in
//! the `zg_agents_ui` module.

const std = @import("std");

pub const runs = @import("runs/root.zig");
pub const mission = @import("mission/root.zig");
pub const notify = @import("notify/root.zig");
pub const sched = @import("sched/root.zig");
pub const tasks = @import("tasks/root.zig");
pub const docs = @import("docs/root.zig");

test {
    _ = runs;
    _ = mission;
    _ = notify;
    _ = tasks;
    _ = sched;
    _ = docs;
}
