//! `zg task` against `fake_task`: the list, a run's result, problems and
//! output tail, JSON, exit codes and an untrusted workspace.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const test_exes = @import("zg_test_exes");
const HeadlessTasks = @import("HeadlessTasks.zig");
const cli = @import("cli.zig");

const testing = std.testing;
const gpa = testing.allocator;

const Fx = struct {
    rt: zg_core.Runtime,
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    env: std.process.Environ.Map,
    tasks: HeadlessTasks,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn init(f: *Fx, trusted: bool) !void {
        f.rt.initTesting();
        f.tmp = testing.tmpDir(.{});
        const io = f.rt.io;
        f.root = f.root_buf[0..try f.tmp.dir.realPathFile(io, ".", &f.root_buf)];
        const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, test_exes.fake_task, gpa);
        defer gpa.free(exe);
        // The fake's path as a ZON string (backslashes on Windows).
        var esc: std.Io.Writer.Allocating = .init(gpa);
        defer esc.deinit();
        try std.zon.stringify.serialize(exe, .{}, &esc.writer);
        const zon = try std.mem.replaceOwned(u8, gpa,
            \\.{ .tasks = .{
            \\    .{ .label = "check", .command = FAKE, .group = .{ .kind = .build, .is_default = true }, .problem_matcher = "$zig",
            \\       .args = .{ "--err", "compiling", "--err", "src/a.zig:2:5: error: oops", "--exit", "1" } },
            \\    .{ .label = "ok", .command = FAKE, .args = .{ "--out", "fine" } },
            \\} }
        , "FAKE", esc.written());
        defer gpa.free(zon);
        try f.tmp.dir.createDirPath(io, ".zigguro");
        try f.tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/tasks.zon", .data = zon });
        f.env = .init(gpa);
        try f.tasks.init(&f.rt, .{ .root = f.root, .env = &f.env, .trusted = trusted });
        f.out = .init(gpa);
        f.err = .init(gpa);
    }

    fn deinit(f: *Fx) void {
        f.out.deinit();
        f.err.deinit();
        f.tasks.deinit();
        f.env.deinit();
        f.tmp.cleanup();
        _ = f.rt.deinit();
    }

    fn run(f: *Fx, args: []const []const u8) !u8 {
        f.out.clearRetainingCapacity();
        f.err.clearRetainingCapacity();
        return cli.cliMain(&f.tasks, args, &f.out.writer, &f.err.writer);
    }
};

test "headless: zg task run tail and problems" {
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();

    try testing.expectEqual(@as(u8, 0), try f.run(&.{"list"}));
    try testing.expectEqualStrings("check [build, default]\nok\n", f.out.written());

    // A failing build: exit 1, the agents' rendering.
    try testing.expectEqual(@as(u8, 1), try f.run(&.{ "run", "check" }));
    const text = f.out.written();
    try testing.expect(std.mem.startsWith(u8, text, "'check' failed with exit code 1 after "));
    try testing.expect(std.mem.endsWith(u8, text, " ms.\n\n1 problem:\nsrc/a.zig:2:5: error: oops\n\nOutput (last lines):\ncompiling\nsrc/a.zig:2:5: error: oops\n"));

    try testing.expectEqual(@as(u8, 0), try f.run(&.{ "run", "ok", "--json", "--", "--out", "more" }));
    const J = struct { label: []const u8, state: []const u8, exit_code: ?u8, problems: []const struct { path: []const u8 }, tail: []const u8 };
    const j = try std.json.parseFromSlice(J, gpa, f.out.written(), .{ .ignore_unknown_fields = true });
    defer j.deinit();
    try testing.expectEqualStrings("succeeded", j.value.state);
    try testing.expectEqual(@as(?u8, 0), j.value.exit_code);
    // Extra arguments come after the task's own.
    try testing.expectEqualStrings("fine\nmore\n", j.value.tail);

    try testing.expectEqual(@as(u8, 2), try f.run(&.{ "run", "nope" }));
    try testing.expectEqualStrings("'nope' did not run: no task is called 'nope'\n", f.out.written());
    try testing.expectEqual(@as(u8, 2), try f.run(&.{"run"}));
    try testing.expectEqual(@as(u8, 2), try f.run(&.{"frob"}));
    try testing.expectEqual(@as(u8, 0), try f.run(&.{"--help"}));
}

test "headless: an untrusted workspace lists its tasks and runs none" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    try testing.expectEqual(@as(u8, 0), try f.run(&.{"list"}));
    try testing.expectEqualStrings("check [build, default] (cannot run: workspace not trusted)\nok (cannot run: workspace not trusted)\n", f.out.written());
    try testing.expectEqual(@as(u8, 2), try f.run(&.{ "run", "ok" }));
    try testing.expectEqualStrings(cli.untrusted_message ++ "\n", f.err.written());
    try testing.expectEqualStrings("", f.out.written());
}

test "headless: common flags" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var bad: []const u8 = "";
    const c = (try cli.Common.parse(arena.allocator(), &.{ "run", "--workspace", "/w", "x", "--untrusted", "--zig=/z/zig", "--", "--workspace" }, &bad)).?;
    try testing.expectEqualStrings("/w", c.workspace.?);
    try testing.expectEqualStrings("/z/zig", c.zig.?);
    try testing.expect(c.untrusted);
    try testing.expectEqual(@as(usize, 4), c.rest.len);
    try testing.expectEqualStrings("--workspace", c.rest[3]);
    try testing.expectEqual(@as(?cli.Common, null), try cli.Common.parse(arena.allocator(), &.{"--zig"}, &bad));
    try testing.expectEqualStrings("--zig", bad);
}
