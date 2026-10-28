//! `zg lsp` and `zg task` (E07.F05.S01.T04): the language servers and
//! the workspace's tasks without the GUI. The commands and their output
//! are zg_codeintel's and zg_dap's headless CLIs (the agents' tool
//! renderings); this composes them for a workspace: `--workspace DIR`
//! (default the current directory), trusted unless `--untrusted` (as
//! `zg agent` trusts the directory it runs in), `--zig PATH` for ZLS and
//! the tasks, `--verbose` for the servers' info and log messages.
//! Server settings files are not read yet: the built-in definitions run.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_codeintel = @import("zg_codeintel");
const zg_dap = @import("zg_dap");

const Io = std.Io;
const headless = zg_codeintel.headless;
const HeadlessTasks = zg_dap.headless.HeadlessTasks;
const task_cli = zg_dap.headless.cli;

const Which = enum { lsp, task };

pub fn runLsp(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const [:0]const u8) !u8 {
    return run(rt, min, argv, .lsp);
}

pub fn runTask(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const [:0]const u8) !u8 {
    return run(rt, min, argv, .task);
}

fn run(rt: *zg_core.Runtime, min: std.process.Init.Minimal, argv: []const [:0]const u8, which: Which) !u8 {
    const io = rt.io;
    var obuf: [16 * 1024]u8 = undefined;
    var ebuf: [2048]u8 = undefined;
    var hbuf: [1024]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &obuf);
    var err_w: Io.File.Writer = .init(.stderr(), io, &ebuf);
    // The servers' messages come from their workers: a writer of their own.
    var host_w: Io.File.Writer = .init(.stderr(), io, &hbuf);
    defer out_w.interface.flush() catch {};
    defer err_w.interface.flush() catch {};
    const out = &out_w.interface;
    const err = &err_w.interface;

    var arena_state: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try arena.alloc([]const u8, argv.len);
    for (argv, args) |a, *b| b.* = a;
    var bad: []const u8 = "";
    const c = try task_cli.Common.parse(arena, args, &bad) orelse {
        try err.print("zg {t}: {s} needs a value\n", .{ which, bad });
        return 2;
    };
    const root = Io.Dir.cwd().realPathFileAlloc(io, c.workspace orelse ".", arena) catch |e| {
        try err.print("zg {t}: no workspace at {s}: {t}\n", .{ which, c.workspace orelse ".", e });
        return 2;
    };
    var env = try min.environ.createMap(arena);
    defer env.deinit();

    var tasks: HeadlessTasks = undefined;
    try tasks.init(rt, .{ .root = root, .env = &env, .zig_exe = c.zig, .trusted = !c.untrusted });
    defer tasks.deinit();
    if (which == .task) return task_cli.cliMain(&tasks, c.rest, out, err);

    var host: headless.HeadlessHost = .init(io, &host_w.interface, .{ .verbose = c.verbose });
    var tc: headless.Toolchain = undefined;
    try tc.init(rt, .{
        .roots = (&root)[0..1],
        .env = &env,
        .host = &host,
        .trusted = !c.untrusted,
        .zig_exe = c.zig,
        .tasks = &tasks,
    });
    defer tc.deinit();
    return headless.cli.cliMain(&tc, c.rest, out, err);
}
