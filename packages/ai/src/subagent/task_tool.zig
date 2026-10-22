//! The `task` tool (E10.F09.S01.T01): delegates a prompt to a subagent
//! and returns its report. Calls in one turn run in parallel, up to the
//! runner's concurrency limit.
//!
//! `task` is marked read-only: the child's own tools go through the
//! permission engine, and a plan-mode parent only gets plan-mode
//! children. A deny rule on `task(<agent>)` (E16) disables one agent.

const std = @import("std");
const proto = @import("zg_ai_proto");
const defs = @import("defs.zig");
const runner = @import("runner.zig");
const registry = @import("../tools/registry.zig");

const Allocator = std.mem.Allocator;

pub const schema =
    \\{"type":"object","properties":{"agent":{"type":"string","description":"Which agent to run; general when omitted."},"prompt":{"type":"string","description":"The task, with everything the agent needs to know: it sees none of this conversation."},"description":{"type":"string","maxLength":80,"description":"A few words for the UI."},"thoroughness":{"enum":["quick","medium","very_thorough"]}},"required":["prompt"],"additionalProperties":false}
;

pub const TaskTool = struct {
    runner: *runner.SubagentRunner,
    description: []const u8 = "",
    names: std.heap.ArenaAllocator,
    spec_list: [1]proto.ToolSpec = undefined,

    pub fn init(gpa: Allocator, r: *runner.SubagentRunner) Allocator.Error!TaskTool {
        var t: TaskTool = .{ .runner = r, .names = .init(gpa) };
        errdefer t.names.deinit();
        t.description = try describe(t.names.allocator(), r.defs);
        return t;
    }

    pub fn deinit(t: *TaskTool) void {
        t.names.deinit();
    }

    pub fn specs(t: *TaskTool) []const proto.ToolSpec {
        t.spec_list = .{.{
            .name = "task",
            .description = t.description,
            .input_schema_json = schema,
            .read_only = true,
            .permission = .control,
            .handler = .{ .ctx = t, .call = call },
        }};
        return &t.spec_list;
    }

    pub fn source(t: *TaskTool) registry.ToolSource {
        return .{ .name = "task", .ctx = t, .list = list, .kind = .builtin };
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const t: *TaskTool = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, t.specs());
    }

    fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const t: *TaskTool = @ptrCast(@alignCast(ctx));
        const r = t.runner;
        const a = c.arena;
        const prompt = str(c.input, "prompt") orelse return errOut(a, "task needs a \"prompt\".");
        const name = str(c.input, "agent") orelse "general";
        const def = defs.find(r.defs, name) orelse
            return errOut(a, try std.fmt.allocPrint(a, "Unknown agent {s}. Available: {s}.", .{ name, try names(a, r.defs) }));
        const thoroughness: ?runner.Thoroughness = if (str(c.input, "thoroughness")) |s| std.meta.stringToEnum(runner.Thoroughness, s) else null;
        const parent = r.mgr.get(c.agent) orelse return errOut(a, "task: the calling agent is gone.");

        r.acquire(c.io) catch return error.Canceled;
        defer r.release();
        const child = r.spawn(parent, def, prompt, .{ .tool_call = c.id, .thoroughness = thoroughness }) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => errOut(a, try std.fmt.allocPrint(a, "Could not start the {s} agent: {s}", .{ name, @errorName(e) })),
        };
        const report = r.awaitReport(c.io, a, child) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => errOut(a, try std.fmt.allocPrint(a, "The {s} agent failed: {s}", .{ name, @errorName(e) })),
        };
        const failed = if (report.finish) |f| f != .end_turn else false;
        return proto.ToolOutput.text(a, report.text, failed) catch error.OutOfMemory;
    }
};

/// The tool description: what `task` does and the agents it can run.
pub fn describe(a: Allocator, ds: []const defs.AgentDef) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "Runs a subagent on a task in its own context and returns its report. The agent sees only the prompt, so include everything it needs. Several task calls in one turn run in parallel. Agents:\n");
    for (ds) |d| try out.print(a, "- {s}: {s}\n", .{ d.name, d.description });
    return out.items;
}

fn names(a: Allocator, ds: []const defs.AgentDef) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (ds, 0..) |d, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, d.name);
    }
    return out.items;
}

fn errOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, true) catch error.OutOfMemory;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
