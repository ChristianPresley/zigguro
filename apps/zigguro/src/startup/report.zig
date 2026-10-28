//! The startup report in the app (E14.F05.S01.T01): once the first frame
//! is interactive, a worker records the summary in `startup.json` in the
//! state folder (last 20 runs) and, with `--startup-report`, prints the
//! report to stdout. Runs without the interactive mark (headless,
//! `--frames`) call `finishNow` at the end.

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
