//! SSH signatures (OpenSSH PROTOCOL.sshsig), as `ssh-keygen -Y sign`
//! makes them and git uses for `gpg.format = ssh`: creation, armor,
//! parsing and cryptographic verification.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wire = @import("../ssh/wire.zig");
const pubkey = @import("../ssh/pubkey.zig");

pub const begin = "-----BEGIN SSH SIGNATURE-----";
pub const end = "-----END SSH SIGNATURE-----";
const magic = "SSHSIG";

pub const HashAlg = enum {
    sha256,
    sha512,

    pub fn name(h: HashAlg) []const u8 {
        return @tagName(h);
    }
};

/// Something that can sign with an SSH key: a key file or an agent key.
pub const Signer = struct {
    /// The public key blob.
    blob: []const u8,
    ctx: ?*anyopaque = null,
    /// Signs `data` with algorithm `alg`; returns the signature blob.
    sign: *const fn (ctx: ?*anyopaque, gpa: Allocator, alg: []const u8, data: []const u8) anyerror![]u8,
};

fn digest(h: HashAlg, msg: []const u8, out: *[64]u8) []const u8 {
    switch (h) {
        .sha256 => {
            std.crypto.hash.sha2.Sha256.hash(msg, out[0..32], .{});
            return out[0..32];
        },
        .sha512 => {
            std.crypto.hash.sha2.Sha512.hash(msg, out, .{});
            return out;
        },
    }
}

fn signedData(gpa: Allocator, namespace: []const u8, h: HashAlg, msg: []const u8) ![]u8 {
    var b: wire.Builder = .init(gpa);
    errdefer b.deinit();
    var d: [64]u8 = undefined;
    try b.raw(magic);
    try b.string(namespace);
    try b.string("");
    try b.string(h.name());
    try b.string(digest(h, msg, &d));
    return b.toOwned();
}

/// The signature algorithm a key signs SSHSIG with (RSA uses SHA-512).
fn algorithmFor(blob: []const u8) ![]const u8 {
    const pk = try pubkey.PublicKey.parse(blob);
    return switch (pk) {
        .rsa => "rsa-sha2-512",
        else => pk.typeName(),
    };
}

/// Signs `msg` in `namespace`, returning the armored signature with a
/// trailing newline, wrapped at 70 columns like ssh-keygen.
pub fn sign(gpa: Allocator, signer: Signer, namespace: []const u8, msg: []const u8, h: HashAlg) ![]u8 {
    if (namespace.len == 0) return error.EmptyNamespace;
    const data = try signedData(gpa, namespace, h, msg);
    defer gpa.free(data);
    const sig = try signer.sign(signer.ctx, gpa, try algorithmFor(signer.blob), data);
    defer gpa.free(sig);
    var b: wire.Builder = .init(gpa);
    defer b.deinit();
    try b.raw(magic);
    try b.int(1);
    try b.string(signer.blob);
    try b.string(namespace);
    try b.string("");
    try b.string(h.name());
    try b.string(sig);
    return armor(gpa, b.bytes());
}

fn armor(gpa: Allocator, blob: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(blob.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, blob);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, begin ++ "\n");
    var i: usize = 0;
    while (i < b64.len) : (i += 70) {
        try out.appendSlice(gpa, b64[i..@min(b64.len, i + 70)]);
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, end ++ "\n");
    return out.toOwnedSlice(gpa);
}

/// A parsed signature; slices borrow from `raw`.
pub const Signature = struct {
    raw: []u8,
    pubkey_blob: []const u8,
    namespace: []const u8,
    hash_alg: HashAlg,
    sig_blob: []const u8,

    pub fn deinit(s: *Signature, gpa: Allocator) void {
        gpa.free(s.raw);
    }

    /// Checks the signature over `msg` in `namespace` (crypto only; who
    /// may sign is the allowed signers' question).
    pub fn verify(s: *const Signature, msg: []const u8, namespace: []const u8) !void {
        if (!std.mem.eql(u8, s.namespace, namespace)) return error.WrongNamespace;
        const pk = try pubkey.PublicKey.parse(s.pubkey_blob);
        var sp: wire.Parser = .init(s.sig_blob);
        const alg = try sp.string();
        // ssh-rsa (SHA-1) signatures are refused, as ssh-keygen does.
        if (pk == .rsa and !std.mem.eql(u8, alg, "rsa-sha2-512") and !std.mem.eql(u8, alg, "rsa-sha2-256")) return error.UnsupportedSignature;
        var buf: [4096]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const data = try signedData(fba.allocator(), s.namespace, s.hash_alg, msg);
        try pk.verify(s.sig_blob, data);
    }
};

/// Parses an armored signature.
pub fn parse(gpa: Allocator, armored: []const u8) !Signature {
    const s = std.mem.indexOf(u8, armored, begin) orelse return error.NotSshSignature;
    const e = std.mem.indexOfPos(u8, armored, s, end) orelse return error.BadSignature;
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(gpa);
    for (armored[s + begin.len .. e]) |c| if (!std.ascii.isWhitespace(c)) try b64.append(gpa, c);
    const dec = std.base64.standard.Decoder;
    const raw = try gpa.alloc(u8, dec.calcSizeForSlice(b64.items) catch return error.BadSignature);
    errdefer gpa.free(raw);
    dec.decode(raw, b64.items) catch return error.BadSignature;
    if (!std.mem.startsWith(u8, raw, magic)) return error.BadSignature;
    var p: wire.Parser = .init(raw[magic.len..]);
    if (try p.int() != 1) return error.UnsupportedSignatureVersion;
    const blob = try p.string();
    const ns = try p.string();
    _ = try p.string();
    const h = try p.string();
    const sig = try p.string();
    const hash_alg: HashAlg = if (std.mem.eql(u8, h, "sha512")) .sha512 else if (std.mem.eql(u8, h, "sha256")) .sha256 else return error.UnsupportedHash;
    return .{ .raw = raw, .pubkey_blob = blob, .namespace = ns, .hash_alg = hash_alg, .sig_blob = sig };
}

test "sign, parse and verify" {
    const gpa = std.testing.allocator;
    const keys = @import("../ssh/keys.zig");
    var key: keys.PrivateKey = .{ .ed25519 = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io) };
    defer key.deinit(gpa);
    const blob = try key.publicBlob(gpa);
    defer gpa.free(blob);
    const S = struct {
        fn f(ctx: ?*anyopaque, a: Allocator, alg: []const u8, data: []const u8) anyerror![]u8 {
            const k: *keys.PrivateKey = @ptrCast(@alignCast(ctx.?));
            return k.sign(a, alg, data);
        }
    };
    const armored = try sign(gpa, .{ .blob = blob, .ctx = &key, .sign = S.f }, "git", "payload\n", .sha512);
    defer gpa.free(armored);
    try std.testing.expect(std.mem.startsWith(u8, armored, begin ++ "\n"));
    var sig = try parse(gpa, armored);
    defer sig.deinit(gpa);
    try sig.verify("payload\n", "git");
    try std.testing.expectError(error.BadSignature, sig.verify("payload!\n", "git"));
    try std.testing.expectError(error.WrongNamespace, sig.verify("payload\n", "file"));
    try std.testing.expectError(error.EmptyNamespace, sign(gpa, .{ .blob = blob, .ctx = &key, .sign = S.f }, "", "x", .sha512));
}
