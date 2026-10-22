//! The `skill` tool (E10.F09.S04.T01): progressive disclosure of skills
//! to the model. The description lists the skills the model may invoke;
//! a call expands one (`skills.expand`) and returns its body, its base
//! directory and its supporting files. `allowed-tools` go to a
//! `GrantSink` (an E16 session rule tagged with the skill, for the rest of
//! the turn); `context: fork` runs the expanded skill in a subagent and
//! returns its report.

const std = @import("std");
const proto = @import("zg_ai_proto");
const registry = @import("../tools/registry.zig");
const defs = @import("../subagent/defs.zig");
const subagent = @import("../subagent/runner.zig");
const skills = @import("skills.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const schema =
    \\{"type":"object","properties":{"name":{"type":"string","description":"The skill's name, as listed."},"args":{"type":"string","description":"Arguments, as the user would type them after /name."}},"required":["name"],"additionalProperties":false}
;

const intro = "Runs a skill: packaged instructions for a kind of task, with supporting files. When a task matches a skill's description, call this with the skill's name (and args) before starting, then follow what it returns.";

/// Pre-approves a skill's `allowed-tools` rules for the rest of the turn.
pub const GrantSink = struct {
    ctx: *anyopaque,
    grant: *const fn (ctx: *anyopaque, io: Io, agent: proto.AgentRef, skill: []const u8, rules: []const []const u8) void,
};

pub const SkillTool = struct {
    gpa: Allocator,
    index: *skills.SkillIndex,
    /// Everything but `owner` and the session id, set per call.
    expand: skills.ExpandCtx = .{},
    subagents: ?*subagent.SubagentRunner = null,
    grants: ?GrantSink = null,
    /// List the skills in the description (off when the app lists them in
    /// the system prompt through the assembler).
    list_in_description: bool = true,
    desc_arena: std.heap.ArenaAllocator,
    spec_list: [1]proto.ToolSpec = undefined,

    pub fn init(gpa: Allocator, index: *skills.SkillIndex) SkillTool {
        return .{ .gpa = gpa, .index = index, .desc_arena = .init(gpa) };
    }

    pub fn deinit(t: *SkillTool) void {
        t.desc_arena.deinit();
    }

    pub fn specs(t: *SkillTool) []const proto.ToolSpec {
        _ = t.desc_arena.reset(.retain_capacity);
        t.spec_list = .{.{
            .name = "skill",
            .description = t.describe(t.desc_arena.allocator()) catch intro,
            .input_schema_json = schema,
            .read_only = true,
            .permission = .control,
            .handler = .{ .ctx = t, .call = call },
        }};
        return &t.spec_list;
    }

    pub fn source(t: *SkillTool) registry.ToolSource {
        return .{ .name = "skill", .ctx = t, .list = list, .kind = .builtin };
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const t: *SkillTool = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, t.specs());
    }

    fn describe(t: *SkillTool, a: Allocator) Allocator.Error![]const u8 {
        if (!t.list_in_description) return intro;
        const listing = try t.index.modelListing(a, skills.max_listing_chars, &.{});
        if (listing.len == 0) return intro;
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "{s}\n\nSkills:\n", .{intro});
        for (listing) |s| try out.print(a, "- {s}: {s}\n", .{ s.name, s.description });
        return out.items;
    }

    fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const t: *SkillTool = @ptrCast(@alignCast(ctx));
        const a = c.arena;
        const name = str(c.input, "name") orelse return errOut(a, "skill needs a \"name\".");
        const s = t.index.find(name) orelse return errOut(a, try std.fmt.allocPrint(a, "Unknown skill {s}.", .{name}));
        if (s.disable_model_invocation) return errOut(a, try std.fmt.allocPrint(a, "The {s} skill can only be run by the user (/{s}).", .{ name, name }));

        var why: []const u8 = "";
        var ectx = t.expand;
        ectx.owner = c.agent;
        const sid = proto.agent_ref.format(c.agent.session);
        ectx.vars.session_id = &sid;
        ectx.diag = &why;
        const ex = skills.expand(c.io, a, s, str(c.input, "args") orelse "", ectx) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => errOut(a, try std.fmt.allocPrint(a, "The {s} skill was not run: {s}", .{ name, why })),
        };
        if (t.grants) |g| if (s.allowed_tools.len > 0) g.grant(g.ctx, c.io, c.agent, s.name, s.allowed_tools);

        if (s.context == .fork) return t.fork(c, s, ex.text);

        var out: std.ArrayList(u8) = .empty;
        if (s.dir.len > 0) try out.print(a, "Base directory for this skill: {s}\n\n", .{s.dir});
        try out.appendSlice(a, ex.text);
        const files = s.supportingFiles(c.io, a) catch &.{};
        if (files.len > 0) {
            try out.appendSlice(a, "\n\nSupporting files (read them when the instructions call for them):\n");
            for (files) |f| try out.print(a, "- {s}\n", .{f});
        }
        if (s.allowed_tools.len > 0 and t.grants != null) {
            try out.appendSlice(a, "\n\nPre-approved for the rest of this turn: ");
            for (s.allowed_tools, 0..) |r, k| try out.print(a, "{s}{s}", .{ if (k > 0) ", " else "", r });
        }
        return proto.ToolOutput.text(a, out.items, false) catch error.OutOfMemory;
    }

    fn fork(t: *SkillTool, c: *proto.ToolCall, s: *const skills.Skill, prompt: []const u8) proto.ToolError!proto.ToolOutput {
        const a = c.arena;
        const r = t.subagents orelse return errOut(a, "This skill runs in a subagent, which is not available here.");
        const agent_name = s.agent orelse "general";
        const def = findAgent(r.defs, agent_name) orelse return errOut(a, try std.fmt.allocPrint(a, "The {s} skill needs the {s} agent, which is not defined.", .{ s.name, agent_name }));
        const parent = r.mgr.get(c.agent) orelse return errOut(a, "skill: the calling agent is gone.");
        r.acquire(c.io) catch return error.Canceled;
        defer r.release();
        const child = r.spawn(parent, def, prompt, .{ .tool_call = c.id }) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => errOut(a, try std.fmt.allocPrint(a, "Could not start the {s} agent: {s}", .{ agent_name, @errorName(e) })),
        };
        const report = r.awaitReport(c.io, a, child) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => errOut(a, try std.fmt.allocPrint(a, "The {s} agent failed: {s}", .{ agent_name, @errorName(e) })),
        };
        const failed = if (report.finish) |f| f != .end_turn else false;
        return proto.ToolOutput.text(a, report.text, failed) catch error.OutOfMemory;
    }
};

/// Exact, then ignoring case (Claude Code skills say `agent: Explore`).
fn findAgent(ds: []const defs.AgentDef, name: []const u8) ?*const defs.AgentDef {
    if (defs.find(ds, name)) |d| return d;
    for (ds) |*d| if (std.ascii.eqlIgnoreCase(d.name, name)) return d;
    return null;
}

fn errOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, true) catch error.OutOfMemory;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
