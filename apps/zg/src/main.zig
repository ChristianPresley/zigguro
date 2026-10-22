//! zg: the headless CLI agent and SCM CLI (works without the GUI).
//! `zg agent` runs the AI harness (E10.F10), `zg ui-test` runs `.zgui`
//! scripts headlessly (E04.F01.S03), `zg update` checks for and stages
//! updates (E17.F04.S01), `zg review` works the review queue
//! (E12.F03.S05); `--version` is answered by
//! zg_release before the runtime starts. Other subcommands arrive with
//! their epics.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_release = @import("zg_release");
const zg_crash = @import("zg_crash");
const cmd_agent = @import("cmd_agent.zig");
const cmd_ui_test = @import("cmd_ui_test.zig");
const cmd_update = @import("cmd_update.zig");
const review_cmd = @import("review_cmd.zig");

pub const std_options: std.Options = .{
    .logFn = zg_core.log.logFn,
    // Crash reports in every mode (std enables it only with runtime safety).
    // std's Windows handler is a vectored one that would run before
    // zg_crash's unhandled-exception filter.
    .enable_segfault_handler = builtin.os.tag != .windows,
    .signal_stack_size = 256 * 1024,
};
pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);
pub const debug = struct {
    pub const handleSegfault = zg_crash.handleSegfault;
};

pub fn main(min: std.process.Init.Minimal) !u8 {
    // Before any runtime init: no allocator, no worker threads.
    if (zg_release.cli.handleVersionFlag(min, &zg_release.current, "zg")) return 0;
    installCrashHandler(min, "zg");

    var rt: zg_core.Runtime = undefined;
    try rt.init(min, .{});
    defer _ = rt.deinit();

    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena.deinit();
    const argv = try min.args.toSlice(arena.allocator());
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "agent")) return cmd_agent.run(&rt, min, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "ui-test")) return cmd_ui_test.run(&rt, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "update")) return cmd_update.run(&rt, min, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "review")) return review_cmd.runCli(&rt, min, argv[2..]);

    var buf: [256]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), rt.io, &buf);
    const w = &out.interface;
    try w.print(
        \\zg {s}
        \\
        \\Usage: zg agent [flags]          run the AI agent (zg agent --help)
        \\       zg ui-test FILE.zgui...   run UI scripts headlessly (zg ui-test --help)
        \\       zg update check|download|status   updates (zg update --help)
        \\       zg review list|show|accept|...    the review queue (zg review --help)
        \\
    , .{zg_release.current.version_string});
    try w.flush();
    return if (argv.len >= 2) 2 else 0;
}

/// Crash reports go to `<state>/crashes` (E17.F05); `install` copies the
/// paths. A failure here only means no reports.
fn installCrashHandler(min: std.process.Init.Minimal, product: []const u8) void {
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    var crash_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = zg_crash.paths.stateDir(min.environ, &state_buf) orelse return;
    const crashes = zg_crash.paths.crashDir(state, &crash_buf) orelse return;
    zg_crash.install(.{ .crash_dir = crashes, .state_dir = state, .product = product }) catch {};
}
