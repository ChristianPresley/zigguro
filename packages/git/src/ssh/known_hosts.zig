//! OpenSSH known_hosts (sshd(8) SSH_KNOWN_HOSTS FILE FORMAT): host
//! patterns with `*`, `?` and `!`, hashed `|1|salt|hash` names,
//! `[host]:port` for non-default ports, and the `@revoked` and
//! `@cert-authority` markers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const pubkey = @import("pubkey.zig");

pub const Status = enum { known, unknown, changed, revoked };

/// The name a host is stored under: `host`, or `[host]:port` when the
/// port is not 22.
pub fn hostName(buf: []u8, host: []const u8, port: u16) []const u8 {
    if (port == 22) return std.fmt.bufPrint(buf, "{s}", .{host}) catch host;
    return std.fmt.bufPrint(buf, "[{s}]:{d}", .{ host, port }) catch host;
}

/// `*` and `?` glob match, ignoring ASCII case.
pub fn glob(pattern: []const u8, s: []const u8) bool {
    if (pattern.len == 0) return s.len == 0;
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) if (glob(pattern[1..], s[i..])) return true;
        return false;
    }
    if (s.len == 0) return false;
    if (pattern[0] != '?' and std.ascii.toLower(pattern[0]) != std.ascii.toLower(s[0])) return false;
    return glob(pattern[1..], s[1..]);
}

/// Whether a comma-separated pattern list matches `name`: some pattern
/// matches and no negated one does.
pub fn matchList(list: []const u8, name: []const u8) bool {
    var hit = false;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        if (p[0] == '!') {
            if (glob(p[1..], name)) return false;
        } else if (glob(p, name)) hit = true;
    }
    return hit;
}

fn hashedMatch(field: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, field, "|1|")) return false;
    const rest = field[3..];
    const bar = std.mem.indexOfScalar(u8, rest, '|') orelse return false;
    const dec = std.base64.standard.Decoder;
    var salt: [64]u8 = undefined;
    var want: [64]u8 = undefined;
    const sl = dec.calcSizeForSlice(rest[0..bar]) catch return false;
    const wl = dec.calcSizeForSlice(rest[bar + 1 ..]) catch return false;
    if (sl > salt.len or wl != HmacSha1.mac_length) return false;
    dec.decode(salt[0..sl], rest[0..bar]) catch return false;
    dec.decode(want[0..wl], rest[bar + 1 ..]) catch return false;
    var got: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&got, name, salt[0..sl]);
    return std.mem.eql(u8, &got, want[0..wl]);
}

const Line = struct {
    marker: enum { none, revoked, cert_authority },
    hosts: []const u8,
    key: []const u8,
};

fn parseLine(raw: []const u8) ?Line {
    var s = std.mem.trim(u8, raw, " \t\r");
    if (s.len == 0 or s[0] == '#') return null;
    var marker: @FieldType(Line, "marker") = .none;
    if (s[0] == '@') {
        const sp = std.mem.indexOfAny(u8, s, " \t") orelse return null;
        const m = s[0..sp];
        if (std.mem.eql(u8, m, "@revoked")) marker = .revoked else if (std.mem.eql(u8, m, "@cert-authority")) marker = .cert_authority else return null;
        s = std.mem.trimStart(u8, s[sp..], " \t");
    }
    const sp = std.mem.indexOfAny(u8, s, " \t") orelse return null;
    return .{ .marker = marker, .hosts = s[0..sp], .key = std.mem.trimStart(u8, s[sp..], " \t") };
}

fn hostMatches(hosts: []const u8, name: []const u8) bool {
    if (std.mem.startsWith(u8, hosts, "|")) return hashedMatch(hosts, name);
    return matchList(hosts, name);
}

/// Checks `blob` for host `name` (from `hostName`) against a
/// known_hosts file's text. `@revoked` wins over everything; a different
/// key of the same type means the key changed.
pub fn check(gpa: Allocator, text: []const u8, name: []const u8, blob: []const u8) !Status {
    const pk = try pubkey.PublicKey.parse(blob);
    var status: Status = .unknown;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = parseLine(raw) orelse continue;
        if (l.marker == .cert_authority) continue;
        const t = pubkey.Text.parse(gpa, l.key) catch continue;
        defer gpa.free(t.blob);
        const same = std.mem.eql(u8, t.blob, blob);
        if (l.marker == .revoked) {
            if (same) return .revoked;
            continue;
        }
        if (!hostMatches(l.hosts, name)) continue;
        if (same) {
            status = .known;
        } else if (status == .unknown and std.mem.eql(u8, t.type, pk.typeName())) status = .changed;
    }
    return status;
}

/// The key types stored for `name`, in file order; for ordering the
/// host key algorithms we offer.
pub fn knownTypes(gpa: Allocator, text: []const u8, name: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = parseLine(raw) orelse continue;
        if (l.marker != .none or !hostMatches(l.hosts, name)) continue;
        const sp = std.mem.indexOfAny(u8, l.key, " \t") orelse continue;
        try out.append(gpa, l.key[0..sp]);
    }
    return out.toOwnedSlice(gpa);
}

/// The line to append for a newly accepted key.
pub fn entry(gpa: Allocator, name: []const u8, blob: []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    try w.writer.print("{s} ", .{name});
    try pubkey.writeText(&w.writer, blob);
    try w.writer.writeByte('\n');
    return w.toOwnedSlice();
}

test "known_hosts matching" {
    const gpa = std.testing.allocator;
    const kp = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    const other = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    var blobs: [2][]u8 = undefined;
    for ([_]std.crypto.sign.Ed25519.KeyPair{ kp, other }, 0..) |k, i| {
        var b: @import("wire.zig").Builder = .init(gpa);
        try b.string("ssh-ed25519");
        try b.string(&k.public_key.toBytes());
        blobs[i] = try b.toOwned();
    }
    defer for (blobs) |b| gpa.free(b);
    var nb: [64]u8 = undefined;
    const e = try entry(gpa, hostName(&nb, "example.com", 2222), blobs[0]);
    defer gpa.free(e);
    try std.testing.expect(std.mem.startsWith(u8, e, "[example.com]:2222 ssh-ed25519 "));
    try std.testing.expectEqual(Status.known, try check(gpa, e, "[example.com]:2222", blobs[0]));
    try std.testing.expectEqual(Status.changed, try check(gpa, e, "[example.com]:2222", blobs[1]));
    try std.testing.expectEqual(Status.unknown, try check(gpa, e, "example.com", blobs[0]));

    // Hashed host names, as `ssh-keygen -H` writes them.
    var salt: [20]u8 = @splat(3);
    var mac: [20]u8 = undefined;
    HmacSha1.create(&mac, "github.com", &salt);
    var s64: [28]u8 = undefined;
    var m64: [28]u8 = undefined;
    const hashed = try std.fmt.allocPrint(gpa, "|1|{s}|{s} {s}", .{ std.base64.standard.Encoder.encode(&s64, &salt), std.base64.standard.Encoder.encode(&m64, &mac), e[std.mem.indexOfScalar(u8, e, ' ').? + 1 ..] });
    defer gpa.free(hashed);
    try std.testing.expectEqual(Status.known, try check(gpa, hashed, "github.com", blobs[0]));
    try std.testing.expectEqual(Status.unknown, try check(gpa, hashed, "gitlab.com", blobs[0]));

    const revoked = try std.fmt.allocPrint(gpa, "@revoked * {s}{s}", .{ e[std.mem.indexOfScalar(u8, e, ' ').? + 1 ..], e });
    defer gpa.free(revoked);
    try std.testing.expectEqual(Status.revoked, try check(gpa, revoked, "[example.com]:2222", blobs[0]));
    try std.testing.expect(matchList("*.example.com,!bad.example.com", "a.example.com"));
    try std.testing.expect(!matchList("*.example.com,!bad.example.com", "bad.example.com"));
}
