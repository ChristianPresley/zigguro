//! `idle` (E14.F06.S01.T02, the idle-memory check of E14.F04.S02.T01):
//! opens a Linux-sized workspace (1 % in quick mode) with five files and
//! the terminal panel, lets it settle for 5 s (1 s quick), then idles for
//! 30 s (3 s quick) on the real clock. Records wakeups per second (waits
//! annotated with `noteWake`), process CPU percent and private and
//! resident memory at the end. Feeds `idle.wakeups`, `idle.cpu` and
//! `mem.idle_private`. `--bench-scenario=idle_memory` runs this too.
//!
//! Values that are not durations go in the `*_ns` fields in their own
//! unit (wakeups/s × 1000, CPU % × 1000, bytes).

const std = @import("std");
const builtin = @import("builtin");
const zg_perf = @import("zg_perf");
const Driver = @import("../runner.zig").Driver;

const sc = zg_perf.scenario;

pub const scenario: sc.Scenario = .{
    .name = "idle",
    .budgets = &.{ "idle.wakeups", "idle.cpu", "mem.idle_private" },
    .repeats = 1,
    .quick_repeats = 1,
    .setup = setup,
    .run = run,
    .teardown = teardown,
};

/// Rates are recorded × this so they survive the integer samples.
pub const milli = 1000;

fn setup(c: *sc.Context) !void {
    const d = c.state(Driver);
    const root = try d.corpus(.{ .profile = .linux, .scale_ppm = if (c.quick) 10_000 else 1_000_000 });
    defer d.gpa.free(root);
    try d.open(root, true);
    // Five files from the corpus, then the terminal.
    const list = try std.fs.path.join(d.gpa, &.{ root, "paths.txt" });
    defer d.gpa.free(list);
    const text = try std.Io.Dir.cwd().readFileAlloc(d.io, list, d.gpa, .limited(1 << 30));
    defer d.gpa.free(text);
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    var opened: u32 = 0;
    var k: u32 = 0;
    while (it.next()) |rel| : (k += 1) {
        if (opened == 5) break;
        if (k % 997 != 0) continue;
        const abs = try std.fs.path.join(d.gpa, &.{ root, rel });
        defer d.gpa.free(abs);
        d.workbench().openFile(abs) catch continue;
        opened += 1;
    }
    d.command("terminal.toggle") catch |e| std.log.warn("idle: no terminal: {t}", .{e});
    try d.idleFor(if (c.quick) std.time.ns_per_s else 5 * std.time.ns_per_s);
}

fn run(c: *sc.Context) !void {
    const d = c.state(Driver);
    const window_ns: u64 = if (c.quick) 3 * std.time.ns_per_s else 30 * std.time.ns_per_s;
    const w0 = zg_perf.idle.wake_count.totalWakes();
    const cpu0 = zg_perf.idle.processCpuTimes() catch null;
    const t0 = zg_core_now(d);
    try d.idleFor(window_ns);
    const dt = zg_core_now(d) - t0;
    const wakes = zg_perf.idle.wake_count.totalWakes() - w0;
    const secs = @as(f64, @floatFromInt(dt)) / std.time.ns_per_s;
    try c.record("wakeups_per_s", @intFromFloat(@as(f64, @floatFromInt(wakes)) / secs * milli));
    if (cpu0) |a| if (zg_perf.idle.processCpuTimes() catch null) |b| {
        const pct = @as(f64, @floatFromInt(b.totalNs() -| a.totalNs())) / @as(f64, @floatFromInt(dt)) * 100;
        try c.record("cpu_pct", @intFromFloat(pct * milli));
    };
    var scratch: [16 * 1024]u8 = undefined;
    if (zg_perf.mem.readProcessMem(d.io, &scratch)) |m| {
        try c.record("private_bytes", m.private_bytes);
        try c.record("rss_bytes", m.rss_bytes);
    } else |e| if (builtin.os.tag == .linux or builtin.os.tag == .windows) return e;
}

fn zg_core_now(d: *Driver) u64 {
    return @import("zg_core").time.nowNs(d.io);
}

fn teardown(c: *sc.Context) !void {
    c.state(Driver).close();
}
