//! Canonical URLs for the source library (E13.F05.S01.T01): one spelling
//! per page, so a source fetched twice is captured once.
//!
//! `canonicalize` gives the stored form: scheme and host lowercased,
//! default ports dropped, the fragment removed, tracking parameters
//! (`utm_*`, `gclid`, `fbclid`, `mc_cid`, `mc_eid`, `ref`, `ref_src`)
//! removed and the rest sorted, runs of `/` collapsed, a trailing
//! `/index.html` stripped. Hosts are kept as received (punycode passes
//! through; there is no IDNA mapping). `dedupeKey` goes further for
//! comparison only: `www.` is folded and `http` counts as `https`.

const std = @import("std");

const Allocator = std.mem.Allocator;

const tracking = [_][]const u8{ "gclid", "fbclid", "mc_cid", "mc_eid", "ref", "ref_src", "dclid", "msclkid", "_hsenc", "_hsmi", "yclid" };

fn isTracking(name: []const u8) bool {
    if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[0..4], "utm_")) return true;
    for (tracking) |t| if (std.ascii.eqlIgnoreCase(t, name)) return true;
    return false;
}

fn defaultPort(scheme: []const u8) ?u16 {
    if (std.mem.eql(u8, scheme, "http")) return 80;
    if (std.mem.eql(u8, scheme, "https")) return 443;
    return null;
}

pub const Parts = struct {
    scheme: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    query: []const u8,
};

/// Splits an absolute http(s) URL; null for anything else.
pub fn split(url: []const u8) ?Parts {
    const u = std.mem.trim(u8, url, " \t\r\n");
    const colon = std.mem.indexOf(u8, u, "://") orelse return null;
    const scheme = u[0..colon];
    if (!(std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https"))) return null;
    const rest = u[colon + 3 ..];
    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var auth = rest[0..auth_end];
    // Credentials never belong in a source's URL.
    if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| auth = auth[at + 1 ..];
    var host = auth;
    var port: ?u16 = null;
    // IPv6 literals keep their brackets.
    const port_colon = if (std.mem.startsWith(u8, auth, "[")) blk: {
        const close = std.mem.indexOfScalar(u8, auth, ']') orelse return null;
        break :blk if (close + 1 < auth.len and auth[close + 1] == ':') close + 1 else null;
    } else std.mem.lastIndexOfScalar(u8, auth, ':');
    if (port_colon) |pc| {
        host = auth[0..pc];
        const ps = auth[pc + 1 ..];
        port = if (ps.len == 0) null else std.fmt.parseInt(u16, ps, 10) catch return null;
    }
    if (host.len == 0) return null;
    var after = rest[auth_end..];
    if (std.mem.indexOfScalar(u8, after, '#')) |h| after = after[0..h];
    const q = std.mem.indexOfScalar(u8, after, '?');
    return .{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path = after[0 .. q orelse after.len],
        .query = if (q) |i| after[i + 1 ..] else "",
    };
}

/// The stored canonical form of `url` (unchanged when it is not an
/// absolute http(s) URL).
pub fn canonicalize(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const p = split(url) orelse return arena.dupe(u8, std.mem.trim(u8, url, " \t\r\n"));
    var out: std.ArrayList(u8) = .empty;
    for (p.scheme) |c| try out.append(arena, std.ascii.toLower(c));
    try out.appendSlice(arena, "://");
    var host = p.host;
    // A trailing dot names the same host.
    if (host.len > 1 and host[host.len - 1] == '.') host = host[0 .. host.len - 1];
    for (host) |c| try out.append(arena, std.ascii.toLower(c));
    const scheme_l = out.items[0..p.scheme.len];
    if (p.port) |port| if (defaultPort(scheme_l) != port) try out.print(arena, ":{d}", .{port});
    // Path: collapse runs of '/', drop a trailing /index.html.
    var path: std.ArrayList(u8) = .empty;
    for (p.path) |c| {
        if (c == '/' and path.items.len > 0 and path.items[path.items.len - 1] == '/') continue;
        try path.append(arena, c);
    }
    var ps: []const u8 = path.items;
    for ([_][]const u8{ "/index.html", "/index.htm" }) |suffix| {
        if (ps.len >= suffix.len and std.ascii.eqlIgnoreCase(ps[ps.len - suffix.len ..], suffix)) {
            ps = ps[0 .. ps.len - suffix.len + 1];
            break;
        }
    }
    if (ps.len == 0) ps = "/";
    try out.appendSlice(arena, ps);
    // Query: drop tracking parameters and empty pieces, sort the rest.
    var params: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, p.query, '&');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const name = kv[0 .. std.mem.indexOfScalar(u8, kv, '=') orelse kv.len];
        if (isTracking(name)) continue;
        try params.append(arena, kv);
    }
    std.mem.sort([]const u8, params.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    for (params.items, 0..) |kv, i| {
        try out.append(arena, if (i == 0) '?' else '&');
        try out.appendSlice(arena, kv);
    }
    return out.items;
}

/// The comparison form of a canonical URL: `https`, no `www.`.
pub fn dedupeKey(arena: Allocator, canonical: []const u8) Allocator.Error![]const u8 {
    var s = canonical;
    if (std.mem.startsWith(u8, s, "http://")) s = s[7..] else if (std.mem.startsWith(u8, s, "https://")) s = s[8..] else return arena.dupe(u8, canonical);
    if (std.mem.startsWith(u8, s, "www.")) s = s[4..];
    return std.mem.concat(arena, u8, &.{ "https://", s });
}

/// A source id: the first 16 bytes of BLAKE3 over the dedupe key, as hex.
pub fn sourceId(key: []const u8) [32]u8 {
    var h: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(key, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

/// The host of a URL, lowercased, without `www.` (for folder names).
pub fn site(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const p = split(url) orelse return arena.dupe(u8, "unknown");
    var h = p.host;
    if (std.ascii.startsWithIgnoreCase(h, "www.")) h = h[4..];
    const out = try arena.alloc(u8, h.len);
    for (h, out) |c, *o| o.* = std.ascii.toLower(c);
    return out;
}

/// Whether `a` and `b` are on the same site (registrable host, roughly:
/// equal after dropping `www.`).
pub fn sameSite(a: []const u8, b: []const u8) bool {
    const pa = split(a) orelse return false;
    const pb = split(b) orelse return false;
    var ha = pa.host;
    var hb = pb.host;
    if (std.ascii.startsWithIgnoreCase(ha, "www.")) ha = ha[4..];
    if (std.ascii.startsWithIgnoreCase(hb, "www.")) hb = hb[4..];
    return std.ascii.eqlIgnoreCase(ha, hb);
}

/// `ref` resolved against `base` (absolute, scheme-relative, root-relative
/// or relative paths; enough for `<link rel=canonical>`).
pub fn resolve(arena: Allocator, base: []const u8, ref: []const u8) Allocator.Error![]const u8 {
    const r = std.mem.trim(u8, ref, " \t\r\n");
    if (split(r) != null) return arena.dupe(u8, r);
    const b = split(base) orelse return arena.dupe(u8, r);
    const scheme_end = std.mem.indexOf(u8, base, "://").? + 3;
    const auth_len = std.mem.indexOfAny(u8, base[scheme_end..], "/?#") orelse base.len - scheme_end;
    const origin = base[0 .. scheme_end + auth_len];
    if (std.mem.startsWith(u8, r, "//")) return std.mem.concat(arena, u8, &.{ b.scheme, ":", r });
    if (std.mem.startsWith(u8, r, "/")) return std.mem.concat(arena, u8, &.{ origin, r });
    const dir_end = (std.mem.lastIndexOfScalar(u8, b.path, '/') orelse 0) + 1;
    const dir = if (b.path.len == 0) "/" else b.path[0..dir_end];
    return std.mem.concat(arena, u8, &.{ origin, dir, r });
}
