//! Slash commands in `zg agent` (E10.F09.S04.T01): `/name args` runs a
//! user-invocable skill (expanded into the prompt, its `allowed-tools`
//! granted for that turn) or a built-in command. The REPL runs both;
//! `-p` runs skills only, as one-shot runs have no conversation to
//! manage.

const std = @import("std");
const commands = @import("../ext/commands.zig");
const skills_mod = @import("../ext/skills.zig");
const args_mod = @import("args.zig");
const runner_mod = @import("runner.zig");
const guarded = @import("../provider/guarded.zig");
const proto = @import("zg_ai_proto");
const index_mod = @import("../session/index.zig");
const fork_mod = @import("../session/fork.zig");
const export_mod = @import("../session/export.zig");
const rewind_mod = @import("../session/rewind.zig");

const Allocator = std.mem.Allocator;
const Runner = runner_mod.Runner;

pub const Outcome = union(enum) {
    /// Not a slash command: send the line as it is.
    not_command,
    /// Send this prompt (an expanded skill, or `/plan <prompt>`).
    prompt: []const u8,
    /// Done; nothing to send.
    handled,
    /// `/exit` or `/quit`.
    exit,
    /// It could not run; the reason was reported.
    failed,
};

/// Runs `line` if it is a slash command. `repl` allows built-ins.
/// Strings live in `arena`.
pub fn run(r: *Runner, arena: Allocator, line: []const u8, repl: bool) !Outcome {
    const inv = commands.parse(line) orelse return .not_command;
    if (repl and (std.mem.eql(u8, inv.name, "exit") or std.mem.eql(u8, inv.name, "quit"))) return .exit;
    const reg: commands.CommandRegistry = .{ .index = if (r.opts.env.skills) |sk| sk.index else null };
    switch (reg.resolve(inv.name)) {
        .unknown => {
            // A one-shot prompt such as "/tmp is full" is just text.
            if (!repl) return .not_command;
            r.note("unknown command /{s}; /help lists them", .{inv.name});
            return .failed;
        },
        .skill => |s| return runSkill(r, arena, s, inv.args),
        .builtin => |b| {
            if (!repl) {
                r.note("/{s} works only in the REPL", .{b.name});
                return .failed;
            }
            return builtin(r, arena, reg, b.name, inv.args);
        },
    }
}

fn runSkill(r: *Runner, arena: Allocator, s: *const skills_mod.Skill, args: []const u8) !Outcome {
    var why: []const u8 = "";
    var ctx = r.expandCtx();
    ctx.diag = &why;
    const ex = skills_mod.expand(r.io, arena, s, args, ctx) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return .failed,
        else => {
            r.note("/{s} was not run: {s}", .{ s.name, why });
            return .failed;
        },
    };
    if (s.allowed_tools.len > 0) try r.perm.grant(r.io, s.allowed_tools);
    return .{ .prompt = ex.text };
}

fn builtin(r: *Runner, arena: Allocator, reg: commands.CommandRegistry, name: []const u8, args: []const u8) !Outcome {
    const eql = std.mem.eql;
    if (eql(u8, name, "help")) {
        r.say(try std.mem.concat(arena, u8, &.{ try reg.help(arena), "  /exit  Leave the REPL\n" }));
    } else if (eql(u8, name, "plan")) {
        if (!r.enterPlanMode()) {
            r.note("plan mode needs exit_plan_mode, which this run does not have", .{});
            return .failed;
        }
        r.note("plan mode: read-only until you approve a plan", .{});
        if (args.len > 0) return .{ .prompt = args };
    } else if (eql(u8, name, "mode")) {
        const m = args_mod.permissionMode(args) orelse {
            r.note("/mode takes default, accept-edits, plan, dont-ask or bypass", .{});
            return .failed;
        };
        r.setMode(m);
        r.note("permission mode: {s}", .{runner_mod.modeName(m)});
    } else if (eql(u8, name, "model")) {
        if (args.len == 0) {
            r.say(try std.fmt.allocPrint(arena, "Model: {s}", .{r.model_id}));
        } else {
            const info = r.mgr.deps.registry.resolve(args) orelse {
                r.note("unknown model {s}", .{args});
                return .failed;
            };
            r.model_id = try r.arena.allocator().dupe(u8, info.id);
            r.agent.cfg.model = r.model_id;
            if (r.opts.env.context) |c| {
                const cm = r.mgr.deps.registry.modelForRole(info, .compaction);
                if (r.mgr.deps.providers.get(cm)) |p| c.setCompactionModel(p, cm);
            }
            r.note("model: {s}", .{r.model_id});
        }
    } else if (eql(u8, name, "clear")) {
        r.agent.truncate(0) catch {
            r.note("the agent is busy", .{});
            return .failed;
        };
        r.note("conversation cleared", .{});
    } else if (eql(u8, name, "compact")) {
        r.note("compacting the conversation...", .{});
        const res = r.agent.compact(if (args.len > 0) args else null) catch |e| {
            switch (e) {
                error.NoCompaction => r.note("this run cannot compact the conversation", .{}),
                error.NothingToCompact => r.note("nothing to compact yet", .{}),
                error.Busy => r.note("the agent is busy", .{}),
                else => r.note("compaction failed: {s}", .{@errorName(e)}),
            }
            return .failed;
        };
        if (res.fallback) {
            r.note("the summary failed, so old tool results were cleared instead ({d} -> {d} tokens)", .{ res.tokens_before, res.tokens_after });
        } else r.note("conversation compacted ({d} -> {d} tokens)", .{ res.tokens_before, res.tokens_after });
    } else if (eql(u8, name, "context")) {
        r.say(try contextText(r, arena));
    } else if (eql(u8, name, "memory")) {
        r.say(try memoryText(r, arena));
    } else if (eql(u8, name, "resume")) {
        return resumeCmd(r, arena, args);
    } else if (eql(u8, name, "branch")) {
        return branchCmd(r, arena, args);
    } else if (eql(u8, name, "rename")) {
        if (args.len == 0) {
            r.note("/rename takes a name", .{});
            return .failed;
        }
        if (!try setName(r, r.currentSession(), args)) return .failed;
        r.note("session renamed to {s}", .{args});
    } else if (eql(u8, name, "export")) {
        return exportCmd(r, arena, args);
    } else if (eql(u8, name, "rewind")) {
        return rewindCmd(r, arena, args);
    } else if (eql(u8, name, "init")) {
        return .{ .prompt = if (args.len > 0) try std.mem.concat(arena, u8, &.{ init_prompt, "\n\nAlso: ", args }) else init_prompt };
    } else if (eql(u8, name, "agents")) {
        var out: std.ArrayList(u8) = .empty;
        for (r.opts.env.agents) |d| try out.print(arena, "{s}  ({s})  {s}\n", .{ d.name, @tagName(d.source), firstLine(d.description) });
        r.say(if (out.items.len > 0) out.items else "No subagents.");
    } else if (eql(u8, name, "hooks")) {
        var out: std.ArrayList(u8) = .empty;
        if (r.opts.env.hooks) |e| for (try e.list(arena)) |h| try out.print(arena, "{s}  [{s}{s}{s}]  {s}  {s}\n", .{
            @tagName(h.event),
            @tagName(h.layer),
            if (h.scope != null) ": " else "",
            h.scope orelse "",
            h.matcher,
            h.command,
        });
        r.say(if (out.items.len > 0) out.items else "No hooks.");
    } else if (eql(u8, name, "cost")) {
        const snap = r.agent.snapshot();
        const u = snap.usage;
        r.say(try std.fmt.allocPrint(arena, "Tokens: {d} in, {d} out, {d} cache read, {d} cache write\nCost: ${d:.4}{s}", .{
            u.input,
            u.output,
            u.cache_read,
            u.cache_write_5m + u.cache_write_1h,
            @as(f64, @floatFromInt(snap.cost_micros)) / 1e6,
            if (snap.estimated) " (estimated)" else "",
        }));
    } else if (eql(u8, name, "skills")) {
        const sk = r.opts.env.skills orelse {
            r.say("No skills.");
            return .handled;
        };
        var out: std.ArrayList(u8) = .empty;
        for (try sk.index.list(arena)) |s| try out.print(arena, "/{s}{s}{s}  {s}{s}\n", .{
            s.name,
            if (s.argument_hint != null) " " else "",
            s.argument_hint orelse "",
            s.description,
            if (!s.user_invocable) " (model only)" else if (s.disable_model_invocation) " (user only)" else "",
        });
        r.say(if (out.items.len > 0) out.items else "No skills.");
    } else {
        r.note("/{s} is not available in zg agent yet", .{name});
        return .failed;
    }
    return .handled;
}

/// `/context`: the next request's size against the window, by section
/// when the run assembles its context.
fn contextText(r: *Runner, arena: Allocator) ![]const u8 {
    const req = try r.agent.nextRequest(arena);
    const info = r.mgr.deps.registry.resolve(r.model_id);
    const window: u64 = if (info) |m| m.context_window else 0;
    var out: std.ArrayList(u8) = .empty;
    if (r.opts.env.context) |c| {
        const rep = c.report();
        try out.print(arena, "Context: {d} of {d} tokens ({d}%)\n", .{ rep.total_tokens, window, pct(rep.total_tokens, window) });
        var w: usize = 0;
        for (rep.sections) |sec| w = @max(w, sec.name.len);
        for (rep.sections) |sec| {
            try out.print(arena, "  {s}", .{sec.name});
            try out.appendNTimes(arena, ' ', w - sec.name.len + 2);
            try out.print(arena, "{d}\n", .{sec.tokens});
        }
        if (rep.cleared > 0) try out.print(arena, "  ({d} old tool results cleared)\n", .{rep.cleared});
    } else {
        const n = guarded.estimateInputTokens(&req);
        try out.print(arena, "Context: about {d} of {d} tokens ({d}%)\n", .{ n, window, pct(n, window) });
    }
    return out.items;
}

fn pct(n: u64, of: u64) u64 {
    return if (of == 0) 0 else n * 100 / of;
}

/// `/memory`: the instruction files in the prompt, with their notes.
fn memoryText(r: *Runner, arena: Allocator) ![]const u8 {
    const c = r.opts.env.context orelse return "No memory files are loaded.";
    const set = c.memorySet();
    if (set.files.len == 0 and set.notes.len == 0) return "No memory files are loaded.";
    var out: std.ArrayList(u8) = .empty;
    for (set.files) |f| try out.print(arena, "{s}  ({s}, {d} tokens{s})\n", .{ f.path, @tagName(f.scope), f.tokens, if (f.truncated) ", truncated" else "" });
    for (set.notes) |n| try out.print(arena, "note: {s}\n", .{n});
    return out.items;
}

/// `/resume`: lists saved sessions; `/resume <id|name>` continues one.
fn resumeCmd(r: *Runner, arena: Allocator, args: []const u8) !Outcome {
    if (r.opts.env.store == null) {
        r.note("sessions are not saved here, so there is nothing to resume", .{});
        return .failed;
    }
    if (args.len == 0) {
        const ix = r.opts.env.index orelse {
            r.say("No saved sessions.");
            return .handled;
        };
        var list: std.ArrayList(*const index_mod.SessionMeta) = .empty;
        try ix.list(arena, .{}, &list);
        var out: std.ArrayList(u8) = .empty;
        const current = r.currentSession();
        for (list.items[0..@min(list.items.len, 20)]) |m| try out.print(arena, "{s}{s}  {d} messages  {s}\n", .{
            if (m.id == current) "* " else "  ",
            &proto.agent_ref.format(m.id),
            m.messages,
            if (m.label().len > 0) m.label() else "(untitled)",
        });
        r.say(if (out.items.len > 0) out.items else "No saved sessions.");
        return .handled;
    }
    const id = r.lookupSession(args) orelse {
        r.note("no session named {s}", .{args});
        return .failed;
    };
    if (id == r.currentSession()) {
        r.note("already in that session", .{});
        return .handled;
    }
    r.switchSession(id, false) catch |e| {
        r.note("could not resume {s} ({s}); started a new session", .{ args, @errorName(e) });
        return .failed;
    };
    r.note("resumed {s}: {d} messages", .{ &r.session_text, r.agent.messages().len });
    return .handled;
}

/// `/branch [name]`: continues in a fork of this session; the original
/// stays as it was.
fn branchCmd(r: *Runner, arena: Allocator, args: []const u8) !Outcome {
    _ = arena;
    if (r.opts.env.store == null or r.sessionWriter() == null) {
        r.note("sessions are not saved here, so there is nothing to branch", .{});
        return .failed;
    }
    const from = r.currentSession();
    const from_text = proto.agent_ref.format(from);
    r.switchSession(from, true) catch |e| {
        r.note("could not branch ({s}); started a new session", .{@errorName(e)});
        return .failed;
    };
    if (args.len > 0) _ = try setName(r, r.currentSession(), args);
    r.note("branched into {s}; {s} is unchanged", .{ &r.session_text, &from_text });
    return .handled;
}

/// Names session `id` in the index.
fn setName(r: *Runner, id: proto.SessionId, name: []const u8) !bool {
    const ix = r.opts.env.index orelse {
        r.note("sessions are not saved here, so they cannot be named", .{});
        return false;
    };
    const now = r.opts.env.clock.now(r.io);
    var m: index_mod.SessionMeta = ix.get(id) orelse .{ .id = id, .created_ms = @intCast(proto.agent_ref.timestampMs(id)), .updated_ms = now, .origin = .cli, .model = r.model_id };
    m.name = name;
    try ix.upsert(m);
    ix.save() catch |e| r.note("could not save the session index: {s}", .{@errorName(e)});
    return true;
}

/// `/export [file]`: the conversation as Markdown, to the file or stdout.
fn exportCmd(r: *Runner, arena: Allocator, args: []const u8) !Outcome {
    const store = r.opts.env.store orelse {
        r.note("sessions are not saved here, so there is nothing to export", .{});
        return .failed;
    };
    const w = r.sessionWriter() orelse {
        r.note("sessions are not saved here, so there is nothing to export", .{});
        return .failed;
    };
    try w.sync();
    const id = r.currentSession();
    const l = fork_mod.openChain(store, r.io, id, .{ .mode = .full, .repair = false }) catch |e| {
        r.note("could not read the session: {s}", .{@errorName(e)});
        return .failed;
    };
    defer l.deinit();
    var title: ?[]const u8 = null;
    if (r.opts.env.index) |ix| if (ix.get(id)) |m| if (m.label().len > 0) {
        title = try arena.dupe(u8, m.label());
    };
    var md: std.Io.Writer.Allocating = .init(arena);
    try export_mod.exportMarkdown(r.gpa, l, &md.writer, .{ .title = title });
    if (args.len == 0) {
        r.say(md.written());
        return .handled;
    }
    std.Io.Dir.cwd().writeFile(r.io, .{ .sub_path = args, .data = md.written() }) catch |e| {
        r.note("could not write {s}: {s}", .{ args, @errorName(e) });
        return .failed;
    };
    r.note("exported to {s}", .{args});
    return .handled;
}

/// `/rewind`: lists the prompts; `/rewind <n>` drops prompt n and
/// everything after it, and prints its text to send again.
fn rewindCmd(r: *Runner, arena: Allocator, args: []const u8) !Outcome {
    const msgs = r.agent.messages();
    var prompts: std.ArrayList(u32) = .empty;
    for (msgs, 0..) |m, i| if (isPrompt(m)) try prompts.append(arena, @intCast(i));
    if (args.len == 0) {
        if (prompts.items.len == 0) {
            r.say("Nothing to rewind.");
            return .handled;
        }
        var out: std.ArrayList(u8) = .empty;
        for (prompts.items, 1..) |i, n| {
            const text = try msgs[i].text(arena);
            const line = std.mem.sliceTo(text, '\n');
            try out.print(arena, "{d}. {s}{s}\n", .{ n, line[0..@min(line.len, 72)], if (line.len > 72 or line.len < text.len) "..." else "" });
        }
        try out.appendSlice(arena, "/rewind <n> goes back to before prompt n.\n");
        r.say(out.items);
        return .handled;
    }
    const n = std.fmt.parseInt(usize, args, 10) catch 0;
    if (n == 0 or n > prompts.items.len) {
        r.note("/rewind takes a prompt number from 1 to {d}", .{prompts.items.len});
        return .failed;
    }
    const rep = rewind_mod.rewind(r.agent, r.io, arena, .{ .index = prompts.items[n - 1] }, .conversation, null, .{ .log = r.sessionWriter() }) catch |e| {
        r.note("could not rewind: {s}", .{@errorName(e)});
        return .failed;
    };
    r.note("rewound to before prompt {d}; it was:", .{n});
    r.say(rep.prompt_text orelse "");
    return .handled;
}

fn isPrompt(m: proto.Message) bool {
    if (m.role != .user or m.meta.synthetic) return false;
    for (m.content) |b| if (b == .tool_result) return false;
    return true;
}

/// `/init`: what the model is asked to do.
const init_prompt =
    \\Look through this project and write an AGENTS.md at its root for coding agents that work on it. Cover:
    \\- the commands to build, test, lint and format, including how to run a single test;
    \\- the architecture: the main parts, where they live and how they fit together, beyond what a directory listing shows;
    \\- conventions that are not obvious from the code: commit rules, naming, error handling, testing patterns.
    \\Read the README and any existing CLAUDE.md, AGENTS.md, ZIGGURO.md, .cursor/rules or .github/copilot-instructions.md first, and keep what is still true. If an AGENTS.md exists, suggest improvements to it instead of replacing it. Keep it short: no generic advice, and nothing a reader can find in a minute.
;

fn firstLine(s: []const u8) []const u8 {
    return std.mem.sliceTo(s, '\n');
}
