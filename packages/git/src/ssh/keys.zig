//! OpenSSH private keys (`openssh-key-v1`, PROTOCOL.key) and signing
//! with them: Ed25519, ECDSA P-256/P-384 and RSA (`rsa-sha2-256/512`).
//! Passphrase-protected keys use bcrypt_pbkdf with aes256-ctr or
//! aes256-gcm@openssh.com, as `ssh-keygen` writes them.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const wire = @import("wire.zig");
const Ed25519 = crypto.sign.Ed25519;
const P256 = crypto.sign.ecdsa.EcdsaP256Sha256;
const P384 = crypto.sign.ecdsa.EcdsaP384Sha384;
const Aes256 = crypto.core.aes.Aes256;

pub const Rsa = struct {
    n: []u8,
    e: []u8,
    d: []u8,
};

/// A private key ready to sign.
pub const PrivateKey = union(enum) {
    ed25519: Ed25519.KeyPair,
    ecdsa_p256: P256.KeyPair,
    ecdsa_p384: P384.KeyPair,
    rsa: Rsa,

    pub fn deinit(k: *PrivateKey, gpa: Allocator) void {
        switch (k.*) {
            .rsa => |r| {
                crypto.secureZero(u8, r.d);
                gpa.free(r.n);
                gpa.free(r.e);
                gpa.free(r.d);
            },
            else => {},
        }
        crypto.secureZero(u8, std.mem.asBytes(k));
    }

    /// The SSH public key blob.
    pub fn publicBlob(k: PrivateKey, gpa: Allocator) ![]u8 {
        var b: wire.Builder = .init(gpa);
        errdefer b.deinit();
        switch (k) {
            .ed25519 => |kp| {
                try b.string("ssh-ed25519");
                try b.string(&kp.public_key.toBytes());
            },
            .ecdsa_p256 => |kp| {
                try b.string("ecdsa-sha2-nistp256");
                try b.string("nistp256");
                try b.string(&kp.public_key.toUncompressedSec1());
            },
            .ecdsa_p384 => |kp| {
                try b.string("ecdsa-sha2-nistp384");
                try b.string("nistp384");
                try b.string(&kp.public_key.toUncompressedSec1());
            },
            .rsa => |r| {
                try b.string("ssh-rsa");
                try b.mpint(r.e);
                try b.mpint(r.n);
            },
        }
        return b.toOwned();
    }

    /// The signature algorithm to use: the key type, or for RSA the
    /// SHA-2 variant `want` names (default rsa-sha2-512).
    pub fn algorithm(k: PrivateKey, want: ?[]const u8) []const u8 {
        return switch (k) {
            .ed25519 => "ssh-ed25519",
            .ecdsa_p256 => "ecdsa-sha2-nistp256",
            .ecdsa_p384 => "ecdsa-sha2-nistp384",
            .rsa => if (want != null and std.mem.eql(u8, want.?, "rsa-sha2-256")) "rsa-sha2-256" else "rsa-sha2-512",
        };
    }

    /// Signs `msg`, returning the signature blob (`string alg, string sig`).
    pub fn sign(k: PrivateKey, gpa: Allocator, alg: []const u8, msg: []const u8) ![]u8 {
        var b: wire.Builder = .init(gpa);
        errdefer b.deinit();
        try b.string(alg);
        switch (k) {
            .ed25519 => |kp| try b.string(&(try kp.sign(msg, null)).toBytes()),
            inline .ecdsa_p256, .ecdsa_p384 => |kp, tag| {
                const E = if (tag == .ecdsa_p256) P256 else P384;
                const raw = (try kp.sign(msg, null)).toBytes();
                const n = E.Signature.encoded_length / 2;
                var inner: wire.Builder = .init(gpa);
                defer inner.deinit();
                try inner.mpint(raw[0..n]);
                try inner.mpint(raw[n..]);
                try b.string(inner.bytes());
            },
            .rsa => |r| {
                const s = try rsaSign(gpa, r, alg, msg);
                defer gpa.free(s);
                try b.string(s);
            },
        }
        return b.toOwned();
    }
};

const sha256_prefix = [_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };
const sha512_prefix = [_]u8{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 };

/// RSASSA-PKCS1-v1_5 (RFC 8017 §8.2.1).
fn rsaSign(gpa: Allocator, r: Rsa, alg: []const u8, msg: []const u8) ![]u8 {
    const M = crypto.ff.Modulus(4096);
    const k = r.n.len;
    const em = try gpa.alloc(u8, k);
    defer gpa.free(em);
    var digest: [64]u8 = undefined;
    const prefix: []const u8, const hlen: usize = if (std.mem.eql(u8, alg, "rsa-sha2-256")) blk: {
        crypto.hash.sha2.Sha256.hash(msg, digest[0..32], .{});
        break :blk .{ &sha256_prefix, 32 };
    } else if (std.mem.eql(u8, alg, "rsa-sha2-512")) blk: {
        crypto.hash.sha2.Sha512.hash(msg, &digest, .{});
        break :blk .{ &sha512_prefix, 64 };
    } else return error.UnsupportedSignature;
    const t_len = prefix.len + hlen;
    if (k < t_len + 11) return error.BadKey;
    em[0] = 0;
    em[1] = 1;
    @memset(em[2 .. k - t_len - 1], 0xff);
    em[k - t_len - 1] = 0;
    @memcpy(em[k - t_len ..][0..prefix.len], prefix);
    @memcpy(em[k - hlen ..], digest[0..hlen]);
    const m = M.fromBytes(r.n, .big) catch return error.BadKey;
    const x = M.Fe.fromBytes(m, em, .big) catch return error.BadKey;
    const y = m.powWithEncodedExponent(x, r.d, .big) catch return error.BadKey;
    const out = try gpa.alloc(u8, k);
    errdefer gpa.free(out);
    y.toBytes(out, .big) catch return error.BadKey;
    return out;
}

pub const Loaded = struct {
    key: PrivateKey,
    comment: []u8,

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        l.key.deinit(gpa);
        gpa.free(l.comment);
    }
};

const begin = "-----BEGIN OPENSSH PRIVATE KEY-----";
const end = "-----END OPENSSH PRIVATE KEY-----";
const magic = "openssh-key-v1\x00";

fn decodeArmor(gpa: Allocator, text: []const u8) ![]u8 {
    const s = std.mem.indexOf(u8, text, begin) orelse return error.UnsupportedKeyFormat;
    const e = std.mem.indexOfPos(u8, text, s, end) orelse return error.BadKey;
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(gpa);
    for (text[s + begin.len .. e]) |c| if (!std.ascii.isWhitespace(c)) try b64.append(gpa, c);
    const dec = std.base64.standard.Decoder;
    const out = try gpa.alloc(u8, dec.calcSizeForSlice(b64.items) catch return error.BadKey);
    errdefer gpa.free(out);
    dec.decode(out, b64.items) catch return error.BadKey;
    return out;
}

/// Whether the key file needs a passphrase.
pub fn isEncrypted(gpa: Allocator, text: []const u8) !bool {
    const raw = try decodeArmor(gpa, text);
    defer gpa.free(raw);
    if (!std.mem.startsWith(u8, raw, magic)) return error.BadKey;
    var p: wire.Parser = .init(raw[magic.len..]);
    return !std.mem.eql(u8, try p.string(), "none");
}

/// The public key blob of a key file, without decrypting it.
pub fn publicBlob(gpa: Allocator, text: []const u8) ![]u8 {
    const raw = try decodeArmor(gpa, text);
    defer gpa.free(raw);
    if (!std.mem.startsWith(u8, raw, magic)) return error.BadKey;
    var p: wire.Parser = .init(raw[magic.len..]);
    _ = try p.string();
    _ = try p.string();
    _ = try p.string();
    if (try p.int() != 1) return error.UnsupportedKeyFormat;
    return gpa.dupe(u8, try p.string());
}

/// Parses an OpenSSH private key file. Encrypted keys need `passphrase`
/// (`error.PassphraseRequired` without one, `error.BadPassphrase` when
/// it is wrong).
pub fn parse(gpa: Allocator, text: []const u8, passphrase: ?[]const u8) !Loaded {
    if (std.mem.indexOf(u8, text, "-----BEGIN RSA PRIVATE KEY-----") != null or
        std.mem.indexOf(u8, text, "-----BEGIN EC PRIVATE KEY-----") != null) return error.UnsupportedKeyFormat;
    const raw = try decodeArmor(gpa, text);
    defer {
        crypto.secureZero(u8, raw);
        gpa.free(raw);
    }
    if (!std.mem.startsWith(u8, raw, magic)) return error.BadKey;
    var p: wire.Parser = .init(raw[magic.len..]);
    const cipher = try p.string();
    const kdf = try p.string();
    const kdf_opts = try p.string();
    if (try p.int() != 1) return error.UnsupportedKeyFormat;
    _ = try p.string();
    const enc_len = try p.int();
    const enc = @constCast(try p.take(enc_len));
    if (!std.mem.eql(u8, cipher, "none")) {
        const pass = passphrase orelse return error.PassphraseRequired;
        if (!std.mem.eql(u8, kdf, "bcrypt")) return error.UnsupportedKeyFormat;
        var kp: wire.Parser = .init(kdf_opts);
        const salt = try kp.string();
        const rounds = try kp.int();
        var kiv: [48]u8 = undefined;
        defer crypto.secureZero(u8, &kiv);
        if (std.mem.eql(u8, cipher, "aes256-ctr")) {
            try crypto.pwhash.bcrypt.opensshKdf(pass, salt, &kiv, rounds);
            const ctx = Aes256.initEnc(kiv[0..32].*);
            crypto.core.modes.ctr(@TypeOf(ctx), ctx, enc, enc, kiv[32..48].*, .big);
        } else if (std.mem.eql(u8, cipher, "aes256-gcm@openssh.com")) {
            try crypto.pwhash.bcrypt.opensshKdf(pass, salt, kiv[0..44], rounds);
            const tag = try p.take(16);
            crypto.aead.aes_gcm.Aes256Gcm.decrypt(enc, enc, tag[0..16].*, "", kiv[32..44].*, kiv[0..32].*) catch return error.BadPassphrase;
        } else return error.UnsupportedKeyFormat;
    }
    var s: wire.Parser = .init(enc);
    if (try s.int() != try s.int()) return if (passphrase != null) error.BadPassphrase else error.BadKey;
    const t = try s.string();
    var key: PrivateKey = undefined;
    if (std.mem.eql(u8, t, "ssh-ed25519")) {
        _ = try s.string();
        const sk = try s.string();
        if (sk.len != 64) return error.BadKey;
        key = .{ .ed25519 = Ed25519.KeyPair.fromSecretKey(try Ed25519.SecretKey.fromBytes(sk[0..64].*)) catch return error.BadKey };
    } else if (std.mem.eql(u8, t, "ecdsa-sha2-nistp256") or std.mem.eql(u8, t, "ecdsa-sha2-nistp384")) {
        _ = try s.string();
        _ = try s.string();
        const d = try s.mpint();
        key = if (t[t.len - 1] == '6') .{ .ecdsa_p256 = try ecdsaKey(P256, d) } else .{ .ecdsa_p384 = try ecdsaKey(P384, d) };
    } else if (std.mem.eql(u8, t, "ssh-rsa")) {
        const n = try s.mpint();
        const e = try s.mpint();
        const d = try s.mpint();
        _ = try s.mpint();
        _ = try s.mpint();
        _ = try s.mpint();
        if (n.len > 512) return error.UnsupportedKeyType;
        const nn = try gpa.dupe(u8, n);
        errdefer gpa.free(nn);
        const ee = try gpa.dupe(u8, e);
        errdefer gpa.free(ee);
        key = .{ .rsa = .{ .n = nn, .e = ee, .d = try gpa.dupe(u8, d) } };
    } else return error.UnsupportedKeyType;
    errdefer key.deinit(gpa);
    return .{ .key = key, .comment = try gpa.dupe(u8, try s.string()) };
}

fn ecdsaKey(comptime E: type, d: []const u8) !E.KeyPair {
    const len = E.SecretKey.encoded_length;
    if (d.len > len) return error.BadKey;
    var b: [len]u8 = @splat(0);
    defer crypto.secureZero(u8, &b);
    @memcpy(b[len - d.len ..], d);
    return E.KeyPair.fromSecretKey(E.SecretKey.fromBytes(b) catch return error.BadKey) catch error.BadKey;
}
