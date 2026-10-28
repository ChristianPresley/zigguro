//! The `runInTerminal` reverse request (E07.F06.S02.T02): the adapter
//! asks for the debuggee to start in a terminal.
//!
//! - The debuggee runs in the manager's `TerminalLauncher` (the app's
//!   integrated terminal over E06, or pipes in the headless host). An
//!   `external` request falls back to the integrated terminal (logged
//!   once) when no external terminal is configured.
//! - `args` run directly, without a shell, unless
//!   `argsCanBeInterpretedByShell`: then they are joined into one line
//!   for the platform shell (`/bin/sh -c`, cmd.exe `/d /s /c`), so that
//!   `$VAR`, redirections and pipes work. Only an argument with
//!   whitespace (or an empty one) is put in double quotes; nothing else
//!   is escaped.
//! - `env` entries with a `null` value unset the variable (`applyEnv`).
//! - Security (E16): an untrusted workspace refuses the request, and the
//!   spawn goes through the manager's `SpawnPolicy` (a denial is the
//!   response's message; a sandbox wrapper and its variables apply).
//!
//! The response carries `processId` and `shellProcessId` when known.

const std = @import("std");
const builtin = @import("builtin");
const zg_lsp = @import("zg_lsp");
const DapConnection = @import("../conn/DapConnection.zig");
const shell_quote = @import("../tasks/shell_quote.zig");
const DebugSession = @import("DebugSession.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ServerProcess = zg_lsp.client.ServerProcess;
const log = std.log.scoped(.dap_session);

pub const Kind = enum { integrated, external };

pub const EnvEntry = struct {
    name: []const u8,
    /// Null unsets the variable.
    value: ?[]const u8,
};

pub const RunInTerminalSpec = struct {
    kind: Kind,
    title: ?[]const u8 = null,
    cwd: []const u8,
    /// The adapter's `args`, as sent.
    args: []const []const u8,
    env: []const EnvEntry = &.{},
    args_can_be_interpreted_by_shell: bool = false,
    /// What to spawn: `args`, or the shell running them joined, after the
    /// spawn policy's wrapper.
    argv: []const []const u8,
    /// The spawn policy's variable allowlist (null keeps all).
    env_allow: ?[]const []const u8 = null,
};

pub const LaunchResult = struct {
    process_id: ?i64 = null,
    shell_process_id: ?i64 = null,
};

/// Starts the debuggee. Runs on a session worker; may block until the
/// process has started.
pub const TerminalLauncher = struct {
    ctx: ?*anyopaque,
    launch: *const fn (ctx: ?*anyopaque, spec: *const RunInTerminalSpec) anyerror!LaunchResult,
    /// An external terminal emulator is configured
    /// (`terminal.external.*`).
    external: bool = false,
};

/// The request's arguments as sent.
const Wire = struct {
    kind: ?[]const u8 = null,
    title: ?[]const u8 = null,
    cwd: []const u8 = "",
    args: []const []const u8 = &.{},
    env: ?std.json.Value = null,
    argsCanBeInterpretedByShell: bool = false,
};

pub const ParseError = error{ OutOfMemory, InvalidArguments };

/// Decodes the request's `arguments` for `os` (which shell joins them).
pub fn parse(a: Allocator, bytes: []const u8, os: std.Target.Os.Tag) ParseError!RunInTerminalSpec {
    const w = std.json.parseFromSliceLeaky(Wire, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    if (w.args.len == 0) return error.InvalidArguments;
    var env: std.ArrayList(EnvEntry) = .empty;
    if (w.env) |v| switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| try env.append(a, .{ .name = e.key_ptr.*, .value = switch (e.value_ptr.*) {
                .string => |s| s,
                .null => null,
                else => return error.InvalidArguments,
            } });
        },
        .null => {},
        else => return error.InvalidArguments,
    };
    const kind: Kind = if (w.kind) |k| (if (std.mem.eql(u8, k, "external")) .external else .integrated) else .integrated;
    return .{
        .kind = kind,
        .title = w.title,
        .cwd = w.cwd,
        .args = w.args,
        .env = env.items,
        .args_can_be_interpreted_by_shell = w.argsCanBeInterpretedByShell,
        .argv = if (w.argsCanBeInterpretedByShell) try shellArgv(a, w.args, os) else w.args,
    };
}

/// The argv that runs `args` joined in the platform shell.
pub fn shellArgv(a: Allocator, args: []const []const u8, os: std.Target.Os.Tag) Allocator.Error![]const []const u8 {
    const style = shell_quote.styleOf(null, os);
    return shell_quote.shellArgv(a, try joinForShell(a, args, style), null, null, os);
}

/// `args` joined with spaces; an argument with whitespace, or an empty
/// one, in double quotes. Shell syntax in the arguments is kept.
pub fn joinForShell(a: Allocator, args: []const []const u8, style: shell_quote.Style) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (args, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
        const plain = arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\r\n") == null;
        if (plain) {
            w.writeAll(arg) catch return error.OutOfMemory;
            continue;
        }
        w.writeByte('"') catch return error.OutOfMemory;
        for (arg) |c| {
            if (c == '"') w.writeAll(switch (style) {
                .posix => "\\\"",
                .cmd => "\"\"",
                .pwsh => "`\"",
            }) catch return error.OutOfMemory else w.writeByte(c) catch return error.OutOfMemory;
        }
        w.writeByte('"') catch return error.OutOfMemory;
    }
    return out.written();
}

/// Applies `entries` to `env`: sets the values, removes the nulls.
pub fn applyEnv(env: *std.process.Environ.Map, entries: []const EnvEntry) Allocator.Error!void {
    for (entries) |e| {
        if (e.value) |v| try env.put(e.name, v) else _ = env.swapRemove(e.name);
    }
}

/// The reverse request handler (on the dispatcher).
pub fn handle(ctx: ?*anyopaque, c: *DapConnection, req: DapConnection.ReverseRequest, _: Allocator) void {
    const s: *DebugSession = @ptrCast(@alignCast(ctx.?));
    const m = s.manager;
    if (!m.cfg.trusted) return refuse(c, req.seq, "runInTerminal needs a trusted workspace");
    const term = m.cfg.terminal orelse return refuse(c, req.seq, "there is no terminal to run the debuggee in");
    const job = s.gpa.create(Job) catch return refuse(c, req.seq, "out of memory");
    job.* = .{ .s = s, .c = c, .seq = req.seq, .term = term, .arena = .init(s.gpa), .spec = undefined };
    const a = job.arena.allocator();
    const bytes = if (req.arguments) |r| r.bytes else "{}";
    job.spec = parse(a, bytes, builtin.os.tag) catch |e| {
        job.destroy();
        return refuse(c, req.seq, if (e == error.OutOfMemory) "out of memory" else "invalid runInTerminal arguments");
    };
    if (m.cfg.policy) |p| switch (p.decide(job.spec.argv, job.spec.cwd)) {
        .deny => |why| {
            job.destroy();
            return refuse(c, req.seq, why);
        },
        .allow => |rules| applyRules(a, &job.spec, rules) catch {
            job.destroy();
            return refuse(c, req.seq, "out of memory");
        },
    };
    if (job.spec.kind == .external and !term.external) {
        if (!m.external_fallback_logged.swap(true, .acq_rel))
            log.info("no external terminal is configured (terminal.external.*): debuggees run in the integrated terminal", .{});
        job.spec.kind = .integrated;
    }
    s.work.spawnLoop(Job.run, .{job}) catch {
        job.destroy();
        return refuse(c, req.seq, "cannot start the debuggee");
    };
}

fn applyRules(a: Allocator, spec: *RunInTerminalSpec, rules: ServerProcess.SpawnPolicy.Rules) Allocator.Error!void {
    if (rules.wrapper_argv) |wrap| {
        const argv = try a.alloc([]const u8, wrap.len + spec.argv.len);
        @memcpy(argv[0..wrap.len], wrap);
        @memcpy(argv[wrap.len..], spec.argv);
        spec.argv = argv;
    }
    if (rules.env_set.len > 0) {
        const env = try a.alloc(EnvEntry, spec.env.len + rules.env_set.len);
        @memcpy(env[0..spec.env.len], spec.env);
        for (env[spec.env.len..], rules.env_set) |*e, kv| e.* = .{ .name = kv[0], .value = kv[1] };
        spec.env = env;
    }
    spec.env_allow = rules.env_allow;
}

fn refuse(c: *DapConnection, seq: u32, msg: []const u8) void {
    c.respond(seq, "runInTerminal", false, null, msg) catch {};
}

const Job = struct {
    s: *DebugSession,
    c: *DapConnection,
    seq: u32,
    term: TerminalLauncher,
    arena: std.heap.ArenaAllocator,
    spec: RunInTerminalSpec,

    fn destroy(j: *Job) void {
        j.arena.deinit();
        j.s.gpa.destroy(j);
    }

    fn run(j: *Job) Io.Cancelable!void {
        defer j.destroy();
        const res = j.term.launch(j.term.ctx, &j.spec) catch |e| {
            const msg = std.fmt.allocPrint(j.arena.allocator(), "cannot start the debuggee in a terminal: {t}", .{e}) catch "cannot start the debuggee";
            return refuse(j.c, j.seq, msg);
        };
        const Body = struct { processId: ?i64, shellProcessId: ?i64 };
        const body = std.json.Stringify.valueAlloc(j.arena.allocator(), Body{ .processId = res.process_id, .shellProcessId = res.shell_process_id }, .{ .emit_null_optional_fields = false }) catch
            return refuse(j.c, j.seq, "out of memory");
        j.c.respond(j.seq, "runInTerminal", true, body, null) catch {};
    }
};
