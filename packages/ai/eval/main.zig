//! `zig build eval` (E10.F10.S02.T02): runs the agent scenarios in this
//! directory and compares them with `baseline.json`.
//!
//!   --suite <dir>        the suite (default packages/ai/eval)
//!   --work <dir>         scenario workspaces (default .zig-cache/eval)
//!   --out <file>         report.json (default zig-out/eval/report.json)
//!   --filter <text>      only scenarios whose name contains it
//!   --jobs <n>           scenarios at once (default: CPU count)
//!   --zig <path>         the zig for `zig` commands (put first on PATH)
//!   --update-baseline    rewrite baseline.json from this run
//!   --live --model <id>  call the real provider, recording missing
//!                        exchanges into eval/cassettes (maintainers)
//!
//! Exits 1 on a regression: a scenario that passed in the baseline and
//! fails now, or turns or cost grown by more than 25%.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const zg_ai = @import("zg_ai");

const eval = zg_ai.testing.eval;
const Io = std.Io;

pub fn main(min: std.process.Init.Minimal) !u8 {
    var rt: zg_core.Runtime = undefined;
    try rt.init(min, .{});
    defer _ = rt.deinit();
    const gpa = rt.gpa;
    const io = rt.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    var suite: []const u8 = "packages/ai/eval";
    var work: []const u8 = ".zig-cache/eval";
    var report_path: []const u8 = "zig-out/eval/report.json";
    var filter: ?[]const u8 = null;
    var jobs: ?u32 = null;
    var update = false;
    var live = false;
    var model: ?[]const u8 = null;
    var zig_exe: ?[]const u8 = null;
    const argv = try min.args.toSlice(arena);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--update-baseline")) {
            update = true;
        } else if (std.mem.eql(u8, a, "--live")) {
            live = true;
        } else if (i + 1 < argv.len and std.mem.startsWith(u8, a, "--")) {
            i += 1;
            const v = argv[i];
            if (std.mem.eql(u8, a, "--suite")) suite = v else if (std.mem.eql(u8, a, "--work")) work = v else if (std.mem.eql(u8, a, "--out")) report_path = v else if (std.mem.eql(u8, a, "--filter")) filter = v else if (std.mem.eql(u8, a, "--model")) model = v else if (std.mem.eql(u8, a, "--zig")) zig_exe = v else if (std.mem.eql(u8, a, "--jobs")) {
                jobs = std.fmt.parseInt(u32, v, 10) catch return usage(out, "--jobs needs a number");
            } else return usage(out, a);
        } else return usage(out, a);
    }
    if (live and model == null) return usage(out, "--live needs --model <id>");

    try Io.Dir.cwd().createDirPath(io, work);
    const work_abs = try Io.Dir.cwd().realPathFileAlloc(io, work, arena);

    var env = try min.environ.createMap(gpa);
    defer env.deinit();
    // Commands find the zig that runs the build first.
    if (zig_exe) |z| if (std.fs.path.dirname(z)) |dir| {
        const sep = if (@import("builtin").os.tag == .windows) ";" else ":";
        const path = if (env.get("PATH")) |p| try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ dir, sep, p }) else dir;
        try env.put("PATH", path);
    };
    var client: ?*zg_net.http.Client = null;
    defer if (client) |c| c.deinit();
    var net: zg_ai.transport.ZgNet = undefined;
    var live_opts: ?eval.Live = null;
    if (live) {
        client = try zg_net.http.Client.init(&rt, .{ .environ_map = &env });
        net = .{ .client = client.? };
        live_opts = .{ .transport = net.transport(), .environ = &env, .model = model.? };
    }

    var report = try eval.runSuite(io, gpa, suite, .{ .work_dir = work_abs, .filter = filter, .jobs = jobs, .live = live_opts, .zig_exe = zig_exe, .environ = &env });
    defer report.deinit();
    try report.writeTable(out);

    // report.json
    if (std.fs.path.dirname(report_path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    var json: Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try report.writeJson(&json.writer);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = json.written() });
    try out.print("report: {s}\n", .{report_path});

    const baseline_path = try std.fs.path.join(arena, &.{ suite, "baseline.json" });
    if (update) {
        if (filter != null) return usage(out, "--update-baseline runs the whole suite; drop --filter");
        var b: Io.Writer.Allocating = .init(gpa);
        defer b.deinit();
        try eval.writeBaseline(&report, &b.writer);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = baseline_path, .data = b.written() });
        try out.print("baseline updated: {s}\n", .{baseline_path});
        return 0;
    }
    const baseline = Io.Dir.cwd().readFileAlloc(io, baseline_path, arena, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound => {
            try out.writeAll("no baseline: every failure counts\n");
            return if (report.passed() == report.results.len) 0 else 1;
        },
        else => return e,
    };
    const regs = try eval.regressions(arena, baseline, &report);
    for (regs) |r| try out.print("regression: {s}: {s}\n", .{ r.name, r.reason });
    if (regs.len > 0) return 1;
    try out.writeAll("no regressions\n");
    return 0;
}

fn usage(out: *Io.Writer, what: []const u8) u8 {
    out.print("zg_ai-eval: bad argument: {s}\nUsage: zg_ai-eval [--suite dir] [--work dir] [--out file] [--filter text] [--jobs n] [--zig path] [--update-baseline] [--live --model id]\n", .{what}) catch {};
    return 2;
}
