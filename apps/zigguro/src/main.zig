//! zigguro: the GUI application (composition root). Until the
//! owning epics land this only initialises the zg_core runtime and handles
//! `--version` (through zg_release, before the runtime starts).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_release = @import("zg_release");

pub const std_options: std.Options = .{ .logFn = zg_core.log.logFn };
pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);

pub fn main(min: std.process.Init.Minimal) !u8 {
    // Before any runtime init: no allocator, no worker threads.
    if (zg_release.cli.handleVersionFlag(min, &zg_release.current, "zigguro")) return 0;

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
