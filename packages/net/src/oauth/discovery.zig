//! Authorization discovery for MCP servers and other protected resources:
//! the `WWW-Authenticate` challenge, RFC 9728 protected resource metadata,
//! RFC 8414 / OpenID Connect authorization server metadata, scope selection
//! and RFC 9207 `iss` validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("../http.zig");

pub const ProtectedResourceMetadata = struct {
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: ?[]const []const u8 = null,
};

pub const AuthServerMetadata = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8 = null,
    scopes_supported: ?[]const []const u8 = null,
    code_challenge_methods_supported: ?[]const []const u8 = null,
    authorization_response_iss_parameter_supported: bool = false,
    client_id_metadata_document_supported: bool = false,
};

pub const Error = error{
    InvalidUrl,
    InsecureUrl,
    MetadataNotFound,
    MetadataFetchFailed,
    InvalidMetadata,
    ResourceMismatch,
    NoAuthorizationServer,
    IssuerMismatch,
    PkceUnsupported,
};

/// The Bearer challenge's parameters. Values are slices of the header;
/// quoted values are returned without their quotes (escapes kept).
pub const Challenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    err: ?[]const u8 = null,
};

/// Finds the `Bearer` challenge in a `WWW-Authenticate` value (RFC 9110
/// section 11.6.1); null when there is none.
pub fn parseWwwAuthenticate(header: []const u8) ?Challenge {
    var ch: Challenge = .{};
    var in_bearer = false;
    var found = false;
    var i: usize = 0;
    const n = header.len;
    while (i < n) {
        while (i < n and (header[i] == ' ' or header[i] == '\t' or header[i] == ',')) i += 1;
        if (i >= n) break;
        const start = i;
        while (i < n and isTchar(header[i])) i += 1;
        const tok = header[start..i];
        if (tok.len == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and (header[j] == ' ' or header[j] == '\t')) j += 1;
        if (j < n and header[j] == '=') {
            j += 1;
            while (j < n and (header[j] == ' ' or header[j] == '\t')) j += 1;
            var value: []const u8 = undefined;
            if (j < n and header[j] == '"') {
                j += 1;
                const vs = j;
                while (j < n and header[j] != '"') j += if (header[j] == '\\') 2 else 1;
                value = header[vs..@min(j, n)];
                j = @min(j + 1, n);
            } else {
                const vs = j;
                while (j < n and header[j] != ',' and header[j] != ' ' and header[j] != '\t') j += 1;
                value = header[vs..j];
            }
            i = j;
            if (!in_bearer) continue;
            if (std.ascii.eqlIgnoreCase(tok, "resource_metadata")) {
                ch.resource_metadata = value;
            } else if (std.ascii.eqlIgnoreCase(tok, "scope")) {
                ch.scope = value;
            } else if (std.ascii.eqlIgnoreCase(tok, "error")) {
                ch.err = value;
            }
        } else {
            if (found and in_bearer) break;
            in_bearer = std.ascii.eqlIgnoreCase(tok, "Bearer");
            found = found or in_bearer;
            i = j;
        }
    }
    return if (found) ch else null;
}

fn isTchar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

/// Up to three candidate metadata URLs, owned.
pub const UrlList = struct {
    items: [3][]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const UrlList) []const []u8 {
        return self.items[0..self.len];
    }

    pub fn deinit(self: *const UrlList, gpa: Allocator) void {
        for (self.slice()) |u| gpa.free(u);
    }

    fn add(self: *UrlList, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
        self.items[self.len] = try std.fmt.allocPrint(gpa, fmt, args);
        self.len += 1;
    }
};

const Split = struct { origin: []const u8, path: []const u8, rest: []const u8 };

/// `scheme://authority`, the path without trailing slashes, and any
/// `?query#fragment` remainder.
fn split(u: []const u8) !Split {
    const se = std.mem.indexOf(u8, u, "://") orelse return error.InvalidUrl;
    if (se == 0) return error.InvalidUrl;
    const a = se + 3;
    const pe = std.mem.indexOfAnyPos(u8, u, a, "/?#") orelse u.len;
    if (pe == a) return error.InvalidUrl;
    const re = std.mem.indexOfAnyPos(u8, u, pe, "?#") orelse u.len;
    var path = u[pe..re];
    while (path.len > 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    return .{ .origin = u[0..pe], .path = path, .rest = u[re..] };
}

/// RFC 9728 section 3.1: the well-known string inserted between host and
/// path, then the root well-known URL (MCP fallback order).
pub fn protectedResourceMetadataUrls(gpa: Allocator, resource: []const u8) !UrlList {
    const s = try split(resource);
    var l: UrlList = .{};
    errdefer l.deinit(gpa);
    const wk = "/.well-known/oauth-protected-resource";
    if (s.path.len > 0) try l.add(gpa, "{s}" ++ wk ++ "{s}", .{ s.origin, s.path });
    try l.add(gpa, "{s}" ++ wk, .{s.origin});
    return l;
}

/// RFC 8414 section 3.1 path insertion, then OpenID Connect discovery with
/// path insertion and path appending (the MCP priority order).
pub fn authServerMetadataUrls(gpa: Allocator, issuer: []const u8) !UrlList {
    const s = try split(issuer);
    if (s.rest.len > 0) return error.InvalidUrl;
    var l: UrlList = .{};
    errdefer l.deinit(gpa);
    try l.add(gpa, "{s}/.well-known/oauth-authorization-server{s}", .{ s.origin, s.path });
    try l.add(gpa, "{s}/.well-known/openid-configuration{s}", .{ s.origin, s.path });
    if (s.path.len > 0) try l.add(gpa, "{s}{s}/.well-known/openid-configuration", .{ s.origin, s.path });
    return l;
}

/// The canonical resource URI (MCP / RFC 8707): lowercase scheme and host,
/// no fragment, no trailing slash. Owned.
pub fn canonicalResource(gpa: Allocator, u: []const u8) ![]u8 {
    const s = try split(u);
    const out = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ s.origin, s.path, s.rest[0 .. std.mem.indexOfScalar(u8, s.rest, '#') orelse s.rest.len] });
    const se = std.mem.indexOf(u8, out, "://").?;
    const at = std.mem.indexOfScalarPos(u8, out, se + 3, '@');
    const host_start = if (at) |p| if (p < s.origin.len) p + 1 else se + 3 else se + 3;
    for (out[0..se]) |*c| c.* = std.ascii.toLower(c.*);
    for (out[host_start..s.origin.len]) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

pub fn resourceMatches(gpa: Allocator, a: []const u8, b: []const u8) !bool {
    const ca = canonicalResource(gpa, a) catch return false;
    defer gpa.free(ca);
    const cb = canonicalResource(gpa, b) catch return false;
    defer gpa.free(cb);
    return std.mem.eql(u8, ca, cb);
}

/// HTTPS, or plain HTTP to a loopback host (local development servers).
pub fn requireSecure(u: []const u8) !void {
    if (std.ascii.startsWithIgnoreCase(u, "https://")) return;
    if (!std.ascii.startsWithIgnoreCase(u, "http://")) return error.InsecureUrl;
    const s = split(u) catch return error.InsecureUrl;
    var host = s.origin["http://".len..];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |p| host = host[p + 1 ..];
    if (std.mem.startsWith(u8, host, "[::1]")) return;
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |p| host = host[0..p];
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return;
    if (std.Io.net.Ip4Address.parse(host, 0)) |a| {
        if (a.bytes[0] == 127) return;
    } else |_| {}
    return error.InsecureUrl;
}

pub fn validateProtectedResource(gpa: Allocator, m: ProtectedResourceMetadata, resource: []const u8) !void {
    if (!try resourceMatches(gpa, m.resource, resource)) return error.ResourceMismatch;
    if (m.authorization_servers.len == 0) return error.NoAuthorizationServer;
}

/// RFC 8414 section 3.3 issuer identity and the MCP PKCE rule: `S256` must
/// be advertised; an absent list is a refusal.
pub fn validateAuthServer(m: AuthServerMetadata, issuer: []const u8) !void {
    if (!std.mem.eql(u8, m.issuer, issuer)) return error.IssuerMismatch;
    const methods = m.code_challenge_methods_supported orelse return error.PkceUnsupported;
    for (methods) |x| {
        if (std.mem.eql(u8, x, "S256")) break;
    } else return error.PkceUnsupported;
    try requireSecure(m.authorization_endpoint);
    try requireSecure(m.token_endpoint);
    if (m.registration_endpoint) |r| try requireSecure(r);
}

/// Fetches the resource's metadata from `hint` (the challenge's
/// `resource_metadata`) or the well-known URLs, and checks that it
/// describes `resource_url`.
pub fn fetchProtectedResourceMetadata(c: *http.Client, gpa: Allocator, resource_url: []const u8, hint: ?[]const u8) !std.json.Parsed(ProtectedResourceMetadata) {
    var l = try protectedResourceMetadataUrls(gpa, resource_url);
    defer l.deinit(gpa);
    if (hint) |h| {
        if (fetchMetadata(ProtectedResourceMetadata, c, gpa, h)) |p| {
            errdefer p.deinit();
            try validateProtectedResource(gpa, p.value, resource_url);
            return p;
        } else |err| if (err != error.MetadataNotFound) return err;
    }
    for (l.slice()) |u| {
        const p = fetchMetadata(ProtectedResourceMetadata, c, gpa, u) catch |err| switch (err) {
            error.MetadataNotFound => continue,
            else => return err,
        };
        errdefer p.deinit();
        try validateProtectedResource(gpa, p.value, resource_url);
        return p;
    }
    return error.MetadataNotFound;
}

/// Fetches and validates `issuer`'s metadata, trying each discovery URL.
pub fn fetchAuthServerMetadata(c: *http.Client, gpa: Allocator, issuer: []const u8) !std.json.Parsed(AuthServerMetadata) {
    try requireSecure(issuer);
    var l = try authServerMetadataUrls(gpa, issuer);
    defer l.deinit(gpa);
    for (l.slice()) |u| {
        const p = fetchMetadata(AuthServerMetadata, c, gpa, u) catch |err| switch (err) {
            error.MetadataNotFound => continue,
            else => return err,
        };
        errdefer p.deinit();
        try validateAuthServer(p.value, issuer);
        return p;
    }
    return error.MetadataNotFound;
}

fn fetchMetadata(comptime T: type, c: *http.Client, gpa: Allocator, u: []const u8) !std.json.Parsed(T) {
    try requireSecure(u);
    var r = c.send(gpa, .{ .url = u, .headers = &.{.{ .name = "accept", .value = "application/json" }} }) catch
        return error.MetadataFetchFailed;
    defer r.deinit(gpa);
    switch (r.status.class()) {
        .success => {},
        .client_error => return error.MetadataNotFound,
        else => return error.MetadataFetchFailed,
    }
    return std.json.parseFromSlice(T, gpa, r.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        error.InvalidMetadata;
}

/// The scope to request: the challenge's, else the resource's
/// `scopes_supported`, united with `previous` (re-authorization keeps what
/// was granted). Owned; null when there is nothing to ask for.
pub fn selectScope(gpa: Allocator, challenge_scope: ?[]const u8, scopes_supported: ?[]const []const u8, previous: ?[]const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (previous) |p| try addScopes(gpa, &out, p);
    if (challenge_scope) |s| {
        try addScopes(gpa, &out, s);
    } else if (scopes_supported) |list| {
        for (list) |s| try addScopes(gpa, &out, s);
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

fn addScopes(gpa: Allocator, out: *std.ArrayList(u8), scopes: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, scopes, " \t");
    while (it.next()) |s| {
        var have = std.mem.tokenizeScalar(u8, out.items, ' ');
        const dup = while (have.next()) |h| {
            if (std.mem.eql(u8, h, s)) break true;
        } else false;
        if (dup) continue;
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, s);
    }
}

/// RFC 9207 as tabulated by MCP: a present `iss` must equal the recorded
/// issuer byte for byte; an absent one is fatal only when the server
/// advertises `authorization_response_iss_parameter_supported`.
pub fn validateIss(iss_supported: bool, expected: []const u8, got: ?[]const u8) error{IssuerMismatch}!void {
    if (got) |g| {
        if (!std.mem.eql(u8, g, expected)) return error.IssuerMismatch;
    } else if (iss_supported) return error.IssuerMismatch;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "discovery: WWW-Authenticate parsing" {
    const c = parseWwwAuthenticate("Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", scope=\"files:read\"").?;
    try testing.expectEqualStrings("https://mcp.example.com/.well-known/oauth-protected-resource", c.resource_metadata.?);
    try testing.expectEqualStrings("files:read", c.scope.?);

    const d = parseWwwAuthenticate("Basic realm=\"a, b\", bearer error=invalid_token, scope=\"a b,c\" , Other x=1").?;
    try testing.expectEqualStrings("invalid_token", d.err.?);
    try testing.expectEqualStrings("a b,c", d.scope.?);
    try testing.expectEqual(@as(?[]const u8, null), d.resource_metadata);

    const e = parseWwwAuthenticate("BEARER").?;
    try testing.expectEqual(@as(?[]const u8, null), e.scope);
    try testing.expectEqual(@as(?Challenge, null), parseWwwAuthenticate("Basic realm=\"x\""));
    try testing.expectEqual(@as(?Challenge, null), parseWwwAuthenticate(""));
    _ = parseWwwAuthenticate("Bearer scope=\"unterminated\\");
}

test "discovery: well-known URL construction" {
    const gpa = testing.allocator;
    const Case = struct { in: []const u8, want: []const []const u8 };
    const prm = [_]Case{
        .{ .in = "https://resource.example.com/resource1", .want = &.{
            "https://resource.example.com/.well-known/oauth-protected-resource/resource1",
            "https://resource.example.com/.well-known/oauth-protected-resource",
        } },
        .{ .in = "https://resource.example.com", .want = &.{"https://resource.example.com/.well-known/oauth-protected-resource"} },
        .{ .in = "https://resource.example.com/", .want = &.{"https://resource.example.com/.well-known/oauth-protected-resource"} },
        .{ .in = "https://mcp.example.com:8443/a/mcp?x=1", .want = &.{
            "https://mcp.example.com:8443/.well-known/oauth-protected-resource/a/mcp",
            "https://mcp.example.com:8443/.well-known/oauth-protected-resource",
        } },
    };
    for (prm) |c| {
        const l = try protectedResourceMetadataUrls(gpa, c.in);
        defer l.deinit(gpa);
        try testing.expectEqual(c.want.len, l.len);
        for (c.want, l.slice()) |w, g| try testing.expectEqualStrings(w, g);
    }
    const as = [_]Case{
        .{ .in = "https://example.com/issuer1", .want = &.{
            "https://example.com/.well-known/oauth-authorization-server/issuer1",
            "https://example.com/.well-known/openid-configuration/issuer1",
            "https://example.com/issuer1/.well-known/openid-configuration",
        } },
        .{ .in = "https://example.com", .want = &.{
            "https://example.com/.well-known/oauth-authorization-server",
            "https://example.com/.well-known/openid-configuration",
        } },
    };
    for (as) |c| {
        const l = try authServerMetadataUrls(gpa, c.in);
        defer l.deinit(gpa);
        try testing.expectEqual(c.want.len, l.len);
        for (c.want, l.slice()) |w, g| try testing.expectEqualStrings(w, g);
    }
    try testing.expectError(error.InvalidUrl, authServerMetadataUrls(gpa, "https://example.com/?q"));
    try testing.expectError(error.InvalidUrl, authServerMetadataUrls(gpa, "example.com"));
}

test "discovery: canonical resource and secure URLs" {
    const gpa = testing.allocator;
    const c = try canonicalResource(gpa, "HTTPS://MCP.Example.com/Server/#frag");
    defer gpa.free(c);
    try testing.expectEqualStrings("https://mcp.example.com/Server", c);
    try testing.expect(try resourceMatches(gpa, "https://mcp.example.com/", "https://MCP.example.com"));
    try testing.expect(!try resourceMatches(gpa, "https://mcp.example.com/a", "https://mcp.example.com/b"));
    try requireSecure("https://as.example/token");
    try requireSecure("http://127.0.0.1:8080/token");
    try requireSecure("http://localhost/x");
    try requireSecure("http://[::1]:9/x");
    try testing.expectError(error.InsecureUrl, requireSecure("http://as.example/token"));
    try testing.expectError(error.InsecureUrl, requireSecure("http://127.0.0.1.evil.example/x"));
    try testing.expectError(error.InsecureUrl, requireSecure("ftp://x/y"));
}

test "discovery: issuer mismatch and missing S256 rejected" {
    const good: AuthServerMetadata = .{
        .issuer = "https://as.example/t",
        .authorization_endpoint = "https://as.example/authorize",
        .token_endpoint = "https://as.example/token",
        .code_challenge_methods_supported = &.{ "plain", "S256" },
    };
    try validateAuthServer(good, "https://as.example/t");
    try testing.expectError(error.IssuerMismatch, validateAuthServer(good, "https://as.example/t/"));
    var no_list = good;
    no_list.code_challenge_methods_supported = null;
    try testing.expectError(error.PkceUnsupported, validateAuthServer(no_list, good.issuer));
    var plain_only = good;
    plain_only.code_challenge_methods_supported = &.{"plain"};
    try testing.expectError(error.PkceUnsupported, validateAuthServer(plain_only, good.issuer));
    var insecure = good;
    insecure.token_endpoint = "http://as.example/token";
    try testing.expectError(error.InsecureUrl, validateAuthServer(insecure, good.issuer));

    const prm: ProtectedResourceMetadata = .{ .resource = "https://mcp.example.com/mcp", .authorization_servers = &.{"https://as.example/t"} };
    try validateProtectedResource(testing.allocator, prm, "https://mcp.example.com/mcp/");
    try testing.expectError(error.ResourceMismatch, validateProtectedResource(testing.allocator, prm, "https://other.example.com/mcp"));
    try testing.expectError(error.NoAuthorizationServer, validateProtectedResource(testing.allocator, .{ .resource = prm.resource, .authorization_servers = &.{} }, prm.resource));
}

test "discovery: iss validation table" {
    const iss = "https://as.example";
    try validateIss(true, iss, iss);
    try testing.expectError(error.IssuerMismatch, validateIss(true, iss, "https://as.example/"));
    try testing.expectError(error.IssuerMismatch, validateIss(true, iss, null));
    try validateIss(false, iss, iss);
    try testing.expectError(error.IssuerMismatch, validateIss(false, iss, "https://evil.example"));
    try validateIss(false, iss, null);
}

test "discovery: scope selection" {
    const gpa = testing.allocator;
    const a = (try selectScope(gpa, "files:read", &.{ "x", "y" }, null)).?;
    defer gpa.free(a);
    try testing.expectEqualStrings("files:read", a);
    const b = (try selectScope(gpa, null, &.{ "x", "y" }, null)).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("x y", b);
    const c = (try selectScope(gpa, "files:write files:read", null, "files:read admin")).?;
    defer gpa.free(c);
    try testing.expectEqualStrings("files:read admin files:write", c);
    try testing.expectEqual(@as(?[]u8, null), try selectScope(gpa, null, null, null));
}
