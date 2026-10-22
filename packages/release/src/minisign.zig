//! Minisign-compatible Ed25519 signing and verification
//! (https://jedisct1.github.io/minisign/). Pure functions over byte slices,
//! so `tools/zig-verify` and the extension signer can share them.
//!
//! - Public key: `base64("Ed" || key_id[8] || ed25519_pk[32])`, 56 chars
//!   starting with "RW".
//! - `.minisig`: four lines,
//!   `untrusted comment: <text>`, `base64(alg[2] || key_id[8] || sig[64])`,
//!   `trusted comment: <text>`, `base64(global_sig[64])`.
//! - `ED` signs BLAKE2b-512 of the message (the only algorithm we sign and
//!   accept); legacy `Ed` signs the raw message and parses so the Zig
//!   toolchain verifier can report it, but `verify` refuses it.
//! - The global signature covers `sig || trusted_comment`, the text after
//!   `trusted comment: ` without the line ending.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const b64 = std.base64.standard;

/// Minisign key id: 8 random bytes, little-endian when printed as hex.
pub const KeyId = [8]u8;

/// Ed25519 seed of a signing key (our seed files, not minisign's encrypted
/// secret key format).
pub const SecretSeed = [32]u8;

/// Errors of the parsers.
pub const ParseError = error{Malformed};

/// A minisign public key.
pub const PublicKey = struct {
    key_id: KeyId,
    key: Ed25519.PublicKey,

    /// Length of the base64 key line.
    pub const encoded_len = 56;

    /// Parses an `RW...` base64 line, or a two-line `.pub` file whose first
    /// line is `untrusted comment: ...`.
    pub fn parse(text: []const u8) ParseError!PublicKey {
        var line = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.startsWith(u8, line, "untrusted comment:")) {
            const nl = std.mem.indexOfScalar(u8, line, '\n') orelse return error.Malformed;
            line = std.mem.trim(u8, line[nl + 1 ..], " \t\r\n");
        }
        if (std.mem.indexOfAny(u8, line, "\r\n") != null) return error.Malformed;
        var raw: [42]u8 = undefined;
        try decodeExact(&raw, line);
        if (!std.mem.eql(u8, raw[0..2], "Ed")) return error.Malformed;
        return .{
            .key_id = raw[2..10].*,
            .key = Ed25519.PublicKey.fromBytes(raw[10..42].*) catch return error.Malformed,
        };
    }

    /// Writes the `RW...` base64 line into `buf`.
    pub fn format(pk: PublicKey, buf: *[encoded_len]u8) []const u8 {
        var raw: [42]u8 = undefined;
        raw[0..2].* = "Ed".*;
        raw[2..10].* = pk.key_id;
        raw[10..42].* = pk.key.toBytes();
        return b64.Encoder.encode(buf, &raw);
    }

    /// Writes a `.pub` file: `untrusted comment: minisign public key <ID>`
    /// and the key line.
    pub fn writeFile(pk: PublicKey, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [encoded_len]u8 = undefined;
        try w.print("untrusted comment: minisign public key {X}\n{s}\n", .{ keyIdNumber(pk.key_id), pk.format(&buf) });
    }
};

/// The key id as minisign prints it (a little-endian u64 in upper-case hex).
pub fn keyIdNumber(id: KeyId) u64 {
    return std.mem.readInt(u64, &id, .little);
}

/// Signature algorithm of a `.minisig`.
pub const Algorithm = enum {
    /// "Ed": Ed25519 over the raw message.
    legacy_ed,
    /// "ED": Ed25519 over BLAKE2b-512(message).
    prehashed_ed,
};

/// A parsed `.minisig` file.
pub const Signature = struct {
    algorithm: Algorithm,
    key_id: KeyId,
    sig: [64]u8,
    /// Slice of the parsed text after `trusted comment: `, without line ending.
    trusted_comment: []const u8,
    global_sig: [64]u8,

    /// Parses the four-line `.minisig` format. Trailing blank lines are
    /// allowed; anything else after line four is rejected. Slices into `text`.
    pub fn parse(text: []const u8) ParseError!Signature {
        var lines = std.mem.splitScalar(u8, text, '\n');
        const l1 = trimCr(lines.next() orelse return error.Malformed);
        const l2 = trimCr(lines.next() orelse return error.Malformed);
        const l3 = trimCr(lines.next() orelse return error.Malformed);
        const l4 = trimCr(lines.next() orelse return error.Malformed);
        while (lines.next()) |rest| if (trimCr(rest).len != 0) return error.Malformed;
        if (!std.mem.startsWith(u8, l1, "untrusted comment:")) return error.Malformed;
        const tc_prefix = "trusted comment: ";
        if (!std.mem.startsWith(u8, l3, tc_prefix)) return error.Malformed;

        var raw: [74]u8 = undefined;
        try decodeExact(&raw, l2);
        const algorithm: Algorithm = if (std.mem.eql(u8, raw[0..2], "ED"))
            .prehashed_ed
        else if (std.mem.eql(u8, raw[0..2], "Ed"))
            .legacy_ed
        else
            return error.Malformed;
        var s: Signature = .{
            .algorithm = algorithm,
            .key_id = raw[2..10].*,
            .sig = raw[10..74].*,
            .trusted_comment = l3[tc_prefix.len..],
            .global_sig = undefined,
        };
        try decodeExact(&s.global_sig, l4);
        return s;
    }
};

/// Errors of `verify` and `verifyStreaming`.
pub const VerifyError = error{ Malformed, UnknownKey, BadSignature, BadGlobalSignature, LegacyNotAllowed };

/// Verifies `sig` over `message` with the key in `keys` whose id matches.
/// Returns that key. Only `ED` (prehashed) signatures are accepted.
pub fn verify(sig: *const Signature, keys: []const PublicKey, message: []const u8) VerifyError!*const PublicKey {
    var h: Blake2b512 = .init(.{});
    h.update(message);
    return verifyStreaming(sig, keys, &h);
}

/// Like `verify`, but over a BLAKE2b-512 state the caller fed while
/// streaming the message. `h` is not consumed (a copy is finalized).
pub fn verifyStreaming(sig: *const Signature, keys: []const PublicKey, h: *const Blake2b512) VerifyError!*const PublicKey {
    if (sig.algorithm != .prehashed_ed) return error.LegacyNotAllowed;
    const pk = findKey(keys, sig.key_id) orelse return error.UnknownKey;
    var copy = h.*;
    var digest: [Blake2b512.digest_length]u8 = undefined;
    copy.final(&digest);
    const s = Ed25519.Signature.fromBytes(sig.sig);
    s.verify(&digest, pk.key) catch return error.BadSignature;
    try verifyGlobal(sig, pk);
    return pk;
}

/// Verifies a legacy `Ed` signature over the raw message. Only for callers
/// that must interoperate with old signatures; our feeds never use it.
pub fn verifyLegacy(sig: *const Signature, keys: []const PublicKey, message: []const u8) VerifyError!*const PublicKey {
    if (sig.algorithm != .legacy_ed) return error.Malformed;
    const pk = findKey(keys, sig.key_id) orelse return error.UnknownKey;
    const s = Ed25519.Signature.fromBytes(sig.sig);
    s.verify(message, pk.key) catch return error.BadSignature;
    try verifyGlobal(sig, pk);
    return pk;
}

fn verifyGlobal(sig: *const Signature, pk: *const PublicKey) VerifyError!void {
    const g = Ed25519.Signature.fromBytes(sig.global_sig);
    var v = g.verifier(pk.key) catch return error.BadGlobalSignature;
    v.update(&sig.sig);
    v.update(sig.trusted_comment);
    v.verify() catch return error.BadGlobalSignature;
}

fn findKey(keys: []const PublicKey, id: KeyId) ?*const PublicKey {
    for (keys) |*k| if (std.mem.eql(u8, &k.key_id, &id)) return k;
    return null;
}

/// A signing key pair and its public key.
pub const KeyPair = struct {
    pk: PublicKey,
    kp: Ed25519.KeyPair,
};

/// Derives the key pair for `seed` and labels it with `key_id`.
pub fn keyPairFromSeed(seed: SecretSeed, key_id: KeyId) error{WeakKey}!KeyPair {
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.WeakKey;
    return .{ .pk = .{ .key_id = key_id, .key = kp.public_key }, .kp = kp };
}

/// Errors of `sign`.
pub const SignError = Allocator.Error || error{ SigningFailed, InvalidComment };

/// Signs `message` (prehashed `ED`) and returns the full `.minisig` text.
/// Signatures are deterministic (RFC 8032, no noise), so the same inputs
/// always give the same bytes. Comments must not contain line breaks.
pub fn sign(
    gpa: Allocator,
    kp: Ed25519.KeyPair,
    key_id: KeyId,
    message: []const u8,
    untrusted_comment: []const u8,
    trusted_comment: []const u8,
) SignError![]u8 {
    var h: Blake2b512 = .init(.{});
    h.update(message);
    return signStreaming(gpa, kp, key_id, &h, untrusted_comment, trusted_comment);
}

/// Like `sign`, over a BLAKE2b-512 state fed while streaming the message.
pub fn signStreaming(
    gpa: Allocator,
    kp: Ed25519.KeyPair,
    key_id: KeyId,
    h: *const Blake2b512,
    untrusted_comment: []const u8,
    trusted_comment: []const u8,
) SignError![]u8 {
    if (std.mem.indexOfAny(u8, untrusted_comment, "\r\n") != null) return error.InvalidComment;
    if (std.mem.indexOfAny(u8, trusted_comment, "\r\n") != null) return error.InvalidComment;
    var copy = h.*;
    var digest: [Blake2b512.digest_length]u8 = undefined;
    copy.final(&digest);
    const s = (kp.sign(&digest, null) catch return error.SigningFailed).toBytes();

    const global_msg = try std.mem.concat(gpa, u8, &.{ &s, trusted_comment });
    defer gpa.free(global_msg);
    const g = (kp.sign(global_msg, null) catch return error.SigningFailed).toBytes();

    var raw: [74]u8 = undefined;
    raw[0..2].* = "ED".*;
    raw[2..10].* = key_id;
    raw[10..74].* = s;
    var sig_b64: [b64.Encoder.calcSize(74)]u8 = undefined;
    var g_b64: [b64.Encoder.calcSize(64)]u8 = undefined;
    return std.fmt.allocPrint(gpa, "untrusted comment: {s}\n{s}\ntrusted comment: {s}\n{s}\n", .{
        untrusted_comment,
        b64.Encoder.encode(&sig_b64, &raw),
        trusted_comment,
        b64.Encoder.encode(&g_b64, &g),
    });
}

fn trimCr(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn decodeExact(out: []u8, text: []const u8) ParseError!void {
    const n = b64.Decoder.calcSizeForSlice(text) catch return error.Malformed;
    if (n != out.len) return error.Malformed;
    b64.Decoder.decode(out, text) catch return error.Malformed;
}

const testing = std.testing;

/// Fixture produced by the reference minisign 0.11 tool; see
/// src/fixtures/minisign/README.md.
const fixtures = struct {
    const pub_key = @embedFile("fixtures/minisign/test.pub");
    const message = @embedFile("fixtures/minisign/message.txt");
    const sig = @embedFile("fixtures/minisign/message.txt.minisig");
};

fn testKey(n: u8) !KeyPair {
    return keyPairFromSeed(@splat(n), .{ n, 1, 2, 3, 4, 5, 6, 7 });
}

test "minisign: parse pubkey" {
    const k = try testKey(1);
    var buf: [PublicKey.encoded_len]u8 = undefined;
    const line = k.pk.format(&buf);
    try testing.expect(std.mem.startsWith(u8, line, "RW"));
    const p = try PublicKey.parse(line);
    try testing.expectEqualSlices(u8, &k.pk.key_id, &p.key_id);
    try testing.expectEqualSlices(u8, &k.pk.key.toBytes(), &p.key.toBytes());

    var fbuf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&fbuf);
    try k.pk.writeFile(&w);
    const p2 = try PublicKey.parse(w.buffered());
    try testing.expectEqualSlices(u8, &k.pk.key_id, &p2.key_id);

    try testing.expectError(error.Malformed, PublicKey.parse(""));
    try testing.expectError(error.Malformed, PublicKey.parse(line[0..55]));
    try testing.expectError(error.Malformed, PublicKey.parse("untrusted comment: x"));
}

test "minisign: verify reference fixture" {
    const pk = try PublicKey.parse(fixtures.pub_key);
    const sig = try Signature.parse(fixtures.sig);
    try testing.expectEqual(Algorithm.prehashed_ed, sig.algorithm);
    _ = try verify(&sig, &.{pk}, fixtures.message);
    try testing.expectError(error.BadSignature, verify(&sig, &.{pk}, "tampered"));
}

test "minisign: sign→verify roundtrip" {
    const k = try testKey(2);
    const text = try sign(testing.allocator, k.kp, k.pk.key_id, "hello", "signature from zg-release", "timestamp:1\tfile:hello");
    defer testing.allocator.free(text);
    const sig = try Signature.parse(text);
    try testing.expectEqualStrings("timestamp:1\tfile:hello", sig.trusted_comment);
    const used = try verify(&sig, &.{ (try testKey(3)).pk, k.pk }, "hello");
    try testing.expectEqualSlices(u8, &k.pk.key_id, &used.key_id);

    // Deterministic.
    const again = try sign(testing.allocator, k.kp, k.pk.key_id, "hello", "signature from zg-release", "timestamp:1\tfile:hello");
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(text, again);

    // Streaming agrees.
    var h: Blake2b512 = .init(.{});
    h.update("hel");
    h.update("lo");
    _ = try verifyStreaming(&sig, &.{k.pk}, &h);

    try testing.expectError(error.InvalidComment, sign(testing.allocator, k.kp, k.pk.key_id, "x", "a\nb", ""));
}

test "minisign: tampered message / trusted comment / global sig rejected" {
    const k = try testKey(4);
    const text = try sign(testing.allocator, k.kp, k.pk.key_id, "payload", "u", "file:a");
    defer testing.allocator.free(text);
    var sig = try Signature.parse(text);
    try testing.expectError(error.BadSignature, verify(&sig, &.{k.pk}, "payloaD"));
    sig.trusted_comment = "file:b";
    try testing.expectError(error.BadGlobalSignature, verify(&sig, &.{k.pk}, "payload"));
    sig = try Signature.parse(text);
    sig.global_sig[0] ^= 1;
    try testing.expectError(error.BadGlobalSignature, verify(&sig, &.{k.pk}, "payload"));
    sig = try Signature.parse(text);
    sig.sig[5] ^= 1;
    try testing.expectError(error.BadSignature, verify(&sig, &.{k.pk}, "payload"));
}

test "minisign: unknown key id" {
    const k = try testKey(5);
    const text = try sign(testing.allocator, k.kp, k.pk.key_id, "m", "u", "t");
    defer testing.allocator.free(text);
    const sig = try Signature.parse(text);
    try testing.expectError(error.UnknownKey, verify(&sig, &.{(try testKey(6)).pk}, "m"));
    try testing.expectError(error.UnknownKey, verify(&sig, &.{}, "m"));
}

test "minisign: parse sig (ED and legacy Ed)" {
    const k = try testKey(7);
    const text = try sign(testing.allocator, k.kp, k.pk.key_id, "m", "u", "t");
    defer testing.allocator.free(text);
    // Rewrite the algorithm to legacy "Ed" and re-sign raw.
    const s = (try k.kp.sign("m", null)).toBytes();
    const g = (try k.kp.sign(&s ++ "t".*, null)).toBytes();
    var raw: [74]u8 = undefined;
    raw[0..2].* = "Ed".*;
    raw[2..10].* = k.pk.key_id;
    raw[10..74].* = s;
    var l2: [100]u8 = undefined;
    var l4: [88]u8 = undefined;
    const legacy = try std.fmt.allocPrint(testing.allocator, "untrusted comment: x\r\n{s}\r\ntrusted comment: t\r\n{s}\r\n\n", .{
        b64.Encoder.encode(&l2, &raw), b64.Encoder.encode(&l4, &g),
    });
    defer testing.allocator.free(legacy);
    const ls = try Signature.parse(legacy);
    try testing.expectEqual(Algorithm.legacy_ed, ls.algorithm);
    try testing.expectError(error.LegacyNotAllowed, verify(&ls, &.{k.pk}, "m"));
    _ = try verifyLegacy(&ls, &.{k.pk}, "m");

    try testing.expectError(error.Malformed, Signature.parse("untrusted comment: x\n"));
    try testing.expectError(error.Malformed, Signature.parse(""));
    const extra = try std.mem.concat(testing.allocator, u8, &.{ text, "junk\n" });
    defer testing.allocator.free(extra);
    try testing.expectError(error.Malformed, Signature.parse(extra));
}

test "fuzz: minisign Signature.parse" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var input: [512]u8 = undefined;
            const n = s.slice(&input);
            const sig = Signature.parse(input[0..n]) catch return;
            try testing.expect(sig.trusted_comment.len <= n);
            _ = verify(&sig, &.{}, "") catch {};
            _ = PublicKey.parse(input[0..n]) catch {};
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "minisign_sig") });
}
