//! `open_1gb` (E14.F06.S01.T02): opens the 1 GiB log corpus (64 MiB in
//! quick mode) in a fresh workbench each repeat and measures from the open
//! to the end of the first frame showing it.
//! Feeds `file.open_1gb_first_screen`.

const std = @import("std");
const zg_perf = @import("zg_perf");
const Driver = @import("../runner.zig").Driver;

const sc = zg_perf.scenario;

pub const scenario: sc.Scenario = .{
    .name = "open_1gb",
    .budgets = &.{"file.open_1gb_first_screen"},
    .repeats = 5,
    .quick_repeats = 2,
    .setup = setup,
    .run = run,
    .teardown = teardown,
};

const State = struct { file: []const u8 };
var state: State = undefined;

fn setup(c: *sc.Context) !void {
    const d = c.state(Driver);
    state.file = try d.corpusFile(.{ .profile = .bigfile_1g, .scale_ppm = if (c.quick) 62_500 else 1_000_000 });
}

fn run(c: *sc.Context) !void {
    const d = c.state(Driver);
    try d.open(null, false);
    defer d.close();
    var m = c.measurement();
    m.start();
    try d.workbench().openFile(state.file);
    try d.frame();
    m.stop();
    try c.record("first_screen", m.sampleNs());
}

fn teardown(c: *sc.Context) !void {
    const d = c.state(Driver);
    d.close();
    d.gpa.free(state.file);
}
