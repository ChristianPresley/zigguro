//! `view_switch` (E14.F06.S01.T02): toggles the side bar, terminal panel,
//! agent pane, review queue and theme on and off (10 commands a cycle)
//! and measures each command to the end of the frame that shows it.
//! Feeds `ui.view_switch`.

const std = @import("std");
const zg_perf = @import("zg_perf");
const Driver = @import("../runner.zig").Driver;

const sc = zg_perf.scenario;

pub const scenario: sc.Scenario = .{
    .name = "view_switch",
    .budgets = &.{"ui.view_switch"},
    .repeats = 10,
    .quick_repeats = 2,
    .warmup = 1,
    .setup = setup,
    .run = run,
    .teardown = teardown,
};

/// Each runs twice a cycle: on, then off.
pub const commands = [_][]const u8{ "workbench.toggleSidebar", "terminal.toggle", "agent.togglePane", "review.queue.toggle", "workbench.toggleTheme" };

fn setup(c: *sc.Context) !void {
    const d = c.state(Driver);
    const file = try d.corpusFile(.{ .profile = .lines_100k, .scale_ppm = if (c.quick) 50_000 else 1_000_000 });
    defer d.gpa.free(file);
    try d.open(file, false);
}

fn run(c: *sc.Context) !void {
    const d = c.state(Driver);
    for (0..2) |_| for (commands) |id| {
        var m = c.measurement();
        m.start();
        try d.command(id);
        try d.frame();
        m.stop();
        try c.record("command_to_frame", m.sampleNs());
    };
}

fn teardown(c: *sc.Context) !void {
    c.state(Driver).close();
}
