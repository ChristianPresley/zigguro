//! The task runner against `fake_task` (testdata/fake_task.zig): the
//! dependency graph, background tasks, headless output, termination,
//! terminals, trust and the agent tools.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const test_exes = @import("zg_test_exes");
const TaskList = @import("TaskList.zig");
const TaskRunner = @import("TaskRunner.zig");
const agent_tool = @import("agent_tool.zig");
const pm = @import("matcher/ProblemMatcher.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;
const fake = test_exes.fake_task;
const is_windows = builtin.os.tag == .windows;

/// A list from tasks.zon text where `FAKE` stands for the fake's path.
fn listOf(zon: []const u8, trusted: bool) !TaskList {
    // Absolute: tasks run in other directories.
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, fake, gpa);
    defer gpa.free(exe);
    const text = try std.mem.replaceOwned(u8, gpa, zon, "FAKE", exe);
    defer gpa.free(text);
    const z = try gpa.dupeZ(u8, text);
    defer gpa.free(z);
    var l = try TaskList.fromSources(gpa, .{ .tasks_zon = z, .os = builtin.os.tag, .trusted = trusted });
    errdefer l.deinit();
    for (l.warnings) |w| std.debug.print("warning: {s}\n", .{w.message});
    try testing.expectEqual(@as(usize, 0), l.warnings.len);
    return l;
}

/// Records what the runner publishes.
const Problems = struct {
    mutex: std.Io.Mutex = .init,
    sets: u32 = 0,
    last: u32 = 0,
    first_at: ?std.Io.Timestamp = null,
    reveals: u32 = 0,

    fn host(p: *Problems) TaskRunner.ProblemHost {
        return .{ .ctx = p, .set = set, .reveal = reveal };
    }

    fn set(ctx: *anyopaque, owner: []const u8, _: []const u8, problems: []const pm.Problem) void {
        const p: *Problems = @ptrCast(@alignCast(ctx));
        p.mutex.lockUncancelable(testing.io);
        defer p.mutex.unlock(testing.io);
        std.debug.assert(std.mem.startsWith(u8, owner, "task:"));
        p.sets += 1;
        p.last = @intCast(problems.len);
        if (problems.len > 0 and p.first_at == null) p.first_at = .now(testing.io, .awake);
    }

    fn reveal(ctx: *anyopaque) void {
        const p: *Problems = @ptrCast(@alignCast(ctx));
        p.reveals += 1;
    }
};

const Fixture = struct {
    rt: zg_core.Runtime,
    list: TaskList,
    runner: TaskRunner,
    arena: std.heap.ArenaAllocator,
    problems: Problems = .{},

    fn init(f: *Fixture, zon: []const u8, cfg: TaskRunner.Config) !void {
        f.rt.initTesting();
        f.list = try listOf(zon, true);
        f.problems = .{};
        var c = cfg;
        if (c.problems == null) c.problems = f.problems.host();
        f.runner = .init(&f.rt, &f.list, c);
        f.arena = .init(gpa);
    }

    fn deinit(f: *Fixture) void {
        f.runner.deinit();
        f.list.deinit();
        f.arena.deinit();
        _ = f.rt.deinit();
    }

    fn runWait(f: *Fixture, label: []const u8, opts: TaskRunner.RunOptions) !TaskRunner.TaskRunSummary {
        const run = try f.runner.run(label, opts);
        return f.runner.wait(run, f.arena.allocator());
    }
};

const root_dir = if (is_windows) "C:\\" else "/";

test "runner: dependsOn parallel/sequence/cycle detection/failure stops chain" {
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "a", .command = "FAKE", .args = .{ "--out", "A" } },
        \\    .{ .label = "b", .command = "FAKE", .args = .{ "--out", "B" } },
        \\    .{ .label = "seq", .command = "", .depends_on = .{ "a", "b" }, .depends_order = .sequence },
        \\    .{ .label = "slow", .command = "FAKE", .args = .{ "--sleep-ms", "300", "--out", "SLOW" } },
        \\    .{ .label = "par", .command = "FAKE", .args = .{ "--out", "PAR" }, .depends_on = .{ "slow", "b" } },
        \\    .{ .label = "x", .command = "FAKE", .depends_on = .{"y"} },
        \\    .{ .label = "y", .command = "FAKE", .depends_on = .{"x"} },
        \\    .{ .label = "fail", .command = "FAKE", .args = .{ "--exit", "3" } },
        \\    .{ .label = "chain", .command = "FAKE", .args = .{ "--out", "CHAIN" }, .depends_on = .{ "fail", "a" }, .depends_order = .sequence },
        \\    .{ .label = "lost", .command = "FAKE", .depends_on = .{"nothing"} },
        \\} }
    , .{ .root = root_dir, .problems = null });
    defer f.deinit();

    const seq = try f.runWait("seq", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.succeeded, seq.state);
    try testing.expectEqualStrings("A\nB\n", seq.tail);

    // Parallel: b finishes while slow sleeps, and par runs after both.
    const par = try f.runWait("par", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.succeeded, par.state);
    try testing.expectEqualStrings("B\nSLOW\nPAR\n", par.tail);
    try testing.expect(par.duration_ms >= 300);

    const cyc = try f.runWait("x", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.failed, cyc.state);
    try testing.expectEqualStrings("dependency cycle: x -> y -> x", cyc.message.?);

    const lost = try f.runWait("lost", .{ .headless = true });
    try testing.expectEqualStrings("task 'lost' depends on 'nothing', which is not a task", lost.message.?);
    const none = try f.runWait("missing", .{ .headless = true });
    try testing.expectEqualStrings("no task is called 'missing'", none.message.?);

    // The failure stops the chain: neither `a` nor `chain` runs.
    const chain = try f.runWait("chain", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.failed, chain.state);
    try testing.expectEqualStrings("a task it depends on failed", chain.message.?);
    try testing.expectEqualStrings("", chain.tail);
    const fail = try f.runWait("fail", .{ .headless = true });
    try testing.expectEqual(@as(?u8, 3), fail.exit_code);
    try testing.expect(fail.message == null);
}

test "runner: background dependency done on endsPattern" {
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "watch", .command = "FAKE", .is_background = true, .problem_matcher = "$zig-watch",
        \\       .args = .{ "--out", "watching", "--sleep-ms", "100", "--out", "src/a.zig:1:2: error: bad", "--out", "Build Summary: 1/3 steps succeeded (1 failed)", "--sleep-ms", "60000" } },
        \\    .{ .label = "main", .command = "FAKE", .args = .{ "--out", "MAIN" }, .depends_on = .{"watch"} },
        \\    .{ .label = "plain-bg", .command = "FAKE", .is_background = true, .args = .{ "--sleep-ms", "60000" } },
        \\    .{ .label = "after-plain", .command = "FAKE", .args = .{ "--out", "AFTER" }, .depends_on = .{"plain-bg"} },
        \\} }
    , .{ .root = "/tmp", .problems = null });
    defer f.deinit();

    const t0: std.Io.Timestamp = .now(testing.io, .awake);
    const main = try f.runWait("main", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.succeeded, main.state);
    // Ready at the end of the first cycle, ~100 ms in, not at exit.
    try testing.expect(t0.durationTo(.now(testing.io, .awake)).toMilliseconds() < 30_000);
    try testing.expect(std.mem.endsWith(u8, main.tail, "MAIN\n"));
    // The cycle's problem was published.
    try testing.expectEqual(@as(u32, 1), f.problems.last);
    try testing.expectEqual(@as(usize, 1), main.problems.len);

    // The watch task keeps running, and the next run reuses it.
    var watch: ?*TaskRunner.TaskRun = null;
    for (f.runner.runs.items) |r| if (std.mem.eql(u8, r.label, "watch")) {
        watch = r;
    };
    try testing.expect(f.runner.status(watch.?).background_active);
    const main2 = try f.runWait("main", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.succeeded, main2.state);
    var watches: usize = 0;
    for (f.runner.runs.items) |r| watches += @intFromBool(std.mem.eql(u8, r.label, "watch"));
    try testing.expectEqual(@as(usize, 1), watches);

    // Without a background matcher a background task is ready at once.
    const after = try f.runWait("after-plain", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.succeeded, after.state);

    f.runner.terminate(watch.?);
    _ = try f.runner.wait(watch.?, f.arena.allocator());
    try testing.expectEqual(TaskRunner.State.terminated, f.runner.status(watch.?).state);
}

test "runner: headless run captures exit code, merged output order and tail" {
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "mixed", .command = "FAKE", .args = .{ "--out", "o1", "--sleep-ms", "30", "--err", "e1", "--sleep-ms", "30", "--out", "o2", "--exit", "7" } },
        \\    .{ .label = "args", .command = "FAKE", .args = .{ "--args", "fixed" } },
        \\    .{ .label = "zigstep", .command = "FAKE", .args = .{ "build", "test" } },
        \\    .{ .label = "envcwd", .command = "FAKE", .cwd = "sub", .env = .{.{ "ZG_TASK_TEST", "yes" }}, .args = .{ "--env", "ZG_TASK_TEST", "--cwd" } },
        \\} }
    , .{ .root = "/tmp", .problems = null });
    defer f.deinit();

    const s = try f.runWait("mixed", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.failed, s.state);
    try testing.expectEqual(@as(?u8, 7), s.exit_code);
    try testing.expectEqualStrings("o1\ne1\no2\n", s.tail);
    const short = try f.runWait("mixed", .{ .headless = true, .output_tail_lines = 2 });
    try testing.expectEqualStrings("e1\no2\n", short.tail);

    const args = try f.runWait("args", .{ .headless = true, .extra_args = &.{ "x y", "--z" } });
    try testing.expectEqualStrings("fixed\nx y\n--z\n", args.tail);

    // Only tasks from zig build steps get --error-style.
    const z = try f.runWait("zigstep", .{ .headless = true });
    try testing.expectEqualStrings("build\ntest\n", z.tail);
    {
        const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, fake, gpa);
        defer gpa.free(exe);
        var zl = try TaskList.fromSources(gpa, .{ .zig_steps = "  test   Run tests\n", .zig_exe = exe, .os = builtin.os.tag, .trusted = true });
        defer zl.deinit();
        f.runner.setList(&zl);
        defer f.runner.setList(&f.list);
        const zs = try f.runWait("zig build test", .{ .headless = true });
        try testing.expectEqualStrings("build\n--error-style\nminimal\ntest\n", zs.tail);
    }

    // A task's env needs the runner's base environment.
    const no_env = try f.runWait("envcwd", .{ .headless = true });
    try testing.expectEqualStrings("the task sets environment variables but the runner has no base environment", no_env.message.?);
}

test "runner: env, cwd and variables" {
    if (is_windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "sub");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &root_buf);
    const root = root_buf[0..n];

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "envcwd", .command = "FAKE", .cwd = "sub", .env = .{.{ "ZG_TASK_TEST", "yes" }}, .args = .{ "--env", "ZG_TASK_TEST", "--env", "PATH", "--cwd" } },
        \\    .{ .label = "shell", .type = .shell, .command = "printf '%s|'", .args = .{ "a b", "it's" } },
        \\} }
    , .{ .root = root, .env = &env, .problems = null });
    defer f.deinit();
    const s = try f.runWait("envcwd", .{ .headless = true });
    const want = try std.fmt.allocPrint(f.arena.allocator(), "ZG_TASK_TEST=yes\nPATH=/usr/bin:/bin\n{s}/sub\n", .{root});
    try testing.expectEqualStrings(want, s.tail);

    const sh = try f.runWait("shell", .{ .headless = true });
    try testing.expectEqual(TaskRunner.State.succeeded, sh.state);
    // The last line had no newline; the tail ends every line.
    try testing.expectEqualStrings("a b|it's|\n", sh.tail);
}

fn alive(pid: i64) bool {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return false;
    var sbuf: [512]u8 = undefined;
    const stat = std.Io.Dir.cwd().readFile(testing.io, path, &sbuf) catch return false;
    // A zombie (state Z) is dead: nothing reaps it in some containers.
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return true;
    return !(close + 2 < stat.len and stat[close + 2] == 'Z');
}

test "runner: terminate kills process tree" {
    if (is_windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "tree", .command = "FAKE", .args = .{ "--child", "--sleep-ms", "60000" } },
        \\} }
    , .{ .root = "/tmp", .problems = null });
    defer f.deinit();
    const run = try f.runner.run("tree", .{ .headless = true });
    var child: ?i64 = null;
    for (0..500) |_| {
        const s = try f.runner.summary(run, f.arena.allocator());
        if (std.mem.indexOf(u8, s.tail, "child ")) |i| {
            child = try std.fmt.parseInt(i64, std.mem.trimEnd(u8, s.tail[i + 6 ..], "\n"), 10);
            break;
        }
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(alive(child.?));
    f.runner.terminate(run);
    const s = try f.runner.wait(run, f.arena.allocator());
    try testing.expectEqual(TaskRunner.State.terminated, s.state);
    for (0..100) |_| {
        if (!alive(child.?)) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(!alive(child.?));
}

test "runner: deadline stops the run and says so" {
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "hang", .command = "FAKE", .args = .{ "--out", "started", "--sleep-ms", "60000" } },
        \\} }
    , .{ .root = "/tmp", .problems = null });
    defer f.deinit();
    const s = try f.runWait("hang", .{ .headless = true, .deadline = .after(testing.io, .fromMilliseconds(200)) });
    try testing.expect(s.timed_out);
    try testing.expectEqual(TaskRunner.State.terminated, s.state);
    try testing.expectEqualStrings("started\n", s.tail);
}

test "runner: problems appear while the task still runs" {
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "compile", .command = "FAKE", .problem_matcher = "$zig", .presentation = .{ .reveal_problems = .on_problem },
        \\       .args = .{ "--sleep-ms", "200", "--err", "/tmp/src/main.zig:9:27: error: expected type 'u32', found '[]const u8'", "--sleep-ms", "3000", "--exit", "1" } },
        \\} }
    , .{ .root = "/tmp", .problems = null });
    defer f.deinit();
    const t0: std.Io.Timestamp = .now(testing.io, .awake);
    const run = try f.runner.run("compile", .{ .headless = true });
    // Published at the next quiet tick (20 ms), not at the exit 3 s on.
    for (0..300) |_| {
        if (f.problems.first_at != null) break;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    const at = f.problems.first_at orelse return error.NoProblem;
    const ms = t0.durationTo(at).toMilliseconds();
    try testing.expect(ms < 1000);
    try testing.expectEqual(@as(u32, 1), f.problems.reveals);
    f.runner.terminate(run);
    const s = try f.runner.wait(run, f.arena.allocator());
    try testing.expectEqual(@as(usize, 1), s.problems.len);
    try testing.expectEqual(@as(u32, 9), s.problems[0].line);
}

/// Records terminal requests; output is fed by the test.
const Terms = struct {
    specs: std.ArrayList(TaskRunner.TermSpec) = .empty,
    keys: std.ArrayList(?[]const u8) = .empty,
    sinks: std.ArrayList(TaskRunner.OutputSink) = .empty,
    arena: std.heap.ArenaAllocator = .init(gpa),
    mutex: std.Io.Mutex = .init,

    fn host(t: *Terms) TaskRunner.TerminalHost {
        return .{ .ctx = t, .open = open, .tap = tap, .onExit = onExit, .kill = kill };
    }

    fn open(ctx: *anyopaque, spec: TaskRunner.TermSpec) anyerror!TaskRunner.TermHandle {
        const t: *Terms = @ptrCast(@alignCast(ctx));
        t.mutex.lockUncancelable(testing.io);
        defer t.mutex.unlock(testing.io);
        const a = t.arena.allocator();
        try t.specs.append(a, spec);
        try t.keys.append(a, if (spec.panel_key) |k| try a.dupe(u8, k) else null);
        return t.specs.items.len;
    }

    fn tap(ctx: *anyopaque, _: TaskRunner.TermHandle, sink: TaskRunner.OutputSink) void {
        const t: *Terms = @ptrCast(@alignCast(ctx));
        // The task's output, as the terminal would see it.
        sink.bytes(sink.ctx, "\x1b[1msrc/a.zig:3:4: error: from the terminal\x1b[0m\r\n");
        t.sinks.append(t.arena.allocator(), sink) catch {};
    }

    fn onExit(_: *anyopaque, _: TaskRunner.TermHandle, cb: TaskRunner.ExitCb) void {
        cb.exited(cb.ctx, 0);
    }

    fn kill(_: *anyopaque, _: TaskRunner.TermHandle) void {}
};

test "runner: panel shared/dedicated/new reuse keys" {
    var terms: Terms = .{};
    defer terms.arena.deinit();
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "b1", .command = "FAKE", .group = .{ .kind = .build }, .problem_matcher = "$zig" },
        \\    .{ .label = "t1", .command = "FAKE", .group = .{ .kind = .@"test" } },
        \\    .{ .label = "other", .command = "FAKE" },
        \\    .{ .label = "own", .command = "FAKE", .presentation = .{ .panel = .dedicated, .reveal = .silent, .focus = true, .clear = true } },
        \\    .{ .label = "fresh", .command = "FAKE", .presentation = .{ .panel = .new } },
        \\} }
    , .{ .root = "/tmp", .term = terms.host(), .problems = null });
    defer f.deinit();
    for ([_][]const u8{ "b1", "t1", "other", "own", "fresh" }) |l| {
        const s = try f.runWait(l, .{});
        try testing.expectEqual(TaskRunner.State.succeeded, s.state);
    }
    const want = [_]?[]const u8{ "tasks:build", "tasks:test", "tasks:none", "task:own", null };
    try testing.expectEqual(want.len, terms.keys.items.len);
    for (want, terms.keys.items) |w, g| {
        if (w) |x| try testing.expectEqualStrings(x, g.?) else try testing.expect(g == null);
    }
    const own = terms.specs.items[3];
    try testing.expectEqual(.silent, own.reveal);
    try testing.expect(own.focus and own.clear);
    try testing.expectEqualStrings("own", own.title);
    // The tapped output went through the matcher (escapes stripped).
    try testing.expectEqual(@as(u32, 1), f.runner.runs.items[0].problems);
    // Headless runs ignore the terminal host.
    _ = try f.runWait("b1", .{ .headless = true });
    try testing.expectEqual(want.len, terms.keys.items.len);
}

test "runner: untrusted task refuses to run" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var list = try listOf(
        \\.{ .tasks = .{ .{ .label = "a", .command = "FAKE", .args = .{ "--out", "ran" } } } }
    , false);
    defer list.deinit();
    var r: TaskRunner = .init(&rt, &list, .{ .root = "/tmp" });
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = try r.wait(try r.run("a", .{ .headless = true }), arena.allocator());
    try testing.expectEqual(TaskRunner.State.failed, s.state);
    try testing.expectEqualStrings("workspace not trusted", s.message.?);
    try testing.expectEqualStrings("", s.tail);
}

test "runner: spawn policy may deny a task" {
    const Deny = struct {
        fn decide(_: ?*anyopaque, argv: []const []const u8, _: ?[]const u8) TaskRunner.SpawnPolicy.Decision {
            return if (std.mem.indexOf(u8, argv[argv.len - 1], "secret") != null) .{ .deny = "not allowed by the sandbox" } else .{ .allow = .{} };
        }
    };
    const policy: TaskRunner.SpawnPolicy = .{ .decideFn = Deny.decide };
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "ok", .command = "FAKE", .args = .{ "--out", "fine" } },
        \\    .{ .label = "no", .command = "FAKE", .args = .{ "--out", "secret" } },
        \\} }
    , .{ .root = "/tmp", .policy = &policy, .problems = null });
    defer f.deinit();
    try testing.expectEqual(TaskRunner.State.succeeded, (try f.runWait("ok", .{ .headless = true })).state);
    const no = try f.runWait("no", .{ .headless = true });
    try testing.expectEqualStrings("not allowed by the sandbox", no.message.?);
}

test "agent_tool: task_run output golden" {
    const problems = [_]pm.Problem{
        .{
            .file = "/home/dev/proj/src/main.zig",
            .line = 9,
            .column = 27,
            .severity = .err,
            .message = "expected type 'u32', found '[]const u8'",
            .source = "zig",
            .related = &.{.{ .file = "/home/dev/proj/src/main.zig", .line = 3, .column = 19, .message = "parameter type declared here" }},
        },
        .{ .file = "/opt/zig/lib/std/start.zig", .line = 698, .column = 0, .severity = .warning, .code = "W1", .message = "outside the workspace", .source = "zig" },
    };
    const s: TaskRunner.TaskRunSummary = .{
        .state = .failed,
        .exit_code = 1,
        .tail = "install\n+- compile exe demo Debug native 1 errors\nerror: the following build command failed with exit code 1\n",
        .problems = &problems,
        .duration_ms = 1234,
        .timed_out = false,
        .message = null,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try agent_tool.renderSummary(&out.writer, "zig build", &s, "/home/dev/proj");
    try testing.expectEqualStrings(
        \\'zig build' failed with exit code 1 after 1234 ms.
        \\
        \\2 problems:
        \\src/main.zig:9:27: error: expected type 'u32', found '[]const u8'
        \\    src/main.zig:3:19: note: parameter type declared here
        \\/opt/zig/lib/std/start.zig:698: warning: outside the workspace [W1]
        \\
        \\Output (last lines):
        \\install
        \\+- compile exe demo Debug native 1 errors
        \\error: the following build command failed with exit code 1
        \\
    , out.written());

    out.clearRetainingCapacity();
    const timed: TaskRunner.TaskRunSummary = .{ .state = .terminated, .exit_code = null, .tail = "", .problems = &.{}, .duration_ms = 200, .timed_out = true, .message = null };
    try agent_tool.renderSummary(&out.writer, "hang", &timed, "/");
    try testing.expectEqualStrings("'hang' timed out after 200 ms and was stopped.\n", out.written());

    out.clearRetainingCapacity();
    const denied: TaskRunner.TaskRunSummary = .{ .state = .failed, .exit_code = null, .tail = "", .problems = &.{}, .duration_ms = 0, .timed_out = false, .message = "workspace not trusted" };
    try agent_tool.renderSummary(&out.writer, "a", &denied, "/");
    try testing.expectEqualStrings("'a' did not run: workspace not trusted\n", out.written());
}

test "agent_tool: task_run and task_list through the runner" {
    var f: Fixture = undefined;
    try f.init(
        \\.{ .tasks = .{
        \\    .{ .label = "check", .command = "FAKE", .group = .{ .kind = .build, .is_default = true }, .problem_matcher = "$zig", .detail = "Check the build",
        \\       .args = .{ "--err", "/tmp/src/a.zig:1:5: error: oops", "--exit", "1" } },
        \\    .{ .label = "watch", .command = "FAKE", .is_background = true },
        \\} }
    , .{ .root = "/tmp", .problems = null });
    defer f.deinit();
    const a = f.arena.allocator();

    var text: std.Io.Writer.Allocating = .init(a);
    var o = try agent_tool.runTool(&f.runner, a, "task_list", "{}", &text.writer);
    try testing.expect(o.ok);
    try testing.expectEqualStrings(
        \\check [build, default]: Check the build
        \\watch [background]
        \\
    , text.written());

    text = .init(a);
    o = try agent_tool.runTool(&f.runner, a, "task_run", "{\"name\":\"check\"}", &text.writer);
    // A failing build is a result, not a tool error.
    try testing.expect(o.ok);
    try testing.expect(std.mem.startsWith(u8, text.written(), "'check' failed with exit code 1 after "));
    try testing.expect(std.mem.indexOf(u8, text.written(), "\n1 problem:\nsrc/a.zig:1:5: error: oops\n") != null);
    const Status = struct { state: []const u8, exit_code: ?u8, timed_out: bool, problems: u32 };
    const st = try std.json.parseFromSliceLeaky(Status, a, o.status.?, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("failed", st.state);
    try testing.expectEqual(@as(u32, 1), st.problems);

    text = .init(a);
    o = try agent_tool.runTool(&f.runner, a, "task_run", "{\"name\":\"nope\"}", &text.writer);
    try testing.expect(!o.ok);
    try testing.expectEqualStrings("'nope' did not run: no task is called 'nope'\n", text.written());

    text = .init(a);
    o = try agent_tool.runTool(&f.runner, a, "task_run", "{\"name\":3}", &text.writer);
    try testing.expect(!o.ok);
}
