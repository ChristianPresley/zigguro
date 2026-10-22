//! `zg agent -p` and `--input-format stream-json` (E10.F10.S01.T01): one
//! prompt, or a stream of protocol lines, then exit with a stable code.

const std = @import("std");
const AgentManager = @import("../loop/Manager.zig");
const args_mod = @import("args.zig");
const exit_codes = @import("exit_codes.zig");
const runner = @import("runner.zig");
const slash = @import("slash.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ExitCode = exit_codes.ExitCode;

/// Runs a print-mode session. Text from a piped stdin is attached to the
/// prompt; with stream-json input, stdin carries the turns instead.
pub fn runPrint(io: Io, gpa: Allocator, mgr: *AgentManager, opts: args_mod.HeadlessOptions, out: *Io.Writer, in: *Io.Reader) !ExitCode {
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
    // `-p "/name args"` runs a skill.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    if (opts.prompt) |p| switch (try slash.run(&r, scratch.allocator(), p, false)) {
        .not_command => {},
        .prompt => |text| r.opts.prompt = text,
        .handled, .exit, .failed => return .usage,
    };
    if (opts.streamInput()) {
        try r.streamInput(in);
    } else {
        const text = r.promptFrom(in) catch |e| switch (e) {
            error.NoPrompt => return runner.usageExit(opts, r.diag),
            else => return e,
        };
        try r.runTurn(text);
        if (r.signalled() == null) try r.checkStructured();
    }
    return r.finishRun();
}
