//! The SSH transport against OpenSSH's sshd, run per connection in inetd
//! mode (`sshd -i`) over pipes: every cipher and host key type, key
//! files (plain and passphrase-protected), ssh-agent, known_hosts
//! policies, and fetch and push through git-upload-pack and
//! git-receive-pack. Skipped without sshd, ssh-keygen and git, on
//! Windows, and when not running as root (sshd -i needs it).

const std = @import("std");
const builtin = @import("builtin");
const Repository = @import("../repository.zig").Repository;
const transport = @import("../remote/transport.zig");
const fetch_mod = @import("../remote/fetch.zig");
const push_mod = @import("../remote/push.zig");
const helpers = @import("../status_test.zig");
const session = @import("session.zig");
const keys = @import("keys.zig");
const pubkey = @import("pubkey.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const sshd = "/usr/sbin/sshd";

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    env: std.process.Environ.Map,
    /// Extra `-o` options for the next sshd.
    server_opts: []const []const u8 = &.{},
    opts: session.Options = .{},
    known: [1][]const u8 = undefined,
    last_session: ?*session.Session = null,

    fn init(gpa: Allocator, io: Io) !?*Fixture {
        if (builtin.os.tag == .windows) return null;
        if (std.os.linux.geteuid() != 0) return null;
        Io.Dir.cwd().access(io, sshd, .{}) catch return null;
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
        Io.Dir.cwd().createDirPath(io, "/run/sshd") catch {};
        f.run("", "mkdir -p .ssh sshd && cd sshd && for t in ed25519 ecdsa rsa; do ssh-keygen -q -t $t -N '' -f hk_$t; done && " ++
            "ssh-keygen -q -t ed25519 -N '' -C me@test -f ../.ssh/id_ed25519 && cat ../.ssh/id_ed25519.pub > authorized_keys") catch {
            f.deinit(gpa);
            return null;
        };
        const cfg = try std.fmt.allocPrint(gpa,
            \\HostKey {0s}/sshd/hk_ed25519
            \\HostKey {0s}/sshd/hk_ecdsa
            \\HostKey {0s}/sshd/hk_rsa
            \\AuthorizedKeysFile {0s}/sshd/authorized_keys
            \\StrictModes no
            \\PermitRootLogin yes
            \\PasswordAuthentication no
            \\KbdInteractiveAuthentication no
            \\UsePAM no
            \\AcceptEnv GIT_PROTOCOL
            \\PidFile none
            \\LogLevel ERROR
            \\
        , .{f.root});
        defer gpa.free(cfg);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "sshd/config", .data = cfg });
        f.known[0] = try std.fs.path.join(gpa, &.{ f.root, ".ssh", "known_hosts" });
        f.opts = .{
            .env = &f.env,
            .dialer = .{ .ctx = f, .dial = dial },
            .ssh_config = "",
            .known_hosts_files = &f.known,
            .strict = .accept_new,
            .agent = "none",
        };
        return f;
    }

    fn deinit(f: *Fixture, gpa: Allocator) void {
        f.env.deinit();
        gpa.free(f.root);
        if (f.known[0].len > 0) gpa.free(f.known[0]);
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    fn sh(f: *Fixture, gpa: Allocator, sub: []const u8, script: []const u8) ![]u8 {
        const dir = try std.fs.path.join(gpa, &.{ f.root, sub });
        defer gpa.free(dir);
        return helpers.sh(gpa, testing.io, dir, &f.env, script);
    }

    fn run(f: *Fixture, sub: []const u8, script: []const u8) !void {
        testing.allocator.free(try f.sh(testing.allocator, sub, script));
    }

    fn open(f: *Fixture, gpa: Allocator, sub: []const u8) !*Repository {
        const dir = try std.fs.path.join(gpa, &.{ f.root, sub });
        defer gpa.free(dir);
        return (try Repository.discover(gpa, testing.io, dir, .{ .env = &f.env })).?;
    }

    const Pipe = struct {
        p: *transport.Process,
        fn close(ctx: ?*anyopaque) void {
            const pp: *Pipe = @ptrCast(@alignCast(ctx.?));
            const gpa = pp.p.gpa;
            pp.p.connection().close();
            gpa.destroy(pp);
        }
    };

    fn dial(ctx: ?*anyopaque, gpa: Allocator, io: Io, host: []const u8, port: u16) anyerror!session.Raw {
        _ = host;
        _ = port;
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        const cfg = try std.fs.path.join(gpa, &.{ f.root, "sshd", "config" });
        defer gpa.free(cfg);
        try argv.appendSlice(gpa, &.{ sshd, "-i", "-f", cfg });
        for (f.server_opts) |o| try argv.appendSlice(gpa, &.{ "-o", o });
        const p = try transport.Process.spawn(gpa, io, argv.items, f.root, &f.env);
        const pp = try gpa.create(Pipe);
        pp.* = .{ .p = p };
        const c = p.connection();
        return .{ .ctx = pp, .reader = c.reader(), .writer = c.writer(), .close = Pipe.close };
    }

    fn connect(ctx: ?*anyopaque, repo: *Repository, remote_url: []const u8, service: transport.Service) anyerror!transport.Connection {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        const s = try session.connect(repo.gpa, repo.io, remote_url, service, f.opts);
        f.last_session = s;
        return s.connection();
    }

    fn connector(f: *Fixture) fetch_mod.Connector {
        return .{ .ctx = f, .connect = connect };
    }

    fn url(f: *Fixture, gpa: Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "root@localhost:{s}/srv.git", .{f.root});
    }

    /// Fetches into the clone "n" and checks it has the server's refs.
    fn fetchAndCheck(f: *Fixture) !void {
        const gpa = testing.allocator;
        const repo = try f.open(gpa, "n");
        defer repo.close();
        var r = try fetch_mod.fetch(repo, "origin", .{}, f.connector());
        defer r.deinit();
        const want = try f.sh(gpa, "srv.git", "git for-each-ref --format='%(objectname) %(refname:lstrip=2)' refs/heads");
        defer gpa.free(want);
        const got = try f.sh(gpa, "n", "git for-each-ref --format='%(objectname) %(refname:lstrip=3)' refs/remotes/origin; git fsck --no-progress --no-dangling 2>&1 | grep -v ^notice: || true");
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }

    fn setupRepos(f: *Fixture) !void {
        try f.run("", "git init -q --bare -b main srv.git && git init -q -b main w && cd w && printf 'a\\n' > a && git add a && git commit -qm one && " ++
            "git push -q ../srv.git main && cd .. && git init -q -b main n");
        const gpa = testing.allocator;
        const u = try f.url(gpa);
        defer gpa.free(u);
        const script = try std.fmt.allocPrint(gpa, "git remote add origin '{s}'", .{u});
        defer gpa.free(script);
        try f.run("n", script);
    }

    fn newCommit(f: *Fixture, n: []const u8) !void {
        const gpa = testing.allocator;
        const script = try std.fmt.allocPrint(gpa, "printf '{s}\\n' >> a && git commit -qam '{s}' && git push -q ../srv.git main", .{ n, n });
        defer gpa.free(script);
        try f.run("w", script);
    }
};

test "ssh: fetch with every cipher and host key type" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.setupRepos();
    const combos = [_][]const []const u8{
        &.{ "Ciphers=aes256-gcm@openssh.com", "HostKeyAlgorithms=ssh-ed25519" },
        &.{ "Ciphers=aes128-gcm@openssh.com", "HostKeyAlgorithms=ecdsa-sha2-nistp256" },
        &.{ "Ciphers=chacha20-poly1305@openssh.com", "HostKeyAlgorithms=rsa-sha2-512" },
        &.{ "Ciphers=aes256-gcm@openssh.com", "HostKeyAlgorithms=rsa-sha2-256", "KexAlgorithms=curve25519-sha256@libssh.org" },
    };
    for (combos, 0..) |o, i| {
        f.server_opts = o;
        var nb: [8]u8 = undefined;
        try f.newCommit(try std.fmt.bufPrint(&nb, "c{d}", .{i}));
        f.fetchAndCheck() catch |e| {
            std.debug.print("server options: {s}\n", .{o[0]});
            return e;
        };
    }
    // Each host key type was accepted once and recorded.
    const kh = try f.sh(gpa, "", "cut -d' ' -f1,2 .ssh/known_hosts");
    defer gpa.free(kh);
    try testing.expectEqualStrings("localhost ssh-ed25519\nlocalhost ecdsa-sha2-nistp256\nlocalhost ssh-rsa\n", kh);
}

test "ssh: protocol v0 when the server gets no GIT_PROTOCOL" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.setupRepos();
    f.opts.protocol_v2 = false;
    try f.fetchAndCheck();
    // Incremental: the second fetch negotiates with what "n" has.
    for (0..40) |i| {
        var nb: [8]u8 = undefined;
        try f.newCommit(try std.fmt.bufPrint(&nb, "v{d}", .{i}));
    }
    try f.fetchAndCheck();
    try f.run("n", "git checkout -q -b local origin/main && for i in 1 2 3; do printf 'l\\n' >> l && git add l && git commit -qm l$i; done");
    try f.newCommit("after");
    try f.fetchAndCheck();
}

test "ssh: known_hosts policies" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.setupRepos();
    f.server_opts = &.{"HostKeyAlgorithms=ssh-ed25519"};

    // Unknown host under StrictHostKeyChecking=yes, and with ask and no prompt.
    f.opts.strict = .yes;
    try testing.expectError(error.HostKeyUnknown, f.fetchAndCheck());
    f.opts.strict = .ask;
    try testing.expectError(error.HostKeyUnknown, f.fetchAndCheck());

    // The prompt sees the fingerprint ssh-keygen prints.
    const Prompt = struct {
        var seen: [64]u8 = undefined;
        var seen_len: usize = 0;
        fn ask(_: ?*anyopaque, host: []const u8, key_type: []const u8, fp: []const u8) bool {
            std.debug.assert(std.mem.eql(u8, host, "localhost"));
            std.debug.assert(std.mem.eql(u8, key_type, "ssh-ed25519"));
            @memcpy(seen[0..fp.len], fp);
            seen_len = fp.len;
            return true;
        }
    };
    f.opts.host_key_prompt = .{ .ask = Prompt.ask };
    try f.fetchAndCheck();
    const fp = try f.sh(gpa, "", "ssh-keygen -l -f sshd/hk_ed25519.pub | cut -d' ' -f2");
    defer gpa.free(fp);
    try testing.expectEqualStrings(std.mem.trimEnd(u8, fp, "\n"), Prompt.seen[0..Prompt.seen_len]);

    // Now known: strict mode passes.
    f.opts.strict = .yes;
    try f.newCommit("two");
    try f.fetchAndCheck();

    // A changed key fails under every policy.
    try f.run("sshd", "rm hk_ed25519 hk_ed25519.pub && ssh-keygen -q -t ed25519 -N '' -f hk_ed25519");
    for ([_]@import("config.zig").Strict{ .yes, .no, .accept_new, .ask }) |p| {
        f.opts.strict = p;
        try testing.expectError(error.HostKeyChanged, f.fetchAndCheck());
    }
}

test "ssh: passphrase-protected keys, ECDSA and RSA key files" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.setupRepos();
    try f.run(".ssh", "ssh-keygen -q -t ed25519 -N 'right horse' -f enc && ssh-keygen -q -t ecdsa -N '' -f ec && ssh-keygen -q -t rsa -b 3072 -N '' -f rsa && " ++
        "cat enc.pub ec.pub rsa.pub > ../sshd/authorized_keys");
    const Pass = struct {
        var calls: u32 = 0;
        fn get(_: ?*anyopaque, a: Allocator, path: []const u8, attempt: u32) anyerror!?[]u8 {
            std.debug.assert(std.mem.endsWith(u8, path, "/enc"));
            calls += 1;
            return try a.dupe(u8, if (attempt == 0) "wrong" else "right horse");
        }
    };
    f.opts.passphrase = .{ .get = Pass.get };
    for ([_][]const u8{ "enc", "ec", "rsa" }) |name| {
        const p = try std.fs.path.join(gpa, &.{ f.root, ".ssh", name });
        defer gpa.free(p);
        f.opts.identity_files = &.{p};
        try f.newCommit(name);
        f.fetchAndCheck() catch |e| {
            std.debug.print("key: {s}\n", .{name});
            return e;
        };
    }
    try testing.expectEqual(@as(u32, 2), Pass.calls);

    // The key's own public half matches ssh-keygen's .pub file.
    const text = try f.sh(gpa, ".ssh", "cat rsa");
    defer gpa.free(text);
    var loaded = try keys.parse(gpa, text, null);
    defer loaded.deinit(gpa);
    const blob = try loaded.key.publicBlob(gpa);
    defer gpa.free(blob);
    const pub_text = try f.sh(gpa, ".ssh", "cat rsa.pub");
    defer gpa.free(pub_text);
    const t = try pubkey.Text.parse(gpa, pub_text);
    defer gpa.free(t.blob);
    try testing.expectEqualSlices(u8, t.blob, blob);
}

test "ssh: push through an agent-held RSA key" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.setupRepos();
    // Only the agent's key is authorized.
    try f.run("", "ssh-keygen -q -t rsa -b 2048 -N '' -f agent_rsa && cat agent_rsa.pub > sshd/authorized_keys && " ++
        "ssh-agent -a \"$HOME/agent.sock\" > /dev/null && SSH_AUTH_SOCK=\"$HOME/agent.sock\" ssh-add -q agent_rsa");
    defer f.run("", "SSH_AUTH_SOCK=\"$HOME/agent.sock\" ssh-agent -k >/dev/null 2>&1; pkill -f \"ssh-agent -a $HOME/agent.sock\" || true") catch {};
    const sock = try std.fs.path.join(gpa, &.{ f.root, "agent.sock" });
    defer gpa.free(sock);
    f.opts.agent = sock;
    f.opts.identity_files = &.{};
    try f.fetchAndCheck();
    try f.run("n", "git checkout -q -b main origin/main && printf 'n\\n' >> a && git commit -qam pushed");
    const repo = try f.open(gpa, "n");
    defer repo.close();
    var r = try push_mod.push(repo, "origin", .{ .refspecs = &.{"main"} }, f.connector());
    defer r.deinit();
    const want = try f.sh(gpa, "n", "git rev-parse main");
    defer gpa.free(want);
    const got = try f.sh(gpa, "srv.git", "git rev-parse main");
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

test "ssh: a refused key reports authentication failure" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.setupRepos();
    try f.run("", ": > sshd/authorized_keys");
    try testing.expectError(error.SshAuthenticationFailed, f.fetchAndCheck());
}
