//! Signing and verifying commits the way git does with
//! `gpg.format = ssh`: the key from `user.signingKey` (a private key
//! file, a public key file or `key::` literal held by ssh-agent), SSHSIG
//! in the `git` namespace, and verification against
//! `gpg.ssh.allowedSignersFile`. OpenPGP and X.509 are not supported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Repository = @import("../repository.zig").Repository;
const sshsig = @import("sshsig.zig");
const embed = @import("embed.zig");
const allowed_signers = @import("allowed_signers.zig");
const keys = @import("../ssh/keys.zig");
const agent_mod = @import("../ssh/agent.zig");
const pubkey = @import("../ssh/pubkey.zig");
const session = @import("../ssh/session.zig");
const ObjectFormat = @import("../oid.zig").ObjectFormat;

pub const namespace = "git";

pub const Options = struct {
    /// Asks for a key file's passphrase.
    passphrase: ?session.PassphraseProvider = null,
    /// The environment for SSH_AUTH_SOCK (null: the repository's).
    env: ?*const std.process.Environ.Map = null,
    /// Overrides the agent address; "none" disables it.
    agent: ?[]const u8 = null,
};

/// The signing key from the repository's configuration.
pub const KeySigner = struct {
    gpa: Allocator,
    io: Io,
    blob: []u8,
    path: ?[]u8 = null,
    text: ?[]u8 = null,
    loaded: ?keys.Loaded = null,
    agent: ?agent_mod.Agent = null,
    opts: Options,

    pub fn deinit(k: *KeySigner) void {
        const gpa = k.gpa;
        if (k.loaded) |*l| l.deinit(gpa);
        if (k.text) |t| {
            std.crypto.secureZero(u8, t);
            gpa.free(t);
        }
        if (k.path) |p| gpa.free(p);
        gpa.free(k.blob);
        gpa.destroy(k);
    }

    pub fn signer(k: *KeySigner) sshsig.Signer {
        return .{ .blob = k.blob, .ctx = k, .sign = signFn };
    }

    fn signFn(ctx: ?*anyopaque, gpa: Allocator, alg: []const u8, data: []const u8) anyerror![]u8 {
        const k: *KeySigner = @ptrCast(@alignCast(ctx.?));
        if (k.text) |text| {
            if (k.loaded == null) k.loaded = try load(k, text);
            return k.loaded.?.key.sign(gpa, alg, data);
        }
        const ag = k.agent orelse return error.SigningKeyNotInAgent;
        const flags: u32 = if (std.mem.eql(u8, alg, "rsa-sha2-512")) agent_mod.flag_rsa_sha2_512 else if (std.mem.eql(u8, alg, "rsa-sha2-256")) agent_mod.flag_rsa_sha2_256 else 0;
        const sig = ag.sign(k.blob, data, flags) catch return error.SigningKeyNotInAgent;
        defer k.gpa.free(sig);
        return gpa.dupe(u8, sig);
    }

    fn load(k: *KeySigner, text: []const u8) !keys.Loaded {
        if (!try keys.isEncrypted(k.gpa, text)) return keys.parse(k.gpa, text, null);
        const p = k.opts.passphrase orelse return error.PassphraseRequired;
        var attempt: u32 = 0;
        while (attempt < 3) : (attempt += 1) {
            const pass = (try p.get(p.ctx, k.gpa, k.path orelse "", attempt)) orelse return error.PassphraseCancelled;
            defer {
                std.crypto.secureZero(u8, pass);
                k.gpa.free(pass);
            }
            return keys.parse(k.gpa, text, pass) catch |e| switch (e) {
                error.BadPassphrase => continue,
                else => |x| return x,
            };
        }
        return error.BadPassphrase;
    }
};

fn expandHome(gpa: Allocator, repo: *Repository, p: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, p, "~/")) {
        const home = repo.home orelse return error.SigningKeyMissing;
        return std.fs.path.join(gpa, &.{ home, p[2..] });
    }
    return gpa.dupe(u8, p);
}

/// Whether commits should be signed by default (`commit.gpgSign`).
pub fn wanted(repo: *Repository) bool {
    return repo.config.getBool("commit.gpgsign") orelse false;
}

/// Loads the configured signing key. `error.SigningUnsupported` for
/// `gpg.format` other than ssh, `error.SigningKeyMissing` without
/// `user.signingKey`.
pub fn fromConfig(repo: *Repository, opts: Options) !*KeySigner {
    const gpa = repo.gpa;
    const format = repo.config.get("gpg.format") orelse "openpgp";
    if (!std.ascii.eqlIgnoreCase(format, "ssh")) return error.SigningUnsupported;
    const key = repo.config.get("user.signingkey") orelse return error.SigningKeyMissing;
    const k = try gpa.create(KeySigner);
    k.* = .{ .gpa = gpa, .io = repo.io, .blob = &.{}, .opts = opts };
    errdefer k.deinit();
    const env = opts.env orelse repo.envMap();
    const agent_path = opts.agent orelse agent_mod.defaultPath(env);
    if (agent_path) |p| if (!std.mem.eql(u8, p, "none")) {
        k.agent = .{ .gpa = gpa, .io = repo.io, .path = p };
    };
    if (std.mem.startsWith(u8, key, "key::")) {
        const t = try pubkey.Text.parse(gpa, key[5..]);
        k.blob = t.blob;
        return k;
    }
    k.path = try expandHome(gpa, repo, key);
    const text = Io.Dir.cwd().readFileAlloc(repo.io, k.path.?, gpa, .limited(1 << 20)) catch return error.SigningKeyMissing;
    if (std.mem.indexOf(u8, text, "PRIVATE KEY-----") != null) {
        k.text = text;
        k.blob = try keys.publicBlob(gpa, text);
        return k;
    }
    defer gpa.free(text);
    const t = try pubkey.Text.parse(gpa, text);
    k.blob = t.blob;
    // A public key: the agent signs; failing that, the private key next to it.
    if (std.mem.endsWith(u8, k.path.?, ".pub")) {
        const priv = k.path.?[0 .. k.path.?.len - 4];
        if (Io.Dir.cwd().readFileAlloc(repo.io, priv, gpa, .limited(1 << 20))) |pt| {
            if (k.agent == null or !agentHas(k)) k.text = pt else gpa.free(pt);
        } else |_| {}
    }
    return k;
}

fn agentHas(k: *KeySigner) bool {
    const ids = k.agent.?.identities() catch return false;
    defer k.agent.?.freeIdentities(ids);
    for (ids) |id| if (std.mem.eql(u8, id.blob, k.blob)) return true;
    return false;
}

/// Signs an unsigned raw commit, returning it with the signature header.
pub fn signCommit(gpa: Allocator, signer: sshsig.Signer, raw: []const u8, fmt: ObjectFormat) ![]u8 {
    const armored = try sshsig.sign(gpa, signer, namespace, raw, .sha512);
    defer gpa.free(armored);
    return embed.embedCommit(gpa, raw, armored, embed.headerName(fmt));
}

pub const VerifyStatus = union(enum) {
    /// Good signature from a listed key: its principals.
    verified: []const u8,
    /// Good signature, but the key is not in the allowed signers.
    unknown_signer,
    bad_signature,
    /// OpenPGP, X.509 or something else.
    unsupported_format,
    no_signature,
};

pub const Verified = struct {
    status: VerifyStatus,
    /// `SHA256:...` of the signing key, when the signature was parsed.
    fingerprint: [50]u8 = undefined,
    fingerprint_len: usize = 0,

    pub fn fingerprintText(v: *const Verified) []const u8 {
        return v.fingerprint[0..v.fingerprint_len];
    }
};

/// Verifies a raw commit's signature. Principal strings borrow from
/// `allowed`.
pub fn verifyCommit(gpa: Allocator, raw: []const u8, fmt: ObjectFormat, allowed: ?*const allowed_signers.AllowedSigners, now: i64) !Verified {
    var split = try embed.splitCommit(gpa, raw, fmt);
    defer split.deinit(gpa);
    const armored = split.signature orelse return .{ .status = .no_signature };
    var sig = sshsig.parse(gpa, armored) catch |e| switch (e) {
        error.NotSshSignature => return .{ .status = .unsupported_format },
        error.OutOfMemory => return e,
        else => return .{ .status = .bad_signature },
    };
    defer sig.deinit(gpa);
    var v: Verified = .{ .status = .bad_signature };
    v.fingerprint_len = pubkey.fingerprint(&v.fingerprint, sig.pubkey_blob).len;
    sig.verify(split.payload, namespace) catch return v;
    const list = allowed orelse {
        v.status = .unknown_signer;
        return v;
    };
    v.status = if (list.findPrincipals(sig.pubkey_blob, namespace, now)) |p| .{ .verified = p } else .unknown_signer;
    return v;
}

/// Reads `gpg.ssh.allowedSignersFile`, if configured and present.
pub fn loadAllowedSigners(repo: *Repository) !?allowed_signers.AllowedSigners {
    const p = repo.config.get("gpg.ssh.allowedsignersfile") orelse return null;
    const path = try expandHome(repo.gpa, repo, p);
    defer repo.gpa.free(path);
    const text = Io.Dir.cwd().readFileAlloc(repo.io, path, repo.gpa, .limited(16 << 20)) catch return null;
    defer repo.gpa.free(text);
    return try allowed_signers.AllowedSigners.parse(repo.gpa, text);
}
