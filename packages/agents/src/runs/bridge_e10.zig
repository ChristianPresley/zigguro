//! `E10Agents` (E13.F01.S01.T02): the `AgentPort` over E10's
//! `AgentManager`. Each started agent gets a queued bus subscriber that
//! reduces `AgentEvent`s to run signals: status to working/needs_input,
//! `approval_needed` to the question, `usage` to cost, `tool_finished` to
//! a tool boundary and `turn_finished` to the summary (last assistant
//! text) and the turn's end.

const std = @import("std");
const zg_ai = @import("zg_ai");
const proto = @import("zg_ai_proto");
const run = @import("run.zig");
const port = @import("port.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Agent = zg_ai.loop.Agent;
const AgentManager = zg_ai.loop.AgentManager;
const ev = zg_ai.loop.events;

pub const Options = struct {
    /// Used when a spec names no model.
    default_model: []const u8,
    /// Deps for unattended runs (a permission engine that denies `ask`);
    /// null uses the manager's deps.
    unattended_deps: ?Agent.Deps = null,
};

const Entry = struct {
    owner: *E10Agents,
    agent: *Agent,
    sink: port.Sink,
    sub: u32 = 0,
    last_error: [256]u8 = undefined,
    last_error_len: usize = 0,
};

pub const E10Agents = struct {
    gpa: Allocator,
    io: Io,
    mgr: *AgentManager,
    opts: Options,

    pub fn init(gpa: Allocator, io: Io, mgr: *AgentManager, opts: Options) E10Agents {
        return .{ .gpa = gpa, .io = io, .mgr = mgr, .opts = opts };
    }

    pub fn agentPort(e: *E10Agents) port.AgentPort {
        return .{ .ctx = e, .vtable = &vtable };
    }

    const vtable: port.AgentPort.VTable = .{ .start = start, .submit = submit, .cancel = cancel, .dispose = dispose, .ref = ref };

    fn start(ctx: *anyopaque, req: port.StartRequest) anyerror!port.Started {
        const e: *E10Agents = @ptrCast(@alignCast(ctx));
        const cfg: Agent.Config = .{
            .model = req.model orelse e.opts.default_model,
            .cwd = req.cwd,
            .budgets = .{
                .max_turns = req.budgets.max_turns,
                .max_wall_ms = req.budgets.max_wall_ms,
                .max_cost_micros = req.budgets.max_cost_micros,
            },
            .session = req.session,
            .system_append = req.system_append,
        };
        const deps = if (req.unattended) (e.opts.unattended_deps orelse e.mgr.deps) else e.mgr.deps;
        const agent = try e.mgr.createWith(cfg, deps);
        errdefer e.mgr.dispose(agent);
        const entry = try e.gpa.create(Entry);
        errdefer e.gpa.destroy(entry);
        entry.* = .{ .owner = e, .agent = agent, .sink = req.sink };
        entry.sub = try agent.subscribe(.{ .ctx = entry, .on_events = onEvents, .mode = .queued });
        return .{ .handle = @intFromPtr(entry), .session = agent.ref.session };
    }

    fn entryOf(h: usize) *Entry {
        return @ptrFromInt(h);
    }

    fn submit(_: *anyopaque, h: usize, text: []const u8) anyerror!void {
        const entry = entryOf(h);
        const busy = entry.agent.snapshot().status;
        const mode: zg_ai.loop.input_queue.Mode = if (busy == .running_tools) .steer else .queue;
        _ = try entry.agent.submit(.{ .text = text, .mode = mode });
    }

    fn cancel(_: *anyopaque, h: usize, what: port.CancelWhat) void {
        entryOf(h).agent.cancel(switch (what) {
            .turn => .turn,
            .everything => .everything,
        });
    }

    fn dispose(ctx: *anyopaque, h: usize) void {
        const e: *E10Agents = @ptrCast(@alignCast(ctx));
        const entry = entryOf(h);
        entry.agent.unsubscribe(entry.sub);
        e.mgr.dispose(entry.agent);
        e.gpa.destroy(entry);
    }

    fn ref(_: *anyopaque, h: usize) ?proto.AgentRef {
        return entryOf(h).agent.ref;
    }
};

fn onEvents(ctx: *anyopaque, batch: []const ev.Envelope) void {
    const entry: *Entry = @ptrCast(@alignCast(ctx));
    for (batch) |env| translate(entry, env.ev);
}

/// The run signal for one event, if any.
fn translate(entry: *Entry, e: ev.AgentEvent) void {
    const sink = entry.sink;
    switch (e) {
        .status => |s| switch (s) {
            .thinking, .streaming, .running_tools, .retrying, .compacting => sink.send(.working),
            .awaiting_approval, .waiting_user => sink.send(.{ .needs_input = null }),
            else => {},
        },
        .approval_needed => |a| sink.send(.{ .needs_input = if (a.label.len != 0) a.label else a.json }),
        .usage => |u| sink.send(.{ .cost = .{
            .micros = u.cost_micros,
            .input_tokens = u.total.input,
            .output_tokens = u.total.output,
        } }),
        .tool_finished => sink.send(.tool_boundary),
        .error_ => |x| {
            const n = @min(x.message.len, entry.last_error.len);
            @memcpy(entry.last_error[0..n], x.message[0..n]);
            entry.last_error_len = n;
        },
        .turn_finished => |t| {
            sendSummary(entry);
            switch (t.reason) {
                .canceled => sink.send(.{ .turn_finished = .canceled }),
                .failed => {
                    if (entry.last_error_len != 0) sink.send(.{ .failed = entry.last_error[0..entry.last_error_len] });
                    sink.send(.{ .turn_finished = .failed });
                },
                .end_turn => sink.send(.{ .turn_finished = .end_turn }),
                else => sink.send(.{ .turn_finished = .other }),
            }
        },
        else => {},
    }
}

fn sendSummary(entry: *Entry) void {
    const a = entry.agent;
    const msgs = a.messages();
    var i = msgs.len;
    while (i > 0) {
        i -= 1;
        const m = msgs[i];
        if (m.role != .assistant) continue;
        for (m.content) |b| switch (b) {
            .text => |t| if (t.text.len != 0) {
                entry.sink.send(.{ .summary = t.text });
                return;
            },
            else => {},
        };
    }
}
