//! The scenario runner (E14.F06.S01.T02): `zigguro --bench-scenario=<name>`
//! boots the app, runs one macro scenario (`bench/scenarios/`) through
//! `zg_perf.scenario`, writes E00 bench JSON (package `scenarios`) and
//! exits. `zig build bench-scenarios` runs them all.
//!
//! Options: `--bench-out=PATH` (the JSON; default stdout only),
//! `--bench-quick` (small corpora, two repeats), `--bench-repeats=N` and
//! `--bench-corpus-root=DIR` (default `ZG_CORPUS_DIR`, else the temp
//! folder). The scenarios run on the headless platform with the software
//! renderer: frames are driven on its virtual clock, and `idle` waits in
//! real time. Timings are CPU-side (command to the end of the frame that
//! shows its effect); presentation needs a real window (`bench-latency`).
//!
//! `latency` is its own harness (`bench/latency.zig`).

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_platform = @import("zg_platform");
const zg_gui = @import("zg_gui");
const zg_perf = @import("zg_perf");
const zg_corpus = @import("zg_corpus");
const Workbench = @import("../workbench.zig").Workbench;

const sc = zg_perf.scenario;

/// Every scenario the runner knows, in `bench-scenarios` order.
pub const all = [_]sc.Scenario{
    @import("scenarios/view_switch.zig").scenario,
    @import("scenarios/editing_100k.zig").scenario,
    @import("scenarios/open_1gb.zig").scenario,
    @import("scenarios/fuzzy_find_1m.zig").scenario,
    @import("scenarios/idle.zig").scenario,
};

/// Names that run another scenario.
const aliases = [_]struct { []const u8, []const u8 }{
    // #980's idle-memory check is the idle scenario's private_bytes.
    .{ "idle_memory", "idle" },
    .{ "typing_100k", "editing_100k" },
};

pub const Options = struct {
    name: []const u8,
    out_path: ?[]const u8 = null,
    quick: bool = false,
    repeats: ?u32 = null,
    corpus_root: ?[]const u8 = null,

    /// Reads `--bench-scenario=<name>` (not `latency`) and the options.
    pub fn parse(args: []const []const u8) ?Options {
        var o: Options = .{ .name = "" };
        for (args) |a| {
            if (value(a, "--bench-scenario=")) |v| o.name = v;
            if (value(a, "--bench-out=")) |v| o.out_path = v;
            if (value(a, "--bench-repeats=")) |v| o.repeats = std.fmt.parseInt(u32, v, 10) catch null;
            if (value(a, "--bench-corpus-root=")) |v| o.corpus_root = v;
            if (std.mem.eql(u8, a, "--bench-quick")) o.quick = true;
        }
        if (o.name.len == 0 or std.mem.eql(u8, o.name, "latency")) return null;
        for (aliases) |al| if (std.mem.eql(u8, o.name, al[0])) {
            o.name = al[1];
        };
        return o;
    }

    fn value(a: []const u8, comptime prefix: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, a, prefix)) a[prefix.len..] else null;
    }
};

/// What scenarios drive: the app on a headless window, with one
/// workbench at a time. Lives in `Context.user`.
pub const Driver = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    rt: *zg_core.Runtime,
    env: *const std.process.Environ.Map,
    app: *zg_gui.App,
    text_sys: zg_gui.paint.text.TextSystem,
    fonts: ?*zg_gui.paint.FontText = null,
    timeline: ?*zg_perf.frame.FrameTimeline = null,
    quick: bool = false,
    corpus_root: []const u8,
    hl: ?*zg_platform.headless.Headless = null,
    host: zg_gui.Host = undefined,
    hw: ?*zg_gui.host.HostWindow = null,
    wb: ?*Workbench = null,
    saved_cwd: ?[:0]u8 = null,

    /// Opens a headless window showing a workbench on `path` (a file, a
    /// folder or null). `real_time` makes waits block on the real clock.
    pub fn open(d: *Driver, path: ?[]const u8, real_time: bool) !void {
        std.debug.assert(d.hl == null);
        // A folder becomes the working folder, as `zigguro DIR` does.
        var file = path;
        if (path) |p| if (isFolder(d.io, p)) {
            d.saved_cwd = try std.process.currentPathAlloc(d.io, d.gpa);
            try std.process.setCurrentPath(d.io, p);
            file = null;
        };
        errdefer d.restoreCwd();
        const hl = try zg_platform.headless.Headless.init(d.gpa, d.io, .{ .real_time = real_time });
        errdefer hl.deinit();
        const wb = try d.gpa.create(Workbench);
        errdefer d.gpa.destroy(wb);
        try wb.init(d.rt, d.env, file);
        errdefer wb.deinit();
        d.host = zg_gui.Host.init(d.gpa, d.io, d.app, hl.platform(), d.text_sys, .{ .fonts = d.fonts, .timeline = d.timeline, .render_thread = false });
        errdefer d.host.deinit();
        const hw = try d.host.open(.{ .title = "zigguro bench", .size = .{ .w = 1280, .h = 800 }, .root = .of(wb) });
        try wb.attach(hw.win);
        d.hl = hl;
        d.wb = wb;
        d.hw = hw;
        for (0..4) |_| try d.frame();
    }

    /// Closes what `open` opened.
    pub fn close(d: *Driver) void {
        const hl = d.hl orelse return;
        const wb = d.wb.?;
        wb.detach();
        d.host.deinit();
        wb.deinit();
        d.gpa.destroy(wb);
        hl.deinit();
        d.hl = null;
        d.wb = null;
        d.hw = null;
        d.restoreCwd();
    }

    fn restoreCwd(d: *Driver) void {
        const p = d.saved_cwd orelse return;
        std.process.setCurrentPath(d.io, p) catch |e| std.log.warn("bench: cannot restore the working folder: {t}", .{e});
        d.gpa.free(p);
        d.saved_cwd = null;
    }

    fn isFolder(io: std.Io, p: []const u8) bool {
        const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
        return st.kind == .directory;
    }

    pub fn workbench(d: *Driver) *Workbench {
        return d.wb.?;
    }

    /// One frame: events, a virtual vsync, the frame.
    pub fn frame(d: *Driver) !void {
        const hl = d.hl.?;
        _ = try d.host.pump();
        try hl.tick(hl.opts.refresh_ns);
        _ = try d.host.pump();
    }

    pub fn waitFrames(d: *Driver, n: u32) !void {
        for (0..n) |_| try d.frame();
    }

    /// Runs the command `id` as the palette would.
    pub fn command(d: *Driver, id: []const u8) !void {
        const wb = d.wb.?;
        const cid = wb.reg.lookup(id) orelse return error.UnknownCommand;
        try wb.reg.execute(cid, null, .palette);
    }

    /// Pumps events for `ns` of real time without forcing frames (needs
    /// `open(.., true)`).
    pub fn idleFor(d: *Driver, ns: u64) !void {
        const hl = d.hl.?;
        const deadline = zg_core.time.nowNs(d.io) + ns;
        while (true) {
            _ = try d.host.pump();
            if (zg_core.time.nowNs(d.io) >= deadline) return;
            hl.platform().waitEvents(deadline);
        }
    }

    /// The folder of corpus `spec` (generated on first use).
    pub fn corpus(d: *Driver, spec: zg_corpus.Spec) ![]const u8 {
        return zg_corpus.ensure(d.gpa, d.io, spec, d.corpus_root);
    }

    /// The single file of a one-file corpus (owned).
    pub fn corpusFile(d: *Driver, spec: zg_corpus.Spec) ![]const u8 {
        const dir = try d.corpus(spec);
        defer d.gpa.free(dir);
        const paths = try std.fs.path.join(d.gpa, &.{ dir, "paths.txt" });
        defer d.gpa.free(paths);
        const text = try std.Io.Dir.cwd().readFileAlloc(d.io, paths, d.gpa, .limited(1 << 20));
        defer d.gpa.free(text);
        const first = std.mem.sliceTo(text, '\n');
        return std.fs.path.join(d.gpa, &.{ dir, first });
    }
};

/// The default corpus root: `ZG_CORPUS_DIR`, else `<tmp>/zg-corpus`.
pub fn defaultCorpusRoot(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const tmp = env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse (if (builtin.os.tag == .windows) "." else "/tmp");
    const fallback = try std.fs.path.join(gpa, &.{ tmp, "zg-corpus" });
    const root = zg_corpus.cacheRoot(env, fallback);
    if (root.ptr != fallback.ptr) {
        gpa.free(fallback);
        return gpa.dupe(u8, root);
    }
    return fallback;
}

/// Runs `opts.name` with `d` and writes the results. Returns the exit
/// code: 0, or 1 when the scenario failed or recorded nothing, 2 for an
/// unknown name.
pub fn run(d: *Driver, opts: Options, w: *std.Io.Writer) !u8 {
    const s = sc.scenario.find(&all, opts.name) orelse {
        try w.print("bench: unknown scenario '{s}'; known:", .{opts.name});
        for (all) |x| try w.print(" {s}", .{x.name});
        try w.writeAll(" (and latency)\n");
        return 2;
    };
    var arena: std.heap.ArenaAllocator = .init(d.gpa);
    defer arena.deinit();
    var env = try sc.captureEnv(d.io, arena.allocator());
    env.corpus_version = zg_corpus.version;
    env.machine_class = d.env.get("ZG_MACHINE_CLASS") orelse "";
    env.git_sha = d.env.get("GITHUB_SHA") orelse "";
    _ = try sc.env.warnings(env, w);
    const st = sc.stabilize(.{ .pin_cpu = null });
    try w.print("bench: scenario {s}, ", .{s.name});
    try st.describe(w);
    try w.flush();

    var c: sc.Context = .init(d.gpa, d.io);
    defer c.deinit();
    c.quick = opts.quick;
    c.user = d;
    var spec = s.*;
    if (opts.repeats) |n| {
        spec.repeats = n;
        spec.quick_repeats = n;
    }
    sc.runScenario(spec, &c) catch |e| {
        d.close();
        try w.print("bench: scenario {s} failed: {t}\n", .{ s.name, e });
        return 1;
    };
    d.close();
    if (c.metrics.count() == 0) {
        try w.print("bench: scenario {s} recorded nothing\n", .{s.name});
        return 1;
    }
    try writeSummary(&c, w);
    var ej: std.Io.Writer.Allocating = .init(arena.allocator());
    try env.writeJson(&ej.writer);
    const meta: sc.context.Meta = .{ .platform = "headless", .machine = env.machine_class, .quick = opts.quick, .env_json = ej.written() };
    if (opts.out_path) |path| {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(d.io, dir) catch {};
        var aw: std.Io.Writer.Allocating = .init(arena.allocator());
        try c.writeJson(&aw.writer, meta);
        try std.Io.Dir.cwd().writeFile(d.io, .{ .sub_path = path, .data = aw.written() });
        try w.print("bench: wrote {s}\n", .{path});
    }
    return 0;
}

fn writeSummary(c: *sc.Context, w: *std.Io.Writer) !void {
    try w.print("{s:<40} {s:>5} {s:>12} {s:>12} {s:>12}\n", .{ "metric", "n", "p50", "p99", "max" });
    for (c.metrics.keys(), c.metrics.values()) |name, *v| {
        if (v.items.len == 0) continue;
        const sorted = try c.gpa.dupe(u64, v.items);
        defer c.gpa.free(sorted);
        const p = zg_perf.startup.bench.Pcts.of(sorted);
        try w.print("{s:<40} {d:>5} {d:>12} {d:>12} {d:>12}\n", .{ name, p.count, p.p50_ns, p.p99_ns, p.max_ns });
    }
}

test "bench runner options" {
    const o = Options.parse(&.{ "zigguro", "--bench-scenario=idle_memory", "--bench-quick", "--bench-repeats=3", "--bench-out=x.json" }).?;
    try std.testing.expectEqualStrings("idle", o.name);
    try std.testing.expect(o.quick);
    try std.testing.expectEqual(@as(?u32, 3), o.repeats);
    try std.testing.expect(Options.parse(&.{ "zigguro", "--bench-scenario=latency" }) == null);
    try std.testing.expect(Options.parse(&.{"zigguro"}) == null);
}

test "every scenario result binds to a budget" {
    // Results are `<scenario>.<metric>`; each scenario lists its budgets,
    // and each budget's scenario source names that scenario.
    for (all) |s| {
        try std.testing.expect(s.budgets.len > 0);
        for (s.budgets) |id| {
            const b = zg_perf.budget.byId(id).?;
            try std.testing.expect(b.source == .scenario);
            try std.testing.expectEqualStrings(s.name, b.source.scenario.name);
        }
    }
}
