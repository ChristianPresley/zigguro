//! data_run_program over real processes (E13.F06.S02.T02): the fixture
//! program (test/fixtures/data_program.zig) is resolved on PATH, run
//! through `ProcessExec` from its argv (no shell), and its output files
//! captured as artifacts.

const std = @import("std");
const builtin = @import("builtin");
const zg_ai = @import("zg_ai");
const zg_agents = @import("zg_agents");
const fixtures = @import("agents_fixtures");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const external = zg_agents.data.external;
const artifacts = zg_agents.artifacts;

const Allow = struct {
    asked: usize = 0,
    fn decide(ctx: *anyopaque, _: *const external.ProgramRun, _: []const u8) external.Decision {
        const s: *Allow = @ptrCast(@alignCast(ctx));
        s.asked += 1;
        return .{ .allow = 1 };
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    store_dir: std.Io.Dir,
    store: *artifacts.ArtifactStore,
    allow: Allow = .{},
    env: std.process.Environ.Map,
    pexec: external.ProcessExec,
    deps: external.Deps,

    fn init(f: *Fx) !void {
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.arena = .init(gpa);
        const a = f.arena.allocator();
        try f.tmp.dir.createDirPath(io, ".zigguro/artifacts");
        f.store_dir = try f.tmp.dir.openDir(io, ".zigguro/artifacts", .{ .iterate = true });
        f.store = try artifacts.ArtifactStore.open(gpa, io, f.store_dir, .{});
        f.allow = .{};
        f.env = try testing.environ.createMap(gpa);
        f.pexec = .{ .gpa = gpa, .env = &f.env };
        f.deps = .{
            .gpa = gpa,
            .io = io,
            .workspace = f.tmp.dir,
            .workspace_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{f.tmp.sub_path}),
            .approval = .{ .ctx = &f.allow, .decide = Allow.decide },
            .exec = f.pexec.port(),
            .store = f.store,
            .run = zg_agents.runs.RunId.fromInt(7),
            .env_path = std.fs.path.dirname(fixtures.program).?,
            .programs = &.{programName()},
        };
    }

    fn deinit(f: *Fx) void {
        f.env.deinit();
        f.store.close();
        f.store_dir.close(io);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn call(f: *Fx, comptime fmt: []const u8, args: anytype) !std.json.Value {
        const a = f.arena.allocator();
        const input = try std.fmt.allocPrint(a, fmt, args);
        const out = try external.run(&f.deps, a, input);
        if (out.is_error) {
            std.debug.print("{s}\n", .{out.text});
            return error.TestUnexpectedResult;
        }
        return std.json.parseFromSliceLeaky(std.json.Value, a, out.text, .{});
    }
};

fn programName() []const u8 {
    return std.fs.path.stem(fixtures.program);
}

test "outputs_captured_as_artifacts" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.call("{{\"program\":\"{s}\",\"args\":[\"write\"]}}", .{programName()});
    try testing.expectEqual(@as(usize, 1), f.allow.asked);
    try testing.expectEqual(@as(i64, 0), r.object.get("exit").?.integer);
    try testing.expect(!r.object.get("timed_out").?.bool);
    try testing.expectEqualStrings("wrote 2 files\n", r.object.get("stdout_tail").?.string);
    try testing.expectEqualStrings("a warning\n", r.object.get("stderr_tail").?.string);
    const outs = r.object.get("outputs").?.array.items;
    try testing.expectEqual(@as(usize, 2), outs.len);
    try testing.expectEqualStrings("markdown", outs[0].object.get("kind").?.string);
    try testing.expectEqualStrings("table", outs[1].object.get("kind").?.string);
    try testing.expectEqualStrings("city,total\nOslo,3\nLima,5\n", outs[1].object.get("preview").?.string);
    const id = artifacts.ArtifactId.parse(outs[1].object.get("id").?.string).?;
    const meta = (try f.store.get(id, f.arena.allocator())).?;
    var run_text = f.deps.run.text();
    try testing.expectEqualStrings(&run_text, meta.run.?);
}

test "argv_reaches_program_without_a_shell" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const tricky = [_][]const u8{ "$(echo hi)", "a b", "*", "; echo injected", "\"q\"", "%PATH%", "x & y", "`id`" };
    var w: std.Io.Writer.Allocating = .init(f.arena.allocator());
    try std.json.Stringify.value(tricky, .{}, &w.writer);
    const r2 = try f.call("{{\"program\":\"{s}\",\"args\":{s}}}", .{ programName(), try std.mem.concat(f.arena.allocator(), u8, &.{ "[\"args\",", w.written()[1..] }) });
    try testing.expectEqual(@as(i64, 7), r2.object.get("exit").?.integer);
    var want: std.ArrayList(u8) = .empty;
    for (tricky) |t| {
        try want.appendSlice(f.arena.allocator(), t);
        try want.append(f.arena.allocator(), '\n');
    }
    try testing.expectEqualStrings(want.items, r2.object.get("stdout_tail").?.string);
}

test "output_tails_bounded" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.call("{{\"program\":\"{s}\",\"args\":[\"spam\",\"5000\"]}}", .{programName()});
    const t = r.object.get("stdout_tail").?.string;
    try testing.expectEqual(@as(usize, external.tail_lines), std.mem.count(u8, t, "\n"));
    try testing.expect(std.mem.endsWith(u8, t, "line 4999\n"));
}

test "timeout_kills_tree" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const port = f.pexec.port();
    const req: external.ExecRequest = .{
        .argv = &.{ fixtures.program, "spawn-sleep", "pid.txt" },
        .cwd = f.deps.workspace_path,
        .timeout_ms = 700,
        .env = &.{},
        .title = "t",
        .ticket = 1,
    };
    const start = std.Io.Clock.awake.now(io);
    const res = try port.exec(port.ctx, io, a, &req);
    const took = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try testing.expect(res.timed_out);
    try testing.expect(res.exit == null);
    try testing.expect(took < 5000);
    const pid_text = try f.tmp.dir.readFileAlloc(io, "pid.txt", a, .limited(32));
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    // The grandchild went with its parent (gone, or a zombie waiting for
    // its new parent to reap it).
    var tries: usize = 0;
    while (alive(a, pid)) : (tries += 1) {
        if (tries > 100) return error.GrandchildSurvived;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
}

fn alive(a: std.mem.Allocator, pid: std.posix.pid_t) bool {
    if (builtin.os.tag == .linux) {
        const path = std.fmt.allocPrint(a, "/proc/{d}/stat", .{pid}) catch return true;
        const stat = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096)) catch return false;
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return true;
        return !(close + 2 < stat.len and stat[close + 2] == 'Z');
    }
    std.posix.kill(pid, @enumFromInt(0)) catch return false;
    return true;
}
