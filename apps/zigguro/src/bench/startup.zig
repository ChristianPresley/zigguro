//! zigguro-bench-startup (E14.F05.S01.T03): launches the real app again
//! and again and reports time to the first interactive frame.
//!
//!   zig build bench-startup -- --runs 20 --cold-runs 5 --workspace DIR
//!   → zig-out/bench-results/startup.json
//!
//! Each launch gets `--startup-report-json=<tmp>/run-N.json
//! --exit-after-startup --bench-inject-key-after-first-frame`; the child
//! writes its marks on the `.awake` clock, which the harness shares, so
//! `spawn → main_entered` (`startup.os_to_main`) is exact. Warm runs come
//! after 2 discarded warm-ups. Cold runs drop the page cache when root on
//! Linux, otherwise they launch a fresh copy of the binary and of the
//! workspace (`pseudo_cold`). Children get their own state folder
//! (`ZIGGURO_STATE_DIR`), so the user's last folder and layout stay as
//! they are. docs/perf/startup.md has the procedure for true cold runs.

const std = @import("std");
const builtin = @import("builtin");
const zg_perf = @import("zg_perf");

const sb = zg_perf.startup.bench;

pub const StartupBenchOptions = struct {
    runs: u16 = 20,
    cold_runs: u16 = 5,
    warmup_runs: u16 = 2,
    timeout_ms: u32 = 10_000,
    workspace: ?[]const u8 = null,
    session: ?[]const u8 = null,
    /// `ZG_PLATFORM` for the children (headless, wayland, x11, win32).
    platform: ?[]const u8 = null,
    exe: ?[]const u8 = null,
    out: ?[]const u8 = null,
    inject: bool = true,

    pub fn parse(args: []const []const u8) !StartupBenchOptions {
        var o: StartupBenchOptions = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--no-inject")) {
                o.inject = false;
                continue;
            }
            const names = [_][]const u8{ "--runs", "--cold-runs", "--warmup-runs", "--timeout-ms", "--workspace", "--session", "--platform", "--exe", "--out" };
            const which = for (names, 0..) |n, k| {
                if (std.mem.eql(u8, a, n)) break k;
            } else return error.UnknownArgument;
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const v = args[i];
            switch (which) {
                0 => o.runs = try std.fmt.parseInt(u16, v, 10),
                1 => o.cold_runs = try std.fmt.parseInt(u16, v, 10),
                2 => o.warmup_runs = try std.fmt.parseInt(u16, v, 10),
                3 => o.timeout_ms = try std.fmt.parseInt(u32, v, 10),
                4 => o.workspace = v,
                5 => o.session = v,
                6 => o.platform = v,
                7 => o.exe = v,
                8 => o.out = v,
                else => unreachable,
            }
        }
        return o;
    }
};

fn nowNs(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.awake.now(io).nanoseconds));
}

/// One launch: spawns `exe`, waits up to `timeout_ms` and returns the
/// child's record and the spawn time.
fn launch(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, exe: []const u8, workspace: ?[]const u8, json_path: []const u8, o: StartupBenchOptions) !struct { run: sb.ChildRun, spawn_ns: u64 } {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, try std.fmt.allocPrint(arena, "--startup-report-json={s}", .{json_path}), "--exit-after-startup" });
    if (o.inject) try argv.append(arena, "--bench-inject-key-after-first-frame");
    if (workspace) |w| try argv.append(arena, w) else try argv.append(arena, "--welcome");
    std.Io.Dir.cwd().deleteFile(io, json_path) catch {};
    const spawn_ns = nowNs(io);
    var child = try std.process.spawn(io, .{ .argv = argv.items, .environ_map = env, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit, .create_no_window = true });
    const Waiter = struct {
        done: std.atomic.Value(bool) = .init(false),
        fn run(w: *@This(), c: *std.process.Child, io_: std.Io) std.Io.Cancelable!?std.process.Child.Term {
            defer w.done.store(true, .release);
            return c.wait(io_) catch |e| {
                if (e == error.Canceled) {
                    c.kill(io_);
                    return error.Canceled;
                }
                return null;
            };
        }
    };
    var waiter: Waiter = .{};
    var fut = io.concurrent(Waiter.run, .{ &waiter, &child, io }) catch {
        // No concurrency: wait without a timeout.
        _ = child.wait(io) catch {};
        return .{ .run = try readRun(arena, io, json_path), .spawn_ns = spawn_ns };
    };
    const deadline = spawn_ns + @as(u64, o.timeout_ms) * std.time.ns_per_ms;
    while (!waiter.done.load(.acquire)) {
        if (nowNs(io) >= deadline) {
            _ = fut.cancel(io) catch {};
            return error.Timeout;
        }
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    const term = (fut.await(io) catch null) orelse return error.WaitFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
    return .{ .run = try readRun(arena, io, json_path), .spawn_ns = spawn_ns };
}

fn readRun(arena: std.mem.Allocator, io: std.Io, path: []const u8) !sb.ChildRun {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return error.NoReport;
    return sb.parseChild(arena, text);
}

/// Copies the files under `src` into `dst` (made fresh, so nothing of it
/// is in the page cache yet).
fn copyTree(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var from = try cwd.openDir(io, src, .{ .iterate = true });
    defer from.close(io);
    try cwd.createDirPath(io, dst);
    var to = try cwd.openDir(io, dst, .{});
    defer to.close(io);
    var w = try from.walk(gpa);
    defer w.deinit();
    while (try w.next(io)) |e| switch (e.kind) {
        .directory => try to.createDirPath(io, e.path),
        .file => try from.copyFile(e.path, to, e.path, io, .{ .make_path = true }),
        else => {},
    };
}

fn isRoot() bool {
    if (builtin.os.tag != .linux) return false;
    return std.os.linux.geteuid() == 0;
}

/// Linux, as root: write back dirty pages, then drop the page cache.
fn dropCaches(io: std.Io) bool {
    if (builtin.os.tag != .linux) return false;
    std.os.linux.sync();
    const f = std.Io.Dir.cwd().openFile(io, "/proc/sys/vm/drop_caches", .{ .mode = .write_only }) catch return false;
    defer f.close(io);
    f.writeStreamingAll(io, "3\n") catch return false;
    return true;
}

pub const Outcome = struct { failures: u32, input_late: u32 };

/// Runs the bench and writes the JSON (to `o.out`) and a summary to `w`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, parent_env: *const std.process.Environ.Map, o: StartupBenchOptions, w: *std.Io.Writer) !Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exe = o.exe orelse return error.MissingExe;
    if (o.session != null) try w.writeAll("bench-startup: --session is not used yet (the E08 session model restores sessions); runs use an empty state folder\n");

    // A scratch folder for records, state and cold copies.
    const tmp_root = try std.fmt.allocPrint(arena, "{s}/zigguro-bench-startup-{d}", .{ parent_env.get("TMPDIR") orelse parent_env.get("TEMP") orelse "/tmp", nowNs(io) });
    try std.Io.Dir.cwd().createDirPath(io, tmp_root);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_root) catch {};
    var env = try parent_env.clone(arena);
    try env.put("ZIGGURO_STATE_DIR", try std.fmt.allocPrint(arena, "{s}/state", .{tmp_root}));
    if (o.platform) |p| try env.put("ZG_PLATFORM", p);

    var c: sb.Collector = .init(gpa);
    defer c.deinit();
    var failures: u32 = 0;
    const total = o.warmup_runs + o.runs;
    for (0..total) |i| {
        const json = try std.fmt.allocPrint(arena, "{s}/run-{d}.json", .{ tmp_root, i });
        const r = launch(arena, io, &env, exe, o.workspace, json, o) catch |e| {
            try w.print("bench-startup: warm run {d} failed: {t}\n", .{ i, e });
            failures += 1;
            continue;
        };
        if (i < o.warmup_runs) continue;
        c.addRun(r.run, r.spawn_ns, false) catch |e| {
            try w.print("bench-startup: warm run {d}: {t}\n", .{ i, e });
            failures += 1;
        };
    }

    const cold_kind: sb.ColdKind = if (o.cold_runs == 0) .none else if (isRoot()) .drop_caches else .pseudo_cold;
    for (0..o.cold_runs) |i| {
        const json = try std.fmt.allocPrint(arena, "{s}/cold-{d}.json", .{ tmp_root, i });
        var run_exe = exe;
        var ws = o.workspace;
        if (cold_kind == .drop_caches) {
            if (!dropCaches(io)) try w.writeAll("bench-startup: could not drop the page cache\n");
        } else {
            const dir = try std.fmt.allocPrint(arena, "{s}/cold-{d}", .{ tmp_root, i });
            try std.Io.Dir.cwd().createDirPath(io, dir);
            run_exe = try std.fs.path.join(arena, &.{ dir, std.fs.path.basename(exe) });
            try std.Io.Dir.cwd().copyFile(exe, std.Io.Dir.cwd(), run_exe, io, .{});
            if (o.workspace) |src| {
                const dst = try std.fs.path.join(arena, &.{ dir, "workspace" });
                try copyTree(gpa, io, src, dst);
                ws = dst;
            }
        }
        const r = launch(arena, io, &env, run_exe, ws, json, o) catch |e| {
            try w.print("bench-startup: cold run {d} failed: {t}\n", .{ i, e });
            failures += 1;
            continue;
        };
        c.addRun(r.run, r.spawn_ns, true) catch |e| {
            try w.print("bench-startup: cold run {d}: {t}\n", .{ i, e });
            failures += 1;
        };
    }

    const governor = sb.readGovernor(arena, io);
    if (governor) |g| if (!std.mem.eql(u8, g, "performance")) try w.print("bench-startup: warning: the CPU governor is {s}, not performance; numbers will vary\n", .{g});
    const meta: sb.Meta = .{
        .platform = o.platform orelse "auto",
        .cold_kind = cold_kind,
        .governor = governor,
        .machine = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag),
        .workspace = o.workspace,
    };
    try c.writeSummary(w);
    if (c.input_late > 0) try w.print("bench-startup: {d} launches handled the injected key later than two frames after the first frame\n", .{c.input_late});
    if (o.out) |path| {
        if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var fw = f.writer(io, &buf);
        try c.writeJson(&fw.interface, meta);
        try fw.interface.flush();
        try w.print("bench-startup: wrote {s}\n", .{path});
    }
    return .{ .failures = failures, .input_late = c.input_late };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const o = StartupBenchOptions.parse(args[1..]) catch |e| {
        std.debug.print("bench-startup: {t}\nusage: zigguro-bench-startup --exe PATH [--out PATH] [--runs N] [--cold-runs N] [--warmup-runs N] [--timeout-ms N] [--workspace DIR] [--platform NAME] [--no-inject]\n", .{e});
        return 2;
    };
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const r = try run(gpa, io, init.environ_map, o, &out.interface);
    try out.interface.flush();
    return if (r.failures == 0 and r.input_late == 0) 0 else 1;
}

test "bench-startup: options" {
    const o = try StartupBenchOptions.parse(&.{ "--runs", "2", "--cold-runs", "0", "--platform", "headless", "--exe", "x", "--no-inject" });
    try std.testing.expectEqual(@as(u16, 2), o.runs);
    try std.testing.expectEqual(@as(u16, 0), o.cold_runs);
    try std.testing.expectEqualStrings("headless", o.platform.?);
    try std.testing.expect(!o.inject);
    try std.testing.expectError(error.UnknownArgument, StartupBenchOptions.parse(&.{"--bogus"}));
    try std.testing.expectError(error.MissingValue, StartupBenchOptions.parse(&.{"--runs"}));
}
