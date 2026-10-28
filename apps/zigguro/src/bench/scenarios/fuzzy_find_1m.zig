//! `fuzzy_find_1m` (E14.F06.S01.T02): ranks the 1 M Chromium-like paths
//! (10 k in quick mode) against 20 fixed queries with the quick-pick
//! matcher (`zg_gui.w.quick_pick.SubsequenceMatcher`, as the pickers score items)
//! through `zg_gui.w.quick_pick.rank.topK` (character-mask prefilter,
//! chunks scored on the `Io`'s workers) and keeps the best 50, measuring
//! query to ranked results. The masks are built in setup, as a file index
//! keeps them (`zg_workspace` `FlatNames.char_mask`). Feeds
//! `workspace.fuzzy_find_1m`. The app has no file quick-open yet, so
//! first paint is not part of the number.

const std = @import("std");
const zg_perf = @import("zg_perf");
const zg_gui = @import("zg_gui");
const Driver = @import("../runner.zig").Driver;

const sc = zg_perf.scenario;

pub const scenario: sc.Scenario = .{
    .name = "fuzzy_find_1m",
    .budgets = &.{"workspace.fuzzy_find_1m"},
    .repeats = 5,
    .quick_repeats = 1,
    .setup = setup,
    .run = run,
    .teardown = teardown,
};

pub const queries = [_][]const u8{
    "rndr",               "third_party/blink/ren", "test.cc",   "ctrl",         "pool_q",
    "kmem",               "cache",                 "a/b/c",     "main.cc",      "chrome/brow",
    "util",               "frame_sched",           "vrtx",      "components/s", "_unittest",
    "net/http/http_strm", "zz",                    "README.md", "q2",           "BUILD.gn",
};

const keep = 50;

const State = struct {
    text: []u8 = &.{},
    paths: std.ArrayList([]const u8) = .empty,
    masks: std.ArrayList(u64) = .empty,
};
var state: State = .{};

fn setup(c: *sc.Context) !void {
    const d = c.state(Driver);
    const dir = try d.corpus(.{ .profile = .chromium, .materialize = .paths_only, .scale_ppm = if (c.quick) 10_000 else 1_000_000 });
    defer d.gpa.free(dir);
    const p = try std.fs.path.join(d.gpa, &.{ dir, "paths.txt" });
    defer d.gpa.free(p);
    state = .{ .text = try std.Io.Dir.cwd().readFileAlloc(d.io, p, d.gpa, .limited(1 << 30)) };
    var it = std.mem.tokenizeScalar(u8, state.text, '\n');
    while (it.next()) |line| {
        try state.paths.append(d.gpa, line);
        try state.masks.append(d.gpa, rank_mod.charMask(line));
    }
}

const rank_mod = zg_gui.w.quick_pick.rank;
const Hit = rank_mod.Hit;

/// The best `out.len` matches of `q` (best first) into `out`; returns the
/// count. `masks` are the paths' `charMask`s.
pub fn rank(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8, masks: ?[]const u64, q: []const u8, out: []Hit) !usize {
    return rank_mod.topK(gpa, io, zg_gui.w.quick_pick.SubsequenceMatcher.matcher(), q, paths, out, .{ .masks = masks });
}

fn run(c: *sc.Context) !void {
    const d = c.state(Driver);
    var top: [keep]Hit = undefined;
    var found: usize = 0;
    for (queries) |q| {
        var m = c.measurement();
        m.start();
        found += try rank(d.gpa, d.io, state.paths.items, state.masks.items, q, &top);
        m.stop();
        try c.record("ranked", m.sampleNs());
    }
    if (found == 0) return error.NoMatches;
}

fn teardown(c: *sc.Context) !void {
    const d = c.state(Driver);
    state.paths.deinit(d.gpa);
    state.masks.deinit(d.gpa);
    d.gpa.free(state.text);
    state = .{};
}

test "fuzzy rank keeps the best matches in order" {
    const paths = [_][]const u8{ "src/render/renderer.cc", "docs/readme.md", "third_party/blink/renderer/core.cc", "x/y" };
    var top: [2]Hit = undefined;
    const n = try rank(std.testing.allocator, std.testing.io, &paths, null, "rndr", &top);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(top[0].score >= top[1].score);
    for (top[0..n]) |h| try std.testing.expect(h.idx == 0 or h.idx == 2);
}
