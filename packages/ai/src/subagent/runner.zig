//! `SubagentRunner` (E10.F09.S01.T01): spawns child agents from
//! definitions and turns their final answer into a report.
//!
//! A child is a new `Agent` under the parent (same session, next agent
//! number, `depth + 1`) with:
//! - the definition's prompt as its system prompt addition and the
//!   delegation prompt as its only user message: no parent history;
//! - a toolset filtered by the definition, without `task` once the depth
//!   limit is reached;
//! - the definition's model (`inherit` is the parent's, `fast` the
//!   cheapest of the parent's provider unless an alias says otherwise);
//! - the definition's permission mode, else the parent's; a plan-mode
//!   parent always gets plan-mode children;
//! - with `isolation: workspace`, its own working copy from `Lanes` (an E09
//!   agent lane), whose handle the report returns while it has changes.
//!
//! At most `max_concurrent` children run at once (a semaphore). The
//! parent's deps (permission, hooks, session log, ledger) are shared, so
//! child sessions are written under the parent's session, approvals reach
//! the parent's queue labelled with the child's ref, and
//! `AgentManager.subscribeAll` sees child events tagged with the child.
//! Cancelling the parent cancels its children.

const std = @import("std");
const proto = @import("zg_ai_proto");
const defs = @import("defs.zig");
const Agent = @import("../loop/Agent.zig");
const AgentManager = @import("../loop/Manager.zig");
const deps = @import("../loop/deps.zig");
const ev = @import("../loop/events.zig");
const reg_mod = @import("../models/registry.zig");
const tool_registry = @import("../tools/registry.zig");
const toolset = @import("../tools/toolset.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const PermissionMode = defs.PermissionMode;
pub const Thoroughness = enum { quick, medium, very_thorough };

pub const Config = struct {
    /// `ai.subagents.maxDepth`: children at this depth get no `task`.
    max_depth: u8 = 3,
    /// `ai.subagents.maxConcurrent`.
    max_concurrent: u32 = 20,
    /// `ai.subagents.maxReportTokens` (about 4 characters each).
    max_report_tokens: u32 = 4000,
};

/// An isolated working copy (E09 agent lane).
pub const Lane = struct {
    path: []const u8,
    handle: []const u8,
    /// Tools rooted in the lane; the runner's registry when null.
    registry: ?*tool_registry.ToolRegistry = null,
};

/// E09's agent lanes (`zg_scm.createLane`), adapted by the app.
pub const Lanes = struct {
    ctx: *anyopaque,
    /// `name` is `agent-<session>-<n>`.
    create: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, name: []const u8, owner: proto.AgentRef) anyerror!Lane,
    /// Called when the child is done: removes a lane without changes and
    /// returns whether it was kept for review.
    finish: *const fn (ctx: *anyopaque, io: Io, handle: []const u8) anyerror!bool,
};

pub const SpawnOpts = struct {
    /// The parent's `task` call id.
    tool_call: ?[]const u8 = null,
    thoroughness: ?Thoroughness = null,
    /// The parent's permission mode; `modeOf` when null.
    parent_mode: ?PermissionMode = null,
};

pub const Report = struct {
    /// The final answer (cut to the report limit) and the trailer.
    text: []const u8,
    agent: []const u8,
    tool_calls: u32,
    tokens: u64,
    cost_micros: u64,
    files_read: u32,
    truncated: bool,
    /// The lane kept for review, if any.
    workspace_handle: ?[]const u8 = null,
    finish: ?ev.FinishReason,
};

pub const SpawnError = error{ UnknownModel, Canceled } || AgentManager.CreateError;

/// A running child and what it owns.
const Child = struct {
    agent: *Agent,
    def: *const defs.AgentDef,
    tools: toolset.AgentTools,
    arena: std.heap.ArenaAllocator,
    lane: ?Lane = null,
};

pub const SubagentRunner = struct {
    gpa: Allocator,
    io: Io,
    mgr: *AgentManager,
    reg: *tool_registry.ToolRegistry,
    defs: []const defs.AgentDef,
    cfg: Config,
    lanes: ?Lanes = null,
    /// The toolset of top-level agents, whose mode children inherit.
    main_tools: ?*toolset.AgentTools = null,
    sem: Io.Semaphore,
    mutex: Io.Mutex = .init,
    children: std.ArrayList(*Child) = .empty,
    lanes_made: u32 = 0,

    pub fn init(gpa: Allocator, io: Io, mgr: *AgentManager, reg: *tool_registry.ToolRegistry, definitions: []const defs.AgentDef, cfg: Config) SubagentRunner {
        return .{ .gpa = gpa, .io = io, .mgr = mgr, .reg = reg, .defs = definitions, .cfg = cfg, .sem = .{ .permits = cfg.max_concurrent } };
    }

    /// Disposes children still alive.
    pub fn deinit(r: *SubagentRunner) void {
        while (true) {
            const c = blk: {
                r.mutex.lockUncancelable(r.io);
                defer r.mutex.unlock(r.io);
                break :blk r.children.pop() orelse break;
            };
            r.free(c);
        }
        r.children.deinit(r.gpa);
    }

    /// Takes a concurrency slot; `release` gives it back.
    pub fn acquire(r: *SubagentRunner, io: Io) Io.Cancelable!void {
        return r.sem.wait(io);
    }

    pub fn release(r: *SubagentRunner) void {
        r.sem.post(r.io);
    }

    /// The permission mode of `ref`: a child's own, else the main
    /// toolset's.
    pub fn modeOf(r: *SubagentRunner, ref: proto.AgentRef) PermissionMode {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.children.items) |c| if (c.agent.ref.session == ref.session and c.agent.ref.agent == ref.agent) return c.tools.cfg.mode;
        return if (r.main_tools) |t| t.cfg.mode else .default;
    }

    /// The definition name of child `ref`, while it is alive.
    pub fn nameOf(r: *SubagentRunner, ref: proto.AgentRef) ?[]const u8 {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.children.items) |c| if (c.agent.ref.session == ref.session and c.agent.ref.agent == ref.agent) return c.def.name;
        return null;
    }

    /// Creates the child and submits `prompt`. The caller holds a slot.
    pub fn spawn(r: *SubagentRunner, parent: *Agent, def: *const defs.AgentDef, prompt: []const u8, opts: SpawnOpts) !*Agent {
        const c = try r.gpa.create(Child);
        c.* = .{ .agent = undefined, .def = def, .tools = undefined, .arena = .init(r.gpa) };
        var tools_ready = false;
        errdefer {
            if (tools_ready) c.tools.deinit();
            c.arena.deinit();
            r.gpa.destroy(c);
        }
        const a = c.arena.allocator();

        const parent_mode = opts.parent_mode orelse r.modeOf(parent.ref);
        const mode: PermissionMode = if (parent_mode == .plan) .plan else def.permission_mode orelse parent_mode;
        const depth = parent.cfg.depth + 1;
        var deny: std.ArrayList([]const u8) = .empty;
        try deny.appendSlice(a, def.disallowed_tools);
        if (depth >= r.cfg.max_depth) try deny.append(a, "task");

        const info = try resolveModel(parent.deps.registry, def.model, parent.cfg.model);

        var system: std.ArrayList(u8) = .empty;
        try system.appendSlice(a, try def.body(r.io, a));
        if (opts.thoroughness) |t| try system.print(a, "\n\nThoroughness: {s}. {s}", .{ @tagName(t), switch (t) {
            .quick => "Answer from the first good evidence; a few searches at most.",
            .medium => "Check the main places the answer could be.",
            .very_thorough => "Search exhaustively, including tests, docs and unusual naming.",
        } });

        var cwd = parent.cfg.cwd;
        var reg = r.reg;
        if (def.isolation == .workspace) if (r.lanes) |l| {
            const n = blk: {
                r.mutex.lockUncancelable(r.io);
                defer r.mutex.unlock(r.io);
                r.lanes_made += 1;
                break :blk r.lanes_made;
            };
            const sid = proto.agent_ref.format(parent.ref.session);
            const name = try std.fmt.allocPrint(a, "agent-{s}-{d}", .{ &sid, n });
            const lane = try l.create(l.ctx, r.io, a, name, parent.ref);
            c.lane = lane;
            cwd = lane.path;
            if (lane.registry) |lr| reg = lr;
        };

        c.tools = .init(r.gpa, r.io, reg, .{ .allow = def.tools orelse &.{"*"}, .deny = deny.items, .mode = mode });
        tools_ready = true;
        var d = parent.deps;
        d.tools = c.tools.tools();
        c.agent = try r.mgr.createWith(.{
            .model = info.id,
            .system_append = system.items,
            .cwd = cwd,
            .budgets = .{ .max_turns = def.max_turns },
            .parent = parent.ref,
            .spawned_by = opts.tool_call,
            .depth = depth,
            .role = .subagent,
        }, d);
        errdefer r.mgr.dispose(c.agent);
        {
            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);
            try r.children.append(r.gpa, c);
        }
        _ = try c.agent.submit(.{ .text = prompt, .source = .subagent_parent });
        return c.agent;
    }

    /// Waits for `child` to finish and builds its report (text in
    /// `arena`), then disposes the child.
    pub fn awaitReport(r: *SubagentRunner, io: Io, arena: Allocator, child: *Agent) !Report {
        _ = io;
        child.waitIdle();
        const c = r.take(child) orelse return error.UnknownChild;
        defer r.free(c);

        const snap = child.snapshot();
        var answer: []const u8 = "";
        var tool_calls: u32 = 0;
        var read: std.StringHashMapUnmanaged(void) = .empty;
        for (child.messages()) |m| {
            if (m.role != .assistant) continue;
            var text: std.ArrayList(u8) = .empty;
            for (m.content) |b| switch (b) {
                .text => |t| try text.appendSlice(arena, t.text),
                .tool_use => |u| {
                    tool_calls += 1;
                    if (std.mem.eql(u8, u.name, "read_file")) if (pathOf(arena, u.input_json)) |p| try read.put(arena, p, {});
                },
                else => {},
            };
            if (text.items.len > 0) answer = text.items;
        }
        const limit = @as(usize, r.cfg.max_report_tokens) * 4;
        const truncated = answer.len > limit;
        if (truncated) answer = answer[0..cutAt(answer, limit)];

        var handle: ?[]const u8 = null;
        if (c.lane) |lane| if (r.lanes) |l| {
            const kept = l.finish(l.ctx, r.io, lane.handle) catch true;
            if (kept) handle = try arena.dupe(u8, lane.handle);
        };

        const tokens = snap.usage.input + snap.usage.output + snap.usage.cache_read + snap.usage.cache_write_5m + snap.usage.cache_write_1h;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, if (answer.len > 0) answer else "(the agent gave no answer)");
        if (truncated) try out.appendSlice(arena, "\n[report truncated]");
        try out.print(arena, "\n\n[agent {s} · {d} tool call{s} · {f} tokens · ${d:.2} · files read: {d}", .{
            c.def.name,
            tool_calls,
            if (tool_calls == 1) "" else "s",
            Compact{ .n = tokens },
            @as(f64, @floatFromInt(snap.cost_micros)) / 1e6,
            read.count(),
        });
        if (handle) |h| try out.print(arena, " · workspace {s}", .{h});
        try out.append(arena, ']');
        return .{
            .text = out.items,
            .agent = c.def.name,
            .tool_calls = tool_calls,
            .tokens = tokens,
            .cost_micros = snap.cost_micros,
            .files_read = @intCast(read.count()),
            .truncated = truncated,
            .workspace_handle = handle,
            .finish = snap.last_finish,
        };
    }

    fn take(r: *SubagentRunner, agent: *Agent) ?*Child {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.children.items, 0..) |c, i| if (c.agent == agent) return r.children.swapRemove(i);
        return null;
    }

    fn free(r: *SubagentRunner, c: *Child) void {
        r.mgr.dispose(c.agent);
        c.tools.deinit();
        c.arena.deinit();
        r.gpa.destroy(c);
    }
};

/// Resolves a definition's model against the parent's.
pub fn resolveModel(reg: *reg_mod.ModelRegistry, want: ?[]const u8, parent_model: []const u8) error{UnknownModel}!*const reg_mod.ModelInfo {
    const parent = reg.resolve(parent_model) orelse return error.UnknownModel;
    const name = want orelse return parent;
    if (std.mem.eql(u8, name, "inherit")) return parent;
    if (reg.resolve(name)) |m| return m;
    if (std.mem.eql(u8, name, "fast")) return reg.modelForRole(parent, .title);
    return error.UnknownModel;
}

/// `38k`, `1.2M`.
const Compact = struct {
    n: u64,
    pub fn format(c: Compact, w: *Io.Writer) Io.Writer.Error!void {
        if (c.n < 1000) return w.print("{d}", .{c.n});
        if (c.n < 1_000_000) return w.print("{d}k", .{(c.n + 500) / 1000});
        return w.print("{d:.1}M", .{@as(f64, @floatFromInt(c.n)) / 1e6});
    }
};

/// The last line end at or before `limit`, else `limit` on a UTF-8
/// boundary.
fn cutAt(s: []const u8, limit: usize) usize {
    if (std.mem.lastIndexOfScalar(u8, s[0..limit], '\n')) |nl| if (nl > limit / 2) return nl;
    var i = limit;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

fn pathOf(arena: Allocator, input_json: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, input_json, .{}) catch return null;
    if (v != .object) return null;
    const p = v.object.get("path") orelse v.object.get("file_path") orelse return null;
    return if (p == .string) p.string else null;
}
