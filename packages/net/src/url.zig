//! Helpers on `std.Uri`: origins, query parameters and form encoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Uri = std.Uri;

/// The default port for `http`, `https`, `ws` and `wss`, or null.
pub fn defaultPort(scheme: []const u8) ?u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "ws")) return 80;
    if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "wss")) return 443;
    return null;
}

/// The explicit or default port.
pub fn port(uri: Uri) ?u16 {
    return uri.port orelse defaultPort(uri.scheme);
}

/// The host as raw text (percent-decoded into `buf`).
pub fn host(uri: Uri, buf: []u8) ![]const u8 {
    const h = uri.host orelse return error.UriMissingHost;
    return h.toRaw(buf) catch error.UriHostTooLong;
}

/// True when scheme, host and port match (RFC 6454 origin).
pub fn sameOrigin(a: Uri, b: Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    if (port(a) != port(b)) return false;
    var ba: [255]u8 = undefined;
    var bb: [255]u8 = undefined;
    const ha = host(a, &ba) catch return false;
    const hb = host(b, &bb) catch return false;
    return std.ascii.eqlIgnoreCase(ha, hb);
}

/// Percent-decodes `s` (and `+` as space when `plus_is_space`) into `gpa`.
pub fn percentDecode(gpa: Allocator, s: []const u8, plus_is_space: bool) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, s.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |v| {
                out.appendAssumeCapacity(v);
                i += 2;
                continue;
            } else |_| {}
        }
        out.appendAssumeCapacity(if (c == '+' and plus_is_space) ' ' else c);
    }
    return out.toOwnedSlice(gpa);
}

/// Finds `name` in an `application/x-www-form-urlencoded` string and
/// returns its decoded value (allocated with `gpa`).
pub fn queryParam(gpa: Allocator, query: []const u8, name: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const k = pair[0 .. eq orelse pair.len];
        const key = try percentDecode(gpa, k, true);
        defer gpa.free(key);
        if (!std.mem.eql(u8, key, name)) continue;
        return try percentDecode(gpa, if (eq) |e| pair[e + 1 ..] else "", true);
    }
    return null;
}

/// Appends `name=value` pairs form-encoded (RFC 3986 unreserved kept, space
/// as `%20`) to `out`, separated by `&`.
pub fn appendForm(gpa: Allocator, out: *std.ArrayList(u8), pairs: []const [2][]const u8) !void {
    for (pairs) |p| {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '?') try out.append(gpa, '&');
        try appendEncoded(gpa, out, p[0]);
        try out.append(gpa, '=');
        try appendEncoded(gpa, out, p[1]);
    }
}

/// Percent-encodes everything but RFC 3986 unreserved characters.
pub fn appendEncoded(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
}

test "url: origins" {
    const a = try Uri.parse("https://Example.com/a?b");
    const b = try Uri.parse("https://example.com:443/other");
    const c = try Uri.parse("http://example.com/");
    const d = try Uri.parse("https://api.example.com/");
    try std.testing.expect(sameOrigin(a, b));
    try std.testing.expect(!sameOrigin(a, c));
    try std.testing.expect(!sameOrigin(a, d));
    try std.testing.expectEqual(@as(?u16, 443), port(a));
    try std.testing.expectEqual(@as(?u16, 80), port(c));
}

test "url: query params and form encoding" {
    const gpa = std.testing.allocator;
    const v = (try queryParam(gpa, "code=a%2Fb+c&state=xyz&empty", "code")).?;
    defer gpa.free(v);
    try std.testing.expectEqualStrings("a/b c", v);
    const e = (try queryParam(gpa, "code=a&empty", "empty")).?;
    defer gpa.free(e);
    try std.testing.expectEqualStrings("", e);
    try std.testing.expect(try queryParam(gpa, "a=1", "b") == null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendForm(gpa, &out, &.{ .{ "grant_type", "authorization_code" }, .{ "redirect_uri", "http://127.0.0.1:5/cb" } });
    try std.testing.expectEqualStrings("grant_type=authorization_code&redirect_uri=http%3A%2F%2F127.0.0.1%3A5%2Fcb", out.items);
    const bad = try percentDecode(gpa, "100%zz%4", false);
    defer gpa.free(bad);
    try std.testing.expectEqualStrings("100%zz%4", bad);
}
