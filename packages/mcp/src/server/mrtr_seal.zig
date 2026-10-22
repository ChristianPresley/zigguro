//! Sealed MRTR `requestState` (E11.F05.S01.T02, MRTR "Server
//! Requirements" 4-5): the server keeps no state between rounds, so the
//! state it hands the client is encrypted and authenticated with
//! XChaCha20-Poly1305. The token is `base64url(nonce24 || ct || tag16)`;
//! the associated data is the method name and the SHA-256 of the request's
//! canonical params (without `_meta`, `inputResponses` and
//! `requestState`), so a token only opens for the request that earned it.
//! The payload binds the principal, an expiry, the handler's private state
//! and the round counter.
//!
//! The key is random per process by default; servers behind a load
//! balancer share one through `Server.Options.seal_key`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("../protocol/root.zig");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

/// What a token carries.
pub const SealPayload = struct {
    principal_hash: [32]u8,
    expires_at_ms: i64,
    method: protocol.Method,
    params_digest: [32]u8,
    /// Handler-private state (`CallCtx.setState`).
    handler_state: []const u8 = "",
    round: u8,
};

/// Why a token was refused; all become `-32602` on the wire.
pub const OpenError = error{ Invalid, Expired, WrongPrincipal, WrongRequest, OutOfMemory };

const version: u8 = 1;
/// version, principal hash, expiry, method, params digest, round.
const header_len = 1 + 32 + 8 + 2 + 32 + 1;
/// The largest token `open` looks at.
pub const max_token_len = 64 * 1024;

pub const Sealer = struct {
    key: [Aead.key_length]u8,

    /// A sealer with a fresh random key.
    pub fn random(io: Io) Sealer {
        var s: Sealer = undefined;
        io.randomSecure(&s.key) catch io.random(&s.key);
        return s;
    }

    /// Seals `p` into a token (owned by `gpa`).
    pub fn seal(s: *const Sealer, io: Io, gpa: Allocator, p: SealPayload) Allocator.Error![]u8 {
        const plain = try gpa.alloc(u8, header_len + p.handler_state.len);
        defer gpa.free(plain);
        plain[0] = version;
        @memcpy(plain[1..33], &p.principal_hash);
        std.mem.writeInt(i64, plain[33..41], p.expires_at_ms, .little);
        std.mem.writeInt(u16, plain[41..43], @intFromEnum(p.method), .little);
        @memcpy(plain[43..75], &p.params_digest);
        plain[75] = p.round;
        @memcpy(plain[header_len..], p.handler_state);

        const raw = try gpa.alloc(u8, Aead.nonce_length + plain.len + Aead.tag_length);
        defer gpa.free(raw);
        const nonce = raw[0..Aead.nonce_length];
        io.randomSecure(nonce) catch io.random(nonce);
        var ad_buf: [ad_len]u8 = undefined;
        const ad = associatedData(&ad_buf, p.method, p.params_digest);
        const ct = raw[Aead.nonce_length..][0..plain.len];
        const tag = raw[Aead.nonce_length + plain.len ..][0..Aead.tag_length];
        Aead.encrypt(ct, tag, plain, ad, nonce.*, s.key);
        const out = try gpa.alloc(u8, b64.Encoder.calcSize(raw.len));
        _ = b64.Encoder.encode(out, raw);
        return out;
    }

    /// Opens `token` sealed for associated data `ad` (`associatedData`).
    /// The payload's state lives in `gpa`'s allocation.
    pub fn open(s: *const Sealer, gpa: Allocator, token: []const u8, ad: []const u8) OpenError!SealPayload {
        if (token.len > max_token_len) return error.Invalid;
        const n = b64.Decoder.calcSizeForSlice(token) catch return error.Invalid;
        if (n < Aead.nonce_length + header_len + Aead.tag_length) return error.Invalid;
        const raw = try gpa.alloc(u8, n);
        defer gpa.free(raw);
        b64.Decoder.decode(raw, token) catch return error.Invalid;
        const nonce = raw[0..Aead.nonce_length].*;
        const ct = raw[Aead.nonce_length .. n - Aead.tag_length];
        const tag = raw[n - Aead.tag_length ..][0..Aead.tag_length].*;
        const plain = try gpa.alloc(u8, ct.len);
        errdefer gpa.free(plain);
        Aead.decrypt(plain, ct, tag, ad, nonce, s.key) catch return error.Invalid;
        if (plain[0] != version) return error.Invalid;
        const m = std.enums.fromInt(protocol.Method, std.mem.readInt(u16, plain[41..43], .little)) orelse return error.Invalid;
        const state = try gpa.dupe(u8, plain[header_len..]);
        defer gpa.free(plain);
        return .{
            .principal_hash = plain[1..33].*,
            .expires_at_ms = std.mem.readInt(i64, plain[33..41], .little),
            .method = m,
            .params_digest = plain[43..75].*,
            .handler_state = state,
            .round = plain[75],
        };
    }
};

/// Checks an opened payload against the request that carried it.
pub fn check(p: SealPayload, now_ms: i64, principal_hash: [32]u8, method: protocol.Method, params_digest: [32]u8) OpenError!void {
    if (now_ms >= p.expires_at_ms) return error.Expired;
    if (!std.crypto.timing_safe.eql([32]u8, p.principal_hash, principal_hash)) return error.WrongPrincipal;
    if (p.method != method or !std.mem.eql(u8, &p.params_digest, &params_digest)) return error.WrongRequest;
}

const max_method_len = 32;
pub const ad_len = max_method_len + 32;

/// The associated data: the method name (zero padded) and the params digest.
pub fn associatedData(buf: *[ad_len]u8, m: protocol.Method, digest: [32]u8) []const u8 {
    @memset(buf, 0);
    const name = m.string();
    @memcpy(buf[0..@min(name.len, max_method_len)], name[0..@min(name.len, max_method_len)]);
    @memcpy(buf[max_method_len..], &digest);
    return buf;
}

/// The hash binding a token to who asked: principal id and auth context.
pub fn principalHash(principal: ?[]const u8, auth_context: []const u8) [32]u8 {
    var h: Sha256 = .init(.{});
    if (principal) |p| {
        h.update("p:");
        h.update(p);
    } else h.update("anonymous");
    h.update(&.{0});
    h.update(auth_context);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// SHA-256 of `params` in canonical form (sorted keys, no whitespace),
/// leaving out the members that change between rounds.
pub fn paramsDigest(gpa: Allocator, params: Value) Allocator.Error![32]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    canonical(gpa, &aw.writer, params, true) catch return error.OutOfMemory;
    var out: [32]u8 = undefined;
    Sha256.hash(aw.written(), &out, .{});
    return out;
}

const skipped = [_][]const u8{ "_meta", "inputResponses", "requestState" };

fn canonical(gpa: Allocator, w: *Io.Writer, v: Value, top: bool) (Io.Writer.Error || Allocator.Error)!void {
    switch (v) {
        .object => |o| {
            const keys = try gpa.dupe([]const u8, o.keys());
            defer gpa.free(keys);
            std.mem.sort([]const u8, keys, {}, lessThan);
            try w.writeByte('{');
            var first = true;
            for (keys) |k| {
                if (top and isSkipped(k)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try std.json.Stringify.encodeJsonString(k, .{}, w);
                try w.writeByte(':');
                try canonical(gpa, w, o.get(k).?, false);
            }
            try w.writeByte('}');
        },
        .array => |a| {
            try w.writeByte('[');
            for (a.items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try canonical(gpa, w, x, false);
            }
            try w.writeByte(']');
        },
        else => try std.json.Stringify.value(v, .{}, w),
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isSkipped(k: []const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, k, s)) return true;
    return false;
}

const testing = std.testing;

fn fixture(a: Allocator, json: []const u8) ![32]u8 {
    return paramsDigest(a, try protocol.codec.parseValue(a, json));
}

test "seal: round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Sealer = .random(testing.io);
    const digest = try fixture(a, "{\"name\":\"t\",\"arguments\":{\"b\":1,\"a\":[true,null]}}");
    // Member order, _meta and the MRTR members do not change the digest.
    try testing.expectEqualSlices(u8, &digest, &(try fixture(a, "{\"_meta\":{\"x\":1},\"arguments\":{\"a\":[true,null],\"b\":1},\"name\":\"t\",\"requestState\":\"z\",\"inputResponses\":{}}")));
    const ph = principalHash("alice", "");
    const tok = try s.seal(testing.io, testing.allocator, .{ .principal_hash = ph, .expires_at_ms = 1000, .method = .tools_call, .params_digest = digest, .handler_state = "step=2", .round = 3 });
    defer testing.allocator.free(tok);
    var ad: [ad_len]u8 = undefined;
    const p = try s.open(a, tok, associatedData(&ad, .tools_call, digest));
    try check(p, 999, ph, .tools_call, digest);
    try testing.expectEqualStrings("step=2", p.handler_state);
    try testing.expectEqual(3, p.round);
    // Every seal uses a fresh nonce.
    const tok2 = try s.seal(testing.io, testing.allocator, .{ .principal_hash = ph, .expires_at_ms = 1000, .method = .tools_call, .params_digest = digest, .round = 3 });
    defer testing.allocator.free(tok2);
    try testing.expect(!std.mem.eql(u8, tok, tok2));
}

test "seal: tamper byte => error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Sealer = .random(testing.io);
    const digest = try fixture(a, "{\"name\":\"t\"}");
    const tok = try s.seal(testing.io, a, .{ .principal_hash = principalHash(null, ""), .expires_at_ms = 1000, .method = .tools_call, .params_digest = digest, .round = 1 });
    var ad: [ad_len]u8 = undefined;
    const good_ad = associatedData(&ad, .tools_call, digest);
    for (0..tok.len) |i| {
        const bad = try a.dupe(u8, tok);
        bad[i] = if (bad[i] == 'A') 'B' else 'A';
        if (s.open(a, bad, good_ad)) |_| return error.TamperedTokenOpened else |err| try testing.expectEqual(error.Invalid, err);
    }
    // Another key fails too.
    const other: Sealer = .random(testing.io);
    try testing.expectError(error.Invalid, other.open(a, tok, good_ad));
}

test "seal: AD mismatch (different args) => error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Sealer = .random(testing.io);
    const digest = try fixture(a, "{\"name\":\"t\",\"arguments\":{\"n\":1}}");
    const tok = try s.seal(testing.io, a, .{ .principal_hash = principalHash(null, ""), .expires_at_ms = 1000, .method = .tools_call, .params_digest = digest, .round = 1 });
    var ad: [ad_len]u8 = undefined;
    try testing.expectError(error.Invalid, s.open(a, tok, associatedData(&ad, .tools_call, try fixture(a, "{\"name\":\"t\",\"arguments\":{\"n\":2}}"))));
    try testing.expectError(error.Invalid, s.open(a, tok, associatedData(&ad, .prompts_get, digest)));
}

test "seal: expired => error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Sealer = .random(testing.io);
    const digest = try fixture(a, "{}");
    const ph = principalHash(null, "");
    const tok = try s.seal(testing.io, a, .{ .principal_hash = ph, .expires_at_ms = 1000, .method = .tools_call, .params_digest = digest, .round = 1 });
    var ad: [ad_len]u8 = undefined;
    const p = try s.open(a, tok, associatedData(&ad, .tools_call, digest));
    try testing.expectError(error.Expired, check(p, 1000, ph, .tools_call, digest));
}

test "seal: other principal => error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Sealer = .random(testing.io);
    const digest = try fixture(a, "{}");
    const tok = try s.seal(testing.io, a, .{ .principal_hash = principalHash("alice", ""), .expires_at_ms = 1000, .method = .tools_call, .params_digest = digest, .round = 1 });
    var ad: [ad_len]u8 = undefined;
    const p = try s.open(a, tok, associatedData(&ad, .tools_call, digest));
    try testing.expectError(error.WrongPrincipal, check(p, 0, principalHash("mallory", ""), .tools_call, digest));
    try testing.expectError(error.WrongPrincipal, check(p, 0, principalHash("alice", "other-token"), .tools_call, digest));
}

test "fuzz: mcp seal open" {
    const s: Sealer = .{ .key = @splat(7) };
    try testing.fuzz(s, struct {
        fn one(sealer: Sealer, sm: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const token = buf[0..sm.slice(&buf)];
            var ad: [ad_len]u8 = undefined;
            const opened = sealer.open(testing.allocator, token, associatedData(&ad, .tools_call, @splat(0)));
            if (opened) |p| {
                testing.allocator.free(p.handler_state);
                return error.RandomTokenOpened;
            } else |_| {}
        }
    }.one, .{});
}
