//! Benchmarks for zg_perf_ui; run with `zig build bench` at the repo root.
//!
//! `perf.hud_frame` (budget `perf.hud_overhead`): a frame that refreshes
//! the HUD over a full 240-bar synthetic timeline (model update, build,
//! layout and paint of the overlay alone), the HUD's worst frame. Frames
//! between refreshes replay its cached paint.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_perf_ui = @import("zg_perf_ui");
const bench = zg_core.bench;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const Blank = struct {
    pub fn build(_: *Blank, ui: *zg_gui.Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        ui.close();
    }
};

fn register(b: *bench.Bench) !void {
    try b.run("perf.hud_frame", {}, struct {
        fn f(_: void, s: *bench.State) void {
            const gpa = std.heap.smp_allocator;
            var tl = zg_perf_ui.hud_model.syntheticTimeline(gpa, 1000) catch return;
            defer tl.deinit();
            var page: Blank = .{};
            const t = zg_gui.testing.TestApp.init(gpa, .{ .root = .of(&page), .size = .{ .w = 1280, .h = 800 } }) catch return;
            defer t.deinit();
            const hud = zg_perf_ui.Hud.init(gpa, &tl, .{}) catch return;
            defer hud.destroy();
            hud.setVisible(t.win, true);
            _ = t.settle();
            for (0..s.iterations()) |_| {
                hud.refreshNow();
                t.app.flushEffects();
                bench.doNotOptimizeAway(t.win.frame());
            }
        }
    }.f);
    try b.run("perf.hud_model_update", {}, struct {
        fn f(_: void, s: *bench.State) void {
            const gpa = std.heap.smp_allocator;
            var tl = zg_perf_ui.hud_model.syntheticTimeline(gpa, 1000) catch return;
            defer tl.deinit();
            var m = zg_perf_ui.hud_model.Model.init(gpa, 240) catch return;
            defer m.deinit();
            for (0..s.iterations()) |_| {
                m.update(&tl, .{}, false);
                bench.doNotOptimizeAway(&m);
            }
        }
    }.f);
}
