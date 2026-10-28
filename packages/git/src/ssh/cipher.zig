//! SSH packet ciphers (E09.F08.S03.T01): `chacha20-poly1305@openssh.com`
//! (OpenSSH PROTOCOL.chacha20poly1305) and `aes{128,256}-gcm@openssh.com`
//! (RFC 5647 framing), plus the unencrypted state before the first
//! NEWKEYS. Both AEAD modes authenticate the whole packet, so no
//! separate MAC is negotiated for them.

const std = @import("std");
const crypto = std.crypto;
const ChaCha = crypto.stream.chacha.ChaCha20With64BitNonce;
const Poly1305 = crypto.onetimeauth.Poly1305;

pub const Kind = enum {
    none,
    chacha20_poly1305,
    aes128_gcm,
    aes256_gcm,

    pub fn fromName(name: []const u8) ?Kind {
        const map = [_]struct { []const u8, Kind }{
            .{ "chacha20-poly1305@openssh.com", .chacha20_poly1305 },
            .{ "aes128-gcm@openssh.com", .aes128_gcm },
            .{ "aes256-gcm@openssh.com", .aes256_gcm },
        };
        for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
        return null;
    }

    pub fn keyLen(k: Kind) usize {
        return switch (k) {
            .none => 0,
            .chacha20_poly1305 => 64,
            .aes128_gcm => 16,
            .aes256_gcm => 32,
        };
    }

    pub fn ivLen(k: Kind) usize {
        return switch (k) {
            .aes128_gcm, .aes256_gcm => 12,
            else => 0,
        };
    }

    pub fn tagLen(k: Kind) usize {
        return if (k == .none) 0 else 16;
    }

    pub fn blockLen(k: Kind) usize {
        return switch (k) {
            .aes128_gcm, .aes256_gcm => 16,
            else => 8,
        };
    }

    /// Whether the 4-byte length is outside the padded block (AEAD modes).
    pub fn lengthOutsideBlocks(k: Kind) bool {
        return k != .none;
    }
};

fn Gcm(comptime Aead: type) type {
    return struct {
        key: [Aead.key_length]u8,
        fixed: [4]u8,
        counter: u64,

        fn init(key: []const u8, iv: []const u8) @This() {
            return .{ .key = key[0..Aead.key_length].*, .fixed = iv[0..4].*, .counter = std.mem.readInt(u64, iv[4..12], .big) };
        }

        fn nonce(g: *@This()) [12]u8 {
            var n: [12]u8 = undefined;
            n[0..4].* = g.fixed;
            std.mem.writeInt(u64, n[4..12], g.counter, .big);
            g.counter +%= 1;
            return n;
        }

        fn seal(g: *@This(), packet: []u8, tag: *[16]u8) void {
            const n = g.nonce();
            Aead.encrypt(packet[4..], tag, packet[4..], packet[0..4], n, g.key);
        }

        fn open(g: *@This(), packet: []u8, tag: [16]u8) !void {
            const n = g.nonce();
            Aead.decrypt(packet[4..], packet[4..], tag, packet[0..4], n, g.key) catch return error.BadPacketMac;
        }
    };
}

const ChaChaPoly = struct {
    main: [32]u8,
    header: [32]u8,

    fn init(key: []const u8) ChaChaPoly {
        return .{ .main = key[0..32].*, .header = key[32..64].* };
    }

    fn nonce(seq: u32) [8]u8 {
        var n: [8]u8 = undefined;
        std.mem.writeInt(u64, &n, seq, .big);
        return n;
    }

    fn polyKey(c: ChaChaPoly, n: [8]u8) [32]u8 {
        var k: [32]u8 = @splat(0);
        ChaCha.xor(&k, &k, 0, c.main, n);
        return k;
    }

    fn seal(c: ChaChaPoly, seq: u32, packet: []u8, tag: *[16]u8) void {
        const n = nonce(seq);
        ChaCha.xor(packet[0..4], packet[0..4], 0, c.header, n);
        ChaCha.xor(packet[4..], packet[4..], 1, c.main, n);
        var pk = c.polyKey(n);
        defer crypto.secureZero(u8, &pk);
        Poly1305.create(tag, packet, &pk);
    }

    fn length(c: ChaChaPoly, seq: u32, enc: [4]u8) u32 {
        var out: [4]u8 = undefined;
        ChaCha.xor(&out, &enc, 0, c.header, nonce(seq));
        return std.mem.readInt(u32, &out, .big);
    }

    fn open(c: ChaChaPoly, seq: u32, packet: []u8, tag: [16]u8) !void {
        const n = nonce(seq);
        var pk = c.polyKey(n);
        defer crypto.secureZero(u8, &pk);
        var want: [16]u8 = undefined;
        Poly1305.create(&want, packet, &pk);
        if (!crypto.timing_safe.eql([16]u8, want, tag)) return error.BadPacketMac;
        ChaCha.xor(packet[4..], packet[4..], 1, c.main, n);
    }
};

/// One direction's cipher state.
pub const Cipher = union(Kind) {
    none,
    chacha20_poly1305: ChaChaPoly,
    aes128_gcm: Gcm(crypto.aead.aes_gcm.Aes128Gcm),
    aes256_gcm: Gcm(crypto.aead.aes_gcm.Aes256Gcm),

    pub fn init(k: Kind, key: []const u8, iv: []const u8) Cipher {
        return switch (k) {
            .none => .none,
            .chacha20_poly1305 => .{ .chacha20_poly1305 = .init(key) },
            .aes128_gcm => .{ .aes128_gcm = .init(key, iv) },
            .aes256_gcm => .{ .aes256_gcm = .init(key, iv) },
        };
    }

    pub fn kind(c: Cipher) Kind {
        return std.meta.activeTag(c);
    }

    /// Encrypts `packet` (length, padding length, payload, padding) in
    /// place and writes the tag (`kind().tagLen()` bytes) to `tag`.
    pub fn seal(c: *Cipher, seq: u32, packet: []u8, tag: *[16]u8) void {
        switch (c.*) {
            .none => {},
            .chacha20_poly1305 => |cc| cc.seal(seq, packet, tag),
            inline .aes128_gcm, .aes256_gcm => |*g| g.seal(packet, tag),
        }
    }

    /// The packet length from the first four bytes on the wire.
    pub fn length(c: *const Cipher, seq: u32, first: [4]u8) u32 {
        return switch (c.*) {
            .chacha20_poly1305 => |cc| cc.length(seq, first),
            else => std.mem.readInt(u32, &first, .big),
        };
    }

    /// Authenticates and decrypts `packet` in place; the length field is
    /// left as it came off the wire.
    pub fn open(c: *Cipher, seq: u32, packet: []u8, tag: [16]u8) !void {
        switch (c.*) {
            .none => {},
            .chacha20_poly1305 => |cc| try cc.open(seq, packet, tag),
            inline .aes128_gcm, .aes256_gcm => |*g| try g.open(packet, tag),
        }
    }

    pub fn wipe(c: *Cipher) void {
        crypto.secureZero(u8, std.mem.asBytes(c));
        c.* = .none;
    }
};

test "seal and open round trip" {
    const key: [64]u8 = @splat(7);
    const iv: [12]u8 = .{ 1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 9 };
    for ([_]Kind{ .chacha20_poly1305, .aes128_gcm, .aes256_gcm }) |k| {
        var tx: Cipher = .init(k, key[0..k.keyLen()], iv[0..k.ivLen()]);
        var rx: Cipher = .init(k, key[0..k.keyLen()], iv[0..k.ivLen()]);
        var pkt: [32]u8 = undefined;
        std.mem.writeInt(u32, pkt[0..4], 28, .big);
        for (pkt[4..], 0..) |*b, i| b.* = @intCast(i);
        const plain = pkt;
        var tag: [16]u8 = undefined;
        tx.seal(5, &pkt, &tag);
        try std.testing.expect(!std.mem.eql(u8, &pkt, &plain));
        try std.testing.expectEqual(@as(u32, 28), rx.length(5, pkt[0..4].*));
        var bad = pkt;
        bad[10] ^= 1;
        var rx2 = rx;
        try std.testing.expectError(error.BadPacketMac, rx2.open(5, &bad, tag));
        try rx.open(5, &pkt, tag);
        try std.testing.expectEqualSlices(u8, plain[4..], pkt[4..]);
    }
}
