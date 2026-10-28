//! `git bisect` against git: the same commits to test, output, state
//! files, refs/bisect/* and HEAD reflog, step by step. Skipped without
//! git and on Windows.

const std = @import("std");
const builtin = @import("builtin");
const bisect = @import("bisect.zig");
const Repository = @import("repository.zig").Repository;
const helpers = @import("status_test.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Commits one second apart: `c <name>` commits on the current branch,
/// other lines run as they are.
fn history(gpa: Allocator, lines: []const []const u8) ![]u8 {
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(gpa);
    try s.appendSlice(gpa, "git init -q -b main && ");
    for (lines, 0..) |l, i| {
        if (std.mem.startsWith(u8, l, "c ")) {
            const name = l[2..];
            try s.print(gpa, "echo {s} > {s}.txt && git add {s}.txt && GIT_AUTHOR_DATE='{d} +0000' GIT_COMMITTER_DATE='{d} +0000' git commit -qm {s} && ", .{ name, name, name, 1700000000 + i, 1700000000 + i, name });
        } else if (std.mem.startsWith(u8, l, "merge ")) {
            try s.print(gpa, "GIT_AUTHOR_DATE='{d} +0000' GIT_COMMITTER_DATE='{d} +0000' git merge -q --no-edit {s} && ", .{ 1700000000 + i, 1700000000 + i, l[6..] });
        } else try s.print(gpa, "{s} && ", .{l});
    }
    try s.appendSlice(gpa, "true");
    return s.toOwnedSlice(gpa);
}

const snapshot =
    "for f in BISECT_START BISECT_TERMS BISECT_LOG BISECT_NAMES BISECT_EXPECTED_REV BISECT_ANCESTORS_OK; do " ++
    "if [ -e .git/$f ]; then echo \"== $f\"; cat .git/$f; fi; done; " ++
    "git for-each-ref refs/bisect; git rev-parse HEAD; git symbolic-ref -q HEAD; cat .git/logs/HEAD; git status --porcelain";

fn runScenario(lines: []const []const u8, steps: []const []const u8) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env.put("HOME", root);
    try env.put("LANG", "C");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CEILING_DIRECTORIES", root);
    try env.put("GIT_AUTHOR_NAME", "A");
    try env.put("GIT_AUTHOR_EMAIL", "a@example.com");
    try env.put("GIT_COMMITTER_NAME", "C");
    try env.put("GIT_COMMITTER_EMAIL", "c@example.com");
    try env.put("GIT_AUTHOR_DATE", "1700001000 +0000");
    try env.put("GIT_COMMITTER_DATE", "1700001000 +0000");
    if (!helpers.gitAvailable(gpa, io, &env)) return error.SkipZigTest;

    const script = try history(gpa, lines);
    defer gpa.free(script);
    const make = try std.fmt.allocPrint(gpa, "mkdir g && cd g && {s} && cd .. && cp -r g n", .{script});
    defer gpa.free(make);
    gpa.free(try helpers.sh(gpa, io, root, &env, make));
    const gdir = try std.fs.path.join(gpa, &.{ root, "g" });
    defer gpa.free(gdir);
    const ndir = try std.fs.path.join(gpa, &.{ root, "n" });
    defer gpa.free(ndir);
    const repo = (try Repository.discover(gpa, io, ndir, .{ .env = &env })).?;
    defer repo.close();

    for (steps) |step| {
        const cmd = try std.fmt.allocPrint(gpa, "git bisect {s} 2>/dev/null; true", .{step});
        defer gpa.free(cmd);
        const git_out = try helpers.sh(gpa, io, gdir, &env, cmd);
        defer gpa.free(git_out);
        // git also shows the first bad commit; the caller does that here.
        const want = if (std.mem.indexOf(u8, git_out, " commit\ncommit ")) |i| git_out[0 .. i + " commit\n".len] else git_out;

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var words: std.ArrayList([]const u8) = .empty;
        defer words.deinit(gpa);
        var it = std.mem.tokenizeScalar(u8, step, ' ');
        while (it.next()) |w| try words.append(gpa, w);
        const verb = words.items[0];
        const args = words.items[1..];
        if (std.mem.eql(u8, verb, "start")) {
            _ = bisect.start(repo, gpa, .{ .bad = if (args.len > 0) args[0] else null, .goods = if (args.len > 1) args[1..] else &.{} }, &aw.writer) catch {};
        } else if (std.mem.eql(u8, verb, "reset")) {
            bisect.reset(repo, gpa, if (args.len > 0) args[0] else null, 0, null) catch {};
        } else if (std.mem.eql(u8, verb, "log")) {
            const l = try bisect.readLog(repo, gpa);
            defer gpa.free(l);
            try aw.writer.writeAll(l);
        } else {
            const m = std.meta.stringToEnum(bisect.Mark, verb).?;
            _ = bisect.mark(repo, gpa, m, args, 0, &aw.writer) catch {};
        }
        testing.expectEqualStrings(want, aw.written()) catch |e| {
            std.debug.print("step: {s}\n", .{step});
            return e;
        };
        const gs = try helpers.sh(gpa, io, gdir, &env, snapshot);
        defer gpa.free(gs);
        const ns = try helpers.sh(gpa, io, ndir, &env, snapshot);
        defer gpa.free(ns);
        testing.expectEqualStrings(gs, ns) catch |e| {
            std.debug.print("state after step: {s}\n", .{step});
            return e;
        };
    }
}

const linear = [_][]const u8{ "c c1", "c c2", "c c3", "c c4", "c c5", "c c6", "c c7", "c c8" };

test "bisect: a linear history, one step at a time" {
    try runScenario(&linear, &.{ "start", "bad", "good HEAD~7", "good", "bad", "bad", "log", "reset" });
}

test "bisect: start with a range, skip, and reset to a commit" {
    try runScenario(&linear, &.{ "start main main~7", "skip", "good", "skip", "bad", "bad", "reset main~2" });
}

test "bisect: only skipped commits left" {
    try runScenario(&linear, &.{ "start main main~3", "skip", "skip", "skip", "reset" });
}

test "bisect: a history with merges" {
    try runScenario(&.{ "c c1", "c c2", "git checkout -qb side HEAD~1", "c s1", "c s2", "c s3", "git checkout -q main", "c c3", "merge side", "c c4", "c c5", "c c6" }, &.{ "start main main~5", "bad", "good", "good", "bad", "reset" });
    try runScenario(&.{ "c c1", "c c2", "git checkout -qb side HEAD~1", "c s1", "c s2", "c s3", "git checkout -q main", "c c3", "merge side", "c c4", "c c5", "c c6" }, &.{ "start main main~6", "good", "bad", "skip", "good", "reset" });
}

test "bisect: a good commit off the bad one's line tests the merge base" {
    try runScenario(&.{ "c c1", "c c2", "git checkout -qb side", "c s1", "c s2", "git checkout -q main", "c c3", "c c4", "c c5" }, &.{ "start main side", "good", "bad", "reset" });
}
