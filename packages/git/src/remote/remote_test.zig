//! Fetch and push against git's own server side (`git upload-pack` and
//! `git receive-pack` over pipes), compared with git doing the same on a
//! copy of the repository. Skipped without git and on Windows.

const std = @import("std");
const builtin = @import("builtin");
const Repository = @import("../repository.zig").Repository;
const transport = @import("transport.zig");
const fetch_mod = @import("fetch.zig");
const push_mod = @import("push.zig");
const remote_mod = @import("remote.zig");
const helpers = @import("../status_test.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Env = struct {
    env: std.process.Environ.Map,
    v2: std.process.Environ.Map,
    /// Serve the remote in-process (remote/local.zig) instead of git.
    native: bool = false,
};

fn connect(ctx: ?*anyopaque, repo: *Repository, url: []const u8, service: transport.Service) anyerror!transport.Connection {
    const e: *Env = @ptrCast(@alignCast(ctx.?));
    if (e.native) return (try @import("local.zig").Local.connect(repo, url, service)).connection();
    const cmd: []const u8 = switch (service) {
        .upload_pack => "upload-pack",
        .receive_pack => "receive-pack",
    };
    const p = try transport.Process.spawn(repo.gpa, repo.io, &.{ "git", cmd, url }, repo.root, if (service == .upload_pack) &e.v2 else &e.env);
    return p.connection();
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    e: *Env,

    fn init(gpa: Allocator, io: Io) !?Fixture {
        if (builtin.os.tag == .windows) return null;
        var f: Fixture = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .root = undefined, .e = try gpa.create(Env) };
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
        f.e.env = .init(gpa);
        const env = &f.e.env;
        try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
        try env.put("HOME", f.root);
        try env.put("LANG", "C");
        try env.put("GIT_CONFIG_NOSYSTEM", "1");
        try env.put("GIT_CEILING_DIRECTORIES", f.root);
        try env.put("GIT_AUTHOR_NAME", "A");
        try env.put("GIT_AUTHOR_EMAIL", "a@example.com");
        try env.put("GIT_COMMITTER_NAME", "C");
        try env.put("GIT_COMMITTER_EMAIL", "c@example.com");
        try env.put("GIT_AUTHOR_DATE", "1700000000 +0000");
        try env.put("GIT_COMMITTER_DATE", "1700000000 +0000");
        f.e.v2 = try env.clone(gpa);
        f.e.native = false;
        try f.e.v2.put("GIT_PROTOCOL", "version=2");
        if (!helpers.gitAvailable(gpa, io, env)) {
            f.deinit(gpa);
            return null;
        }
        return f;
    }

    fn deinit(f: *Fixture, gpa: Allocator) void {
        f.e.env.deinit();
        f.e.v2.deinit();
        gpa.destroy(f.e);
        gpa.free(f.root);
        f.tmp.cleanup();
    }

    fn sh(f: *Fixture, gpa: Allocator, sub: []const u8, script: []const u8) ![]u8 {
        const dir = try std.fs.path.join(gpa, &.{ f.root, sub });
        defer gpa.free(dir);
        return helpers.sh(gpa, testing.io, dir, &f.e.env, script);
    }

    fn run(f: *Fixture, sub: []const u8, script: []const u8) !void {
        testing.allocator.free(try f.sh(testing.allocator, sub, script));
    }

    fn open(f: *Fixture, gpa: Allocator, sub: []const u8) !*Repository {
        const dir = try std.fs.path.join(gpa, &.{ f.root, sub });
        defer gpa.free(dir);
        return (try Repository.discover(gpa, testing.io, dir, .{ .env = &f.e.env })).?;
    }

    fn connector(f: *Fixture) fetch_mod.Connector {
        return .{ .ctx = f.e, .connect = connect };
    }

    /// The same script output in both clones.
    fn expectSame(f: *Fixture, script: []const u8) !void {
        const gpa = testing.allocator;
        const want = try f.sh(gpa, "g", script);
        defer gpa.free(want);
        const got = try f.sh(gpa, "n", script);
        defer gpa.free(got);
        testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("script: {s}\n", .{script});
            return e;
        };
    }
};

const refs_snapshot = "git for-each-ref --format='%(refname) %(objectname)'; echo --; cat .git/FETCH_HEAD 2>/dev/null; echo --; " ++
    "for r in $(git for-each-ref --format='%(refname)' refs/remotes refs/tags); do git reflog -1 --format=\"$r %gs\" $r 2>/dev/null; done; git fsck --no-progress --no-dangling 2>&1";

fn fetchUpdates(native: bool) !void {
    const gpa = testing.allocator;
    var f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    f.e.native = native;
    try f.run("", "mkdir srv && cd srv && git init -q -b main && printf 'a\\n' > a && git add a && git commit -qm one && git tag -a v1 -m v1 && " ++
        "git checkout -qb feature && printf 'f\\n' > f && git add f && git commit -qm feat && git checkout -q main && " ++
        "cd .. && git clone -q srv g && cp -a g n");

    // Plain fetch after new commits, a new branch and a new tag.
    try f.run("srv", "printf 'b\\n' >> a && git commit -qam two && git tag -a v2 -m v2 && git tag light && git checkout -qb other && printf 'o\\n' > o && git add o && git commit -qm other && git checkout -q main");
    try f.run("g", "git fetch origin 2>/dev/null");
    {
        const repo = try f.open(gpa, "n");
        defer repo.close();
        var r = try fetch_mod.fetch(repo, "origin", .{}, f.connector());
        defer r.deinit();
        try testing.expectEqual(@as(usize, 0), r.rejected());
    }
    try f.expectSame(refs_snapshot);

    // A rewritten branch: forced update; a deleted branch: pruned.
    try f.run("srv", "git checkout -q feature && git reset -q --hard HEAD~1 && printf 'g\\n' > g && git add g && git commit -qm rewrite && git checkout -q main && git branch -D -q other");
    try f.run("g", "git fetch --prune origin 2>/dev/null");
    {
        const repo = try f.open(gpa, "n");
        defer repo.close();
        var r = try fetch_mod.fetch(repo, "origin", .{ .prune = true, .reflog_action = "fetch --prune origin" }, f.connector());
        defer r.deinit();
    }
    try f.expectSame(refs_snapshot);

    // A command-line refspec without a destination: FETCH_HEAD only.
    try f.run("srv", "printf 'c\\n' >> a && git commit -qam three");
    try f.run("g", "git fetch origin main 2>/dev/null");
    {
        const repo = try f.open(gpa, "n");
        defer repo.close();
        var r = try fetch_mod.fetch(repo, "origin", .{ .refspecs = &.{"main"} }, f.connector());
        defer r.deinit();
    }
    try f.expectSame("cat .git/FETCH_HEAD; git fsck --no-progress --no-dangling 2>&1; git cat-file -t $(cut -f1 .git/FETCH_HEAD)");
}

fn fetchEmpty(native: bool) !void {
    const gpa = testing.allocator;
    var f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    f.e.native = native;
    try f.run("", "mkdir srv && cd srv && git init -q -b main && for i in 1 2 3 4 5; do seq 1 $((i*200)) > f$i; git add f$i; git commit -qm c$i; done && git tag -a v1 -m v1 HEAD~2 && " ++
        "cd .. && for d in g n; do git init -q -b main $d && (cd $d && git remote add origin ../srv); done");
    // git 2.48 and later also create origin/HEAD here (followRemoteHEAD);
    // the native fetch does not, so pin the older behavior.
    try f.run("g", "git -c remote.origin.followRemoteHEAD=never fetch origin 2>/dev/null");
    {
        const repo = try f.open(gpa, "n");
        defer repo.close();
        var r = try fetch_mod.fetch(repo, "origin", .{}, f.connector());
        defer r.deinit();
        try testing.expect(r.objects > 0);
    }
    try f.expectSame(refs_snapshot ++ "; git rev-list --all --objects | wc -l");
}

const push_snapshot = "git -C ../srv.git for-each-ref --format='%(refname) %(objectname)'; git -C ../srv.git fsck --no-progress --no-dangling 2>&1; echo --; " ++
    "git for-each-ref --format='%(refname) %(objectname)' refs/remotes; git config --get-regexp '^branch\\.' || true";

fn pushSteps(native: bool) !void {
    const gpa = testing.allocator;
    var f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    f.e.native = native;
    // One bare server per side so both start equal.
    try f.run("", "mkdir seed && cd seed && git init -q -b main && printf 'a\\n' > a && git add a && git commit -qm one && git checkout -qb feature && printf 'f\\n' > f && git add f && git commit -qm f && git checkout -q main && " ++
        "cd .. && mkdir g n && git clone -q --bare seed g/srv.git && git clone -q --bare seed n/srv.git && git clone -q g/srv.git g/c && git clone -q n/srv.git n/c");
    const steps = [_]struct { setup: []const u8, git: []const u8, opts: push_mod.Options }{
        .{ .setup = "printf 'b\\n' >> a && git commit -qam two && seq 1 500 > big && git add big && git commit -qm big", .git = "git push -q origin", .opts = .{} },
        .{ .setup = "git checkout -qb topic && printf 't\\n' > t && git add t && git commit -qm topic", .git = "git push -q -u origin topic", .opts = .{ .refspecs = &.{"topic"}, .set_upstream = true } },
        .{ .setup = "git checkout -q main && git tag -a v1 -m v1 && git tag light HEAD~1", .git = "git push -q origin --tags", .opts = .{ .tags = true } },
        .{ .setup = "git reset -q --hard HEAD~1 && printf 'x\\n' > x && git add x && git commit -qm diverge", .git = "git push -q origin main 2>/dev/null || true", .opts = .{ .refspecs = &.{"main"} } },
        .{ .setup = "true", .git = "git push -q -f origin main", .opts = .{ .refspecs = &.{"main"}, .force = true } },
        .{ .setup = "true", .git = "git push -q origin :feature", .opts = .{ .refspecs = &.{":feature"} } },
        .{ .setup = "true", .git = "git push -q origin main:refs/heads/copy HEAD~1:refs/heads/other", .opts = .{ .refspecs = &.{ "main:refs/heads/copy", "HEAD~1:refs/heads/other" } } },
    };
    for (steps) |s| {
        try f.run("g/c", s.setup);
        try f.run("n/c", s.setup);
        try f.run("g/c", s.git);
        const repo = try f.open(gpa, "n/c");
        defer repo.close();
        var r = try push_mod.push(repo, "origin", s.opts, f.connector());
        defer r.deinit();
        const want = try f.sh(gpa, "g/c", push_snapshot);
        defer gpa.free(want);
        const got = try f.sh(gpa, "n/c", push_snapshot);
        defer gpa.free(got);
        testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("push step: {s}\n", .{s.git});
            return e;
        };
    }
}

test "fetch: new commits, forced updates, tags and prune match git fetch" {
    try fetchUpdates(false);
}

test "local remote: new commits, forced updates, tags and prune match git fetch" {
    try fetchUpdates(true);
}

test "fetch: into an empty repository" {
    try fetchEmpty(false);
}

test "local remote: into an empty repository" {
    try fetchEmpty(true);
}

test "push: new, fast-forward, rejected, forced, deleted and tags match git push" {
    try pushSteps(false);
}

test "local remote: new, fast-forward, rejected, forced, deleted and tags match git push" {
    try pushSteps(true);
}

test "remote: add, set-url, rename and remove like git remote" {
    const gpa = testing.allocator;
    var f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.run("", "mkdir srv && cd srv && git init -q -b main && git commit -q --allow-empty -m one && cd .. && git clone -q srv g && cp -a g n");
    const script = "git remote add up ../srv && git -c remote.up.followRemoteHEAD=never fetch -q up && git remote set-url --push up ../elsewhere && git branch -q -u up/main main && git remote rename up upstream && git remote rename origin old && git remote remove old";
    try f.run("g", script);
    {
        const repo = try f.open(gpa, "n");
        defer repo.close();
        try remote_mod.add(repo, "up", "../srv");
        var r = try fetch_mod.fetch(repo, "up", .{}, f.connector());
        r.deinit();
        try remote_mod.setUrl(repo, "up", "../elsewhere", true);
        try @import("../branch.zig").setUpstream(repo, "main", "up/main");
        try remote_mod.rename(repo, "up", "upstream");
        try remote_mod.rename(repo, "origin", "old");
        try remote_mod.remove(repo, "old");
        try testing.expectError(error.RemoteExists, remote_mod.add(repo, "upstream", "x"));
    }
    try f.expectSame("git config --get-regexp '^(remote|branch)\\.' ; git for-each-ref --format='%(refname) %(objectname)'");
}

test "local remote: a non-bare remote refuses its checked-out branch" {
    const gpa = testing.allocator;
    var f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    f.e.native = true;
    try f.run("", "mkdir srv && cd srv && git init -q -b main && git commit -q --allow-empty -m one && git branch other && cd .. && git clone -q srv n && " ++
        "cd n && git commit -q --allow-empty -m two && git checkout -q -b other origin/other && git commit -q --allow-empty -m three");
    const repo = try f.open(gpa, "n");
    defer repo.close();
    var r = try push_mod.push(repo, "origin", .{ .refspecs = &.{ "main", "other" } }, f.connector());
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.refs.len);
    for (r.refs) |ref| {
        if (std.mem.eql(u8, ref.remote, "refs/heads/main")) {
            try testing.expectEqualStrings("branch is currently checked out", ref.reason.?);
        } else try testing.expect(ref.ok());
    }
    const srv = try f.sh(gpa, "srv", "git log --format=%s main; git log --format=%s other");
    defer gpa.free(srv);
    try testing.expectEqualStrings("one\nthree\none\n", srv);
}
