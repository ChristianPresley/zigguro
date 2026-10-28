//! `git submodule` against git: add, init, update, sync, deinit and
//! status leave the same files, config, index and checkouts, and print
//! the same lines. Skipped without git and on Windows.

const std = @import("std");
const builtin = @import("builtin");
const submodule = @import("submodule.zig");
const Repository = @import("repository.zig").Repository;
const transport = @import("remote/transport.zig");
const helpers = @import("status_test.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

fn localConnect(_: ?*anyopaque, repo: *Repository, url: []const u8, service: transport.Service) anyerror!transport.Connection {
    return (try @import("remote/local.zig").Local.connect(repo, url, service)).connection();
}

const connector: @import("remote/fetch.zig").Connector = .{ .ctx = null, .connect = localConnect };

/// What both sides must agree on, read with git.
const snapshot =
    "cat .gitmodules 2>/dev/null; echo ==; cat .git/config; echo ==; git ls-files -s; echo ==; git status --porcelain; echo ==; " ++
    "if [ -e deps/lib/.git ]; then cat deps/lib/.git; cat .git/modules/deps/lib/config; git -C deps/lib rev-parse HEAD; git -C deps/lib symbolic-ref -q HEAD; " ++
    "git -C deps/lib for-each-ref; cat .git/modules/deps/lib/logs/HEAD; git -C deps/lib status --porcelain; fi; ls -A deps/lib 2>/dev/null; echo ==; " ++
    "git -c protocol.file.allow=always submodule status";

const Env = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    env: std.process.Environ.Map,

    fn sh(e: *Env, dir: []const u8, script: []const u8) ![]u8 {
        const cwd = try std.fs.path.join(testing.allocator, &.{ e.root, dir });
        defer testing.allocator.free(cwd);
        return helpers.sh(testing.allocator, testing.io, cwd, &e.env, script);
    }

    fn run(e: *Env, dir: []const u8, script: []const u8) !void {
        testing.allocator.free(try e.sh(dir, script));
    }

    fn open(e: *Env, dir: []const u8) !*Repository {
        const p = try std.fs.path.join(testing.allocator, &.{ e.root, dir });
        defer testing.allocator.free(p);
        return (try Repository.discover(testing.allocator, testing.io, p, .{ .env = &e.env })).?;
    }

    /// Runs `git submodule <args>` in `gdir` and `step` natively in
    /// `ndir`; their output and the two repositories must match.
    fn same(e: *Env, gdir: []const u8, ndir: []const u8, args: []const u8, step: anytype) !void {
        const gpa = testing.allocator;
        const cmd = try std.fmt.allocPrint(gpa, "git -c protocol.file.allow=always submodule {s} 2>/dev/null", .{args});
        defer gpa.free(cmd);
        const want = try e.sh(gdir, cmd);
        defer gpa.free(want);
        const repo = try e.open(ndir);
        defer repo.close();
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try step.run(repo, &aw.writer);
        testing.expectEqualStrings(want, aw.written()) catch |err| {
            std.debug.print("git submodule {s}\n", .{args});
            return err;
        };
        const gs = try e.sh(gdir, snapshot);
        defer gpa.free(gs);
        const ns = try e.sh(ndir, snapshot);
        defer gpa.free(ns);
        // The two repositories sit in different folders.
        const gabs = try std.fs.path.join(gpa, &.{ e.root, gdir });
        defer gpa.free(gabs);
        const nabs = try std.fs.path.join(gpa, &.{ e.root, ndir });
        defer gpa.free(nabs);
        const gs2 = try std.mem.replaceOwned(u8, gpa, gs, gabs, nabs);
        defer gpa.free(gs2);
        testing.expectEqualStrings(gs2, ns) catch |err| {
            std.debug.print("after git submodule {s}\n", .{args});
            return err;
        };
    }
};

fn Step(comptime f: anytype) type {
    return struct {
        paths: []const []const u8 = &.{},
        fn run(s: @This(), repo: *Repository, out: *std.Io.Writer) !void {
            try f(repo, s.paths, out);
        }
    };
}

fn doAdd(repo: *Repository, _: []const []const u8, _: *std.Io.Writer) !void {
    try submodule.add(repo, testing.allocator, "../lib", "deps/lib", connector, .{ .common = .{ .env = repo.env } });
}
fn doInit(repo: *Repository, paths: []const []const u8, _: *std.Io.Writer) !void {
    try submodule.initModules(repo, testing.allocator, paths, .{ .env = repo.env });
}
fn doUpdate(repo: *Repository, paths: []const []const u8, out: *std.Io.Writer) !void {
    try submodule.update(repo, testing.allocator, paths, connector, .{ .common = .{ .env = repo.env } }, out);
}
fn doUpdateInit(repo: *Repository, paths: []const []const u8, out: *std.Io.Writer) !void {
    try submodule.update(repo, testing.allocator, paths, connector, .{ .init = true, .common = .{ .env = repo.env } }, out);
}
fn doSync(repo: *Repository, paths: []const []const u8, out: *std.Io.Writer) !void {
    try submodule.sync(repo, testing.allocator, paths, .{ .env = repo.env }, out);
}
fn doDeinit(repo: *Repository, paths: []const []const u8, out: *std.Io.Writer) !void {
    try submodule.deinitModules(repo, testing.allocator, paths, false, .{ .env = repo.env }, out);
}
fn doStatus(repo: *Repository, _: []const []const u8, out: *std.Io.Writer) !void {
    try submodule.status(repo, testing.allocator, out);
}

test "submodule: add, init, update, sync, deinit and status match git" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var e: Env = .{ .tmp = testing.tmpDir(.{}), .root = undefined, .env = .init(gpa) };
    defer e.tmp.cleanup();
    defer e.env.deinit();
    e.root = try e.tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(e.root);
    for ([_][2][]const u8{
        .{ "PATH", "/usr/local/bin:/usr/bin:/bin" }, .{ "HOME", e.root },                           .{ "LANG", "C" },
        .{ "GIT_CONFIG_NOSYSTEM", "1" },             .{ "GIT_CEILING_DIRECTORIES", e.root },        .{ "GIT_AUTHOR_NAME", "A" },
        .{ "GIT_AUTHOR_EMAIL", "a@example.com" },    .{ "GIT_COMMITTER_NAME", "C" },                .{ "GIT_COMMITTER_EMAIL", "c@example.com" },
        .{ "GIT_AUTHOR_DATE", "1700000000 +0000" },  .{ "GIT_COMMITTER_DATE", "1700000000 +0000" },
    }) |kv| try e.env.put(kv[0], kv[1]);
    if (!helpers.gitAvailable(gpa, io, &e.env)) return error.SkipZigTest;

    try e.run("", "git init -q -b main lib && cd lib && echo l > l.txt && git add . && git commit -qm l1 && echo l2 > l.txt && git commit -qam l2 && cd .. && " ++
        "git init -q -b main g && cd g && echo s > s.txt && git add . && git commit -qm s1 && cd .. && cp -r g n");

    // add, then commit it on both sides.
    try e.same("g", "n", "add ../lib deps/lib", Step(doAdd){});
    try e.same("g", "n", "status", Step(doStatus){});
    try e.run("", "cd g && git commit -qm add-sub && cd ../n && git commit -qm add-sub && cd .. && git clone -q g cg 2>/dev/null && git clone -q g cn 2>/dev/null");

    // A fresh clone: init, update, a moved submodule, sync, deinit.
    try e.same("cg", "cn", "status", Step(doStatus){});
    try e.same("cg", "cn", "init", Step(doInit){});
    try e.same("cg", "cn", "update", Step(doUpdate){});
    try e.same("cg", "cn", "status", Step(doStatus){});
    try e.run("", "cd cg/deps/lib && git checkout -q HEAD~1 && cd ../../../cn/deps/lib && git checkout -q HEAD~1");
    try e.same("cg", "cn", "status", Step(doStatus){});
    try e.same("cg", "cn", "update", Step(doUpdate){});
    try e.run("", "cd cg && git config -f .gitmodules submodule.deps/lib.url ../lib2 && cd ../cn && git config -f .gitmodules submodule.deps/lib.url ../lib2");
    try e.same("cg", "cn", "sync", Step(doSync){});
    try e.run("", "cd cg && git checkout -q .gitmodules && cd ../cn && git checkout -q .gitmodules");
    try e.same("cg", "cn", "deinit deps/lib", Step(doDeinit){ .paths = &.{"deps/lib"} });
    try e.same("cg", "cn", "status", Step(doStatus){});
    try e.same("cg", "cn", "update --init", Step(doUpdateInit){});
}

test "submodule: relative URLs follow the default remote" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env.put("HOME", root);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    if (!helpers.gitAvailable(gpa, testing.io, &env)) return error.SkipZigTest;
    gpa.free(try helpers.sh(gpa, testing.io, root, &env, "git init -q r && cd r && git remote add origin https://example.com/org/super.git"));
    const p = try std.fs.path.join(gpa, &.{ root, "r" });
    defer gpa.free(p);
    const repo = (try Repository.discover(gpa, testing.io, p, .{ .env = &env })).?;
    defer repo.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://example.com/org/lib.git", try submodule.resolveUrl(repo, a, "../lib.git"));
    try testing.expectEqualStrings("https://example.com/org/super.git/sub", try submodule.resolveUrl(repo, a, "./sub"));
    try testing.expectEqualStrings("git@host:x/y", try submodule.resolveUrl(repo, a, "git@host:x/y"));
}
