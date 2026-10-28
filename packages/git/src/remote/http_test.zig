//! Smart HTTP against `git http-backend` (behind testdata/
//! git_http_server.py, with Basic auth): fetch and push compared with
//! git over the same server, and the credential pipeline's store helper,
//! provider, approve and reject. Skipped without git or python3, and on
//! Windows.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const options = @import("zg_options");
const Repository = @import("../repository.zig").Repository;
const transport = @import("transport.zig");
const http = @import("http.zig");
const credential = @import("credential.zig");
const fetch_mod = @import("fetch.zig");
const push_mod = @import("push.zig");
const helpers = @import("../status_test.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ctx = struct {
    client: *zg_net.http.Client,
    provider: ?credential.Provider = null,
    approved: usize = 0,
    rejected: usize = 0,
};

fn connect(ctx: ?*anyopaque, repo: *Repository, url: []const u8, service: transport.Service) anyerror!transport.Connection {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    const h = try http.Http.connect(repo.gpa, repo.io, url, service, .{ .client = c.client, .credentials = .{ .repo = repo, .provider = c.provider }, .tmp_dir = repo.git_dir });
    return h.connection();
}

fn fillGood(ctx: ?*anyopaque, a: Allocator, c: *credential.Credential) anyerror!bool {
    _ = ctx;
    c.username = try a.dupe(u8, "u");
    c.password = try a.dupe(u8, "secret");
    return true;
}

fn fillBad(_: ?*anyopaque, a: Allocator, c: *credential.Credential) anyerror!bool {
    c.username = try a.dupe(u8, "u");
    c.password = try a.dupe(u8, "wrong");
    return true;
}

fn onApprove(ctx: ?*anyopaque, _: *const credential.Credential) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    c.approved += 1;
}

fn onReject(ctx: ?*anyopaque, _: *const credential.Credential) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    c.rejected += 1;
}

test "http: fetch and push through git http-backend, with credentials" {
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
    try env.put("GIT_AUTHOR_DATE", "1700000000 +0000");
    try env.put("GIT_COMMITTER_DATE", "1700000000 +0000");
    if (!helpers.gitAvailable(gpa, io, &env)) return error.SkipZigTest;
    gpa.free(helpers.sh(gpa, io, root, &env, "python3 -c 'import http.server'") catch return error.SkipZigTest);

    // Two identical bare servers (one per side), clones of each.
    gpa.free(try helpers.sh(gpa, io, root, &env, "mkdir seed srv && cd seed && git init -q -b main && printf 'a\\n' > a && git add a && git commit -qm one && git tag -a v1 -m v1 && cd .. && " ++
        "git clone -q --bare seed srv/g.git && git clone -q --bare seed srv/n.git && git clone -q srv/g.git g && git clone -q srv/n.git n"));

    const script = try std.fs.path.join(gpa, &.{ options.package_root, "testdata", "git_http_server.py" });
    defer gpa.free(script);
    const srv_dir = try std.fs.path.join(gpa, &.{ root, "srv" });
    defer gpa.free(srv_dir);
    var server = try std.process.spawn(io, .{ .argv = &.{ "python3", script, srv_dir, "u:secret" }, .environ_map = &env, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
    defer {
        server.stdin.?.close(io);
        server.stdin = null;
        _ = server.wait(io) catch {};
    }
    var pbuf: [64]u8 = undefined;
    var pr = server.stdout.?.readerStreaming(io, &pbuf);
    const port_line = try pr.interface.takeDelimiterExclusive('\n');
    const port = try std.fmt.parseInt(u16, std.mem.trim(u8, port_line, " \r"), 10);

    const setup = try std.fmt.allocPrint(gpa, "for d in g n; do (cd $d && git remote set-url origin http://127.0.0.1:{d}/$d.git && git config credential.helper store); done && printf 'http://u:secret@127.0.0.1:{d}\\n' > .git-credentials && " ++
        "cd srv && for d in g n; do git -C $d.git config http.receivepack true; done", .{ port, port });
    defer gpa.free(setup);
    gpa.free(try helpers.sh(gpa, io, root, &env, setup));

    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const client = try zg_net.http.Client.init(&rt, .{ .proxy = .none, .environ_map = &env });
    defer client.deinit();
    var ctx: Ctx = .{ .client = client };
    const connector: fetch_mod.Connector = .{ .ctx = &ctx, .connect = connect };

    const g_dir = try std.fs.path.join(gpa, &.{ root, "g" });
    defer gpa.free(g_dir);
    const n_dir = try std.fs.path.join(gpa, &.{ root, "n" });
    defer gpa.free(n_dir);
    const snapshot = "{ git for-each-ref --format='%(refname) %(objectname)'; cat .git/FETCH_HEAD 2>/dev/null; git fsck --no-progress --no-dangling 2>&1; " ++
        "for r in $(git for-each-ref --format='%(refname)' refs/remotes refs/tags); do git reflog -1 --format=\"$r %gs\" $r 2>/dev/null; done; } | sed -E 's#/[gn](\\.git)?$#/X#'";

    // New commits on both servers, then fetch.
    gpa.free(try helpers.sh(gpa, io, root, &env, "for d in g n; do git clone -q srv/$d.git w$d && (cd w$d && printf 'b\\n' >> a && git commit -qam two && git tag -a v2 -m v2 && git push -q --tags origin main); done"));
    gpa.free(try helpers.sh(gpa, io, g_dir, &env, "git fetch origin 2>/dev/null"));
    {
        const repo = (try Repository.discover(gpa, io, n_dir, .{ .env = &env })).?;
        defer repo.close();
        var r = try fetch_mod.fetch(repo, "origin", .{}, connector);
        defer r.deinit();
        try testing.expect(r.objects > 0);
    }
    {
        const want = try helpers.sh(gpa, io, g_dir, &env, snapshot);
        defer gpa.free(want);
        const got = try helpers.sh(gpa, io, n_dir, &env, snapshot);
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }

    // Push a new commit and a new branch.
    const commit_script = "git merge -q --ff-only origin/main && printf 'c\\n' >> a && git commit -qam three && git branch side";
    gpa.free(try helpers.sh(gpa, io, g_dir, &env, commit_script));
    gpa.free(try helpers.sh(gpa, io, n_dir, &env, commit_script));
    gpa.free(try helpers.sh(gpa, io, g_dir, &env, "git push -q origin main side"));
    {
        const repo = (try Repository.discover(gpa, io, n_dir, .{ .env = &env })).?;
        defer repo.close();
        var r = try push_mod.push(repo, "origin", .{ .refspecs = &.{ "main", "side" } }, connector);
        defer r.deinit();
        try testing.expect(r.allOk());
    }
    {
        const s2 = "git for-each-ref --format='%(refname) %(objectname)'; git fsck --no-progress --no-dangling 2>&1";
        const want = try helpers.sh(gpa, io, root, &env, "cd srv/g.git && " ++ s2);
        defer gpa.free(want);
        const got = try helpers.sh(gpa, io, root, &env, "cd srv/n.git && " ++ s2);
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }

    // Without the store helper: the provider decides.
    gpa.free(try helpers.sh(gpa, io, n_dir, &env, "git config --unset credential.helper"));
    {
        const repo = (try Repository.discover(gpa, io, n_dir, .{ .env = &env })).?;
        defer repo.close();
        try testing.expectError(error.AuthenticationRequired, fetch_mod.fetch(repo, "origin", .{}, connector));
        ctx.provider = .{ .ctx = &ctx, .fill = fillBad, .approve = onApprove, .reject = onReject };
        try testing.expectError(error.AuthenticationFailed, fetch_mod.fetch(repo, "origin", .{}, connector));
        try testing.expect(ctx.rejected > 0);
        ctx.provider = .{ .ctx = &ctx, .fill = fillGood, .approve = onApprove, .reject = onReject };
        var r = try fetch_mod.fetch(repo, "origin", .{}, connector);
        r.deinit();
        try testing.expect(ctx.approved > 0);
    }
}

test "http: live fetch (ZG_LIVE_GIT_URL, opt-in)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var penv = try testing.environ.createMap(gpa);
    defer penv.deinit();
    const url = penv.get("ZG_LIVE_GIT_URL") orelse return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git/objects");
    try tmp.dir.createDirPath(io, ".git/refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    const cfg = try std.fmt.allocPrint(gpa, "[core]\n\trepositoryformatversion = 0\n[remote \"origin\"]\n\turl = {s}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n", .{url});
    defer gpa.free(cfg);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = cfg });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const repo = (try Repository.discover(gpa, io, root, .{ .env = &penv })).?;
    defer repo.close();
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const client = try zg_net.http.Client.init(&rt, .{ .environ_map = &penv });
    defer client.deinit();
    var d: @import("connect.zig").Default = .{ .client = client };
    var r = try fetch_mod.fetch(repo, "origin", .{}, d.connector());
    defer r.deinit();
    std.debug.print("live fetch: {d} objects, {d} refs\n", .{ r.objects, r.updates.len });
    try testing.expect(r.objects > 0);
}
