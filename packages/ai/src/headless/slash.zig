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
            r.note("model: {s}", .{r.model_id});
        }
    } else if (eql(u8, name, "clear")) {
        r.agent.truncate(0) catch {
            r.note("the agent is busy", .{});
            return .failed;
        };
        r.note("conversation cleared", .{});
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
