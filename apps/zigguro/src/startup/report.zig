//! The startup report in the app (E14.F05.S01.T01): once the first frame
//! is interactive, a worker records the summary in `startup.json` in the
//! state folder (last 20 runs) and, with `--startup-report`, prints the
//! report to stdout. Runs without the interactive mark (headless,
//! `--frames`) call `finishNow` at the end.
//!
//! For `zigguro-bench-startup` (E14.F05.S01.T03): `--startup-report-json=
//! <path>` writes the run's marks there, and `--exit-after-startup` exits
//! right after.

const std = @import("std");
const zg_perf = @import("zg_perf");

const startup = zg_perf.startup;
const log = std.log.scoped(.startup);

pub const StartupReport = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Print the report (`--startup-report`).
    print: bool,
    /// The state folder for startup.json; null: not persisted.
    state_dir: ?[]const u8,
    /// `--startup-report-json`: where to write the run's marks.
    json_path: ?[]const u8 = null,
    /// `--exit-after-startup`: exit once the report is written.
    exit_after: bool = false,
    /// The display refresh interval (the frame timeline's), when known.
    refresh_ns: ?*const u64 = null,
    group: std.Io.Group = .init,
    done: std.atomic.Value(bool) = .init(false),

    /// Runs `finish` on a worker when the first frame is interactive.
    pub fn arm(r: *StartupReport) void {
        if (!startup.global().on(.interactive, .{ .ctx = r, .f = onInteractive })) log.warn("startup hooks full", .{});
    }

    fn onInteractive(ctx: ?*anyopaque, _: *startup.StartupTimeline) void {
        const r: *StartupReport = @ptrCast(@alignCast(ctx.?));
        r.group.concurrent(r.io, task, .{r}) catch r.finish();
    }

    fn task(r: *StartupReport) std.Io.Cancelable!void {
        r.finish();
    }

    /// Records (and prints) the summary now, unless that already happened.
    pub fn finishNow(r: *StartupReport) void {
        r.finish();
    }

    fn finish(r: *StartupReport) void {
        if (r.done.swap(true, .acq_rel)) return;
        var s = startup.global().summary();
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(r.io).nanoseconds, std.time.ns_per_ms));
        var dir: ?std.Io.Dir = null;
        if (r.state_dir) |p| dir = std.Io.Dir.cwd().openDir(r.io, p, .{}) catch null;
        defer if (dir) |d| d.close(r.io);
        if (dir) |d| {
            var arena: std.heap.ArenaAllocator = .init(r.gpa);
            defer arena.deinit();
            s.launch_kind = startup.report.launchKind(startup.report.readHistory(arena.allocator(), r.io, d), now_ms);
            startup.report.persist(r.gpa, r.io, d, s, now_ms) catch |e| log.warn("startup.json: {t}", .{e});
        }
        if (r.print) {
            var buf: [4096]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&buf);
            startup.report.writeReport(s, &fw) catch {};
            var out_buf: [256]u8 = undefined;
            var out = std.Io.File.stdout().writer(r.io, &out_buf);
            out.interface.writeAll(fw.buffered()) catch {};
            out.interface.flush() catch {};
        }
        if (r.json_path) |p| r.writeJson(p, s) catch |e| log.warn("--startup-report-json {s}: {t}", .{ p, e });
        if (r.exit_after) std.process.exit(0);
    }

    fn writeJson(r: *StartupReport, path: []const u8, s: startup.Summary) !void {
        if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(r.io, d) catch {};
        var af = try std.Io.Dir.cwd().createFileAtomic(r.io, path, .{ .replace = true });
        defer af.deinit(r.io);
        var buf: [2048]u8 = undefined;
        var fw = af.file.writer(r.io, &buf);
        try startup.bench.writeChildJson(s, if (r.refresh_ns) |p| p.* else 0, &fw.interface);
        try fw.interface.flush();
        try af.replace(r.io);
    }

    /// Waits for a running `finish`.
    pub fn deinit(r: *StartupReport) void {
        r.group.await(r.io) catch {};
    }
};

test "startup report: persists once into the state folder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var r: StartupReport = .{ .gpa = gpa, .io = io, .print = false, .state_dir = dir };
    defer r.deinit();
    r.finishNow();
    r.finishNow();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 1), startup.report.readHistory(arena.allocator(), io, tmp.dir).len);
}

test "startup report: writes the bench record" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/run/run-0.json", .{&tmp.sub_path});
    const refresh: u64 = 16_000_000;
    var r: StartupReport = .{ .gpa = gpa, .io = io, .print = false, .state_dir = null, .json_path = path, .refresh_ns = &refresh };
    defer r.deinit();
    r.finishNow();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .limited(1 << 16));
    const run = try startup.bench.parseChild(arena.allocator(), text);
    try std.testing.expectEqual(refresh, run.refresh_ns);
}
