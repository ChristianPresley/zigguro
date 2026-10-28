//! Status against git itself: each scenario builds a repository with the
//! system git, then compares `status` with `git status --porcelain`.
//! Skipped where no git is installed (and on Windows, whose shell differs).

const std = @import("std");
const builtin = @import("builtin");
const status_mod = @import("status.zig");
const Repository = @import("repository.zig").Repository;
const testing = std.testing;

const Scenario = struct {
    name: []const u8,
    /// sh script run in the new repository after `git init -b main`.
    script: []const u8,
    untracked: status_mod.Untracked = .normal,
    ignored: bool = false,
};

const base = "printf 'one\\n' > a.txt; mkdir -p src/deep; printf 'x\\n' > src/x.zig; printf 'y\\n' > src/deep/y.zig; git add -A; git commit -qm base; ";

const scenarios = [_]Scenario{
    .{ .name = "clean", .script = base },
    .{ .name = "empty repository", .script = "printf 'n\\n' > new.txt" },
    .{ .name = "staged in an unborn repository", .script = "printf 'n\\n' > new.txt; git add new.txt" },
    .{ .name = "modified", .script = base ++ "printf 'two\\n' > a.txt" },
    .{ .name = "same size modification", .script = base ++ "printf 'owe\\n' > a.txt" },
    .{ .name = "staged and modified again", .script = base ++ "printf 'two\\n' > a.txt; git add a.txt; printf 'three\\n' > a.txt" },
    .{ .name = "added and untracked", .script = base ++ "printf 'n\\n' > n.txt; git add n.txt; printf 'u\\n' > u.txt" },
    .{ .name = "deleted unstaged and staged", .script = base ++ "rm a.txt; git rm -q src/x.zig" },
    .{ .name = "untracked directories", .script = base ++ "mkdir -p new/inner empty; printf 'z\\n' > new/inner/z.txt; printf 'q\\n' > src/deep/q.zig" },
    .{ .name = "untracked all", .script = base ++ "mkdir -p new/inner; printf 'z\\n' > new/inner/z.txt; printf 'w\\n' > new/w.txt", .untracked = .all },
    .{ .name = "untracked no", .script = base ++ "printf 'u\\n' > u.txt; printf 'two\\n' > a.txt", .untracked = .no },
    .{ .name = "gitignore with negation and directories", .script = base ++ "printf '*.log\\n!keep.log\\nbuild/\\n' > .gitignore; printf l > x.log; printf k > keep.log; mkdir -p build logs; printf b > build/out; printf l > logs/a.log" },
    .{ .name = "nested gitignore and anchors", .script = base ++ "printf '/top.tmp\\n' > .gitignore; printf 'gen\\n' > src/.gitignore; printf t > top.tmp; mkdir -p src/sub; printf t > src/sub/top.tmp; printf g > src/gen; git add .gitignore src/.gitignore; git commit -qm ig" },
    .{ .name = "info exclude", .script = base ++ "printf 'secret\\n' >> .git/info/exclude; printf s > secret; printf v > visible" },
    .{ .name = "ignored listed", .script = base ++ "printf '*.o\\nout/\\n' > .gitignore; printf o > a.o; mkdir out; printf x > out/x", .ignored = true },
    .{ .name = "mode change", .script = base ++ "git config core.filemode true; chmod +x a.txt" },
    .{ .name = "filemode off", .script = base ++ "git config core.filemode false; chmod +x a.txt" },
    .{ .name = "type change to a symlink", .script = base ++ "rm a.txt; ln -s src/x.zig a.txt" },
    .{ .name = "symlink retarget", .script = base ++ "ln -s a.txt l; git add l; git commit -qm l; rm l; ln -s src/x.zig l" },
    .{ .name = "intent to add", .script = base ++ "printf 'i\\n' > i.txt; git add -N i.txt" },
    .{ .name = "file replaced by a directory", .script = base ++ "rm a.txt; mkdir a.txt; printf d > a.txt/inside" },
    .{ .name = "directory replaced by a file", .script = base ++ "rm -r src/deep; printf f > src/deep" },
    .{ .name = "conflict both modified", .script = base ++ "git checkout -qb other; printf 'theirs\\n' > a.txt; git commit -qam t; git checkout -q main; printf 'ours\\n' > a.txt; git commit -qam o; git merge -q other >/dev/null 2>&1 || true" },
    .{ .name = "conflicts added and deleted", .script = base ++ "git checkout -qb other; printf 'T\\n' > b.txt; git rm -q src/x.zig; printf 'z2\\n' > src/deep/y.zig; git add -A; git commit -qm t; git checkout -q main; printf 'O\\n' > b.txt; printf 'x2\\n' > src/x.zig; git rm -q src/deep/y.zig; git add -A; git commit -qm o; git merge -q other >/dev/null 2>&1 || true" },
    .{ .name = "autocrlf", .script = "git config core.autocrlf true; printf 'one\\ntwo\\n' > a.txt; git add a.txt; git commit -qm c; printf 'one\\r\\ntwo\\r\\n' > a.txt" },
    .{ .name = "racy rewrite in the same second", .script = base ++ "printf 'two\\n' > a.txt; git add a.txt; printf 'six\\n' > a.txt" },
    .{ .name = "files untracked by git rm --cached", .script = base ++ "git rm -rq --cached src" },
};

pub fn gitAvailable(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "git", "--version" }, .environ_map = env }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

pub fn sh(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, env: *const std.process.Environ.Map, script: []const u8) ![]u8 {
    const r = try std.process.run(gpa, io, .{
        .argv = &.{ "sh", "-c", script },
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(r.stderr);
    if (!(r.term == .exited and r.term.exited == 0)) {
        std.debug.print("script failed: {s}\n{s}\n", .{ script, r.stderr });
        gpa.free(r.stdout);
        return error.ScriptFailed;
    }
    return r.stdout;
}

/// Lines sorted, so ordering differences between sections do not count.
fn sortedLines(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| try out.append(gpa, l);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

test "status: porcelain equivalence with git on scenarios" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env.put("HOME", root);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CEILING_DIRECTORIES", root);
    try env.put("GIT_AUTHOR_NAME", "A");
    try env.put("GIT_AUTHOR_EMAIL", "a@example.com");
    try env.put("GIT_COMMITTER_NAME", "C");
    try env.put("GIT_COMMITTER_EMAIL", "c@example.com");
    try env.put("LANG", "C");
    if (!gitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var failures: usize = 0;
    for (scenarios, 0..) |sc, n| {
        var nb: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "s{d}", .{n});
        try tmp.dir.createDirPath(io, name);
        const dir = try std.fs.path.join(gpa, &.{ root, name });
        defer gpa.free(dir);
        const init = try std.mem.concat(gpa, u8, &.{ "git init -q -b main . && git config core.symlinks true && ", sc.script });
        defer gpa.free(init);
        gpa.free(try sh(gpa, io, dir, &env, init));

        const repo = (try Repository.discover(gpa, io, dir, .{ .env = &env })).?;
        defer repo.close();
        var res = try status_mod.status(repo, .{ .untracked = sc.untracked, .ignored = sc.ignored });
        defer res.deinit();
        const ours = try res.porcelain(gpa);
        defer gpa.free(ours);

        const flags = switch (sc.untracked) {
            .no => "-uno",
            .normal => "-unormal",
            .all => "-uall",
        };
        const cmd = try std.fmt.allocPrint(gpa, "git -c core.quotepath=false -c status.renames=false status --porcelain {s}{s}", .{ flags, if (sc.ignored) " --ignored" else "" });
        defer gpa.free(cmd);
        const theirs = try sh(gpa, io, dir, &env, cmd);
        defer gpa.free(theirs);

        const a = try sortedLines(gpa, ours);
        defer gpa.free(a);
        const b = try sortedLines(gpa, theirs);
        defer gpa.free(b);
        var same = a.len == b.len;
        if (same) for (a, b) |x, y| {
            if (!std.mem.eql(u8, x, y)) same = false;
        };
        if (!same) {
            failures += 1;
            std.debug.print("\nscenario \"{s}\":\n--- ours\n{s}--- git\n{s}", .{ sc.name, ours, theirs });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "status: refresh writes stat data so the next run needs no hashing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env.put("HOME", root);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CEILING_DIRECTORIES", root);
    if (!gitAvailable(gpa, io, &env)) return error.SkipZigTest;
    gpa.free(try sh(gpa, io, root, &env, "mkdir r && cd r && git init -q && printf a > a && git add a && touch -d '2001-01-01' a"));
    const dir = try std.fs.path.join(gpa, &.{ root, "r" });
    defer gpa.free(dir);
    const repo = (try Repository.discover(gpa, io, dir, .{ .env = &env })).?;
    defer repo.close();
    var r1 = try status_mod.status(repo, .{});
    defer r1.deinit();
    try testing.expectEqual(@as(usize, 1), r1.refreshed);
    var r2 = try status_mod.status(repo, .{});
    defer r2.deinit();
    try testing.expectEqual(@as(usize, 0), r2.refreshed);
    // git reads the refreshed index.
    const out = try sh(gpa, io, dir, &env, "git status --porcelain && git diff --cached --stat");
    defer gpa.free(out);
    try testing.expectEqualStrings("A  a\n a | 1 +\n 1 file changed, 1 insertion(+)\n", out);
}

test "stage and commit: git accepts the result (fsck, log, status)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const stage = @import("stage.zig");
    const commit_cmd = @import("commit_cmd.zig");
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env.put("HOME", root);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CEILING_DIRECTORIES", root);
    try env.put("GIT_AUTHOR_NAME", "A");
    try env.put("GIT_AUTHOR_EMAIL", "a@example.com");
    try env.put("GIT_COMMITTER_NAME", "C");
    try env.put("GIT_COMMITTER_EMAIL", "c@example.com");
    if (!gitAvailable(gpa, io, &env)) return error.SkipZigTest;
    gpa.free(try sh(gpa, io, root, &env, "mkdir r && cd r && git init -q -b main && mkdir -p d/e && printf 1 > d/e/f && printf 2 > g && ln -s g l && printf x > x && chmod +x x && git add -A && git commit -qm base"));
    const dir = try std.fs.path.join(gpa, &.{ root, "r" });
    defer gpa.free(dir);
    const repo = (try Repository.discover(gpa, io, dir, .{ .env = &env })).?;
    defer repo.close();
    try tmp.dir.writeFile(io, .{ .sub_path = "r/g", .data = "22" });
    try tmp.dir.writeFile(io, .{ .sub_path = "r/d/new", .data = "n" });
    try tmp.dir.deleteFile(io, "r/d/e/f");
    _ = try stage.add(repo, &.{}, .{});
    var c1 = try commit_cmd.commit(repo, .{ .message = "native one\n\nbody", .env = &env });
    defer c1.deinit(gpa);
    try tmp.dir.writeFile(io, .{ .sub_path = "r/g", .data = "333" });
    var c2 = try commit_cmd.commit(repo, .{ .message = "native two", .all = true, .env = &env });
    defer c2.deinit(gpa);
    const out = try sh(gpa, io, dir, &env, "git fsck --strict --no-progress 2>&1 && git log --format='%s|%an' && git status --porcelain && git ls-files -s | wc -l && git reflog --format=%gs | head -2");
    defer gpa.free(out);
    try testing.expectEqualStrings("native two|A\nnative one|A\nbase|A\n4\ncommit: native two\ncommit: native one\n", out);
}
