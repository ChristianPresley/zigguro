//! `editing_100k` (E14.F06.S01.T02): types 500 keys (50 quick) into the
//! middle of a 100 k-line file, one headless frame per key, and records
//! each key frame's UI-thread CPU from the frame timeline. Feeds
//! `ui.frame_cpu_keystroke`; `input.key_to_photon` needs a real window
//! (`zig build bench-latency`).

const std = @import("std");
const zg_perf = @import("zg_perf");
const zg_platform = @import("zg_platform");
const Driver = @import("../runner.zig").Driver;
const keys = @import("../keys.zig");

const sc = zg_perf.scenario;

pub const scenario: sc.Scenario = .{
    .name = "editing_100k",
    .budgets = &.{"ui.frame_cpu_keystroke"},
    .repeats = 3,
    .quick_repeats = 1,
    .setup = setup,
    .run = run,
    .teardown = teardown,
};

fn setup(c: *sc.Context) !void {
    const d = c.state(Driver);
    if (d.timeline == null) return error.NoFrameTimeline;
    const file = try d.corpusFile(.{ .profile = .lines_100k, .scale_ppm = if (c.quick) 50_000 else 1_000_000 });
    defer d.gpa.free(file);
    try d.open(file, false);
}

const Sink = struct {
    c: *sc.Context,
    err: ?anyerror = null,

    fn f(ctx: *anyopaque, rec: *const zg_perf.frame.FrameRecord, violation: bool) void {
        const s: *Sink = @ptrCast(@alignCast(ctx));
        if (violation or !rec.isKeyInput()) return;
        s.c.record("frame_cpu", rec.cpuNs()) catch |e| {
            s.err = e;
        };
    }
};

fn run(c: *sc.Context) !void {
    const d = c.state(Driver);
    const wb = d.workbench();
    const lines = wb.view.lineCount();
    wb.gotoLine(@intCast(@max(lines / 2, 1)), 10);
    try d.waitFrames(2);
    const tl = d.timeline.?;
    var sink: Sink = .{ .c = c };
    tl.sink = .{ .ctx = &sink, .f = Sink.f };
    defer tl.sink = null;
    const hl = d.hl.?;
    const win = d.hw.?.id;
    const n: u32 = if (c.quick) 50 else 500;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const k = keys.keyFor(keys.sequence(i));
        var ev: zg_platform.event.KeyEvent = .{ .key = k.key, .keysym = k.keysym, .codepoint = if (k.text.len == 1) k.text[0] else 0, .mods = .{}, .action = .press, .text = .{ .len = @intCast(k.text.len) }, .native_scancode = k.evdev, .time_ns = 0 };
        try hl.injectPayload(.{ .key = .{ .win = win, .ev = ev } }, k.text);
        ev.action = .release;
        ev.text = .empty;
        try hl.inject(.{ .key = .{ .win = win, .ev = ev } });
        try d.frame();
    }
    try d.waitFrames(4);
    if (sink.err) |e| return e;
}

fn teardown(c: *sc.Context) !void {
    c.state(Driver).close();
}
