//! The git bridge against git itself: each scenario builds a repository
//! with git, copies it, runs an operation natively on one copy and with
//! git on the other, and compares commits (ids included, dates are
//! fixed), index, worktree, state files, stashes and reflog. Skipped
//! without git and on Windows.

const std = @import("std");
const builtin = @import("builtin");
const git = @import("zg_git");
const common = @import("common.zig");
const merge = @import("merge.zig");
const pick = @import("pick.zig");
const stash = @import("stash.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Op = union(enum) {
    merge: struct { name: []const u8, opts: merge.Options = .{} },
    merge_abort,
    cherry_pick: []const u8,
    cherry_pick_n: []const u8,
    revert: []const u8,
    stash_push: stash.PushOptions,
    stash_apply: usize,
    stash_pop: usize,
    stash_drop: usize,
    stash_clear,
};

const Scenario = struct {
    name: []const u8,
    setup: []const u8,
    git: []const u8,
    op: Op,
    /// The native operation is expected to fail with this error.
    fails: ?anyerror = null,
};

/// a.txt has eight lines; `feature` and `main` both branch from base.
const base = "git init -q -b main && printf '1\\n2\\n3\\n4\\n5\\n6\\n7\\n8\\n' > a.txt && printf 'k\\n' > keep.txt && printf 'gone\\n' > gone.txt && git add -A && git commit -qm base && ";
const diverged = base ++
    "git checkout -qb feature && sed -i 's/^1$/one/' a.txt && printf 'f\\n' > f.txt && git add -A && git commit -qm 'feature one' && " ++
    "sed -i 's/^2$/two/' a.txt && git commit -qam 'feature two' && " ++
    "git checkout -q main && sed -i 's/^8$/eight/' a.txt && printf 'm\\n' > m.txt && git add -A && git commit -qm 'main one'";
const conflicting = base ++
    "git checkout -qb feature && sed -i 's/^4$/four (feature)/' a.txt && git commit -qam 'feature four' && " ++
    "git checkout -q main && sed -i 's/^4$/four (main)/' a.txt && git commit -qam 'main four'";

const scenarios = [_]Scenario{
    .{ .name = "merge: three-way, clean", .setup = diverged, .git = "git merge -q --no-edit feature", .op = .{ .merge = .{ .name = "feature" } } },
    .{ .name = "merge: fast-forward", .setup = diverged ++ " && git checkout -qb behind HEAD~1 && git checkout -q main && git checkout -q behind", .git = "git merge -q main", .op = .{ .merge = .{ .name = "main" } } },
    .{ .name = "merge: up to date", .setup = diverged ++ " && git branch old HEAD~1", .git = "git merge -q old", .op = .{ .merge = .{ .name = "old" } } },
    .{ .name = "merge: --no-ff of a fast-forward", .setup = diverged ++ " && git checkout -qb behind HEAD~1 && git checkout -q behind", .git = "git merge -q --no-ff --no-edit main", .op = .{ .merge = .{ .name = "main", .opts = .{ .ff = .never } } } },
    .{ .name = "merge: into another branch", .setup = diverged ++ " && git checkout -qb topic", .git = "git merge -q --no-edit feature", .op = .{ .merge = .{ .name = "feature" } } },
    .{ .name = "merge: --no-commit", .setup = diverged, .git = "git merge -q --no-commit feature", .op = .{ .merge = .{ .name = "feature", .opts = .{ .commit = false } } } },
    .{ .name = "merge: content conflict", .setup = conflicting, .git = "git merge -q feature >/dev/null 2>&1 || true", .op = .{ .merge = .{ .name = "feature" } } },
    .{ .name = "merge: modify/delete conflict", .setup = base ++ "git checkout -qb feature && git rm -q gone.txt && git commit -qm del && git checkout -q main && printf 'kept\\n' > gone.txt && git commit -qam mod", .git = "git merge -q feature >/dev/null 2>&1 || true", .op = .{ .merge = .{ .name = "feature" } } },
    .{ .name = "merge: add/add conflict", .setup = base ++ "git checkout -qb feature && printf 'x\\ny\\n' > n.txt && git add n.txt && git commit -qm addf && git checkout -q main && printf 'x\\nz\\n' > n.txt && git add n.txt && git commit -qm addm", .git = "git merge -q feature >/dev/null 2>&1 || true", .op = .{ .merge = .{ .name = "feature" } } },
    .{ .name = "merge: blocked by a local edit", .setup = diverged ++ " && printf 'dirty\\n' >> a.txt", .git = "git merge -q --no-edit feature >/dev/null 2>&1 || true", .op = .{ .merge = .{ .name = "feature" } }, .fails = error.WouldOverwrite },
    .{ .name = "merge: unrelated local edits carry over", .setup = diverged ++ " && printf 'dirty\\n' >> keep.txt", .git = "git merge -q --no-edit feature", .op = .{ .merge = .{ .name = "feature" } } },
    .{ .name = "merge: --abort", .setup = conflicting ++ " && { git merge -q feature >/dev/null 2>&1 || true; }", .git = "git merge --abort", .op = .merge_abort },
    .{ .name = "cherry-pick: clean", .setup = diverged, .git = "git cherry-pick feature~1 >/dev/null", .op = .{ .cherry_pick = "feature~1" } },
    .{ .name = "cherry-pick: -n", .setup = diverged, .git = "git cherry-pick -n feature~1", .op = .{ .cherry_pick_n = "feature~1" } },
    .{ .name = "cherry-pick: conflict", .setup = conflicting, .git = "git cherry-pick feature >/dev/null 2>&1 || true", .op = .{ .cherry_pick = "feature" } },
    .{ .name = "revert: clean", .setup = diverged ++ " && git merge -q --no-edit feature", .git = "git revert --no-edit HEAD^2 >/dev/null", .op = .{ .revert = "HEAD^2" } },
    .{ .name = "revert: conflict", .setup = diverged ++ " && sed -i 's/^eight$/EIGHT/' a.txt && git commit -qam again", .git = "git revert --no-edit HEAD~1 >/dev/null 2>&1 || true", .op = .{ .revert = "HEAD~1" } },
    .{ .name = "stash: push", .setup = diverged ++ " && printf 'staged\\n' >> keep.txt && git add keep.txt && printf 'wt\\n' >> a.txt && rm gone.txt && printf 'u\\n' > untracked.txt", .git = "git stash -q", .op = .{ .stash_push = .{} } },
    .{ .name = "stash: push -u -m", .setup = diverged ++ " && printf 'wt\\n' >> a.txt && mkdir -p d && printf 'u\\n' > d/untracked.txt", .git = "git stash push -q -u -m 'my work'", .op = .{ .stash_push = .{ .include_untracked = true, .message = "my work" } } },
    .{ .name = "stash: push --keep-index", .setup = diverged ++ " && printf 'staged\\n' >> keep.txt && git add keep.txt && printf 'wt\\n' >> a.txt", .git = "git stash push -q --keep-index", .op = .{ .stash_push = .{ .keep_index = true } } },
    .{ .name = "stash: pop", .setup = diverged ++ " && printf 'wt\\n' >> a.txt && printf 'n\\n' > new.txt && git add new.txt && rm gone.txt && git stash -q", .git = "git stash pop -q", .op = .{ .stash_pop = 0 } },
    .{ .name = "stash: pop -u onto a moved HEAD", .setup = diverged ++ " && printf 'wt\\n' >> a.txt && printf 'u\\n' > u.txt && git stash -q -u && git merge -q --no-edit feature", .git = "git stash pop -q", .op = .{ .stash_pop = 0 } },
    .{ .name = "stash: apply with a conflict", .setup = conflicting ++ " && sed -i 's/^5$/five/' a.txt && git stash -q && sed -i 's/^5$/FIVE/' a.txt && git commit -qam five", .git = "git stash apply -q >/dev/null 2>&1 || true", .op = .{ .stash_apply = 0 } },
    .{ .name = "stash: drop from the middle", .setup = diverged ++ " && for i in 1 2 3; do printf \"$i\\n\" >> a.txt; git stash -q; done", .git = "git stash drop -q stash@{1}", .op = .{ .stash_drop = 1 } },
    .{ .name = "stash: drop the last", .setup = diverged ++ " && printf 'x\\n' >> a.txt && git stash -q", .git = "git stash drop -q", .op = .{ .stash_drop = 0 } },
    .{ .name = "stash: clear", .setup = diverged ++ " && printf 'x\\n' >> a.txt && git stash -q && printf 'y\\n' >> a.txt && git stash -q", .git = "git stash clear", .op = .stash_clear },
};

/// What both copies are compared on.
const snapshot =
    "git log --all --format='%H %P %an %cn %s' 2>&1; echo --; " ++
    "git status --porcelain --untracked-files=all; echo --; git ls-files -s; echo --; " ++
    "for f in $(git ls-files | uniq; git ls-files -o --exclude-standard); do echo \"== $f\"; cat \"$f\"; done; echo --; " ++
    "for s in MERGE_HEAD MERGE_MSG MERGE_MODE CHERRY_PICK_HEAD REVERT_HEAD ORIG_HEAD; do test -f .git/$s && { echo \"== $s\"; cat .git/$s; }; done; echo --; " ++
    "git stash list --format='%H %gs'; git cat-file -p stash 2>/dev/null; git ls-tree -r stash 2>/dev/null; echo --; git reflog -3 --format='%gs'; git fsck --no-progress --no-dangling 2>&1";

fn sh(gpa: Allocator, io: Io, cwd: []const u8, env: *const std.process.Environ.Map, script: []const u8) ![]u8 {
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

fn runNative(repo: *git.Repository, op: Op) !void {
    switch (op) {
        .merge => |m| {
            var r = try merge.merge(repo, m.name, m.opts);
            r.deinit();
        },
        .merge_abort => try merge.abort(repo),
        .cherry_pick => |rev| {
            var r = try pick.cherryPick(repo, rev, .{});
            r.deinit();
        },
        .cherry_pick_n => |rev| {
            var r = try pick.cherryPick(repo, rev, .{ .commit = false });
            r.deinit();
        },
        .revert => |rev| {
            var r = try pick.revert(repo, rev, .{});
            r.deinit();
        },
        .stash_push => |o| _ = try stash.push(repo, o),
        .stash_apply => |n| {
            var r = try stash.apply(repo, .{ .n = n });
            r.deinit();
        },
        .stash_pop => |n| {
            var r = try stash.pop(repo, .{ .n = n });
            r.deinit();
        },
        .stash_drop => |n| try stash.drop(repo, n),
        .stash_clear => try stash.clear(repo),
    }
}

test "gitbridge: merge, cherry-pick, revert and stash match git" {
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
    try env.put("LANG", "C");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CEILING_DIRECTORIES", root);
    try env.put("GIT_AUTHOR_NAME", "A");
    try env.put("GIT_AUTHOR_EMAIL", "a@example.com");
    try env.put("GIT_COMMITTER_NAME", "C");
    try env.put("GIT_COMMITTER_EMAIL", "c@example.com");
    try env.put("GIT_AUTHOR_DATE", "1700000000 +0100");
    try env.put("GIT_COMMITTER_DATE", "1700000000 +0100");
    const probe = sh(gpa, io, root, &env, "git --version") catch return error.SkipZigTest;
    gpa.free(probe);

    var failures: usize = 0;
    for (scenarios, 0..) |sc, i| {
        var name_buf: [32]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&name_buf, "s{d}", .{i});
        const setup = try std.fmt.allocPrint(gpa, "mkdir {s} && cd {s} && mkdir n && cd n && {s} && cd .. && cp -a n g", .{ dir_name, dir_name, sc.setup });
        defer gpa.free(setup);
        gpa.free(try sh(gpa, io, root, &env, setup));
        const n_dir = try std.fs.path.join(gpa, &.{ root, dir_name, "n" });
        defer gpa.free(n_dir);
        const g_dir = try std.fs.path.join(gpa, &.{ root, dir_name, "g" });
        defer gpa.free(g_dir);

        gpa.free(try sh(gpa, io, g_dir, &env, sc.git));
        const repo = (try git.Repository.discover(gpa, io, n_dir, .{ .env = &env })).?;
        const got_err: ?anyerror = if (runNative(repo, sc.op)) null else |e| e;
        repo.close();
        const as_expected = if (sc.fails) |w| (got_err != null and got_err.? == w) else got_err == null;
        if (!as_expected) {
            std.debug.print("scenario '{s}': native returned {?}, want {?}\n", .{ sc.name, got_err, sc.fails });
            failures += 1;
            continue;
        }
        const want = try sh(gpa, io, g_dir, &env, snapshot);
        defer gpa.free(want);
        const got = try sh(gpa, io, n_dir, &env, snapshot);
        defer gpa.free(got);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("scenario '{s}' differs\n--- git:\n{s}\n--- native:\n{s}\n", .{ sc.name, want, got });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
