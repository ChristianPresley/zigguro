//! Host patterns for `web_fetch(domain:...)` rules and egress allowlists
//! (E16.F02.S01.T01).
//!
//! - Hosts compare lower-case with one trailing `.` stripped.
//! - `*` alone matches every host.
//! - A leading `*.` matches any depth of subdomain, but not the bare domain:
//!   `*.example.com` matches `a.b.example.com`, not `example.com`.
//! - Any other `*` matches exactly one label and never crosses a dot:
//!   `example.*` matches `example.org`, not `example.evil.com`.
//! - IPv4 literals match exactly; IPv6 literals are written in brackets.
//! - An optional `:port` restricts the port.
//!
//! IDN: `toAscii` converts U-labels to A-labels (punycode, RFC 3492).
//! Patterns are converted when parsed and the egress layer converts hosts
//! before matching, so `bücher.example` and `xn--bcher-kva.example` are the
//! same host. Only ASCII is case-folded; full IDNA2008 mapping and NFC
//! normalisation are not applied, so a non-normalised U-label simply fails
//! to match an allow rule (never the reverse).

const std = @import("std");

/// Errors from `parse`.
pub const Error = error{ BadDomain, OutOfMemory };

/// Longest accepted host (RFC 1035 plus brackets).
pub const max_host = 255;

/// A compiled host pattern; `host` is owned by the arena given to `parse`.
pub const DomainPattern = struct {
    /// Lower-case pattern without brackets, port or leading `*.`.
    host: []const u8,
    any_subdomain: bool = false,
    all: bool = false,
    port: ?u16 = null,

    /// True when `host` (optionally `host:port` / `[v6]:port`) matches.
    /// `port` overrides a port in `host` when given.
    pub fn matches(p: *const DomainPattern, host_in: []const u8, port: ?u16) bool {
        var hb: [max_host]u8 = undefined;
        const h = normalize(host_in, &hb) orelse return false;
        const got_port = port orelse h.port;
        if (p.port) |want| if (got_port == null or got_port.? != want) return false;
        if (p.all) return true;
        const name = h.host;
        if (p.any_subdomain) {
            if (name.len <= p.host.len + 1) return false;
            const cut = name.len - p.host.len;
            if (name[cut - 1] != '.') return false;
            return labelsMatch(p.host, name[cut..]);
        }
        return labelsMatch(p.host, name);
    }
};

const Normalized = struct { host: []const u8, port: ?u16 };

fn normalize(in: []const u8, buf: *[max_host]u8) ?Normalized {
    var s = in;
    var port: ?u16 = null;
    if (s.len > 0 and s[0] == '[') {
        const close = std.mem.indexOfScalar(u8, s, ']') orelse return null;
        if (close + 1 < s.len) {
            if (s[close + 1] != ':') return null;
            port = std.fmt.parseInt(u16, s[close + 2 ..], 10) catch return null;
        }
        s = s[1..close];
    } else if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| {
        // One colon = host:port; more = bare IPv6 literal (no port).
        if (std.mem.indexOfScalar(u8, s, ':').? == colon) {
            port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
            s = s[0..colon];
        }
    }
    if (s.len > 0 and s[s.len - 1] == '.') s = s[0 .. s.len - 1];
    if (s.len == 0 or s.len > max_host) return null;
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return .{ .host = buf[0..s.len], .port = port };
}

/// Label-wise compare; a `*` label in the pattern matches one label.
fn labelsMatch(pat: []const u8, name: []const u8) bool {
    var pi = std.mem.splitScalar(u8, pat, '.');
    var ni = std.mem.splitScalar(u8, name, '.');
    while (true) {
        const a = pi.next();
        const b = ni.next();
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        if (std.mem.eql(u8, a.?, "*")) {
            if (b.?.len == 0) return false;
            continue;
        }
        if (!std.mem.eql(u8, a.?, b.?)) return false;
    }
}

/// Parses a domain pattern (without the `domain:` prefix).
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!DomainPattern {
    var p: DomainPattern = .{ .host = "" };
    var nb: [max_host]u8 = undefined;
    var s = text;
    if (std.mem.eql(u8, s, "*")) {
        p.all = true;
        return p;
    }
    // `*:443` restricts only the port.
    if (std.mem.startsWith(u8, s, "*:")) {
        p.all = true;
        p.port = std.fmt.parseInt(u16, s[2..], 10) catch return error.BadDomain;
        return p;
    }
    if (std.mem.startsWith(u8, s, "*.")) {
        p.any_subdomain = true;
        s = s[2..];
    }
    var ab: [max_host]u8 = undefined;
    s = toAscii(&ab, s) catch return error.BadDomain;
    const n = normalize(s, &nb) orelse return error.BadDomain;
    p.port = n.port;
    for (n.host) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '*' or c == ':' or c == '_';
        if (!ok) return error.BadDomain;
    }
    var labels = std.mem.splitScalar(u8, n.host, '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63) return error.BadDomain;
        if (std.mem.indexOfScalar(u8, l, '*') != null and !std.mem.eql(u8, l, "*")) return error.BadDomain;
    }
    p.host = try arena.dupe(u8, n.host);
    return p;
}

/// Errors from `toAscii`.
pub const IdnError = error{ InvalidUtf8, LabelTooLong, HostTooLong };

/// Converts every non-ASCII label of `host` to its `xn--` A-label and
/// lower-cases ASCII. Pure-ASCII input is returned lower-cased. The result
/// lives in `buf`.
pub fn toAscii(buf: *[max_host]u8, host: []const u8) IdnError![]const u8 {
    var len: usize = 0;
    var labels = std.mem.splitScalar(u8, host, '.');
    var first = true;
    while (labels.next()) |label| {
        if (!first) {
            if (len >= buf.len) return error.HostTooLong;
            buf[len] = '.';
            len += 1;
        }
        first = false;
        const ascii = for (label) |c| {
            if (c >= 0x80) break false;
        } else true;
        if (ascii) {
            if (len + label.len > buf.len) return error.HostTooLong;
            for (label, 0..) |c, i| buf[len + i] = std.ascii.toLower(c);
            len += label.len;
            continue;
        }
        var out: [63]u8 = undefined;
        const enc = try punycode(&out, label);
        if (len + 4 + enc.len > buf.len) return error.HostTooLong;
        @memcpy(buf[len..][0..4], "xn--");
        @memcpy(buf[len + 4 ..][0..enc.len], enc);
        len += 4 + enc.len;
    }
    return buf[0..len];
}

/// RFC 3492 punycode encoding of one label (without the `xn--` prefix).
fn punycode(out: *[63]u8, label: []const u8) IdnError![]const u8 {
    const base = 36;
    const tmin = 1;
    const tmax = 26;
    var cps: [63]u21 = undefined;
    var n_cps: usize = 0;
    var it = (std.unicode.Utf8View.init(label) catch return error.InvalidUtf8).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n_cps == cps.len) return error.LabelTooLong;
        cps[n_cps] = if (cp < 0x80) std.ascii.toLower(@intCast(cp)) else cp;
        n_cps += 1;
    }
    const input = cps[0..n_cps];
    var len: usize = 0;
    for (input) |cp| if (cp < 0x80) {
        if (len == out.len) return error.LabelTooLong;
        out[len] = @intCast(cp);
        len += 1;
    };
    const basic = len;
    var h = basic;
    if (basic > 0) {
        if (len == out.len) return error.LabelTooLong;
        out[len] = '-';
        len += 1;
    }
    var n: u32 = 128;
    var delta: u32 = 0;
    var bias: u32 = 72;
    while (h < input.len) {
        var m_cp: u32 = std.math.maxInt(u32);
        for (input) |cp| if (cp >= n and cp < m_cp) {
            m_cp = cp;
        };
        delta = std.math.add(u32, delta, std.math.mul(u32, m_cp - n, @intCast(h + 1)) catch return error.LabelTooLong) catch return error.LabelTooLong;
        n = m_cp;
        for (input) |cp| {
            if (cp < n) delta += 1;
            if (cp == n) {
                var q = delta;
                var k: u32 = base;
                while (true) : (k += base) {
                    const t: u32 = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
                    if (q < t) break;
                    if (len == out.len) return error.LabelTooLong;
                    out[len] = digit(t + (q - t) % (base - t));
                    len += 1;
                    q = (q - t) / (base - t);
                }
                if (len == out.len) return error.LabelTooLong;
                out[len] = digit(q);
                len += 1;
                bias = adapt(delta, @intCast(h + 1), h == basic);
                delta = 0;
                h += 1;
            }
        }
        delta += 1;
        n += 1;
    }
    return out[0..len];
}

fn digit(d: u32) u8 {
    return if (d < 26) @intCast('a' + d) else @intCast('0' + d - 26);
}

fn adapt(delta_in: u32, numpoints: u32, first: bool) u32 {
    var delta = if (first) delta_in / 700 else delta_in / 2;
    delta += delta / numpoints;
    var k: u32 = 0;
    while (delta > ((36 - 1) * 26) / 2) : (k += 36) delta /= 36 - 1;
    return k + (36 * delta) / (delta + 38);
}

test "domain: toAscii punycode vectors" {
    var buf: [max_host]u8 = undefined;
    try std.testing.expectEqualStrings("xn--bcher-kva.example", try toAscii(&buf, "bücher.example"));
    try std.testing.expectEqualStrings("xn--mnchen-3ya.de", try toAscii(&buf, "MüNCHEN.DE"));
    try std.testing.expectEqualStrings("api.github.com", try toAscii(&buf, "API.GitHub.com"));
    // RFC 3492 section 7.1 sample (B) Chinese (simplified).
    try std.testing.expectEqualStrings("xn--ihqwcrb4cv8a8dqg056pqjye", try toAscii(&buf, "他们为什么不说中文"));
    // RFC 3492 sample (L) Japanese with ASCII.
    try std.testing.expectEqualStrings("xn--3b-ww4c5e180e575a65lsy2b", try toAscii(&buf, "3年b組金八先生"));
    try std.testing.expectEqualStrings("xn--e1afmkfd.xn--p1ai", try toAscii(&buf, "пример.рф"));
    try std.testing.expectError(error.InvalidUtf8, toAscii(&buf, "a\xffb"));
    try std.testing.expect(try m("bücher.example", "xn--bcher-kva.example"));
}

fn m(pattern: []const u8, host: []const u8) !bool {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), pattern);
    return p.matches(host, null);
}

test "domain: wildcard never crosses a dot except leading *." {
    try std.testing.expect(try m("*.example.com", "a.example.com"));
    try std.testing.expect(try m("*.example.com", "a.b.example.com"));
    try std.testing.expect(!(try m("*.example.com", "example.com")));
    try std.testing.expect(!(try m("*.example.com", "badexample.com")));
    try std.testing.expect(try m("example.*", "example.org"));
    try std.testing.expect(!(try m("example.*", "example.evil.com")));
    try std.testing.expect(try m("api.*.example.com", "api.eu.example.com"));
    try std.testing.expect(!(try m("api.*.example.com", "api.a.b.example.com")));
    try std.testing.expect(try m("Example.COM", "example.com."));
    try std.testing.expect(try m("*", "anything.at.all"));
    try std.testing.expectError(error.BadDomain, m("ex*ample.com", "x"));
    try std.testing.expectError(error.BadDomain, m("a..b", "x"));
    try std.testing.expectError(error.BadDomain, m("a b.com", "x"));
}

test "domain: ipv6 bracket and port" {
    try std.testing.expect(try m("[::1]", "[::1]"));
    try std.testing.expect(try m("[::1]", "::1"));
    try std.testing.expect(try m("[::1]:8080", "[::1]:8080"));
    try std.testing.expect(!(try m("[::1]:8080", "[::1]:9090")));
    try std.testing.expect(!(try m("[::1]:8080", "[::1]")));
    try std.testing.expect(try m("127.0.0.1", "127.0.0.1:5000"));
    try std.testing.expect(!(try m("127.0.0.1", "127.0.0.10")));
    try std.testing.expect(try m("*.github.com:443", "api.github.com:443"));
    try std.testing.expect(!(try m("*:443", "x.com:80")));
    const p = try parse(std.testing.allocator, "localhost:3000");
    defer std.testing.allocator.free(p.host);
    try std.testing.expect(p.matches("localhost", 3000));
}
