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
pub const research = @import("research/root.zig");
pub const data = @import("data/root.zig");
pub const artifacts = @import("artifacts/root.zig");
pub const vector = @import("vector/root.zig");
pub const chart = @import("chart/root.zig");
pub const diagram_render = @import("diagram_render/root.zig");
pub const library = @import("library/root.zig");
pub const workflow = @import("workflow/root.zig");

test {
    _ = runs;
    _ = mission;
    _ = notify;
    _ = tasks;
    _ = sched;
    _ = docs;
    _ = research;
    _ = data;
    _ = vector;
    _ = chart;
    _ = diagram_render;
    _ = artifacts;
    _ = library;
    _ = workflow;
}
