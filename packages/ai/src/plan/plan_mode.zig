//! Plan mode (E10.F09.S02.T01): entering and leaving it, and the
//! `exit_plan_mode` tool that presents a plan for approval.
//!
//! In plan mode the toolset keeps read-only tools, the plan-mode tools and
//! `run_command` (`readonly.zig`), the invoke pipeline refuses any other
//! call, and the assembler adds the plan-mode addendum. `PlanMode` keeps
//! those in step: `enter` and `leave` set the agent's flag and every
//! target it was given (toolset, assembler state, compaction re-injection
//! and an extra sink such as a permission engine).
//!
//! `exit_plan_mode` publishes `plan_proposed` and asks the `Approver` (the
//! CLI prompt below, or an E16 approval ticket of kind `plan`). On approval
//! the plan, as the user may have edited it, is written atomically to
//! `.zigguro/plans/<session>.md`, `plan_approved` is published, the mode
//! switches and the plan joins the system prompt and survives compaction.
//! "Approve and clear context" also replaces the history with the plan.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Agent = @import("../loop/Agent.zig");
const assembler = @import("../context/assembler.zig");
const compactor = @import("../context/compactor.zig");
const resume_mod = @import("../session/resume.zig");
const index = @import("../session/index.zig");
const registry = @import("../tools/registry.zig");
const toolset = @import("../tools/toolset.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const PermissionMode = resume_mod.PermissionMode;

pub const schema =
    \\{"type":"object","properties":{"plan":{"type":"string","description":"The plan, in Markdown: what will change, where, and how it will be checked."}},"required":["plan"],"additionalProperties":false}
;

pub const description = "Presents your plan to the user for approval and leaves plan mode when they approve. Call it once your research is done; the user may approve, edit the plan or ask you to keep planning.";

pub const PlanDecision = union(enum) {
    /// Leave plan mode in this mode (`accept_edits` or `default`).
    approve: PermissionMode,
    /// The same, and the history is replaced with the plan.
    approve_clear_context: PermissionMode,
    /// Stay in plan mode; the feedback goes back to the model.
    keep_planning: ?[]const u8,
};

pub const Answer = struct {
    decision: PlanDecision,
    /// The plan as the user edited it before approving.
    edited_plan: ?[]const u8 = null,
};

/// Asks the user about a plan. Slices in the answer live in `arena`.
pub const Approver = struct {
    ctx: *anyopaque,
    ask: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, plan: []const u8) Io.Cancelable!Answer,
};

/// Anything else that follows the mode, such as a permission engine.
pub const ModeSink = struct {
    ctx: *anyopaque,
    set: *const fn (ctx: *anyopaque, mode: PermissionMode) void,
};

/// Takes a new session title (F08.S01.T02).
pub const TitleSink = struct {
    ctx: *anyopaque,
    set: *const fn (ctx: *anyopaque, title: []const u8) void,
};

pub const Targets = struct {
    tools: ?*toolset.AgentTools = null,
    /// The agent's assembler state (`ContextAssembler.state`).
    state: ?*assembler.State = null,
    compaction: ?*compactor.LoopCompaction = null,
    mode_sink: ?ModeSink = null,
    title: ?TitleSink = null,
};

pub const PlanMode = struct {
    gpa: Allocator,
    agent: *Agent,
    /// Workspace root; plans go to `<ws_root>/.zigguro/plans/`.
    ws_root: []const u8,
    approver: Approver,
    targets: Targets = .{},
    mode: PermissionMode = .default,
    /// The approved plan (owned); targets borrow it.
    plan: ?[]u8 = null,
    spec_list: [1]proto.ToolSpec = undefined,

    pub fn init(gpa: Allocator, agent: *Agent, ws_root: []const u8, approver: Approver, targets: Targets) PlanMode {
        return .{ .gpa = gpa, .agent = agent, .ws_root = ws_root, .approver = approver, .targets = targets };
    }

    pub fn deinit(pm: *PlanMode) void {
        pm.setPlanTargets(null);
        if (pm.plan) |p| pm.gpa.free(p);
        pm.plan = null;
    }

    /// Plan mode on: the plan toolset, the pipeline check and the prompt
    /// addendum from the next request.
    pub fn enter(pm: *PlanMode) void {
        pm.setMode(.plan);
    }

    /// Plan mode off, in `mode`.
    pub fn leave(pm: *PlanMode, mode: PermissionMode) void {
        pm.setMode(if (mode == .plan) .default else mode);
    }

    pub fn setMode(pm: *PlanMode, mode: PermissionMode) void {
        pm.mode = mode;
        pm.agent.setPlanMode(mode == .plan);
        if (pm.targets.tools) |t| t.setMode(mode);
        if (pm.targets.state) |s| s.mode = promptMode(mode);
        if (pm.targets.mode_sink) |s| s.set(s.ctx, mode);
    }

    pub fn specs(pm: *PlanMode) []const proto.ToolSpec {
        pm.spec_list = .{.{
            .name = "exit_plan_mode",
            .description = description,
            .input_schema_json = schema,
            .read_only = true,
            .permission = .control,
            .handler = .{ .ctx = pm, .call = call },
        }};
        return &pm.spec_list;
    }

    pub fn source(pm: *PlanMode) registry.ToolSource {
        return .{ .name = "plan_mode", .ctx = pm, .list = list, .kind = .builtin };
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const pm: *PlanMode = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, pm.specs());
    }

    fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const pm: *PlanMode = @ptrCast(@alignCast(ctx));
        const a = c.arena;
        if (c.agent.session != pm.agent.ref.session or c.agent.agent != pm.agent.ref.agent)
            return errOut(a, "exit_plan_mode is for the main agent; report the plan instead.");
        if (pm.mode != .plan) return errOut(a, "Not in plan mode; carry on with the task.");
        const plan = str(c.input, "plan") orelse return errOut(a, "exit_plan_mode needs a \"plan\".");
        if (std.mem.trim(u8, plan, " \t\r\n").len == 0) return errOut(a, "The plan is empty.");

        pm.publishOwned(.plan_proposed, plan) catch return error.OutOfMemory;
        const answer = pm.approver.ask(pm.approver.ctx, c.io, a, plan) catch return error.Canceled;
        const mode, const clear = switch (answer.decision) {
            .keep_planning => |fb| return proto.ToolOutput.text(a, if (fb) |f|
                std.fmt.allocPrint(a, "The user wants to keep planning. Their feedback:\n{s}", .{f}) catch return error.OutOfMemory
            else
                "The user wants to keep planning. Ask what to change if it is unclear.", false) catch error.OutOfMemory,
            .approve => |m| .{ m, false },
            .approve_clear_context => |m| .{ m, true },
        };
        const final = answer.edited_plan orelse plan;
        const path = pm.approve(c.io, a, final, mode) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return errOut(a, std.fmt.allocPrint(a, "The plan was approved but could not be saved: {s}", .{@errorName(e)}) catch return error.OutOfMemory),
        };
        if (clear) {
            const text = std.fmt.allocPrint(a, "Implement this approved plan (saved at {s}):\n\n{s}", .{ path, final }) catch return error.OutOfMemory;
            pm.agent.clearContextTo(text) catch return error.OutOfMemory;
        }
        var out: std.ArrayList(u8) = .empty;
        out.print(a, "Plan approved; mode is now {s}. Proceed.", .{modeName(mode)}) catch return error.OutOfMemory;
        if (answer.edited_plan != null) out.print(a, " The user edited the plan; follow this version:\n\n{s}", .{final}) catch return error.OutOfMemory;
        return proto.ToolOutput.text(a, out.items, false) catch error.OutOfMemory;
    }

    /// Saves the plan, publishes `plan_approved` and switches to `mode`.
    /// Returns the plan file's path (in `arena`).
    pub fn approve(pm: *PlanMode, io: Io, arena: Allocator, plan: []const u8, mode: PermissionMode) ![]const u8 {
        const path = try planPath(arena, pm.ws_root, pm.agent.ref.session);
        try writePlan(io, path, plan);
        const owned = try pm.gpa.dupe(u8, plan);
        pm.setPlanTargets(owned);
        if (pm.plan) |p| pm.gpa.free(p);
        pm.plan = owned;
        if (pm.targets.title) |t| if (planTitle(plan)) |title| t.set(t.ctx, title);
        {
            pm.agent.alloc_mutex.lockUncancelable(pm.agent.io);
            defer pm.agent.alloc_mutex.unlock(pm.agent.io);
            const ar = pm.agent.arena.allocator();
            pm.agent.publish(.{ .plan_approved = .{ .mode = modeName(mode), .path = try ar.dupe(u8, path) } });
        }
        pm.leave(mode);
        return path;
    }

    fn setPlanTargets(pm: *PlanMode, plan: ?[]const u8) void {
        if (pm.targets.state) |s| s.plan = plan;
        if (pm.targets.compaction) |l| l.reinject.plan = plan;
    }

    fn publishOwned(pm: *PlanMode, comptime tag: std.meta.Tag(@import("../loop/events.zig").AgentEvent), text: []const u8) Allocator.Error!void {
        pm.agent.alloc_mutex.lockUncancelable(pm.agent.io);
        defer pm.agent.alloc_mutex.unlock(pm.agent.io);
        const copy = try pm.agent.arena.allocator().dupe(u8, text);
        pm.agent.publish(@unionInit(@import("../loop/events.zig").AgentEvent, @tagName(tag), copy));
    }
};

/// `<ws_root>/.zigguro/plans/<session>.md`.
pub fn planPath(arena: Allocator, ws_root: []const u8, session: proto.SessionId) Allocator.Error![]const u8 {
    const id = proto.agent_ref.format(session);
    return std.fs.path.join(arena, &.{ ws_root, ".zigguro", "plans", try std.fmt.allocPrint(arena, "{s}.md", .{&id}) });
}

/// Writes the plan through a temporary file and a rename.
pub fn writePlan(io: Io, path: []const u8, plan: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    try index.writeAtomic(io, dir, std.fs.path.basename(path), plan);
}

/// The plan's first heading, or else its first line, without `#`s.
pub fn planTitle(plan: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, plan, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') return clip(std.mem.trim(u8, std.mem.trimStart(u8, line, "#"), " \t"));
        if (first == null) first = line;
    }
    return if (first) |f| clip(f) else null;
}

fn clip(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (s.len <= 80) return s;
    var end: usize = 80;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

pub fn modeName(m: PermissionMode) []const u8 {
    return switch (m) {
        .default => "default",
        .accept_edits => "accept-edits",
        .plan => "plan",
        .bypass_permissions => "bypass",
        .dont_ask => "dont-ask",
    };
}

fn promptMode(m: PermissionMode) assembler.Mode {
    return switch (m) {
        .default, .dont_ask => .default,
        .plan => .plan,
        .accept_edits => .accept_edits,
        .bypass_permissions => .bypass,
    };
}

/// The terminal approver: shows the plan and asks
/// `[a]pprove+auto-accept / [y] approve / [n] keep planning`.
pub const CliApprover = struct {
    in: *Io.Reader,
    out: *Io.Writer,

    pub fn approver(c: *CliApprover) Approver {
        return .{ .ctx = c, .ask = ask };
    }

    fn ask(ctx: *anyopaque, _: Io, arena: Allocator, plan: []const u8) Io.Cancelable!Answer {
        const c: *CliApprover = @ptrCast(@alignCast(ctx));
        render(c.out, plan) catch {};
        while (true) {
            c.out.writeAll("Approve this plan? [a] approve and auto-accept edits  [y] approve  [n] keep planning: ") catch {};
            c.out.flush() catch {};
            const line = readLine(c.in, arena) orelse return .{ .decision = .{ .keep_planning = null } };
            const choice = std.mem.trim(u8, line, " \t\r");
            if (eqlAny(choice, &.{ "a", "A" })) return .{ .decision = .{ .approve = .accept_edits } };
            if (eqlAny(choice, &.{ "y", "Y", "yes" })) return .{ .decision = .{ .approve = .default } };
            if (eqlAny(choice, &.{ "n", "N", "no" })) {
                c.out.writeAll("What should change? (Enter to skip): ") catch {};
                c.out.flush() catch {};
                const fb = std.mem.trim(u8, readLine(c.in, arena) orelse "", " \t\r");
                return .{ .decision = .{ .keep_planning = if (fb.len > 0) fb else null } };
            }
        }
    }

    pub fn render(w: *Io.Writer, plan: []const u8) Io.Writer.Error!void {
        try w.writeAll("\n── Proposed plan ──────────────────────────\n");
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, plan, "\n"), '\n');
        while (lines.next()) |l| try w.print("│ {s}\n", .{l});
        try w.writeAll("───────────────────────────────────────────\n");
    }

    fn readLine(in: *Io.Reader, arena: Allocator) ?[]const u8 {
        const line = in.takeDelimiter('\n') catch return null;
        return arena.dupe(u8, line orelse return null) catch null;
    }
};

fn eqlAny(s: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn errOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, true) catch error.OutOfMemory;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
