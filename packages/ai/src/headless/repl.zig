//! `zg agent` without `-p` on a terminal (E10.F10.S01.T01): a line REPL.
//! The terminal provides line editing; Ctrl-D exits. SIGINT cancels the
//! running turn and keeps the REPL; SIGTERM ends it. `/name args` runs a
//! skill or a built-in command (`slash.zig`); `/exit` and `/quit` leave.

const std = @import("std");
const AgentManager = @import("../loop/Manager.zig");
const args_mod = @import("args.zig");
const exit_codes = @import("exit_codes.zig");
const runner = @import("runner.zig");
const slash = @import("slash.zig");

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
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const text = switch (try slash.run(&r, scratch.allocator(), line, true)) {
            .not_command => line,
            .prompt => |p| p,
            .handled, .failed => continue,
            .exit => break,
        };
        // The line lives in `in`'s buffer; the agent copies it on submit.
        try r.runTurn(text);
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
