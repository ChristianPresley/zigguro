//! A scripted agent with `todo_write` and `ask_user`, for the plan tests.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Agent = @import("../loop/Agent.zig");
const AgentManager = @import("../loop/Manager.zig");
const reg_mod = @import("../models/registry.zig");
const scripted = @import("../provider/scripted.zig");
const Provider = @import("../provider/Provider.zig");
const request = @import("../provider/request.zig");
const assembler = @import("../context/assembler.zig");
const reminders = @import("../context/reminders.zig");
const tool_registry = @import("../tools/registry.zig");
const toolset = @import("../tools/toolset.zig");
const todos = @import("todos.zig");
const ask_user = @import("ask_user.zig");

const testing = std.testing;
const io = testing.io;

pub const Step = scripted.ScriptedProvider.Step;
pub const script = scripted.script;

const catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "test",
    \\    .models = .{
    \\        .{ .id = "m", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 3_000_000, .output_per_mtok_micros = 15_000_000 } },
    \\    },
    \\}
;

pub const Harness = struct {
    registry: reg_mod.ModelRegistry,
    sp: *scripted.ScriptedProvider,
    provider: Provider,
    reg: tool_registry.ToolRegistry,
    agent_tools: toolset.AgentTools,
    queue: reminders.ReminderQueue,
    context: assembler.ContextAssembler,
    mgr: *AgentManager,
    agent: *Agent,
    todos: todos.TodoStore,
    ask: ask_user.AskUserTool,

    /// `asker` null: nobody can answer.
    pub fn init(h: *Harness, turns: []const []const Step, asker: ?ask_user.Asker) !void {
        h.registry = .init(testing.allocator, io, catalog);
        h.sp = try .init(testing.allocator, turns, .all);
        h.provider = h.sp.provider();
        h.reg = .init(testing.allocator, io);
        h.agent_tools = .init(testing.allocator, io, &h.reg, .{});
        h.agent_tools.warn_invalidations = false;
        h.queue = .init(testing.allocator, io);
        h.context = .init(testing.allocator, &h.queue, .{ .env = .{ .cwd = "/w", .platform = "linux", .now_ms = 0 } }, .{});
        h.mgr = try AgentManager.init(testing.allocator, io, .{ .registry = &h.registry, .providers = .fixed(&h.provider), .tools = h.agent_tools.tools(), .context = h.context.builder() });
        h.todos = .init(testing.allocator, io);
        h.todos.mgr = h.mgr;
        h.todos.state = &h.context.state;
        try h.reg.addSource(h.todos.source());
        h.ask = .{ .asker = asker, .mgr = h.mgr };
        try h.reg.addSource(h.ask.source());
        h.agent = try h.mgr.create(.{ .model = "m" });
    }

    pub fn deinit(h: *Harness) void {
        h.mgr.deinit();
        h.todos.deinit();
        h.context.deinit();
        h.queue.deinit();
        h.agent_tools.deinit();
        h.reg.deinit();
        h.sp.destroy();
        h.registry.deinit();
    }

    pub fn run(h: *Harness, text: []const u8) !void {
        _ = try h.agent.submit(.{ .text = text });
        h.agent.waitIdle();
    }

    /// The text of the first tool result in request `i`'s last message.
    pub fn resultIn(h: *Harness, i: usize) []const u8 {
        const req = h.sp.requests()[i];
        const last = req.messages[req.messages.len - 1];
        return last.content[0].tool_result.parts[0].text;
    }

    pub fn isErrorIn(h: *Harness, i: usize) bool {
        const req = h.sp.requests()[i];
        return req.messages[req.messages.len - 1].content[0].tool_result.is_error;
    }

    /// Whether request `i`'s last message carries `needle` in any block.
    pub fn lastHas(h: *Harness, i: usize, needle: []const u8) bool {
        const req: request.Request = h.sp.requests()[i];
        for (req.messages[req.messages.len - 1].content) |b| switch (b) {
            .text => |t| if (std.mem.indexOf(u8, t.text, needle) != null) return true,
            .tool_result => |r| for (r.parts) |p| if (p == .text and std.mem.indexOf(u8, p.text, needle) != null) return true,
            else => {},
        };
        return false;
    }

    pub fn names(h: *Harness, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (h.agent.deps.tools.list()) |s| {
            if (out.items.len > 0) try out.append(arena, ',');
            try out.appendSlice(arena, s.name);
        }
        return out.items;
    }
};
