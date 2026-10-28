//! SSH public keys and signature verification: `ssh-ed25519` (RFC 8709),
//! `ecdsa-sha2-nistp256/384` (RFC 5656) and RSA with `rsa-sha2-256/512`
//! (RFC 8332). Used for host keys, SSHSIG and allowed_signers.

const std = @import("std");
const crypto = std.crypto;
const wire = @import("wire.zig");
const Ed25519 = crypto.sign.Ed25519;
const P256 = crypto.sign.ecdsa.EcdsaP256Sha256;
const P384 = crypto.sign.ecdsa.EcdsaP384Sha384;
const rsa = crypto.Certificate.rsa;

pub const Error = error{ UnsupportedKeyType, BadKey, UnsupportedSignature, BadSignature } || wire.Error;

/// A parsed public key. Slices borrow from the blob it was parsed from.
pub const PublicKey = union(enum) {
    ed25519: [32]u8,
    ecdsa_p256: []const u8,
    ecdsa_p384: []const u8,
    rsa: struct { e: []const u8, n: []const u8 },

    /// Parses a key blob (`string type, ...`).
    pub fn parse(blob: []const u8) Error!PublicKey {
        var p: wire.Parser = .init(blob);
        const t = try p.string();
        if (std.mem.eql(u8, t, "ssh-ed25519")) {
            const k = try p.string();
            if (k.len != 32) return error.BadKey;
            return .{ .ed25519 = k[0..32].* };
        }
        if (std.mem.eql(u8, t, "ecdsa-sha2-nistp256") or std.mem.eql(u8, t, "ecdsa-sha2-nistp384")) {
            const curve = try p.string();
            const q = try p.string();
            if (std.mem.eql(u8, t, "ecdsa-sha2-nistp256")) {
                if (!std.mem.eql(u8, curve, "nistp256")) return error.BadKey;
                _ = P256.PublicKey.fromSec1(q) catch return error.BadKey;
                return .{ .ecdsa_p256 = q };
            }
            if (!std.mem.eql(u8, curve, "nistp384")) return error.BadKey;
            _ = P384.PublicKey.fromSec1(q) catch return error.BadKey;
            return .{ .ecdsa_p384 = q };
        }
        if (std.mem.eql(u8, t, "ssh-rsa")) {
            const e = try p.mpint();
            const n = try p.mpint();
            if (n.len < 128 or n.len > 512) return error.BadKey;
            return .{ .rsa = .{ .e = e, .n = n } };
        }
        return error.UnsupportedKeyType;
    }

    pub fn typeName(k: PublicKey) []const u8 {
        return switch (k) {
            .ed25519 => "ssh-ed25519",
            .ecdsa_p256 => "ecdsa-sha2-nistp256",
            .ecdsa_p384 => "ecdsa-sha2-nistp384",
            .rsa => "ssh-rsa",
        };
    }

    /// Whether signature algorithm `alg` can be made by this key.
    pub fn allows(k: PublicKey, alg: []const u8) bool {
        return switch (k) {
            .rsa => std.mem.eql(u8, alg, "rsa-sha2-256") or std.mem.eql(u8, alg, "rsa-sha2-512"),
            else => std.mem.eql(u8, alg, k.typeName()),
        };
    }

    /// Verifies a signature blob (`string alg, string sig`) over `msg`.
    pub fn verify(k: PublicKey, sig_blob: []const u8, msg: []const u8) Error!void {
        var p: wire.Parser = .init(sig_blob);
        const alg = try p.string();
        const sig = try p.string();
        if (!k.allows(alg)) return error.UnsupportedSignature;
        switch (k) {
            .ed25519 => |pk| {
                if (sig.len != 64) return error.BadSignature;
                const key = Ed25519.PublicKey.fromBytes(pk) catch return error.BadKey;
                Ed25519.Signature.fromBytes(sig[0..64].*).verify(msg, key) catch return error.BadSignature;
            },
            inline .ecdsa_p256, .ecdsa_p384 => |q, tag| {
                const E = if (tag == .ecdsa_p256) P256 else P384;
                const n = E.Signature.encoded_length / 2;
                var sp: wire.Parser = .init(sig);
                const r = try sp.mpint();
                const s = try sp.mpint();
                if (r.len > n or s.len > n) return error.BadSignature;
                var raw: [E.Signature.encoded_length]u8 = @splat(0);
                @memcpy(raw[n - r.len .. n], r);
                @memcpy(raw[2 * n - s.len ..], s);
                const key = E.PublicKey.fromSec1(q) catch return error.BadKey;
                E.Signature.fromBytes(raw).verify(msg, key) catch return error.BadSignature;
            },
            .rsa => |r| {
                if (sig.len > r.n.len) return error.BadSignature;
                const key = rsa.PublicKey.fromBytes(r.e, r.n) catch return error.BadKey;
                inline for (.{ 128, 256, 384, 512 }) |len| if (r.n.len == len) {
                    var s: [len]u8 = @splat(0);
                    @memcpy(s[len - sig.len ..], sig);
                    const res = if (std.mem.eql(u8, alg, "rsa-sha2-512"))
                        rsa.PKCS1v1_5Signature.verify(len, s, msg, key, crypto.hash.sha2.Sha512)
                    else
                        rsa.PKCS1v1_5Signature.verify(len, s, msg, key, crypto.hash.sha2.Sha256);
                    res catch return error.BadSignature;
                    return;
                };
                return error.UnsupportedSignature;
            },
        }
    }
};

/// `SHA256:<base64>` as `ssh-keygen -l` prints it.
pub fn fingerprint(buf: *[50]u8, blob: []const u8) []const u8 {
    var h: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(blob, &h, .{});
    @memcpy(buf[0..7], "SHA256:");
    return buf[0 .. 7 + std.base64.standard_no_pad.Encoder.encode(buf[7..], &h).len];
}

/// One `type base64 [comment]` key as written in known_hosts,
/// authorized_keys, allowed_signers and `.pub` files.
pub const Text = struct {
    type: []const u8,
    blob: []u8,
    comment: []const u8,

    /// Decodes the key at the start of `s`; `blob` is allocated.
    pub fn parse(gpa: std.mem.Allocator, s: []const u8) !Text {
        var it = std.mem.tokenizeAny(u8, s, " \t");
        const t = it.next() orelse return error.BadKey;
        const b64 = it.next() orelse return error.BadKey;
        const dec = std.base64.standard.Decoder;
        const blob = try gpa.alloc(u8, dec.calcSizeForSlice(b64) catch return error.BadKey);
        errdefer gpa.free(blob);
        dec.decode(blob, b64) catch return error.BadKey;
        var p: wire.Parser = .init(blob);
        if (!std.mem.eql(u8, try p.string(), t)) return error.BadKey;
        return .{ .type = t, .blob = blob, .comment = std.mem.trim(u8, it.rest(), " \t\r") };
    }
};

/// Writes `type base64` for a key blob.
pub fn writeText(w: *std.Io.Writer, blob: []const u8) !void {
    var p: wire.Parser = .init(blob);
    try w.print("{s} ", .{try p.string()});
    try std.base64.standard.Encoder.encodeWriter(w, blob);
}

test "ed25519 key verifies its signature" {
    const kp = Ed25519.KeyPair.generate(std.testing.io);
    var b: wire.Builder = .init(std.testing.allocator);
    defer b.deinit();
    try b.string("ssh-ed25519");
    try b.string(&kp.public_key.toBytes());
    const pk = try PublicKey.parse(b.bytes());
    var s: wire.Builder = .init(std.testing.allocator);
    defer s.deinit();
    try s.string("ssh-ed25519");
    try s.string(&(try kp.sign("hi", null)).toBytes());
    try pk.verify(s.bytes(), "hi");
    try std.testing.expectError(error.BadSignature, pk.verify(s.bytes(), "ho"));
    var fp: [50]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, fingerprint(&fp, b.bytes()), "SHA256:"));
    try std.testing.expectEqual(@as(usize, 50), fingerprint(&fp, b.bytes()).len);
}
