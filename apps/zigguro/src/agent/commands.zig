//! Slash commands and skills in the IDE (the E10.F09.S04.T01 front end).
//!
//! `AgentCommands` loads the workspace's skills and commands
//! (`.zigguro/` and `.claude/` `skills/` and `commands/`), registers the
//! built-in commands and user-invocable skills with the E15 command
//! palette (`zg_ai.ext.commands.PaletteSink` adapted to
//! `CommandRegistry.register`, as "AI: /name" in the Agent category), and
//! decides what a prompt line starting with `/` does (`handle`):
//!
//! - a skill expands (arguments substituted) into the prompt the agent
//!   gets; shell injections are not run yet (they need the terminal
//!   seam), so they show the disabled notice;
//! - `/help`, `/skills`, `/agents` and `/cost` answer with a note;
//! - `/plan [prompt]` and `/mode <mode>` switch modes (and send the
//!   prompt); `/clear` clears the conversation;
//! - the other built-ins say they are not available in the IDE yet.
//!
//! A palette command opens the agent panel and runs `/name`, or, for one
//! that takes arguments, puts `/name ` in the prompt (`on_palette`).

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_config = @import("zg_config");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const cmds = zg_ai.ext.commands;
const skills = zg_ai.ext.skills;
const builtin_commands = zg_ai.ext.builtin_commands;
const registry = zg_config.commands;

/// What a slash command does.
pub const Outcome = union(enum) {
    /// Send this to the agent.
    prompt: []const u8,
    /// Show this in the transcript.
    note: []const u8,
    /// Clear the conversation.
    clear,
};

/// The agent state commands act on (set when the agent starts).
pub const Target = struct {
    agent: *zg_ai.loop.Agent,
    plan_mode: ?*zg_ai.plan.PlanMode = null,
    agent_tools: ?*zg_ai.tools.AgentTools = null,
    subagents: []const zg_ai.subagent.defs.AgentDef = &.{},
};

pub const AgentCommands = struct {
    gpa: Allocator,
    io: Io,
    /// Skill roots, palette strings.
    arena: std.heap.ArenaAllocator,
    index: skills.SkillIndex,
    target: ?Target = null,
    /// A palette command ran: `name`, and whether it takes arguments.
    on_palette: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, name: []const u8, takes_args: bool) void } = null,

    /// Loads the skills of `project_dir`.
    pub fn init(gpa: Allocator, io: Io, project_dir: []const u8) !*AgentCommands {
        const c = try gpa.create(AgentCommands);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .index = .init(gpa, io) };
        errdefer c.arena.deinit();
        errdefer c.index.deinit();
        for (try skills.standardRoots(c.arena.allocator(), project_dir, null, null, true)) |r| try c.index.addRoot(r);
        return c;
    }

    pub fn deinit(c: *AgentCommands) void {
        c.index.deinit();
        c.arena.deinit();
        c.gpa.destroy(c);
    }

    /// The resolver over the built-ins and the skills.
    pub fn resolver(c: *AgentCommands) cmds.CommandRegistry {
        return .{ .index = &c.index };
    }

    // -- palette -------------------------------------------------------------

    /// One registered palette command.
    const Entry = struct {
        owner: *AgentCommands,
        name: []const u8,
        takes_args: bool,
    };

    /// Registers the built-ins and user-invocable skills with `reg`.
    pub fn registerPalette(c: *AgentCommands, reg: *registry.CommandRegistry) !void {
        var ctx: SinkCtx = .{ .c = c, .reg = reg };
        try cmds.registerWithPalette(c.arena.allocator(), .{ .ctx = &ctx, .add = SinkCtx.add }, &c.index, &builtin_commands.all);
    }

    const SinkCtx = struct {
        c: *AgentCommands,
        reg: *registry.CommandRegistry,

        fn add(ctx: *anyopaque, e: cmds.PaletteEntry) anyerror!void {
            const s: *SinkCtx = @ptrCast(@alignCast(ctx));
            const a = s.c.arena.allocator();
            const name = if (std.mem.startsWith(u8, e.id, "ai.skill.")) e.id["ai.skill.".len..] else e.id["ai.".len..];
            const entry = try a.create(Entry);
            entry.* = .{ .owner = s.c, .name = name, .takes_args = e.args_hint != null };
            _ = s.reg.register(.{
                .id = e.id,
                .title = e.title,
                .category = "Agent",
                .description = e.description,
                .source = .{ .builtin = "zigguro" },
                .handler = .{ .ctx = entry, .run = run },
            }) catch |err| switch (err) {
                // A skill with a built-in's name: the built-in wins.
                error.DuplicateId => {},
                else => return err,
            };
        }

        fn run(ctx: ?*anyopaque, _: *registry.Invocation) anyerror!void {
            const e: *Entry = @ptrCast(@alignCast(ctx.?));
            if (e.owner.on_palette) |h| h.f(h.ctx, e.name, e.takes_args);
        }
    };

    // -- prompt lines ----------------------------------------------------------

    /// What `line` does when it is a slash command (strings in `arena`);
    /// null when it is an ordinary prompt.
    pub fn handle(c: *AgentCommands, arena: Allocator, line: []const u8) !?Outcome {
        const inv = cmds.parse(line) orelse return null;
        const r = c.resolver();
        return switch (r.resolve(inv.name)) {
            .unknown => .{ .note = try std.fmt.allocPrint(arena, "Unknown command /{s}. /help lists the commands.", .{inv.name}) },
            .skill => |s| blk: {
                var why: []const u8 = "";
                const ex = skills.expand(c.io, arena, s, inv.args, .{ .disable_shell = true, .diag = &why }) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk .{ .note = try std.fmt.allocPrint(arena, "/{s} failed: {s}", .{ inv.name, if (why.len > 0) why else @errorName(e) }) },
                };
                break :blk .{ .prompt = ex.text };
            },
            .builtin => |b| try c.builtin(arena, b.name, inv.args),
        };
    }

    fn builtin(c: *AgentCommands, arena: Allocator, name: []const u8, args: []const u8) !Outcome {
        const eq = std.mem.eql;
        if (eq(u8, name, "help")) return .{ .note = try c.resolver().help(arena) };
        if (eq(u8, name, "skills")) return .{ .note = try c.skillList(arena) };
        const t = c.target orelse return .{ .note = "Start the agent first." };
        if (eq(u8, name, "clear")) return .clear;
        if (eq(u8, name, "cost")) {
            const s = t.agent.snapshot();
            const u = s.usage;
            return .{ .note = try std.fmt.allocPrint(arena, "{d} input and {d} output tokens ({d} read from cache), ${d:.2}.", .{ u.input, u.output, u.cache_read, @as(f64, @floatFromInt(s.cost_micros)) / 1e6 }) };
        }
        if (eq(u8, name, "agents")) {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, "Subagents:\n");
            for (t.subagents) |d| try out.print(arena, "  {s}  {s}\n", .{ d.name, d.description });
            if (t.subagents.len == 0) try out.appendSlice(arena, "  (none)\n");
            return .{ .note = out.items };
        }
        if (eq(u8, name, "plan")) {
            const pm = t.plan_mode orelse return .{ .note = "Plan mode is not available." };
            pm.enter();
            if (args.len > 0) return .{ .prompt = args };
            return .{ .note = "Plan mode: the agent plans and asks before changing anything." };
        }
        if (eq(u8, name, "mode")) {
            const m = std.meta.stringToEnum(zg_ai.tools.toolset.PermissionMode, args) orelse
                return .{ .note = try std.fmt.allocPrint(arena, "Unknown mode \"{s}\". Modes: {s}.", .{ args, modeNames() }) };
            if (t.plan_mode) |pm| {
                if (m == .plan) pm.enter() else pm.leave(m);
            } else if (t.agent_tools) |at| at.setMode(m);
            return .{ .note = try std.fmt.allocPrint(arena, "Permission mode: {t}.", .{m}) };
        }
        return .{ .note = try std.fmt.allocPrint(arena, "/{s} is not available in the IDE yet.", .{name}) };
    }

    fn skillList(c: *AgentCommands, arena: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const list = try c.index.list(arena);
        try out.appendSlice(arena, "Skills and commands:\n");
        for (list) |s| try out.print(arena, "  /{s}  {s}\n", .{ s.name, s.description });
        if (list.len == 0) try out.appendSlice(arena, "  (none: add them under .zigguro/skills or .zigguro/commands)\n");
        return out.items;
    }
};

fn modeNames() []const u8 {
    comptime var s: []const u8 = "";
    inline for (@typeInfo(zg_ai.tools.toolset.PermissionMode).@"enum".fields, 0..) |f, i| s = s ++ (if (i == 0) "" else ", ") ++ f.name;
    return s;
}

const testing = std.testing;

test "slash commands: built-ins, unknown names and ordinary prompts" {
    const gpa = testing.allocator;
    const c = try AgentCommands.init(gpa, testing.io, ".zig-cache/no-such-project");
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(try c.handle(a, "explain this file") == null);
    const help = (try c.handle(a, "/help")).?.note;
    try testing.expect(std.mem.indexOf(u8, help, "/plan [prompt]") != null);
    try testing.expect(std.mem.indexOf(u8, (try c.handle(a, "/nope")).?.note, "Unknown command /nope") != null);
    // Commands that act on the agent need one.
    try testing.expectEqualStrings("Start the agent first.", (try c.handle(a, "/cost")).?.note);
}

test "slash commands: a project command expands into the prompt" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".zigguro/commands");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/commands/greet.md", .data = "---\ndescription: Greets someone\n---\nSay hello to $ARGUMENTS.\n" });
    var buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const c = try AgentCommands.init(gpa, io, root);
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const out = (try c.handle(arena.allocator(), "/greet Ada")).?;
    try testing.expectEqualStrings("Say hello to Ada.", std.mem.trim(u8, out.prompt, " \n"));
    try testing.expect(std.mem.indexOf(u8, (try c.handle(arena.allocator(), "/skills")).?.note, "/greet  Greets someone") != null);

    // In the palette: built-ins and the command, which report back.
    var keys: zg_config.context.ContextKeyService = .init(gpa);
    defer keys.deinit();
    const reg = try registry.CommandRegistry.init(gpa, &keys, .{ .io = io });
    defer reg.deinit();
    try c.registerPalette(reg);
    const Seen = struct {
        name: [32]u8 = undefined,
        len: usize = 0,
        takes_args: bool = false,
        fn f(ctx: *anyopaque, name: []const u8, takes_args: bool) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(s.name[0..name.len], name);
            s.len = name.len;
            s.takes_args = takes_args;
        }
    };
    var seen: Seen = .{};
    c.on_palette = .{ .ctx = &seen, .f = Seen.f };
    try testing.expectEqualStrings("AI: /greet", reg.get(reg.lookup("ai.skill.greet").?).title);
    try reg.execute(reg.lookup("ai.help").?, null, .palette);
    try testing.expectEqualStrings("help", seen.name[0..seen.len]);
    try testing.expect(!seen.takes_args);
    try reg.execute(reg.lookup("ai.plan").?, null, .palette);
    try testing.expectEqualStrings("plan", seen.name[0..seen.len]);
    try testing.expect(seen.takes_args);
}
