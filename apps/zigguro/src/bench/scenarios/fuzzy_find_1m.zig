//! `fuzzy_find_1m` (E14.F06.S01.T02): ranks the 1 M Chromium-like paths
//! (10 k in quick mode) against 20 fixed queries with the quick-pick
//! matcher (`zg_gui.w.quick_pick.SubsequenceMatcher`, as the pickers score items)
//! and keeps the best 50, measuring query to ranked results. Feeds
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
    while (it.next()) |line| try state.paths.append(d.gpa, line);
}

const Hit = struct { score: i32, idx: u32 };

fn better(_: void, a: Hit, b: Hit) bool {
    return a.score > b.score or (a.score == b.score and a.idx < b.idx);
}

/// The best `keep` matches of `q` (best first) into `out`; returns the
/// count.
pub fn rank(gpa: std.mem.Allocator, paths: []const []const u8, q: []const u8, out: []Hit) !usize {
    const m = zg_gui.w.quick_pick.SubsequenceMatcher.matcher();
    var hl: std.ArrayList([2]u32) = .empty;
    defer hl.deinit(gpa);
    var n: usize = 0;
    for (paths, 0..) |path, i| {
        hl.clearRetainingCapacity();
        const s = m.score(q, path, &hl, gpa) orelse continue;
        const h: Hit = .{ .score = s, .idx = @intCast(i) };
        if (n < out.len) {
            out[n] = h;
            n += 1;
            if (n == out.len) std.mem.sort(Hit, out, {}, better);
        } else if (better({}, h, out[n - 1])) {
            // Insert into the sorted top list.
            var j = n - 1;
            while (j > 0 and better({}, h, out[j - 1])) : (j -= 1) out[j] = out[j - 1];
            out[j] = h;
        }
    }
    if (n < out.len) std.mem.sort(Hit, out[0..n], {}, better);
    return n;
}

fn run(c: *sc.Context) !void {
    const d = c.state(Driver);
    var top: [keep]Hit = undefined;
    var found: usize = 0;
    for (queries) |q| {
        var m = c.measurement();
        m.start();
        found += try rank(d.gpa, state.paths.items, q, &top);
        m.stop();
        try c.record("ranked", m.sampleNs());
    }
    if (found == 0) return error.NoMatches;
}

fn teardown(c: *sc.Context) !void {
    const d = c.state(Driver);
    state.paths.deinit(d.gpa);
    d.gpa.free(state.text);
    state = .{};
}

test "fuzzy rank keeps the best matches in order" {
    const paths = [_][]const u8{ "src/render/renderer.cc", "docs/readme.md", "third_party/blink/renderer/core.cc", "x/y" };
    var top: [2]Hit = undefined;
    const n = try rank(std.testing.allocator, &paths, "rndr", &top);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(top[0].score >= top[1].score);
    for (top[0..n]) |h| try std.testing.expect(h.idx == 0 or h.idx == 2);
}
