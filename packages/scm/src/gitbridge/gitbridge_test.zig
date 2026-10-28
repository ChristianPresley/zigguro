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
const rebase = @import("rebase.zig");
const pull_mod = @import("pull.zig");
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
    rebase: struct { upstream: []const u8, opts: rebase.Options = .{} },
    rebase_continue,
    rebase_skip,
    rebase_abort,
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
    .{ .name = "rebase: replay onto main", .setup = diverged ++ " && git checkout -q feature", .git = "git rebase -q main", .op = .{ .rebase = .{ .upstream = "main" } } },
    .{ .name = "rebase: --onto", .setup = diverged ++ " && git checkout -q feature && printf 'x\\n' > x.txt && git add x.txt && git commit -qm 'feature three'", .git = "git rebase -q --onto main feature~1", .op = .{ .rebase = .{ .upstream = "feature~1", .opts = .{ .onto = "main" } } } },
    .{ .name = "rebase: fast-forward", .setup = diverged ++ " && git checkout -qb behind main~1", .git = "git rebase -q main", .op = .{ .rebase = .{ .upstream = "main" } } },
    .{ .name = "rebase: up to date", .setup = diverged, .git = "git rebase -q main~1", .op = .{ .rebase = .{ .upstream = "main~1" } } },
    .{ .name = "rebase: drops a commit already upstream", .setup = diverged ++ " && git cherry-pick feature~1 >/dev/null && git checkout -q feature", .git = "git rebase -q main", .op = .{ .rebase = .{ .upstream = "main" } } },
    .{ .name = "rebase: a merge in the branch is flattened", .setup = diverged ++ " && git checkout -q feature && git checkout -qb side main~1 && printf 's\\n' > s.txt && git add s.txt && git commit -qm side && git checkout -q feature && git merge -q --no-edit side && git checkout -qb up main && printf 'u\\n' > u.txt && git add u.txt && git commit -qm up && git checkout -q feature", .git = "git rebase -q up", .op = .{ .rebase = .{ .upstream = "up" } } },
    .{ .name = "rebase: stops on a conflict", .setup = conflicting ++ " && sed -i 's/^6$/six/' a.txt && git commit -qam 'main six' && git checkout -q feature && printf 'g\\n' > g.txt && git add g.txt && git commit -qm 'feature g'", .git = "git rebase -q main >/dev/null 2>&1 || true", .op = .{ .rebase = .{ .upstream = "main" } } },
    .{ .name = "rebase: --continue after git stopped", .setup = conflicting ++ " && git checkout -q feature && printf 'g\\n' > g.txt && git add g.txt && git commit -qm 'feature g' && { git rebase -q main >/dev/null 2>&1 || true; } && printf 'resolved\\n' > a.txt && git add a.txt", .git = "GIT_EDITOR=true git rebase --continue >/dev/null 2>&1", .op = .rebase_continue },
    .{ .name = "rebase: --skip", .setup = conflicting ++ " && git checkout -q feature && printf 'g\\n' > g.txt && git add g.txt && git commit -qm 'feature g' && { git rebase -q main >/dev/null 2>&1 || true; }", .git = "git rebase --skip >/dev/null 2>&1", .op = .rebase_skip },
    .{ .name = "rebase: --abort", .setup = conflicting ++ " && git checkout -q feature && { git rebase -q main >/dev/null 2>&1 || true; }", .git = "git rebase --abort", .op = .rebase_abort },
    .{ .name = "rebase: refused with local changes", .setup = diverged ++ " && git checkout -q feature && printf 'x\\n' >> keep.txt", .git = "git rebase -q main >/dev/null 2>&1 || true", .op = .{ .rebase = .{ .upstream = "main" } }, .fails = error.UncommittedChanges },
};

/// What both copies are compared on.
const snapshot =
    "git log --all --format='%H %P %an %cn %s' 2>&1; echo --; " ++
    "git status --porcelain --untracked-files=all; echo --; git ls-files -s; echo --; " ++
    "for f in $(git ls-files | uniq; git ls-files -o --exclude-standard); do echo \"== $f\"; cat \"$f\"; done; echo --; " ++
    "for s in MERGE_HEAD MERGE_MSG MERGE_MODE CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD ORIG_HEAD rebase-merge/head-name rebase-merge/onto rebase-merge/orig-head rebase-merge/done rebase-merge/git-rebase-todo rebase-merge/msgnum rebase-merge/end rebase-merge/stopped-sha rebase-merge/message rebase-merge/author-script; do test -f .git/$s && { echo \"== $s\"; cat .git/$s; }; done; echo --; git symbolic-ref -q HEAD || git rev-parse HEAD; " ++
    "git stash list --format='%H %gs'; git cat-file -p stash 2>/dev/null; git ls-tree -r stash 2>/dev/null; echo --; git reflog -3 --format='%gs'; b=$(git symbolic-ref -q HEAD) && git reflog show -2 --format='%gs' $b; git fsck --no-progress --no-dangling 2>&1";

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
        .rebase => |rb| {
            var r = try rebase.rebase(repo, rb.upstream, rb.opts);
            r.deinit();
        },
        .rebase_continue => {
            var r = try rebase.continueRebase(repo, .{});
            r.deinit();
        },
        .rebase_skip => {
            var r = try rebase.skip(repo, .{});
            r.deinit();
        },
        .rebase_abort => try rebase.abort(repo),
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

const PullScenario = struct {
    name: []const u8,
    /// Run in the clone `n` after the server moved on.
    setup: []const u8,
    git: []const u8,
    opts: pull_mod.Options,
};

const pull_scenarios = [_]PullScenario{
    .{ .name = "pull: merge", .setup = "printf 'l\\n' > l.txt && git add l.txt && git commit -qm local", .git = "git pull -q --no-rebase", .opts = .{ .mode = .merge, .reflog_action = "pull -q --no-rebase" } },
    .{ .name = "pull: rebase", .setup = "printf 'l\\n' > l.txt && git add l.txt && git commit -qm local", .git = "git pull -q --rebase", .opts = .{ .mode = .rebase, .reflog_action = "pull -q --rebase" } },
    .{ .name = "pull: fast-forward only", .setup = "true", .git = "git pull -q --ff-only", .opts = .{ .ff = .only, .reflog_action = "pull -q --ff-only" } },
    .{ .name = "pull: pull.rebase from the config", .setup = "git config pull.rebase true && printf 'l\\n' > l.txt && git add l.txt && git commit -qm local", .git = "git pull -q", .opts = .{ .reflog_action = "pull -q" } },
    .{ .name = "pull: merge into a topic branch", .setup = "git checkout -q -b topic --track origin/main && printf 'l\\n' > l.txt && git add l.txt && git commit -qm local", .git = "git pull -q --no-rebase", .opts = .{ .mode = .merge, .reflog_action = "pull -q --no-rebase" } },
};

fn localConnect(_: ?*anyopaque, repo: *git.Repository, url: []const u8, service: git.remote.transport.Service) anyerror!git.remote.transport.Connection {
    return (try git.remote.local.Local.connect(repo, url, service)).connection();
}

test "gitbridge: pull matches git" {
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

    const pull_snapshot = snapshot ++ "; echo --; cat .git/FETCH_HEAD; git reflog show -1 --format='%gs' refs/remotes/origin/main";
    var failures: usize = 0;
    for (pull_scenarios, 0..) |sc, i| {
        var name_buf: [32]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&name_buf, "p{d}", .{i});
        const setup = try std.fmt.allocPrint(gpa, "mkdir {s} && cd {s} && mkdir srv && cd srv && {s}true && cd .. && " ++
            "git clone -q srv n && cd srv && printf 'up\\n' > up.txt && git add up.txt && git commit -qm upstream && cd ../n && {s} && cd .. && cp -a n g", .{ dir_name, dir_name, base, sc.setup });
        defer gpa.free(setup);
        gpa.free(try sh(gpa, io, root, &env, setup));
        const n_dir = try std.fs.path.join(gpa, &.{ root, dir_name, "n" });
        defer gpa.free(n_dir);
        const g_dir = try std.fs.path.join(gpa, &.{ root, dir_name, "g" });
        defer gpa.free(g_dir);

        gpa.free(try sh(gpa, io, g_dir, &env, sc.git));
        const repo = (try git.Repository.discover(gpa, io, n_dir, .{ .env = &env })).?;
        var opts = sc.opts;
        opts.tz_offset_min = 60;
        if (pull_mod.pull(repo, .{ .connect = localConnect }, opts)) |r| {
            var res = r;
            res.deinit();
        } else |e| {
            std.debug.print("scenario '{s}': native returned {}\n", .{ sc.name, e });
            failures += 1;
            repo.close();
            continue;
        }
        repo.close();
        const want = try sh(gpa, io, g_dir, &env, pull_snapshot);
        defer gpa.free(want);
        const got = try sh(gpa, io, n_dir, &env, pull_snapshot);
        defer gpa.free(got);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("scenario '{s}' differs\n--- git:\n{s}\n--- native:\n{s}\n", .{ sc.name, want, got });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

const IStep = union(enum) {
    /// `git rebase -i <upstream>` with this todo list.
    start: struct { upstream: []const u8, todo: []const rebase.TodoItem },
    cont,
    skip,
    abort,
    /// Runs in both copies.
    sh: []const u8,
};

const IScenario = struct { name: []const u8, setup: []const u8, steps: []const IStep, editor: []const u8 = ":" };

/// Five commits on `feature` (f1..f5, each with a body) over `main one`.
const stack = base ++
    "git checkout -qb feature && for i in 1 2 3 4 5; do printf \"$i\\n\" > f$i.txt && git add f$i.txt && git commit -qm \"f$i\" -m \"body $i\"; done && " ++
    "git checkout -q main && sed -i 's/^8$/eight/' a.txt && git commit -qam 'main one' && git checkout -q feature";
/// `feature`: g1 adds g.txt, g2 changes line 4 (which main changed too), g3 adds h.txt.
const squash_conflict = base ++
    "git checkout -qb feature && printf 'g\\n' > g.txt && git add g.txt && git commit -qm g1 && " ++
    "sed -i 's/^4$/four (feature)/' a.txt && git commit -qam g2 && printf 'h\\n' > h.txt && git add h.txt && git commit -qm g3 && " ++
    "git checkout -q main && sed -i 's/^4$/four (main)/' a.txt && git commit -qam 'main four' && git checkout -q feature";

fn todoItem(comptime cmd: rebase.Command, comptime rev: []const u8) rebase.TodoItem {
    return .{ .cmd = cmd, .rev = rev };
}

const interactive_scenarios = [_]IScenario{
    .{ .name = "rebase -i: squash, fixup and reword", .setup = stack, .steps = &.{.{ .start = .{ .upstream = "main", .todo = &.{
        todoItem(.pick, "feature~4"), todoItem(.squash, "feature~3"), todoItem(.squash, "feature~2"), todoItem(.fixup, "feature~1"), todoItem(.reword, "feature"),
    } } }} },
    .{ .name = "rebase -i: a fixup run, reordered, a drop", .setup = stack, .steps = &.{.{ .start = .{ .upstream = "main", .todo = &.{
        todoItem(.pick, "feature~3"), todoItem(.fixup, "feature~4"), todoItem(.fixup, "feature~1"), todoItem(.drop, "feature~2"), todoItem(.pick, "feature"),
    } } }} },
    .{ .name = "rebase -i: edit amends, break stops", .setup = stack, .steps = &.{
        .{ .start = .{ .upstream = "main", .todo = &.{ todoItem(.pick, "feature~4"), todoItem(.edit, "feature~3"), todoItem(.reword, "feature~2"), .{ .cmd = .@"break" }, todoItem(.pick, "feature~1"), todoItem(.drop, "feature") } } },
        .{ .sh = "printf 'more\\n' >> f2.txt && git add f2.txt" },
        .cont,
        .cont,
    } },
    .{ .name = "rebase -i: commits already in place fast-forward", .setup = stack, .steps = &.{
        .{ .start = .{ .upstream = "feature~5", .todo = &.{ todoItem(.pick, "feature~4"), todoItem(.edit, "feature~3"), todoItem(.pick, "feature~2"), todoItem(.reword, "feature~1"), todoItem(.pick, "feature") } } },
        .cont,
    } },
    .{ .name = "rebase -i: a squash that conflicts", .setup = squash_conflict, .steps = &.{
        .{ .start = .{ .upstream = "main", .todo = &.{ todoItem(.pick, "feature~2"), todoItem(.squash, "feature~1"), todoItem(.fixup, "feature") } } },
        .{ .sh = "printf 'resolved\\n' > a.txt && git add a.txt" },
        .cont,
    } },
    .{ .name = "rebase -i: a pick that conflicts, skipped", .setup = squash_conflict, .steps = &.{
        .{ .start = .{ .upstream = "main", .todo = &.{ todoItem(.pick, "feature~1"), todoItem(.pick, "feature~2"), todoItem(.pick, "feature") } } },
        .skip,
    } },
    .{ .name = "rebase -i: abort after an edit", .setup = stack, .steps = &.{
        .{ .start = .{ .upstream = "main", .todo = &.{ todoItem(.edit, "feature~4"), todoItem(.pick, "feature~3") } } },
        .abort,
    } },
    .{
        .name = "rebase -i: reword with a new message",
        .setup = stack,
        .editor = "f() { printf \"Renamed\\n\\nwith a body\\n\" > \"$1\"; }; f",
        .steps = &.{.{ .start = .{ .upstream = "main", .todo = &.{ todoItem(.pick, "feature~4"), .{ .cmd = .reword, .rev = "feature~3", .message = "Renamed\n\nwith a body" } } } }},
    },
};

/// The git command for a step.
fn gitStep(a: Allocator, step: IStep, editor: []const u8) ![]const u8 {
    const quiet = " >/dev/null 2>&1 || true";
    return switch (step) {
        .start => |s| blk: {
            var fmt: std.ArrayList(u8) = .empty;
            var revs: std.ArrayList(u8) = .empty;
            for (s.todo) |it| {
                if (it.cmd == .@"break") {
                    try fmt.appendSlice(a, "break\\n");
                    continue;
                }
                try fmt.print(a, "{s} %s %s\\n", .{@tagName(it.cmd)});
                try revs.print(a, " $(git rev-parse {s}) $(git log -1 --format=%s {s})", .{ it.rev, it.rev });
            }
            break :blk std.fmt.allocPrint(a, "printf '{s}'{s} > ../todo && GIT_SEQUENCE_EDITOR='cp ../todo' GIT_EDITOR='{s}' git rebase -i {s}{s}", .{ fmt.items, revs.items, editor, s.upstream, quiet });
        },
        .cont => std.fmt.allocPrint(a, "GIT_EDITOR=: git rebase --continue{s}", .{quiet}),
        .skip => std.fmt.allocPrint(a, "git rebase --skip{s}", .{quiet}),
        .abort => std.fmt.allocPrint(a, "git rebase --abort{s}", .{quiet}),
        .sh => |c| a.dupe(u8, c),
    };
}

fn nativeStep(repo: *git.Repository, step: IStep) !void {
    var r = switch (step) {
        .start => |s| try rebase.rebase(repo, s.upstream, .{ .todo = s.todo }),
        .cont => try rebase.continueRebase(repo, .{}),
        .skip => try rebase.skip(repo, .{}),
        .abort => return rebase.abort(repo),
        .sh => unreachable,
    };
    r.deinit();
}

test "gitbridge: interactive rebase matches git" {
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

    const i_snapshot = snapshot ++ "; echo --; for s in amend current-fixups message-squash; do test -f .git/rebase-merge/$s && { echo \"== $s\"; cat .git/rebase-merge/$s; echo; }; done; " ++
        "git reflog --format='%H %gs'; git log -1 --format=%B";
    var failures: usize = 0;
    scenario: for (interactive_scenarios, 0..) |sc, i| {
        var name_buf: [32]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&name_buf, "i{d}", .{i});
        const setup = try std.fmt.allocPrint(gpa, "mkdir {s} && cd {s} && mkdir n && cd n && {s} && cd .. && cp -a n g", .{ dir_name, dir_name, sc.setup });
        defer gpa.free(setup);
        gpa.free(try sh(gpa, io, root, &env, setup));
        const n_dir = try std.fs.path.join(gpa, &.{ root, dir_name, "n" });
        defer gpa.free(n_dir);
        const g_dir = try std.fs.path.join(gpa, &.{ root, dir_name, "g" });
        defer gpa.free(g_dir);
        for (sc.steps, 0..) |step, k| {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            gpa.free(try sh(gpa, io, g_dir, &env, try gitStep(arena.allocator(), step, sc.editor)));
            if (step == .sh) {
                gpa.free(try sh(gpa, io, n_dir, &env, step.sh));
            } else {
                const repo = (try git.Repository.discover(gpa, io, n_dir, .{ .env = &env })).?;
                defer repo.close();
                nativeStep(repo, step) catch |e| {
                    std.debug.print("scenario '{s}' step {d}: native returned {}\n", .{ sc.name, k, e });
                    failures += 1;
                    continue :scenario;
                };
            }
            const want = try sh(gpa, io, g_dir, &env, i_snapshot);
            defer gpa.free(want);
            const got = try sh(gpa, io, n_dir, &env, i_snapshot);
            defer gpa.free(got);
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("scenario '{s}' step {d} differs\n--- git:\n{s}\n--- native:\n{s}\n", .{ sc.name, k, want, got });
                failures += 1;
                continue :scenario;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
