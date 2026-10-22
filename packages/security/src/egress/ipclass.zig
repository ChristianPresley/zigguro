//! IP address classification for the egress guard and proxy
//! (E16.F05.S01.T01). Every address zigguro dials on an agent's or a remote
//! server's behalf is classified first; anything that is not `public` is
//! refused unless the user explicitly allowed it, which is what blocks SSRF
//! to loopback services, LAN hosts and cloud metadata endpoints.
//!
//! The table follows the IANA special-purpose address registries (RFC 6890
//! and its updates). Addresses that embed an IPv4 address (IPv4-mapped,
//! NAT64 and 6to4) are classified by the embedded address so that
//! `::ffff:127.0.0.1` cannot slip past an IPv4-only check.

const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

/// The class of an address. Only `public` may be dialled without an
/// explicit `allow_private` entry.
pub const IpClass = enum {
    public,
    loopback,
    private,
    link_local,
    cgnat,
    unique_local,
    multicast,
    unspecified,
    documentation,
    reserved,
    /// An IPv6 address embedding a non-public IPv4 address.
    ipv4_mapped_private,

    /// True for the only class that is dialled by default.
    pub fn isPublic(c: IpClass) bool {
        return c == .public;
    }
};

const Row4 = struct { net: [4]u8, len: u6, class: IpClass };
const Row6 = struct { net: [16]u8, len: u8, class: IpClass };

/// IPv4 special-purpose blocks, most specific first.
pub const v4_table = [_]Row4{
    .{ .net = .{ 0, 0, 0, 0 }, .len = 8, .class = .unspecified },
    .{ .net = .{ 10, 0, 0, 0 }, .len = 8, .class = .private },
    .{ .net = .{ 100, 64, 0, 0 }, .len = 10, .class = .cgnat },
    .{ .net = .{ 127, 0, 0, 0 }, .len = 8, .class = .loopback },
    .{ .net = .{ 169, 254, 0, 0 }, .len = 16, .class = .link_local },
    .{ .net = .{ 172, 16, 0, 0 }, .len = 12, .class = .private },
    .{ .net = .{ 192, 0, 0, 0 }, .len = 24, .class = .reserved },
    .{ .net = .{ 192, 0, 2, 0 }, .len = 24, .class = .documentation },
    .{ .net = .{ 192, 31, 196, 0 }, .len = 24, .class = .reserved },
    .{ .net = .{ 192, 52, 193, 0 }, .len = 24, .class = .reserved },
    .{ .net = .{ 192, 88, 99, 0 }, .len = 24, .class = .reserved },
    .{ .net = .{ 192, 168, 0, 0 }, .len = 16, .class = .private },
    .{ .net = .{ 192, 175, 48, 0 }, .len = 24, .class = .reserved },
    .{ .net = .{ 198, 18, 0, 0 }, .len = 15, .class = .reserved },
    .{ .net = .{ 198, 51, 100, 0 }, .len = 24, .class = .documentation },
    .{ .net = .{ 203, 0, 113, 0 }, .len = 24, .class = .documentation },
    .{ .net = .{ 224, 0, 0, 0 }, .len = 4, .class = .multicast },
    .{ .net = .{ 240, 0, 0, 0 }, .len = 4, .class = .reserved },
};

fn v6(comptime text: []const u8) [16]u8 {
    @setEvalBranchQuota(10_000);
    return (IpAddress.parseIp6(text, 0) catch unreachable).ip6.bytes;
}

/// IPv6 special-purpose blocks (embedded-IPv4 prefixes are handled before
/// this table). Anything outside 2000::/3 that no row names is `reserved`.
pub const v6_table = [_]Row6{
    .{ .net = v6("::"), .len = 128, .class = .unspecified },
    .{ .net = v6("::1"), .len = 128, .class = .loopback },
    .{ .net = v6("64:ff9b:1::"), .len = 48, .class = .reserved },
    .{ .net = v6("100::"), .len = 64, .class = .reserved },
    .{ .net = v6("2001:db8::"), .len = 32, .class = .documentation },
    .{ .net = v6("2001::"), .len = 23, .class = .reserved },
    .{ .net = v6("3fff::"), .len = 20, .class = .documentation },
    .{ .net = v6("5f00::"), .len = 16, .class = .reserved },
    .{ .net = v6("fc00::"), .len = 7, .class = .unique_local },
    .{ .net = v6("fe80::"), .len = 10, .class = .link_local },
    .{ .net = v6("fec0::"), .len = 10, .class = .unique_local },
    .{ .net = v6("ff00::"), .len = 8, .class = .multicast },
};

fn prefixMatch(addr: []const u8, net: []const u8, len: usize) bool {
    const full = len / 8;
    if (!std.mem.eql(u8, addr[0..full], net[0..full])) return false;
    const rem: u3 = @intCast(len % 8);
    if (rem == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @intCast(8 - @as(u4, rem));
    return (addr[full] & mask) == (net[full] & mask);
}

/// Classifies a raw IPv4 address.
pub fn classify4(b: [4]u8) IpClass {
    for (v4_table) |r| if (prefixMatch(&b, &r.net, r.len)) return r.class;
    return .public;
}

/// The IPv4 address embedded in an IPv4-mapped (::ffff:0:0/96), NAT64
/// (64:ff9b::/96), IPv4-compatible (::/96) or 6to4 (2002::/16) address.
pub fn embedded4(b: [16]u8) ?[4]u8 {
    const mapped = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff };
    const nat64 = [_]u8{ 0, 0x64, 0xff, 0x9b } ++ [_]u8{0} ** 8;
    if (std.mem.eql(u8, b[0..12], &mapped) or std.mem.eql(u8, b[0..12], &nat64)) return b[12..16].*;
    if (b[0] == 0x20 and b[1] == 0x02) return b[2..6].*;
    // Deprecated IPv4-compatible ::a.b.c.d (but not :: or ::1).
    if (std.mem.allEqual(u8, b[0..12], 0) and !(std.mem.allEqual(u8, b[12..15], 0) and b[15] <= 1)) return b[12..16].*;
    return null;
}

/// Classifies a raw IPv6 address.
pub fn classify6(b: [16]u8) IpClass {
    if (embedded4(b)) |e| {
        const c = classify4(e);
        return if (c == .public) .public else .ipv4_mapped_private;
    }
    for (v6_table) |r| if (prefixMatch(&b, &r.net, r.len)) return r.class;
    // Only 2000::/3 is allocated global unicast.
    if (b[0] & 0xe0 != 0x20) return .reserved;
    return .public;
}

/// Classifies an address of either family.
pub fn classify(addr: IpAddress) IpClass {
    return switch (addr) {
        .ip4 => |a| classify4(a.bytes),
        .ip6 => |a| classify6(a.bytes),
    };
}

/// An address block used for `allow_private` opt-ins. IPv4 blocks are
/// stored as IPv4; an IPv4-mapped IPv6 address is matched against them by
/// its embedded address.
pub const Cidr = struct {
    family: IpAddress.Family,
    bytes: [16]u8 = @splat(0),
    len: u8,

    pub const ParseError = error{InvalidCidr};

    /// Parses `a.b.c.d/n`, `x::y/n` or a bare address (full length).
    pub fn parse(text: []const u8) ParseError!Cidr {
        const slash = std.mem.findScalar(u8, text, '/');
        const addr_text = if (slash) |s| text[0..s] else text;
        const addr = IpAddress.parse(addr_text, 0) catch return error.InvalidCidr;
        var c: Cidr = switch (addr) {
            .ip4 => |a| .{ .family = .ip4, .len = 32, .bytes = a.bytes ++ [_]u8{0} ** 12 },
            .ip6 => |a| .{ .family = .ip6, .len = 128, .bytes = a.bytes },
        };
        if (slash) |s| {
            const n = std.fmt.parseInt(u8, text[s + 1 ..], 10) catch return error.InvalidCidr;
            if (n > c.len) return error.InvalidCidr;
            c.len = n;
        }
        return c;
    }

    /// True when `addr` lies inside this block.
    pub fn contains(c: Cidr, addr: IpAddress) bool {
        switch (addr) {
            .ip4 => |a| return c.family == .ip4 and prefixMatch(&a.bytes, c.bytes[0..4], c.len),
            .ip6 => |a| {
                if (c.family == .ip6) return prefixMatch(&a.bytes, &c.bytes, c.len);
                const e = embedded4(a.bytes) orelse return false;
                return prefixMatch(&e, c.bytes[0..4], c.len);
            },
        }
    }

    /// Formats as `addr/len`.
    pub fn format(c: Cidr, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (c.family) {
            .ip4 => try w.print("{d}.{d}.{d}.{d}/{d}", .{ c.bytes[0], c.bytes[1], c.bytes[2], c.bytes[3], c.len }),
            .ip6 => {
                const a: IpAddress = .{ .ip6 = .{ .port = 0, .bytes = c.bytes } };
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{f}", .{a}) catch unreachable;
                // IpAddress formats as `[addr]:0`; keep only the address.
                const end = std.mem.findScalar(u8, s, ']') orelse s.len;
                try w.print("{s}/{d}", .{ s[1..end], c.len });
            },
        }
    }
};

/// True when any of `allow` covers `addr`.
pub fn allowed(allow: []const Cidr, addr: IpAddress) bool {
    for (allow) |c| if (c.contains(addr)) return true;
    return false;
}

fn cls(text: []const u8) IpClass {
    return classify(IpAddress.parse(text, 0) catch unreachable);
}

test "ipclass: every RFC 6890 row" {
    // One address at the start, one in the middle and one at the end of
    // every IPv4 row, plus the first address past it.
    for (v4_table) |r| {
        const base = std.mem.readInt(u32, &r.net, .big);
        const size: u64 = @as(u64, 1) << @intCast(32 - @as(u6, r.len));
        const last: u32 = @intCast(base + size - 1);
        for ([_]u32{ base, @intCast(base + size / 2), last }) |x| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, x, .big);
            try std.testing.expectEqual(r.class, classify4(b));
            // The same address mapped into IPv6 is never public.
            const m = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff } ++ b;
            try std.testing.expectEqual(IpClass.ipv4_mapped_private, classify6(m));
        }
    }
    for (v6_table) |r| try std.testing.expectEqual(r.class, classify6(r.net));
}

test "ipclass: well-known addresses" {
    const T = struct { []const u8, IpClass };
    const cases = [_]T{
        .{ "8.8.8.8", .public },
        .{ "1.1.1.1", .public },
        .{ "9.255.255.255", .public },
        .{ "11.0.0.0", .public },
        .{ "100.63.255.255", .public },
        .{ "100.64.0.1", .cgnat },
        .{ "100.128.0.0", .public },
        .{ "127.0.0.1", .loopback },
        .{ "127.255.255.254", .loopback },
        .{ "169.254.169.254", .link_local },
        .{ "172.15.255.255", .public },
        .{ "172.16.0.1", .private },
        .{ "172.31.255.255", .private },
        .{ "172.32.0.0", .public },
        .{ "192.168.1.1", .private },
        .{ "198.18.0.1", .reserved },
        .{ "198.19.255.255", .reserved },
        .{ "198.20.0.0", .public },
        .{ "224.0.0.1", .multicast },
        .{ "255.255.255.255", .reserved },
        .{ "0.0.0.0", .unspecified },
        .{ "::", .unspecified },
        .{ "::1", .loopback },
        .{ "fd00:ec2::254", .unique_local },
        .{ "fe80::1", .link_local },
        .{ "ff02::1", .multicast },
        .{ "2001:db8::1", .documentation },
        .{ "2606:4700::1111", .public },
        .{ "2a00:1450::1", .public },
        .{ "::ffff:127.0.0.1", .ipv4_mapped_private },
        .{ "::ffff:169.254.169.254", .ipv4_mapped_private },
        .{ "::ffff:8.8.8.8", .public },
        .{ "64:ff9b::a00:1", .ipv4_mapped_private },
        .{ "64:ff9b::808:808", .public },
        .{ "2002:7f00:1::", .ipv4_mapped_private },
        .{ "2002:808:808::", .public },
        .{ "::7f00:1", .ipv4_mapped_private },
        .{ "100::1", .reserved },
        .{ "4000::1", .reserved },
        .{ "3fff::1", .documentation },
    };
    for (cases) |c| {
        errdefer std.debug.print("address {s}\n", .{c[0]});
        try std.testing.expectEqual(c[1], cls(c[0]));
    }
}

test "ipclass: cidr parse, contains and format" {
    const lan = try Cidr.parse("192.168.1.0/24");
    try std.testing.expect(lan.contains(try IpAddress.parse("192.168.1.77", 0)));
    try std.testing.expect(!lan.contains(try IpAddress.parse("192.168.2.1", 0)));
    try std.testing.expect(lan.contains(try IpAddress.parse("::ffff:192.168.1.5", 0)));
    const one = try Cidr.parse("10.0.0.5");
    try std.testing.expect(one.contains(try IpAddress.parse("10.0.0.5", 0)));
    try std.testing.expect(!one.contains(try IpAddress.parse("10.0.0.6", 0)));
    const ula = try Cidr.parse("fd00::/8");
    try std.testing.expect(ula.contains(try IpAddress.parse("fd12::1", 0)));
    try std.testing.expect(!ula.contains(try IpAddress.parse("fe80::1", 0)));
    try std.testing.expectError(error.InvalidCidr, Cidr.parse("10.0.0.0/33"));
    try std.testing.expectError(error.InvalidCidr, Cidr.parse("nope/8"));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("192.168.1.0/24", try std.fmt.bufPrint(&buf, "{f}", .{lan}));
    try std.testing.expectEqualStrings("fd00::/8", try std.fmt.bufPrint(&buf, "{f}", .{ula}));
}
