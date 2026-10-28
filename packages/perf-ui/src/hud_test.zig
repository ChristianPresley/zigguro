//! HUD tests (E14.F03.S01.T02) on the headless `TestApp` with a virtual
//! clock: toggling, zero frames at idle, refresh rate while frames arrive,
//! the danger colour on over-budget bars and bar clicks.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_perf = @import("zg_perf");
const hud_mod = @import("hud.zig");
const model = @import("hud_model.zig");

const TestApp = zg_gui.testing.TestApp;
const Ui = zg_gui.Ui;
const FrameTimeline = zg_perf.frame.FrameTimeline;

/// A page that redraws when `typing` (a stand-in for an editor).
const Page = struct {
    n: u32 = 0,
    pub fn build(p: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        defer ui.close();
        var buf: [16]u8 = undefined;
        ui.text(std.fmt.bufPrint(&buf, "{d}", .{p.n}) catch "", .{});
    }
};

const Fixture = struct {
    t: *TestApp,
    page: Page = .{},
    tl: FrameTimeline,
    hud: *hud_mod.Hud,
    seq: u64 = 0,
    page_view: u16 = 0,

    fn init(f: *Fixture, tl: FrameTimeline) !void {
        const gpa = std.testing.allocator;
        f.* = .{ .t = undefined, .tl = tl, .hud = undefined };
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.page), .size = .{ .w = 800, .h = 600 } });
        f.hud = try hud_mod.Hud.init(gpa, &f.tl, .{});
        _ = f.frames();
    }

    fn deinit(f: *Fixture) void {
        f.hud.destroy();
        f.t.deinit();
        f.tl.deinit();
    }

    /// Runs frames until idle, recording each one that drew in the
    /// timeline the way the Host does; returns how many drew.
    fn frames(f: *Fixture) u32 {
        var n: u32 = 0;
        while (n < 16) {
            _ = f.t.app.drainMessages();
            const st = f.t.win.frame();
            if (st.idle) break;
            n += 1;
            if (!st.presented) continue;
            f.seq += 1;
            const now: u64 = f.t.app.now_ms * std.time.ns_per_ms;
            f.tl.onFrameStats(.{ .seq = f.seq, .t_frame_start_ns = now, .build_ns = 1_000_000, .t_submit_ns = now + 2_000_000, .present_id = f.seq, .expect_feedback = false });
        }
        return n;
    }

    /// Advances the virtual clock by `ms` in 16 ms steps, running timers
    /// and frames; `typing` redraws the page every step.
    fn run(f: *Fixture, ms: u64, typing: bool) u32 {
        var n: u32 = 0;
        var left = ms;
        while (left > 0) {
            const step = @min(left, 16);
            left -= step;
            f.t.app.now_ms += step;
            f.t.win.tick(f.t.app.now_ms);
            if (typing) {
                f.page.n += 1;
                f.t.win.markAllDirty();
            }
            n += f.frames();
        }
        return n;
    }
};

test "hud: toggle opens and closes overlay" {
    var f: Fixture = undefined;
    try f.init(try FrameTimeline.init(std.testing.allocator, 1024));
    defer f.deinit();
    try std.testing.expect(f.t.find(.{ .test_id = "perf.hud" }) == null);
    f.hud.toggle(f.t.win);
    _ = f.frames();
    try std.testing.expect(f.hud.isVisible());
    const r = try f.t.rectOf(.{ .test_id = "perf.hud" });
    // Top-right, 8 px in.
    try std.testing.expectApproxEqAbs(@as(f32, 800 - 8), r.right(), 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 8), r.y, 0.5);
    f.hud.toggle(f.t.win);
    _ = f.frames();
    try std.testing.expect(!f.hud.isVisible());
    try std.testing.expect(f.t.find(.{ .test_id = "perf.hud" }) == null);
    try std.testing.expect(f.tl.listener == null);
}

test "hud: no frames requested while idle" {
    var f: Fixture = undefined;
    try f.init(try FrameTimeline.init(std.testing.allocator, 1024));
    defer f.deinit();
    f.hud.setVisible(f.t.win, true);
    _ = f.frames();
    // The HUD settles: one "idle" repaint, then nothing.
    _ = f.run(1000, false);
    try std.testing.expect(f.hud.model.idle);
    try std.testing.expectEqual(@as(u32, 0), f.run(10_000, false));
    try std.testing.expect(f.t.win.nextDeadline() == null);
    // Activity wakes it again.
    _ = f.run(600, true);
    try std.testing.expect(!f.hud.model.idle);
    _ = f.run(1000, false);
    try std.testing.expectEqual(@as(u32, 0), f.run(5_000, false));
}

test "hud: refreshes at most 4 Hz while frames arrive" {
    var f: Fixture = undefined;
    try f.init(try FrameTimeline.init(std.testing.allocator, 1024));
    defer f.deinit();
    f.hud.setVisible(f.t.win, true);
    _ = f.frames();
    const before = f.hud.refreshes;
    const drawn = f.run(2000, true);
    try std.testing.expect(drawn >= 100);
    const per_2s = f.hud.refreshes - before;
    try std.testing.expect(per_2s >= 6 and per_2s <= 9);
    try std.testing.expect(f.hud.model.len > 100);
}

fn hex(c: zg_gui.core.geom.Color, buf: []u8) []const u8 {
    const v = (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | c.a;
    return std.fmt.bufPrint(buf, "#{x:0>8}", .{v}) catch unreachable;
}

test "hud: over-budget bar uses danger color" {
    var f: Fixture = undefined;
    try f.init(try model.syntheticTimeline(std.testing.allocator, 100));
    defer f.deinit();
    f.hud.setVisible(f.t.win, true);
    _ = f.frames();
    var buf: [16]u8 = undefined;
    const out = f.t.rec.text();
    const danger = hex(f.t.app.theme.color(.danger), &buf);
    // Frames 25, 50, 75 and 100 are slow: six segments each.
    try std.testing.expectEqual(@as(usize, 4 * 6), std.mem.count(u8, out, danger));
    var buf2: [16]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, out, hex(f.t.app.theme.color(.accent), &buf2)) != null);
}

test "hud: click triggers flight recorder" {
    var f: Fixture = undefined;
    try f.init(try model.syntheticTimeline(std.testing.allocator, 100));
    defer f.deinit();
    const Fake = struct {
        notes: u32 = 0,
        last: [48]u8 = undefined,
        len: usize = 0,
        fn trigger(ctx: *anyopaque, note: []const u8) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.notes += 1;
            @memcpy(r.last[0..note.len], note);
            r.len = note.len;
        }
    };
    var fake: Fake = .{};
    f.hud.recorder = .{ .ctx = &fake, .trigger = Fake.trigger };
    f.hud.setVisible(f.t.win, true);
    _ = f.frames();
    const g = try f.t.rectOf(.{ .kind = "perf_hud_graph" });
    // The newest bar is at the right edge.
    const p: zg_gui.core.geom.Vec2 = .{ .x = g.right() - 0.5, .y = g.bottom() - 2 };
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = p } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = p } });
    try std.testing.expectEqual(@as(u32, 1), fake.notes);
    try std.testing.expectEqualStrings("hud click seq=100", fake.last[0..fake.len]);
}
