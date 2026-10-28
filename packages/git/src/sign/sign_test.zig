//! SSH commit signing against git and ssh-keygen: an Ed25519-signed
//! commit is byte-identical to `git commit -S` (Ed25519 signatures are
//! deterministic), `git verify-commit` accepts our ECDSA, RSA (through
//! ssh-agent) and passphrase-key signatures, and we verify git's.
//! Skipped without git and ssh-keygen, and on Windows.

const std = @import("std");
const builtin = @import("builtin");
const Repository = @import("../repository.zig").Repository;
const commit_cmd = @import("../commit_cmd.zig");
const signing = @import("signing.zig");
const sshsig = @import("sshsig.zig");
const helpers = @import("../status_test.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    env: std.process.Environ.Map,

    fn init(gpa: Allocator, io: Io) !?*Fixture {
        if (builtin.os.tag == .windows) return null;
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
        f.run("", "mkdir .ssh && cd .ssh && ssh-keygen -q -t ed25519 -N '' -C ed -f ed && ssh-keygen -q -t ecdsa -N '' -f ec && " ++
            "ssh-keygen -q -t ed25519 -N 'pass phrase' -f enc && ssh-keygen -q -t rsa -b 2048 -N '' -f rsa && " ++
            "for k in ed ec enc rsa; do printf 'a@example.com %s\\n' \"$(cat $k.pub)\"; done > allowed && cd .. && " ++
            "git init -q -b main g && cd g && git config gpg.format ssh && git config commit.gpgsign true && " ++
            "git config gpg.ssh.allowedSignersFile \"$HOME/.ssh/allowed\" && git config user.signingkey \"$HOME/.ssh/ed\" && " ++
            "printf 'a\\n' > a && git add a && git commit -qm base && cd .. && cp -a g n") catch {
            f.deinit(gpa);
            return null;
        };
        return f;
    }

    fn deinit(f: *Fixture, gpa: Allocator) void {
        f.env.deinit();
        gpa.free(f.root);
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

    fn commit(f: *Fixture, sub: []const u8, msg: []const u8, opts: signing.Options) !void {
        const gpa = testing.allocator;
        const repo = try f.open(gpa, sub);
        defer repo.close();
        var r = try commit_cmd.commit(repo, .{ .message = msg, .allow_empty = true, .signing = opts });
        r.deinit(gpa);
    }

    fn verifyByGit(f: *Fixture, sub: []const u8) !void {
        try f.run(sub, "git verify-commit HEAD 2>/dev/null");
    }
};

test "sign: Ed25519 commits match git commit -S byte for byte" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.run("g", "git commit -q --allow-empty -m signed");
    try f.commit("n", "signed", .{});
    const want = try f.sh(gpa, "g", "git cat-file commit HEAD; git rev-parse HEAD");
    defer gpa.free(want);
    const got = try f.sh(gpa, "n", "git cat-file commit HEAD; git rev-parse HEAD");
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
    try f.verifyByGit("n");

    // And we verify git's signature, with the principal from allowed signers.
    const repo = try f.open(gpa, "g");
    defer repo.close();
    const head = (try repo.head()).?;
    const obj = try repo.odb.read(gpa, head);
    defer gpa.free(obj.data);
    var allowed = (try signing.loadAllowedSigners(repo)).?;
    defer allowed.deinit();
    const v = try signing.verifyCommit(gpa, obj.data, repo.format, &allowed, 1700000000);
    try testing.expectEqualStrings("a@example.com", v.status.verified);
    const fp = try f.sh(gpa, "", "ssh-keygen -l -f .ssh/ed.pub | cut -d' ' -f2");
    defer gpa.free(fp);
    try testing.expectEqualStrings(std.mem.trimEnd(u8, fp, "\n"), v.fingerprintText());

    // A tampered payload fails; a commit without a signature says so.
    const bad = try std.mem.replaceOwned(u8, gpa, obj.data, "signed", "signeD");
    defer gpa.free(bad);
    try testing.expectEqual(signing.VerifyStatus.bad_signature, (try signing.verifyCommit(gpa, bad, repo.format, &allowed, 0)).status);
    try testing.expectEqual(signing.VerifyStatus.no_signature, (try signing.verifyCommit(gpa, "tree x\n\nm\n", repo.format, &allowed, 0)).status);
}

test "sign: ECDSA, passphrase-protected and agent RSA keys verify with git" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);

    try f.run("n", "git config user.signingkey \"$HOME/.ssh/ec\"");
    try f.commit("n", "ecdsa", .{});
    try f.verifyByGit("n");

    try f.run("n", "git config user.signingkey \"$HOME/.ssh/enc\"");
    try testing.expectError(error.PassphraseRequired, f.commit("n", "enc", .{ .agent = "none" }));
    const Pass = struct {
        fn get(_: ?*anyopaque, a: Allocator, _: []const u8, _: u32) anyerror!?[]u8 {
            return try a.dupe(u8, "pass phrase");
        }
    };
    try f.commit("n", "enc", .{ .agent = "none", .passphrase = .{ .get = Pass.get } });
    try f.verifyByGit("n");

    // RSA held by ssh-agent, named by its public key.
    try f.run("", "ssh-agent -a \"$HOME/agent.sock\" > /dev/null && SSH_AUTH_SOCK=\"$HOME/agent.sock\" ssh-add -q .ssh/rsa && mv .ssh/rsa .ssh/rsa.moved");
    defer f.run("", "pkill -f \"ssh-agent -a $HOME/agent.sock\" || true") catch {};
    try f.run("n", "git config user.signingkey \"key::$(cat $HOME/.ssh/rsa.pub)\"");
    const sock = try std.fs.path.join(gpa, &.{ f.root, "agent.sock" });
    defer gpa.free(sock);
    try f.commit("n", "rsa", .{ .agent = sock });
    try f.verifyByGit("n");
}

test "sign: OpenPGP and a missing key are refused before writing" {
    const gpa = testing.allocator;
    const f = (try Fixture.init(gpa, testing.io)) orelse return error.SkipZigTest;
    defer f.deinit(gpa);
    try f.run("n", "git config --unset user.signingkey");
    try testing.expectError(error.SigningKeyMissing, f.commit("n", "x", .{}));
    try f.run("n", "git config gpg.format openpgp");
    try testing.expectError(error.SigningUnsupported, f.commit("n", "x", .{}));
    const log = try f.sh(gpa, "n", "git log --format=%s");
    defer gpa.free(log);
    try testing.expectEqualStrings("base\n", log);
}
