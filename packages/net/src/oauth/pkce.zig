//! PKCE (RFC 7636) with the S256 method, and the `state` value. Both come
//! from `io.randomSecure`, which always asks the OS for fresh entropy.

const std = @import("std");
const Io = std.Io;
const b64 = std.base64.url_safe_no_pad;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Base64url (no padding) length of 32 octets.
pub const encoded_len = 43;

pub const Pkce = struct {
    verifier: [encoded_len]u8,
    challenge: [encoded_len]u8,

    /// A fresh verifier from 32 random octets and its S256 challenge.
    pub fn generate(io: Io) !Pkce {
        var raw: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &raw);
        try io.randomSecure(&raw);
        var v: [encoded_len]u8 = undefined;
        _ = b64.Encoder.encode(&v, &raw);
        return fromVerifier(v);
    }

    /// The pair for a known verifier (tests and RFC vectors).
    pub fn fromVerifier(verifier: [encoded_len]u8) Pkce {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&verifier, &digest, .{});
        var p: Pkce = .{ .verifier = verifier, .challenge = undefined };
        _ = b64.Encoder.encode(&p.challenge, &digest);
        return p;
    }

    /// Zeroes the verifier once the code has been redeemed.
    pub fn wipe(self: *Pkce) void {
        std.crypto.secureZero(u8, &self.verifier);
    }
};

/// A high-entropy `state`: 32 random octets, base64url.
pub fn randomState(io: Io, out: *[encoded_len]u8) ![]const u8 {
    var raw: [32]u8 = undefined;
    try io.randomSecure(&raw);
    return b64.Encoder.encode(out, &raw);
}

test "pkce: RFC 7636 appendix B vector" {
    const p = Pkce.fromVerifier("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".*);
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &p.challenge);
}

test "pkce: generated values are url-safe and distinct" {
    const io = std.testing.io;
    var a = try Pkce.generate(io);
    const b = try Pkce.generate(io);
    try std.testing.expect(!std.mem.eql(u8, &a.verifier, &b.verifier));
    for (a.verifier ++ a.challenge) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
    try std.testing.expectEqualSlices(u8, &Pkce.fromVerifier(a.verifier).challenge, &a.challenge);
    a.wipe();
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** encoded_len), &a.verifier);
    var s1: [encoded_len]u8 = undefined;
    var s2: [encoded_len]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, try randomState(io, &s1), try randomState(io, &s2)));
}
