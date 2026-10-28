//! An SSH-2 client, the subset git needs (E09.F08.S03): version
//! exchange and the binary packet protocol (RFC 4253) with strict KEX,
//! `curve25519-sha256` key exchange (RFC 8731) with rekeying, public key
//! user authentication (RFC 4252), and one `session` channel running a
//! remote command (RFC 4254). The channel's stdout and stdin are exposed
//! as an `Io.Reader` and `Io.Writer`.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = crypto.hash.sha2.Sha256;
const X25519 = crypto.dh.X25519;
const wire = @import("wire.zig");
const cipher = @import("cipher.zig");
const pubkey = @import("pubkey.zig");

pub const msg = struct {
    pub const disconnect = 1;
    pub const ignore = 2;
    pub const unimplemented = 3;
    pub const debug = 4;
    pub const service_request = 5;
    pub const service_accept = 6;
    pub const ext_info = 7;
    pub const kexinit = 20;
    pub const newkeys = 21;
    pub const kex_ecdh_init = 30;
    pub const kex_ecdh_reply = 31;
    pub const userauth_request = 50;
    pub const userauth_failure = 51;
    pub const userauth_success = 52;
    pub const userauth_banner = 53;
    pub const userauth_pk_ok = 60;
    pub const global_request = 80;
    pub const request_failure = 82;
    pub const channel_open = 90;
    pub const channel_open_confirmation = 91;
    pub const channel_open_failure = 92;
    pub const channel_window_adjust = 93;
    pub const channel_data = 94;
    pub const channel_extended_data = 95;
    pub const channel_eof = 96;
    pub const channel_close = 97;
    pub const channel_request = 98;
    pub const channel_success = 99;
    pub const channel_failure = 100;
};

pub const client_version = "SSH-2.0-zigguro_1.0";
const kex_algorithms = "curve25519-sha256,curve25519-sha256@libssh.org,ext-info-c,kex-strict-c-v00@openssh.com";
const ciphers = "aes256-gcm@openssh.com,aes128-gcm@openssh.com,chacha20-poly1305@openssh.com";
// The AEAD ciphers carry their own tags; a MAC is still negotiated.
const macs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512";
pub const default_host_key_algorithms = "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,rsa-sha2-512,rsa-sha2-256";

const max_packet = 256 * 1024;
const local_window_size: u32 = 2 * 1024 * 1024;
const local_max_packet: u32 = 32 * 1024;

/// Decides whether the server's host key is acceptable.
pub const HostKeyVerifier = struct {
    ctx: ?*anyopaque = null,
    verify: *const fn (ctx: ?*anyopaque, blob: []const u8) anyerror!void,
};

/// A key the client can authenticate with.
pub const Identity = struct {
    blob: []const u8,
    ctx: ?*anyopaque = null,
    /// Signs `data` with algorithm `alg`; returns the signature blob.
    sign: *const fn (ctx: ?*anyopaque, gpa: Allocator, alg: []const u8, data: []const u8) anyerror![]u8,
};

pub const HandshakeOptions = struct {
    host_key_algorithms: []const u8 = default_host_key_algorithms,
    verifier: HostKeyVerifier,
    /// Use chacha20-poly1305 with a server without strict KEX (Terrapin).
    allow_terrapin: bool = false,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    raw_reader: *Io.Reader,
    raw_writer: *Io.Writer,

    tx: cipher.Cipher = .none,
    rx: cipher.Cipher = .none,
    tx_seq: u32 = 0,
    rx_seq: u32 = 0,
    pkt: []u8,
    out: std.ArrayList(u8) = .empty,

    server_version: []u8 = &.{},
    session_id: ?[32]u8 = null,
    strict: bool = false,
    host_key_algorithms: []const u8 = default_host_key_algorithms,
    verifier: ?HostKeyVerifier = null,
    allow_terrapin: bool = false,
    /// `server-sig-algs` from SSH_MSG_EXT_INFO.
    server_sig_algs: ?[]u8 = null,
    host_key: ?[]u8 = null,
    negotiated_cipher: cipher.Kind = .none,
    kex_count: u32 = 0,
    /// The reason text of a SSH_MSG_DISCONNECT from the server.
    disconnect_reason: ?[]u8 = null,
    /// Banners the server sent during authentication.
    banner: std.ArrayList(u8) = .empty,

    // The session channel.
    remote_id: u32 = 0,
    remote_window: u64 = 0,
    remote_max: u32 = 0,
    local_window: u32 = 0,
    chan_open: bool = false,
    chan_eof: bool = false,
    chan_closed: bool = false,
    sent_close: bool = false,
    exit_status: ?u32 = null,
    inbox: std.ArrayList(u8) = .empty,
    inbox_pos: usize = 0,
    stderr: std.ArrayList(u8) = .empty,
    err: ?anyerror = null,
    reader_iface: Io.Reader,
    writer_iface: Io.Writer,
    wbuf: [local_max_packet]u8 = undefined,
    rbuf: []u8,

    pub fn create(gpa: Allocator, io: Io, r: *Io.Reader, w: *Io.Writer) !*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        const pkt = try gpa.alloc(u8, max_packet + 64);
        errdefer gpa.free(pkt);
        const rbuf = try gpa.alloc(u8, @import("../remote/transport.zig").read_buffer_len);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .raw_reader = r,
            .raw_writer = w,
            .pkt = pkt,
            .rbuf = rbuf,
            .reader_iface = .{ .vtable = &.{ .stream = streamChannel }, .buffer = rbuf, .seek = 0, .end = 0 },
            .writer_iface = undefined,
        };
        c.writer_iface = .{ .vtable = &.{ .drain = drainChannel }, .buffer = &c.wbuf };
        return c;
    }

    pub fn destroy(c: *Client) void {
        const gpa = c.gpa;
        c.tx.wipe();
        c.rx.wipe();
        crypto.secureZero(u8, c.pkt);
        gpa.free(c.pkt);
        gpa.free(c.rbuf);
        c.out.deinit(gpa);
        gpa.free(c.server_version);
        if (c.server_sig_algs) |s| gpa.free(s);
        if (c.host_key) |s| gpa.free(s);
        if (c.disconnect_reason) |s| gpa.free(s);
        c.banner.deinit(gpa);
        c.inbox.deinit(gpa);
        c.stderr.deinit(gpa);
        gpa.destroy(c);
    }

    // ---- packets ----

    fn random(c: *Client, buf: []u8) void {
        c.io.random(buf);
    }

    /// Sends one packet with `payload`.
    pub fn send(c: *Client, payload: []const u8) !void {
        const k = c.tx.kind();
        const bs = k.blockLen();
        const base = 1 + payload.len + @as(usize, if (k.lengthOutsideBlocks()) 0 else 4);
        var pad = bs - base % bs;
        if (pad < 4) pad += bs;
        const total = 4 + 1 + payload.len + pad;
        try c.out.resize(c.gpa, total);
        const p = c.out.items;
        std.mem.writeInt(u32, p[0..4], @intCast(total - 4), .big);
        p[4] = @intCast(pad);
        @memcpy(p[5..][0..payload.len], payload);
        c.random(p[5 + payload.len ..]);
        var tag: [16]u8 = undefined;
        c.tx.seal(c.tx_seq, p, &tag);
        c.tx_seq +%= 1;
        try c.raw_writer.writeAll(p);
        try c.raw_writer.writeAll(tag[0..k.tagLen()]);
        try c.raw_writer.flush();
        crypto.secureZero(u8, p);
    }

    fn sendBuilt(c: *Client, b: *wire.Builder) !void {
        try c.send(b.bytes());
    }

    /// Reads one packet; the payload is valid until the next read.
    fn recvRaw(c: *Client) ![]u8 {
        const first = (try c.raw_reader.takeArray(4)).*;
        const len = c.rx.length(c.rx_seq, first);
        if (len < 5 or len > max_packet) return error.BadPacketLength;
        const total = 4 + @as(usize, len);
        @memcpy(c.pkt[0..4], &first);
        try c.raw_reader.readSliceAll(c.pkt[4..total]);
        var tag: [16]u8 = undefined;
        try c.raw_reader.readSliceAll(tag[0..c.rx.kind().tagLen()]);
        try c.rx.open(c.rx_seq, c.pkt[0..total], tag);
        c.rx_seq +%= 1;
        const pad = c.pkt[4];
        if (@as(usize, pad) + 1 > len) return error.BadPacketLength;
        return c.pkt[5 .. total - pad];
    }

    /// The next packet that is not transport noise, handling server
    /// KEXINIT (rekey), EXT_INFO and DISCONNECT.
    pub fn recv(c: *Client) ![]u8 {
        while (true) {
            const p = try c.recvRaw();
            if (p.len == 0) return error.BadPacket;
            switch (p[0]) {
                msg.ignore, msg.debug, msg.unimplemented => continue,
                msg.disconnect => {
                    var r: wire.Parser = .init(p[1..]);
                    _ = r.int() catch 0;
                    const reason = r.string() catch "";
                    if (c.disconnect_reason == null) c.disconnect_reason = try c.gpa.dupe(u8, reason);
                    return error.Disconnected;
                },
                msg.ext_info => {
                    try c.extInfo(p);
                    continue;
                },
                msg.kexinit => {
                    const copy = try c.gpa.dupe(u8, p);
                    defer c.gpa.free(copy);
                    try c.kex(copy);
                    continue;
                },
                else => return p,
            }
        }
    }

    fn expect(c: *Client, t: u8) ![]u8 {
        const p = try c.recv();
        if (p[0] != t) return error.UnexpectedMessage;
        return p;
    }

    fn extInfo(c: *Client, p: []const u8) !void {
        var r: wire.Parser = .init(p[1..]);
        const n = try r.int();
        for (0..n) |_| {
            const name = try r.string();
            const value = try r.string();
            if (std.mem.eql(u8, name, "server-sig-algs")) {
                if (c.server_sig_algs) |s| c.gpa.free(s);
                c.server_sig_algs = try c.gpa.dupe(u8, value);
            }
        }
    }

    // ---- handshake ----

    /// Version exchange and the first key exchange.
    pub fn handshake(c: *Client, opts: HandshakeOptions) !void {
        c.host_key_algorithms = opts.host_key_algorithms;
        c.verifier = opts.verifier;
        c.allow_terrapin = opts.allow_terrapin;
        try c.raw_writer.writeAll(client_version ++ "\r\n");
        try c.raw_writer.flush();
        // Servers may send other lines before their version.
        var lines: usize = 0;
        while (true) : (lines += 1) {
            if (lines > 64) return error.NoSshServer;
            const line = c.raw_reader.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.StreamTooLong => return error.NoSshServer,
                else => |x| return x,
            };
            const v = std.mem.trimEnd(u8, line, "\r\n");
            if (!std.mem.startsWith(u8, v, "SSH-")) continue;
            if (!std.mem.startsWith(u8, v, "SSH-2.0-") and !std.mem.startsWith(u8, v, "SSH-1.99-")) return error.UnsupportedSshVersion;
            c.server_version = try c.gpa.dupe(u8, v);
            break;
        }
        const first = try c.recvRaw();
        if (first.len == 0 or first[0] != msg.kexinit) return error.UnexpectedMessage;
        const copy = try c.gpa.dupe(u8, first);
        defer c.gpa.free(copy);
        try c.kex(copy);
    }

    fn kexinitPayload(c: *Client) ![]u8 {
        var b: wire.Builder = .init(c.gpa);
        errdefer b.deinit();
        try b.byte(msg.kexinit);
        var cookie: [16]u8 = undefined;
        c.random(&cookie);
        try b.raw(&cookie);
        // ext-info-c and kex-strict-c only belong in the first KEXINIT.
        try b.string(if (c.kex_count == 0) kex_algorithms else "curve25519-sha256,curve25519-sha256@libssh.org");
        try b.string(c.host_key_algorithms);
        for (0..2) |_| try b.string(ciphers);
        for (0..2) |_| try b.string(macs);
        for (0..2) |_| try b.string("none");
        for (0..2) |_| try b.string("");
        try b.boolean(false);
        try b.int(0);
        return b.toOwned();
    }

    /// One key exchange, given the server's KEXINIT payload.
    fn kex(c: *Client, server_kexinit: []const u8) !void {
        const ours = try c.kexinitPayload();
        defer c.gpa.free(ours);
        try c.send(ours);

        var sp: wire.Parser = .init(server_kexinit[17..]);
        const s_kex = try sp.string();
        const s_hostkey = try sp.string();
        const s_enc_cs = try sp.string();
        const s_enc_sc = try sp.string();
        _ = try sp.string();
        _ = try sp.string();
        const s_comp_cs = try sp.string();
        const s_comp_sc = try sp.string();
        _ = try sp.string();
        _ = try sp.string();
        const follows = try sp.boolean();

        if (c.kex_count == 0) {
            c.strict = wire.hasName(s_kex, "kex-strict-s-v00@openssh.com");
            // Strict KEX: the server's KEXINIT must have been its first packet.
            if (c.strict and c.rx_seq != 1) return error.StrictKexViolation;
        }
        _ = wire.negotiate("curve25519-sha256,curve25519-sha256@libssh.org", s_kex) orelse return error.NoCommonKexAlgorithm;
        const hk_alg = wire.negotiate(c.host_key_algorithms, s_hostkey) orelse return error.NoCommonHostKeyAlgorithm;
        const enc_cs = cipher.Kind.fromName(wire.negotiate(ciphers, s_enc_cs) orelse return error.NoCommonCipher).?;
        const enc_sc = cipher.Kind.fromName(wire.negotiate(ciphers, s_enc_sc) orelse return error.NoCommonCipher).?;
        if (!wire.hasName(s_comp_cs, "none") or !wire.hasName(s_comp_sc, "none")) return error.NoCommonCompression;
        if (!c.strict and !c.allow_terrapin and (enc_cs == .chacha20_poly1305 or enc_sc == .chacha20_poly1305))
            return error.TerrapinVulnerableServer;
        // A guessed packet for a different algorithm is discarded.
        if (follows and !std.mem.eql(u8, firstName(s_kex), "curve25519-sha256") and !std.mem.eql(u8, firstName(s_kex), "curve25519-sha256@libssh.org"))
            _ = try c.recvRaw();

        const eph = X25519.KeyPair.generate(c.io);
        {
            var b: wire.Builder = .init(c.gpa);
            defer b.deinit();
            try b.byte(msg.kex_ecdh_init);
            try b.string(&eph.public_key);
            try c.sendBuilt(&b);
        }
        const reply = try c.recvRaw();
        if (reply.len == 0 or reply[0] != msg.kex_ecdh_reply) return error.UnexpectedMessage;
        var rp: wire.Parser = .init(reply[1..]);
        const k_s = try c.gpa.dupe(u8, try rp.string());
        defer c.gpa.free(k_s);
        const q_s = try rp.string();
        const sig = try c.gpa.dupe(u8, try rp.string());
        defer c.gpa.free(sig);
        if (q_s.len != 32) return error.BadKexReply;
        var shared = X25519.scalarmult(eph.secret_key, q_s[0..32].*) catch return error.BadKexReply;
        defer crypto.secureZero(u8, &shared);

        var kb: wire.Builder = .init(c.gpa);
        defer kb.deinit();
        try kb.mpint(&shared);

        var h: [32]u8 = undefined;
        {
            var hb: wire.Builder = .init(c.gpa);
            defer hb.deinit();
            try hb.string(client_version);
            try hb.string(c.server_version);
            try hb.string(ours);
            try hb.string(server_kexinit);
            try hb.string(k_s);
            try hb.string(&eph.public_key);
            try hb.string(q_s);
            try hb.raw(kb.bytes());
            Sha256.hash(hb.bytes(), &h, .{});
        }

        // The host key must sign H with the negotiated algorithm.
        const pk = try pubkey.PublicKey.parse(k_s);
        var sigp: wire.Parser = .init(sig);
        if (!std.mem.eql(u8, try sigp.string(), hk_alg) or !pk.allows(hk_alg)) return error.HostKeySignatureMismatch;
        pk.verify(sig, &h) catch return error.HostKeySignatureInvalid;
        if (c.host_key) |old| {
            // A rekey must present the same host key.
            if (!std.mem.eql(u8, old, k_s)) return error.HostKeyChangedDuringRekey;
        } else {
            try c.verifier.?.verify(c.verifier.?.ctx, k_s);
            c.host_key = try c.gpa.dupe(u8, k_s);
        }
        if (c.session_id == null) c.session_id = h;

        try c.send(&.{msg.newkeys});
        const nk = try c.recvRaw();
        if (nk.len == 0 or nk[0] != msg.newkeys) return error.UnexpectedMessage;

        var key_buf: [64]u8 = undefined;
        var iv_buf: [64]u8 = undefined;
        defer crypto.secureZero(u8, &key_buf);
        c.derive(kb.bytes(), &h, 'A', iv_buf[0..enc_cs.ivLen()]);
        c.derive(kb.bytes(), &h, 'C', key_buf[0..enc_cs.keyLen()]);
        c.tx.wipe();
        c.tx = .init(enc_cs, key_buf[0..enc_cs.keyLen()], iv_buf[0..enc_cs.ivLen()]);
        c.derive(kb.bytes(), &h, 'B', iv_buf[0..enc_sc.ivLen()]);
        c.derive(kb.bytes(), &h, 'D', key_buf[0..enc_sc.keyLen()]);
        c.rx.wipe();
        c.rx = .init(enc_sc, key_buf[0..enc_sc.keyLen()], iv_buf[0..enc_sc.ivLen()]);
        if (c.strict) {
            c.tx_seq = 0;
            c.rx_seq = 0;
        }
        c.negotiated_cipher = enc_cs;
        c.kex_count += 1;
    }

    /// RFC 4253 §7.2 key derivation with SHA-256.
    fn derive(c: *Client, k: []const u8, h: *const [32]u8, letter: u8, out: []u8) void {
        var block: [32]u8 = undefined;
        var hs = Sha256.init(.{});
        hs.update(k);
        hs.update(h);
        hs.update(&.{letter});
        hs.update(&c.session_id.?);
        hs.final(&block);
        var n: usize = 0;
        while (true) {
            const take = @min(32, out.len - n);
            @memcpy(out[n..][0..take], block[0..take]);
            n += take;
            if (n == out.len) break;
            var hx = Sha256.init(.{});
            hx.update(k);
            hx.update(h);
            hx.update(out[0..n]);
            hx.final(&block);
        }
        crypto.secureZero(u8, &block);
    }

    // ---- authentication ----

    /// The signature algorithm to offer for a key blob, or null when the
    /// server will not accept any we can make.
    pub fn algorithmFor(c: *Client, blob: []const u8) ?[]const u8 {
        var p: wire.Parser = .init(blob);
        const t = p.string() catch return null;
        if (!std.mem.eql(u8, t, "ssh-rsa")) return t;
        const algs = c.server_sig_algs orelse return "rsa-sha2-512";
        if (wire.hasName(algs, "rsa-sha2-512")) return "rsa-sha2-512";
        if (wire.hasName(algs, "rsa-sha2-256")) return "rsa-sha2-256";
        return null;
    }

    /// Public key authentication with the identities in order. Each key
    /// is offered first; only a key the server accepts is asked to sign.
    pub fn authenticate(c: *Client, user: []const u8, identities: []const Identity) !void {
        {
            var b: wire.Builder = .init(c.gpa);
            defer b.deinit();
            try b.byte(msg.service_request);
            try b.string("ssh-userauth");
            try c.sendBuilt(&b);
        }
        _ = try c.expect(msg.service_accept);
        var last_err: ?anyerror = null;
        for (identities) |id| {
            const alg = c.algorithmFor(id.blob) orelse continue;
            {
                var b: wire.Builder = .init(c.gpa);
                defer b.deinit();
                try authHeader(&b, user, false, alg, id.blob);
                try c.sendBuilt(&b);
            }
            switch (try c.authReply()) {
                .success => return,
                .failure => continue,
                .pk_ok => {},
            }
            var data: wire.Builder = .init(c.gpa);
            defer data.deinit();
            try data.string(&c.session_id.?);
            try authHeader(&data, user, true, alg, id.blob);
            const sig = id.sign(id.ctx, c.gpa, alg, data.bytes()) catch |e| {
                last_err = e;
                continue;
            };
            defer c.gpa.free(sig);
            var b: wire.Builder = .init(c.gpa);
            defer b.deinit();
            try authHeader(&b, user, true, alg, id.blob);
            try b.string(sig);
            try c.sendBuilt(&b);
            switch (try c.authReply()) {
                .success => return,
                else => continue,
            }
        }
        if (last_err) |e| return e;
        return error.SshAuthenticationFailed;
    }

    fn authHeader(b: *wire.Builder, user: []const u8, has_sig: bool, alg: []const u8, blob: []const u8) !void {
        try b.byte(msg.userauth_request);
        try b.string(user);
        try b.string("ssh-connection");
        try b.string("publickey");
        try b.boolean(has_sig);
        try b.string(alg);
        try b.string(blob);
    }

    fn authReply(c: *Client) !enum { success, failure, pk_ok } {
        while (true) {
            const p = try c.recv();
            switch (p[0]) {
                msg.userauth_success => return .success,
                msg.userauth_pk_ok => return .pk_ok,
                msg.userauth_failure => {
                    var r: wire.Parser = .init(p[1..]);
                    if (!wire.hasName(try r.string(), "publickey")) return error.PublicKeyAuthNotAllowed;
                    return .failure;
                },
                msg.userauth_banner => {
                    var r: wire.Parser = .init(p[1..]);
                    try c.banner.appendSlice(c.gpa, try r.string());
                },
                msg.global_request => try c.globalRequest(p),
                else => return error.UnexpectedMessage,
            }
        }
    }

    fn globalRequest(c: *Client, p: []const u8) !void {
        var r: wire.Parser = .init(p[1..]);
        _ = try r.string();
        if (try r.boolean()) try c.send(&.{msg.request_failure});
    }

    // ---- the session channel ----

    /// Opens a session channel, sets `env` and runs `command`.
    pub fn exec(c: *Client, command: []const u8, env: []const [2][]const u8) !void {
        {
            var b: wire.Builder = .init(c.gpa);
            defer b.deinit();
            try b.byte(msg.channel_open);
            try b.string("session");
            try b.int(0);
            try b.int(local_window_size);
            try b.int(local_max_packet);
            try c.sendBuilt(&b);
        }
        while (true) {
            const p = try c.recv();
            switch (p[0]) {
                msg.channel_open_confirmation => {
                    var r: wire.Parser = .init(p[1..]);
                    _ = try r.int();
                    c.remote_id = try r.int();
                    c.remote_window = try r.int();
                    c.remote_max = try r.int();
                    if (c.remote_max == 0) return error.BadChannel;
                    c.local_window = local_window_size;
                    c.chan_open = true;
                    break;
                },
                msg.channel_open_failure => return error.ChannelOpenFailed,
                msg.global_request => try c.globalRequest(p),
                else => return error.UnexpectedMessage,
            }
        }
        for (env) |kv| {
            var b: wire.Builder = .init(c.gpa);
            defer b.deinit();
            try b.byte(msg.channel_request);
            try b.int(c.remote_id);
            try b.string("env");
            try b.boolean(false);
            try b.string(kv[0]);
            try b.string(kv[1]);
            try c.sendBuilt(&b);
        }
        {
            var b: wire.Builder = .init(c.gpa);
            defer b.deinit();
            try b.byte(msg.channel_request);
            try b.int(c.remote_id);
            try b.string("exec");
            try b.boolean(true);
            try b.string(command);
            try c.sendBuilt(&b);
        }
        while (true) {
            switch (try c.pump()) {
                .success => return,
                .failure => return error.ExecRefused,
                .other => if (c.chan_closed) return error.ExecRefused,
            }
        }
    }

    /// Handles one connection-protocol packet.
    fn pump(c: *Client) !enum { success, failure, other } {
        const p = try c.recv();
        var r: wire.Parser = .init(p[1..]);
        switch (p[0]) {
            msg.channel_data => {
                _ = try r.int();
                const d = try r.string();
                if (d.len > c.local_window) return error.ChannelWindowExceeded;
                c.local_window -= @intCast(d.len);
                try c.inbox.appendSlice(c.gpa, d);
                if (c.local_window < local_window_size / 2 and !c.chan_eof) {
                    var b: wire.Builder = .init(c.gpa);
                    defer b.deinit();
                    try b.byte(msg.channel_window_adjust);
                    try b.int(c.remote_id);
                    try b.int(local_window_size - c.local_window);
                    try c.sendBuilt(&b);
                    c.local_window = local_window_size;
                }
            },
            msg.channel_extended_data => {
                _ = try r.int();
                _ = try r.int();
                const d = try r.string();
                if (d.len > c.local_window) return error.ChannelWindowExceeded;
                c.local_window -= @intCast(d.len);
                if (c.stderr.items.len < 64 * 1024) try c.stderr.appendSlice(c.gpa, d);
            },
            msg.channel_window_adjust => {
                _ = try r.int();
                c.remote_window += try r.int();
            },
            msg.channel_eof => c.chan_eof = true,
            msg.channel_close => {
                c.chan_eof = true;
                c.chan_closed = true;
                c.sendClose() catch {};
            },
            msg.channel_request => {
                _ = try r.int();
                const name = try r.string();
                const want = try r.boolean();
                if (std.mem.eql(u8, name, "exit-status")) c.exit_status = try r.int();
                if (std.mem.eql(u8, name, "exit-signal")) c.exit_status = 255;
                if (want) {
                    var b: wire.Builder = .init(c.gpa);
                    defer b.deinit();
                    try b.byte(msg.channel_failure);
                    try b.int(c.remote_id);
                    try c.sendBuilt(&b);
                }
            },
            msg.channel_success => return .success,
            msg.channel_failure => return .failure,
            msg.global_request => try c.globalRequest(p),
            else => return error.UnexpectedMessage,
        }
        return .other;
    }

    fn sendData(c: *Client, data: []const u8) !void {
        var d = data;
        while (d.len > 0) {
            if (c.chan_closed) return error.ChannelClosed;
            if (c.remote_window == 0) {
                _ = try c.pump();
                continue;
            }
            const n: usize = @intCast(@min(@as(u64, d.len), c.remote_window, c.remote_max, local_max_packet));
            var b: wire.Builder = .init(c.gpa);
            defer b.deinit();
            try b.byte(msg.channel_data);
            try b.int(c.remote_id);
            try b.string(d[0..n]);
            try c.sendBuilt(&b);
            c.remote_window -= n;
            d = d[n..];
        }
    }

    fn sendClose(c: *Client) !void {
        if (c.sent_close or !c.chan_open) return;
        c.sent_close = true;
        var b: wire.Builder = .init(c.gpa);
        defer b.deinit();
        try b.byte(msg.channel_eof);
        try b.int(c.remote_id);
        try c.sendBuilt(&b);
        b.list.clearRetainingCapacity();
        try b.byte(msg.channel_close);
        try b.int(c.remote_id);
        try c.sendBuilt(&b);
    }

    /// Closes the channel and says goodbye; the byte stream stays open.
    pub fn shutdown(c: *Client) void {
        c.writer_iface.flush() catch {};
        c.sendClose() catch {};
        var b: wire.Builder = .init(c.gpa);
        defer b.deinit();
        b.byte(msg.disconnect) catch return;
        b.int(11) catch return;
        b.string("") catch return;
        b.string("") catch return;
        c.send(b.bytes()) catch {};
    }

    pub fn reader(c: *Client) *Io.Reader {
        return &c.reader_iface;
    }

    pub fn writer(c: *Client) *Io.Writer {
        return &c.writer_iface;
    }

    fn streamChannel(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const c: *Client = @alignCast(@fieldParentPtr("reader_iface", r));
        while (c.inbox_pos == c.inbox.items.len) {
            if (c.chan_eof) return error.EndOfStream;
            _ = c.pump() catch |e| {
                c.err = e;
                return error.ReadFailed;
            };
        }
        const n = try w.write(limit.slice(c.inbox.items[c.inbox_pos..]));
        c.inbox_pos += n;
        if (c.inbox_pos == c.inbox.items.len) {
            c.inbox.clearRetainingCapacity();
            c.inbox_pos = 0;
        }
        return n;
    }

    fn drainChannel(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const c: *Client = @alignCast(@fieldParentPtr("writer_iface", w));
        c.sendData(w.buffered()) catch |e| {
            c.err = e;
            return error.WriteFailed;
        };
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            c.sendData(d) catch |e| {
                c.err = e;
                return error.WriteFailed;
            };
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            c.sendData(last) catch |e| {
                c.err = e;
                return error.WriteFailed;
            };
            n += last.len;
        }
        return n;
    }
};

fn firstName(list: []const u8) []const u8 {
    var it = wire.names(list);
    return it.next() orelse "";
}
