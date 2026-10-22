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
//! IDN: hosts are compared as given; the egress layer converts U-labels to
//! A-labels before matching.

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
