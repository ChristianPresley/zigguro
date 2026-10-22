//! zigguro: the GUI application (composition root). Until the
//! owning epics land this only initialises the zg_core runtime and handles
//! `--version` (through zg_release, before the runtime starts).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_release = @import("zg_release");
const zg_crash = @import("zg_crash");

pub const std_options: std.Options = .{
    .logFn = zg_core.log.logFn,
    // Crash reports in every mode (std enables it only with runtime safety).
    .enable_segfault_handler = true,
    .signal_stack_size = 256 * 1024,
};
pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);
pub const debug = struct {
    pub const handleSegfault = zg_crash.handleSegfault;
};

pub fn main(min: std.process.Init.Minimal) !u8 {
    // Before any runtime init: no allocator, no worker threads.
    if (zg_release.cli.handleVersionFlag(min, &zg_release.current, "zigguro")) return 0;
    installCrashHandler(min, "zigguro");

    var rt: zg_core.Runtime = undefined;
    try rt.init(min, .{});
    defer _ = rt.deinit();

    var buf: [256]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), rt.io, &buf);
    const w = &out.interface;
    try w.print("zigguro {s}: nothing to run yet; see GitHub issue #1198 for the plan\n", .{zg_release.current.version_string});
    try w.flush();
    return 0;
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
