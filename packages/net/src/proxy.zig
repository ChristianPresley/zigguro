//! Proxy selection. `std.http.Client.initDefaultProxies` reads
//! `http_proxy` / `https_proxy` / `all_proxy` but ignores `NO_PROXY`; this
//! file implements it with curl's documented semantics:
//!
//! - comma-separated entries, whitespace trimmed, case-insensitive;
//! - `*` alone matches every host;
//! - `example.com` and `.example.com` match the domain and its subdomains;
//! - `host:port` restricts an entry to one port;
//! - IP literals match exactly; `addr/bits` is a CIDR block (IPv4 or IPv6).
//!
//! `localhost`, `127.0.0.0/8` and `::1` always bypass the proxy.

const std = @import("std");
const net = std.Io.net;

/// How a `Client` picks its proxy.
pub const ProxyConfig = union(enum) {
    /// `http_proxy`, `https_proxy`, `all_proxy` and `no_proxy` (any case).
    from_env,
    none,
    explicit: struct { http: ?[]const u8 = null, https: ?[]const u8 = null, no_proxy: []const u8 = "" },
};

/// The `NO_PROXY` value from the environment (`no_proxy` wins), or "".
pub fn noProxyFromEnv(env: *const std.process.Environ.Map) []const u8 {
    return env.get("no_proxy") orelse env.get("NO_PROXY") orelse "";
}

/// True when `host:port` must be reached directly.
pub fn shouldBypass(no_proxy: []const u8, host_in: []const u8, port: u16) bool {
    const host = trimBrackets(trimDot(host_in));
    if (isLoopback(host)) return true;
    var it = std.mem.splitScalar(u8, no_proxy, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;
        if (std.mem.eql(u8, entry, "*")) return true;
        if (matchEntry(entry, host, port)) return true;
    }
    return false;
}

fn matchEntry(entry: []const u8, host: []const u8, port: u16) bool {
    var pattern = entry;
    // Split an optional `:port`, taking care with IPv6 literals.
    if (pattern.len > 0 and pattern[0] == '[') {
        const close = std.mem.indexOfScalar(u8, pattern, ']') orelse return false;
        const after = pattern[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return false;
            const p = std.fmt.parseInt(u16, after[1..], 10) catch return false;
            if (p != port) return false;
        }
        pattern = pattern[1..close];
    } else if (std.mem.count(u8, pattern, ":") == 1) {
        const c = std.mem.indexOfScalar(u8, pattern, ':').?;
        const p = std.fmt.parseInt(u16, pattern[c + 1 ..], 10) catch return false;
        if (p != port) return false;
        pattern = pattern[0..c];
    }
    if (std.mem.indexOfScalar(u8, pattern, '/')) |slash| {
        const bits = std.fmt.parseInt(u8, pattern[slash + 1 ..], 10) catch return false;
        return inCidr(host, pattern[0..slash], bits);
    }
    if (parseIp(pattern)) |p| {
        const h = parseIp(host) orelse return false;
        return p.eql(h);
    }
    const domain = trimDot(pattern);
    if (domain.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    return host.len > domain.len and host[host.len - domain.len - 1] == '.' and
        std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain);
}

const Ip = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    fn eql(a: Ip, b: Ip) bool {
        return switch (a) {
            .v4 => |x| b == .v4 and std.mem.eql(u8, &x, &b.v4),
            .v6 => |x| b == .v6 and std.mem.eql(u8, &x, &b.v6),
        };
    }

    fn bytes(self: *const Ip) []const u8 {
        return switch (self.*) {
            .v4 => |*x| x,
            .v6 => |*x| x,
        };
    }
};

fn parseIp(text: []const u8) ?Ip {
    if (net.Ip4Address.parse(text, 0)) |a| return .{ .v4 = a.bytes } else |_| {}
    if (std.mem.indexOfScalar(u8, text, ':') == null) return null;
    if (net.Ip6Address.parse(text, 0)) |a| return .{ .v6 = a.bytes } else |_| {}
    return null;
}

fn inCidr(host: []const u8, network: []const u8, bits: u8) bool {
    const h = parseIp(host) orelse return false;
    const n = parseIp(network) orelse return false;
    if (std.meta.activeTag(h) != std.meta.activeTag(n)) return false;
    const hb = h.bytes();
    const nb = n.bytes();
    if (bits > hb.len * 8) return false;
    const full = bits / 8;
    if (!std.mem.eql(u8, hb[0..full], nb[0..full])) return false;
    const rem: u3 = @intCast(bits % 8);
    if (rem == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @intCast(8 - @as(u4, rem));
    return (hb[full] & mask) == (nb[full] & mask);
}

fn isLoopback(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (inCidr(host, "127.0.0.0", 8)) return true;
    const ip = parseIp(host) orelse return false;
    return ip.eql(parseIp("::1").?);
}

fn trimDot(s: []const u8) []const u8 {
    var r = s;
    while (r.len > 0 and r[0] == '.') r = r[1..];
    while (r.len > 0 and r[r.len - 1] == '.') r = r[0 .. r.len - 1];
    return r;
}

fn trimBrackets(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') return s[1 .. s.len - 1];
    return s;
}

test "proxy: shouldBypass table" {
    const cases = [_]struct { np: []const u8, host: []const u8, port: u16, want: bool }{
        .{ .np = "", .host = "example.com", .port = 443, .want = false },
        .{ .np = "*", .host = "anything.org", .port = 80, .want = true },
        .{ .np = "example.com", .host = "example.com", .port = 443, .want = true },
        .{ .np = "example.com", .host = "api.example.com", .port = 443, .want = true },
        .{ .np = "example.com", .host = "badexample.com", .port = 443, .want = false },
        .{ .np = ".example.com", .host = "example.com", .port = 443, .want = true },
        .{ .np = ".example.com", .host = "a.b.example.com", .port = 443, .want = true },
        .{ .np = "EXAMPLE.com", .host = "Api.Example.COM", .port = 443, .want = true },
        .{ .np = " foo.org , example.com:8080 ", .host = "example.com", .port = 8080, .want = true },
        .{ .np = "example.com:8080", .host = "example.com", .port = 443, .want = false },
        .{ .np = "10.0.0.0/8", .host = "10.1.2.3", .port = 80, .want = true },
        .{ .np = "10.0.0.0/8", .host = "11.1.2.3", .port = 80, .want = false },
        .{ .np = "192.168.1.0/23", .host = "192.168.0.9", .port = 80, .want = true },
        .{ .np = "192.168.1.0/24", .host = "192.168.0.9", .port = 80, .want = false },
        .{ .np = "192.168.1.5", .host = "192.168.1.5", .port = 80, .want = true },
        .{ .np = "192.168.1.5", .host = "192.168.1.6", .port = 80, .want = false },
        .{ .np = "2001:db8::/32", .host = "2001:db8:1::5", .port = 443, .want = true },
        .{ .np = "2001:db8::/32", .host = "2001:db9::5", .port = 443, .want = false },
        .{ .np = "[2001:db8::1]:443", .host = "[2001:db8::1]", .port = 443, .want = true },
        .{ .np = "[2001:db8::1]:443", .host = "2001:db8::1", .port = 80, .want = false },
        .{ .np = "", .host = "localhost", .port = 3000, .want = true },
        .{ .np = "", .host = "127.0.0.2", .port = 3000, .want = true },
        .{ .np = "", .host = "[::1]", .port = 3000, .want = true },
        .{ .np = "", .host = "example.com.", .port = 443, .want = false },
        .{ .np = "example.com", .host = "example.com.", .port = 443, .want = true },
    };
    for (cases) |c| {
        std.testing.expectEqual(c.want, shouldBypass(c.np, c.host, c.port)) catch |err| {
            std.debug.print("NO_PROXY='{s}' host={s}:{d}\n", .{ c.np, c.host, c.port });
            return err;
        };
    }
}
