//! `zg agent` without `-p` on a terminal (E10.F10.S01.T01): a line REPL.
//! The terminal provides line editing; Ctrl-D exits. SIGINT cancels the
//! running turn and keeps the REPL; SIGTERM ends it. Slash commands come
//! with E10.F09.S04.T01; until then only `/exit`, `/quit` and `/plan`
//! (plan mode until a plan is approved) are known.

const std = @import("std");
const AgentManager = @import("../loop/Manager.zig");
const args_mod = @import("args.zig");
const exit_codes = @import("exit_codes.zig");
const runner = @import("runner.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ExitCode = exit_codes.ExitCode;

pub const prompt = "> ";

pub fn runRepl(io: Io, gpa: Allocator, mgr: *AgentManager, opts: args_mod.HeadlessOptions, out: *Io.Writer, in: *Io.Reader) !ExitCode {
    var r: runner.Runner = undefined;
    defer r.deinit();
    r.init(io, gpa, mgr, opts, out) catch |e| switch (e) {
        error.UnknownModel, error.SessionNotFound, error.NoSessionStore, error.SchemaNotFound, error.InvalidSchema => return runner.usageExit(opts, r.diag),
        error.SessionLocked => {
            r.note("the session is open in another process", .{});
            return .failed;
        },
        else => return e,
    };
    r.repl = true;
    while (r.signalled() == null) {
        r.writePrompt(prompt);
        const raw = in.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                _ = in.discardDelimiterInclusive('\n') catch break;
                r.note("line too long; ignored", .{});
                continue;
            },
            else => break,
        } orelse break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '/') {
            const cmd = line[1 .. std.mem.indexOfAny(u8, line, " \t") orelse line.len];
            if (std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "quit")) break;
            if (std.mem.eql(u8, cmd, "plan")) {
                if (r.enterPlanMode()) r.note("plan mode: read-only until you approve a plan", .{}) else r.note("plan mode needs exit_plan_mode, which this run does not have", .{});
                continue;
            }
            r.note("unknown command /{s}", .{cmd});
            continue;
        }
        // The line lives in `in`'s buffer; the agent copies it on submit.
        try r.runTurn(line);
        const o = r.outcome();
        if (o.finish) |f| switch (f) {
            .end_turn, .max_tokens => {},
            .canceled => r.note("turn canceled", .{}),
            .budget, .max_turns => r.note("stopped: budget reached", .{}),
            else => r.note("{s}", .{r.error_text orelse "the turn failed"}),
        };
    }
    r.endLine();
    return if (r.signalled()) |s| switch (s) {
        .interrupt => .interrupted,
        .terminate => .terminated,
    } else .ok;
}
