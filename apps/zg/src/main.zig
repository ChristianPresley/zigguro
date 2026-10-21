//! zg: the headless CLI agent and SCM CLI (works without the GUI). Until the
//! owning epics land this only initialises the zg_core runtime and handles
//! `--version`.

const std = @import("std");
const zg_core = @import("zg_core");
const options = @import("zg_options");

pub const std_options: std.Options = .{ .logFn = zg_core.log.logFn };
pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);

pub fn main(min: std.process.Init.Minimal) !u8 {
    var rt: zg_core.Runtime = undefined;
    try rt.init(min, .{});
    defer _ = rt.deinit();

    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena.deinit();
    const args = try min.args.toSlice(arena.allocator());

    var buf: [256]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), rt.io, &buf);
    const w = &out.interface;
    if (args.len > 1 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V"))) {
        try w.print("zg {s}\n", .{options.version});
    } else {
        try w.print("zg {s}: nothing to run yet; see GitHub issue #1198 for the plan\n", .{options.version});
    }
    try w.flush();
    return 0;
}
