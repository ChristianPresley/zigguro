//! Unforgeable capability tokens (E16.F02.S03.T01). The harness mints a
//! token when a human approves something (or to identify an actor to the
//! `zg` CLI); the token binds the approval to the exact input hash the human
//! saw (INV-14) and expires. The key is per process and never leaves it:
//! child processes ask the parent to verify.
//!
//! Token = base64url(HmacSha256(key, kind | subject | input_hash | expires)
//! || expires_le64), 54 characters.

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;

/// Length of an encoded token.
pub const token_len = b64.Encoder.calcSize(HmacSha256.mac_length + 8);

comptime {
    std.debug.assert(token_len == 54);
}

/// The per-process signing key.
pub const TokenKey = struct {
    key: [32]u8,

    /// A fresh key from the OS CSPRNG.
    pub fn generate(io: std.Io) std.Io.RandomSecureError!TokenKey {
        var k: TokenKey = undefined;
        try io.randomSecure(&k.key);
        return k;
    }

    /// Zeroes the key.
    pub fn wipe(k: *TokenKey) void {
        std.crypto.secureZero(u8, &k.key);
    }
};

/// What a token grants.
pub const Capability = struct {
    kind: Kind,
    /// Session or agent id.
    subject: []const u8,
    /// Blake3 of the exact tool input bytes (or command text) approved.
    input_hash: [32]u8,
    expires_ms: i64,

    /// Token purposes.
    pub const Kind = enum(u8) { approval, actor, signing };
};

/// Default lifetimes.
pub const ttl_approval_ms: i64 = 10 * std.time.ms_per_min;
/// Signing tokens are short-lived.
pub const ttl_signing_ms: i64 = 60 * std.time.ms_per_s;

fn mac(k: *const TokenKey, cap: Capability, out: *[HmacSha256.mac_length]u8) void {
    var h = HmacSha256.init(&k.key);
    h.update(&.{@intFromEnum(cap.kind)});
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, cap.subject.len, .little);
    h.update(&len);
    h.update(cap.subject);
    h.update(&cap.input_hash);
    var exp: [8]u8 = undefined;
    std.mem.writeInt(i64, &exp, cap.expires_ms, .little);
    h.update(&exp);
    h.final(out);
}

/// Writes the token for `cap`.
pub fn mint(k: *const TokenKey, cap: Capability, out: *[token_len]u8) void {
    var raw: [HmacSha256.mac_length + 8]u8 = undefined;
    mac(k, cap, raw[0..HmacSha256.mac_length]);
    std.mem.writeInt(i64, raw[HmacSha256.mac_length..], cap.expires_ms, .little);
    _ = b64.Encoder.encode(out, &raw);
}

/// Checks `token` against what the verifier expects (`cap_expected`'s
/// `expires_ms` is ignored; the token's own expiry is authenticated).
/// Compares in constant time.
pub fn verify(k: *const TokenKey, cap_expected: Capability, token: []const u8, now_ms: i64) error{ BadToken, Expired }!void {
    if (token.len != token_len) return error.BadToken;
    var raw: [HmacSha256.mac_length + 8]u8 = undefined;
    b64.Decoder.decode(&raw, token) catch return error.BadToken;
    var cap = cap_expected;
    cap.expires_ms = std.mem.readInt(i64, raw[HmacSha256.mac_length..], .little);
    var want: [HmacSha256.mac_length]u8 = undefined;
    mac(k, cap, &want);
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, want, raw[0..HmacSha256.mac_length].*)) return error.BadToken;
    if (now_ms >= cap.expires_ms) return error.Expired;
}

/// Blake3 of `input`, the hash approvals and tokens bind to.
pub fn inputHash(input: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(input, &out, .{});
    return out;
}

test "INV-14 token: altered input hash rejected" {
    const k = try TokenKey.generate(std.testing.io);
    const cap: Capability = .{ .kind = .approval, .subject = "s1", .input_hash = inputHash("rm -rf build"), .expires_ms = 1000 };
    var tok: [token_len]u8 = undefined;
    mint(&k, cap, &tok);
    try verify(&k, cap, &tok, 10);
    var other = cap;
    other.input_hash = inputHash("rm -rf /");
    try std.testing.expectError(error.BadToken, verify(&k, other, &tok, 10));
    other = cap;
    other.subject = "s2";
    try std.testing.expectError(error.BadToken, verify(&k, other, &tok, 10));
    other = cap;
    other.kind = .signing;
    try std.testing.expectError(error.BadToken, verify(&k, other, &tok, 10));
}

test "token: expired rejected" {
    const k = try TokenKey.generate(std.testing.io);
    const cap: Capability = .{ .kind = .actor, .subject = "agent", .input_hash = @splat(0), .expires_ms = 1000 };
    var tok: [token_len]u8 = undefined;
    mint(&k, cap, &tok);
    try std.testing.expectError(error.Expired, verify(&k, cap, &tok, 1000));
    // Tampering with the embedded expiry breaks the MAC.
    var forged = tok;
    forged[token_len - 2] = if (forged[token_len - 2] == 'A') 'B' else 'A';
    try std.testing.expectError(error.BadToken, verify(&k, cap, &forged, 10));
}

test "token: different key rejected" {
    const k1 = try TokenKey.generate(std.testing.io);
    const k2 = try TokenKey.generate(std.testing.io);
    const cap: Capability = .{ .kind = .approval, .subject = "s", .input_hash = @splat(7), .expires_ms = 50 };
    var tok: [token_len]u8 = undefined;
    mint(&k1, cap, &tok);
    try std.testing.expectError(error.BadToken, verify(&k2, cap, &tok, 1));
    try std.testing.expectError(error.BadToken, verify(&k1, cap, "short", 1));
}

test "token: constant-time compare used" {
    // Review checklist: verify must go through std.crypto.timing_safe.eql.
    const src = @embedFile("token.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "timing_safe" ++ ".eql") != null);
}
