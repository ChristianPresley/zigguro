//! Minisign signature verification with std crypto only
//! (https://jedisct1.github.io/minisign/).
//!
//! A public key is `base64("Ed" || key_id[8] || ed25519_pk[32])`. A
//! `.minisig` file has four lines:
//!
//!   untrusted comment: <text>
//!   base64(sig_alg[2] || key_id[8] || sig[64])
//!   trusted comment: <text>
//!   base64(global_sig[64])
//!
//! `ED` signs BLAKE2b-512 of the file; legacy `Ed` signs the raw file and is
//! refused unless asked for. The global signature covers `sig ||
//! trusted_comment`, the text after the `trusted comment: ` prefix. On top of
//! the reference tool, `verify` requires the trusted comment's `file:` value
//! to equal the expected name (the Zig mirror rules' downgrade check).

const std = @import("std");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const b64 = std.base64.standard.Decoder;

/// The Zig Software Foundation release key (ziglang.org/download).
pub const zsf_public_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

pub const PublicKey = struct {
    key_id: [8]u8,
    key: Ed25519.PublicKey,

    /// Parses the base64 key line, or a whole `.pub` file (the line after
    /// `untrusted comment:`).
    pub fn parseBase64(text: []const u8) error{Malformed}!PublicKey {
        var line = std.mem.trim(u8, text, " \t\r\n");
        if (std.mem.startsWith(u8, line, "untrusted comment:")) {
            const nl = std.mem.indexOfScalar(u8, line, '\n') orelse return error.Malformed;
            line = std.mem.trim(u8, line[nl + 1 ..], " \t\r\n");
            if (std.mem.indexOfScalar(u8, line, '\n')) |e| line = std.mem.trimEnd(u8, line[0..e], "\r");
        }
        var raw: [42]u8 = undefined;
        try decodeExact(&raw, line);
        if (!std.mem.eql(u8, raw[0..2], "Ed")) return error.Malformed;
        return .{
            .key_id = raw[2..10].*,
            .key = Ed25519.PublicKey.fromBytes(raw[10..42].*) catch return error.Malformed,
        };
    }
};

pub const Algorithm = enum { legacy_Ed, prehashed_ED };

pub const Signature = struct {
    algorithm: Algorithm,
    key_id: [8]u8,
    sig: [64]u8,
    /// A slice of the parsed text, without prefix or line ending.
    trusted_comment: []const u8,
    global_sig: [64]u8,

    pub fn parse(text: []const u8) error{Malformed}!Signature {
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
            .prehashed_ED
        else if (std.mem.eql(u8, raw[0..2], "Ed"))
            .legacy_Ed
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

pub const VerifyError = error{ KeyIdMismatch, BadSignature, BadGlobalSignature, LegacyNotAllowed, FileNameMismatch, Malformed, ReadFailed };

pub const Options = struct {
    /// Accept legacy `Ed` signatures over the raw file.
    allow_legacy: bool = false,
};

/// Streams `file_reader` through BLAKE2b-512 (or the raw Ed25519 verifier
/// for allowed legacy signatures), then checks the signature, the global
/// signature and the trusted comment's `file:<expected_name>`.
pub fn verify(pk: PublicKey, sig: Signature, file_reader: *Io.Reader, expected_name: []const u8) VerifyError!void {
    return verifyOptions(pk, sig, file_reader, expected_name, .{});
}

pub fn verifyOptions(pk: PublicKey, sig: Signature, file_reader: *Io.Reader, expected_name: []const u8, opts: Options) VerifyError!void {
    if (sig.algorithm == .legacy_Ed and !opts.allow_legacy) return error.LegacyNotAllowed;
    if (!std.mem.eql(u8, &sig.key_id, &pk.key_id)) return error.KeyIdMismatch;
    const ed_sig = Ed25519.Signature.fromBytes(sig.sig);
    switch (sig.algorithm) {
        .prehashed_ED => {
            var h = Blake2b512.init(.{});
            try streamInto(file_reader, &h);
            var digest: [Blake2b512.digest_length]u8 = undefined;
            h.final(&digest);
            ed_sig.verify(&digest, pk.key) catch return error.BadSignature;
        },
        .legacy_Ed => {
            var v = ed_sig.verifier(pk.key) catch return error.BadSignature;
            try streamInto(file_reader, &v);
            v.verify() catch return error.BadSignature;
        },
    }
    var v = Ed25519.Signature.fromBytes(sig.global_sig).verifier(pk.key) catch return error.BadGlobalSignature;
    v.update(&sig.sig);
    v.update(sig.trusted_comment);
    v.verify() catch return error.BadGlobalSignature;
    if (!fileNameMatches(sig.trusted_comment, expected_name)) return error.FileNameMismatch;
}

/// True when the tab- or space-separated `key:value` list has
/// `file:<name>` exactly.
pub fn fileNameMatches(trusted_comment: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, trusted_comment, " \t");
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "file:") and std.mem.eql(u8, kv["file:".len..], name)) return true;
    }
    return false;
}

fn streamInto(r: *Io.Reader, sink: anytype) error{ReadFailed}!void {
    while (true) {
        const chunk = r.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.ReadFailed,
        };
        sink.update(chunk);
        r.toss(chunk.len);
    }
}

fn decodeExact(out: []u8, text: []const u8) error{Malformed}!void {
    const n = b64.calcSizeForSlice(text) catch return error.Malformed;
    if (n != out.len) return error.Malformed;
    b64.decode(out, text) catch return error.Malformed;
}

fn trimCr(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const td = struct {
    const pubkey = @embedFile("testdata/test.pub");
    const file = @embedFile("testdata/sample.txt");
    const sig = @embedFile("testdata/sample.txt.minisig");
    const legacy = @embedFile("testdata/sample.txt.legacy.minisig");
};

fn check(sig_text: []const u8, file: []const u8, name: []const u8, opts: Options) VerifyError!void {
    const pk = try PublicKey.parseBase64(td.pubkey);
    const sig = try Signature.parse(sig_text);
    var r: Io.Reader = .fixed(file);
    return verifyOptions(pk, sig, &r, name, opts);
}

test "minisign: verifies ED signature (testdata)" {
    try check(td.sig, td.file, "sample.txt", .{});
    const sig = try Signature.parse(td.sig);
    try testing.expectEqual(Algorithm.prehashed_ED, sig.algorithm);
    try testing.expectEqualStrings("timestamp:1760000000\tfile:sample.txt\thashed", sig.trusted_comment);
}

test "minisign: rejects tampered file" {
    var copy = td.file.*;
    copy[3] ^= 1;
    try testing.expectError(error.BadSignature, check(td.sig, &copy, "sample.txt", .{}));
    try testing.expectError(error.BadSignature, check(td.sig, td.file[0 .. td.file.len - 1], "sample.txt", .{}));
}

test "minisign: rejects tampered trusted comment" {
    var buf: [512]u8 = undefined;
    const t = buf[0..td.sig.len];
    @memcpy(t, td.sig);
    const at = std.mem.indexOf(u8, t, "file:sample.txt").?;
    @memcpy(t[at .. at + "file:sample.txt".len], "file:sample.tx_");
    try testing.expectError(error.BadGlobalSignature, check(t, td.file, "sample.tx_", .{}));
}

test "minisign: rejects key id mismatch" {
    var pk = try PublicKey.parseBase64(td.pubkey);
    pk.key_id[0] ^= 0xff;
    var r: Io.Reader = .fixed(td.file);
    try testing.expectError(error.KeyIdMismatch, verify(pk, try Signature.parse(td.sig), &r, "sample.txt"));
}

test "minisign: rejects legacy Ed by default" {
    try testing.expectError(error.LegacyNotAllowed, check(td.legacy, td.file, "sample.txt", .{}));
    try check(td.legacy, td.file, "sample.txt", .{ .allow_legacy = true });
    var copy = td.file.*;
    copy[0] ^= 1;
    try testing.expectError(error.BadSignature, check(td.legacy, &copy, "sample.txt", .{ .allow_legacy = true }));
}

test "minisign: rejects file: mismatch" {
    try testing.expectError(error.FileNameMismatch, check(td.sig, td.file, "other.txt", .{}));
    try testing.expectError(error.FileNameMismatch, check(td.sig, td.file, "sample", .{}));
    try testing.expect(fileNameMatches("timestamp:1 file:zig-x86_64-linux-0.16.0.tar.xz", "zig-x86_64-linux-0.16.0.tar.xz"));
    try testing.expect(!fileNameMatches("file:zig-x86_64-linux-0.15.2.tar.xz", "zig-x86_64-linux-0.16.0.tar.xz"));
}

test "pubkey: parses ZSF key RWSGOq2..." {
    const pk = try PublicKey.parseBase64(zsf_public_key);
    try testing.expectEqualSlices(u8, &.{ 0x86, 0x3a, 0xad, 0x8d, 0x55, 0xe7, 0x00, 0xd9 }, &pk.key_id);
    const file_form = try PublicKey.parseBase64("untrusted comment: minisign public key\r\n" ++ zsf_public_key ++ "\r\n");
    try testing.expectEqualSlices(u8, &pk.key_id, &file_form.key_id);
    try testing.expectError(error.Malformed, PublicKey.parseBase64("RWSGOq2NVecA2UPN"));
    try testing.expectError(error.Malformed, PublicKey.parseBase64(""));
}

test "minisign: malformed signatures" {
    try testing.expectError(error.Malformed, Signature.parse(""));
    try testing.expectError(error.Malformed, Signature.parse("untrusted comment: x\nAAAA\ntrusted comment: y\nAAAA\n"));
    try testing.expectError(error.Malformed, Signature.parse("comment: x\n\n\n\n"));
}

test "fuzz: Signature.parse never panics" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [400]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const sig = Signature.parse(input) catch return;
            try testing.expect(sig.trusted_comment.len <= input.len);
        }
    }.one, .{});
}
