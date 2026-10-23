//! Task lifecycle hooks (E13.F03.S02.T01), as in Claude Code's agent
//! teams: `TaskCreated` runs before an agent's task is created and
//! `TaskCompleted` before an agent marks one complete. A hook that exits
//! with code 2 blocks the action, and its stderr goes back to the agent as
//! the tool's error. Hooks are configured in settings `ai.hooks` and run
//! by E10's `HookEngine` (`fromEngine`).

const std = @import("std");
const zg_ai = @import("zg_ai");
const runs = @import("../runs/root.zig");
const task_mod = @import("task.zig");
const ids = @import("ids.zig");

const Allocator = std.mem.Allocator;
const HookEngine = zg_ai.ext.HookEngine;

pub const Event = enum { created, completed };

pub const Input = struct {
    /// 0 for a task not created yet.
    id: task_mod.TaskId = 0,
    title: []const u8,
    description: []const u8 = "",
    run: ?runs.RunId = null,
    /// The agent definition working on it.
    agent: ?[]const u8 = null,
};

pub const HookPort = struct {
    ctx: *anyopaque,
    /// Why the action is blocked, or null to go ahead. Strings in `arena`.
    run: *const fn (ctx: *anyopaque, arena: Allocator, ev: Event, in: Input) anyerror!?[]const u8,

    /// The E10 hook engine's `TaskCreated` and `TaskCompleted` hooks.
    pub fn fromEngine(e: *HookEngine) HookPort {
        return .{ .ctx = e, .run = engineRun };
    }

    fn engineRun(ctx: *anyopaque, arena: Allocator, ev: Event, in: Input) anyerror!?[]const u8 {
        const e: *HookEngine = @ptrCast(@alignCast(ctx));
        const out = try e.run(e.io, arena, switch (ev) {
            .created => .TaskCreated,
            .completed => .TaskCompleted,
        }, try engineInput(arena, in));
        return out.block orelse out.stop_all;
    }
};

pub fn engineInput(arena: Allocator, in: Input) !zg_ai.ext.hook_io.Input {
    return .{
        .task_id = if (in.id != 0) try arena.dupe(u8, ids.format(in.id).slice()) else null,
        .task_subject = in.title,
        .task_description = in.description,
        .teammate_name = in.agent orelse if (in.run) |r| try std.fmt.allocPrint(arena, "{f}", .{r}) else null,
        .agent_id = if (in.run) |r| try std.fmt.allocPrint(arena, "{f}", .{r}) else null,
    };
}

test "engine input carries the task" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const in = try engineInput(arena.allocator(), .{ .id = 42, .title = "Write docs", .description = "Body", .agent = "writer" });
    const json = try zg_ai.ext.hook_io.encodeInput(arena.allocator(), .TaskCompleted, in);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hook_event_name\":\"TaskCompleted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"task_id\":\"T-0042\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"teammate_name\":\"writer\"") != null);
    try std.testing.expect(zg_ai.ext.hook_io.HookEvent.TaskCompleted.blockable());
}
