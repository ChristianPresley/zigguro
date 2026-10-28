//! `git init` and `git clone` against git: the same layout, config, refs,
//! reflogs and checkout. Skipped without git and on Windows.

const std = @import("std");
const builtin = @import("builtin");
const init_mod = @import("init.zig");
const Repository = @import("repository.zig").Repository;
const transport = @import("remote/transport.zig");
const helpers = @import("status_test.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    env: std.process.Environ.Map,

    fn init(gpa: Allocator) !?*Fixture {
        if (builtin.os.tag == .windows) return null;
        const io = testing.io;
        const f = try gpa.create(Fixture);
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .root = undefined, .env = .init(gpa) };
        f.root = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
        const env = &f.env;
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
        if (!helpers.gitAvailable(gpa, io, env)) {
            f.deinit(gpa);
            return null;
        }
        return f;
    }

    fn deinit(f: *Fixture, gpa: Allocator) void {
        f.env.deinit();
        gpa.free(f.root);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    fn sh(f: *Fixture, gpa: Allocator, script: []const u8) ![]u8 {
        return helpers.sh(gpa, testing.io, f.root, &f.env, script);
    }

    fn run(f: *Fixture, script: []const u8) !void {
        testing.allocator.free(try f.sh(testing.allocator, script));
    }

    fn path(f: *Fixture, gpa: Allocator, sub: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ f.root, sub });
    }

    fn expectSame(f: *Fixture, script_fmt: []const u8, a: []const u8, b: []const u8) !void {
        const gpa = testing.allocator;
        const sa = try std.mem.replaceOwned(u8, gpa, script_fmt, "DIR", a);
        defer gpa.free(sa);
        const sb = try std.mem.replaceOwned(u8, gpa, script_fmt, "DIR", b);
        defer gpa.free(sb);
        const want = try f.sh(gpa, sa);
        defer gpa.free(want);
        const got = try f.sh(gpa, sb);
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
};

fn localConnect(_: ?*anyopaque, repo: *Repository, url: []const u8, service: transport.Service) anyerror!transport.Connection {
    return (try @import("remote/local.zig").Local.connect(repo, url, service)).connection();
}

test "init: the layout, config and HEAD git makes" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.run("git init -q g && git init -q --bare gb && git config --global init.defaultBranch trunk && git init -q gd");
    for ([_]struct { sub: []const u8, opts: init_mod.InitOptions }{
        .{ .sub = "n", .opts = .{ .initial_branch = "master" } },
        .{ .sub = "nb", .opts = .{ .bare = true, .initial_branch = "master" } },
        .{ .sub = "nd", .opts = .{} },
    }) |c| {
        const p = try f.path(gpa, c.sub);
        defer gpa.free(p);
        var o = c.opts;
        o.env = &f.env;
        try testing.expectEqual(init_mod.Initialized.created, try init_mod.init(gpa, testing.io, p, o));
        try testing.expectEqual(init_mod.Initialized.reinitialized, try init_mod.init(gpa, testing.io, p, o));
    }
    const layout = "cd DIR && find . -path ./hooks -prune -o -path ./.git/hooks -prune -o -print | sort && cat $(git rev-parse --git-dir)/config $(git rev-parse --git-dir)/HEAD && git status --porcelain --branch";
    try f.expectSame(layout, "g", "n");
    try f.expectSame("cd DIR && find . -path ./hooks -prune -o -print | sort && cat config HEAD && git rev-parse --is-bare-repository", "gb", "nb");
    try f.expectSame("cd DIR && cat .git/HEAD", "gd", "nd");
}

test "clone: refs, config, reflogs and the checkout match git clone" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.run("git init -q -b main srv && cd srv && printf 'a\\n' > a.txt && mkdir d && printf 'b\\n' > d/b.txt && git add -A && git commit -qm one && " ++
        "git checkout -qb topic && printf 'c\\n' > c.txt && git add c.txt && git commit -qm two && git checkout -q main && git tag v1 HEAD~0 && git tag -a -m 'tag two' v2 topic && " ++
        "cd .. && git init -q --bare empty && git clone -q srv g && git clone -q -b topic srv gt && git clone -q empty ge 2>/dev/null");
    const io = testing.io;
    const srv = try f.path(gpa, "srv");
    defer gpa.free(srv);
    const empty = try f.path(gpa, "empty");
    defer gpa.free(empty);
    for ([_]struct { sub: []const u8, url: []const u8, branch: ?[]const u8 = null }{
        .{ .sub = "n", .url = srv },
        .{ .sub = "nt", .url = srv, .branch = "topic" },
        .{ .sub = "ne", .url = empty },
    }) |c| {
        const p = try f.path(gpa, c.sub);
        defer gpa.free(p);
        const repo = try init_mod.clone(gpa, io, c.url, p, .{ .connect = localConnect }, .{ .branch = c.branch, .env = &f.env });
        repo.close();
    }
    const snap = "cd DIR && git for-each-ref --format='%(refname) %(objectname) %(symref)' && cat .git/HEAD && git config --local --list && " ++
        "git status --porcelain=v2 --branch && git ls-files -s && cat a.txt d/b.txt c.txt 2>/dev/null; " ++
        "for r in HEAD $(git for-each-ref --format='%(refname)' refs/heads refs/remotes); do git reflog show --format='%gs' $r 2>/dev/null | sed \"s|^|$r |\"; done; git fsck --no-progress 2>&1 | grep -v ^notice:; true";
    try f.expectSame(snap, "g", "n");
    try f.expectSame(snap, "gt", "nt");
    try f.expectSame(snap, "ge", "ne");

    // The destination must be empty.
    const g = try f.path(gpa, "g");
    defer gpa.free(g);
    try testing.expectError(error.DestinationNotEmpty, init_mod.clone(gpa, io, srv, g, .{ .connect = localConnect }, .{ .env = &f.env }));
}
