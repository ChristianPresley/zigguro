//! The authorization-code grant with PKCE: the authorization URL, the token
//! endpoint requests (code exchange and refresh) and `TokenSet`.
//!
//! Secrets (codes, verifiers, tokens) are never logged; request bodies that
//! carry them are zeroed before they are freed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = @import("../http.zig");
const url = @import("../url.zig");

/// Opens `url` in the system browser. E01 injects the real one.
pub const OpenUrlFn = *const fn (ctx: ?*anyopaque, url: []const u8) anyerror!void;

pub const AuthRequest = struct {
    authorization_endpoint: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    scope: ?[]const u8,
    state: []const u8,
    code_challenge: []const u8,
    /// RFC 8707 resource indicator (the canonical MCP server URI).
    resource: []const u8,
    extra: []const [2][]const u8 = &.{},
};

/// The authorization endpoint with the request as its query (S256).
pub fn buildAuthorizationUrl(gpa: Allocator, r: AuthRequest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var ep = r.authorization_endpoint;
    if (std.mem.indexOfScalar(u8, ep, '#')) |h| ep = ep[0..h];
    try out.appendSlice(gpa, ep);
    if (std.mem.indexOfScalar(u8, ep, '?') == null) {
        try out.append(gpa, '?');
    } else if (out.items[out.items.len - 1] == '&') {
        out.items.len -= 1;
    }
    try url.appendForm(gpa, &out, &.{
        .{ "response_type", "code" },
        .{ "client_id", r.client_id },
        .{ "redirect_uri", r.redirect_uri },
        .{ "state", r.state },
        .{ "code_challenge", r.code_challenge },
        .{ "code_challenge_method", "S256" },
        .{ "resource", r.resource },
    });
    if (r.scope) |s| try url.appendForm(gpa, &out, &.{.{ "scope", s }});
    try url.appendForm(gpa, &out, r.extra);
    return out.toOwnedSlice(gpa);
}

/// Tokens from a token endpoint. Strings are owned by the allocator that
/// produced the set; free with `deinit`.
pub const TokenSet = struct {
    access_token: []const u8,
    token_type: []const u8,
    /// Unix seconds; null when the server sent no `expires_in`.
    expires_at: ?i64 = null,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,

    pub fn clone(self: TokenSet, gpa: Allocator) !TokenSet {
        var t: TokenSet = .{ .access_token = &.{}, .token_type = &.{}, .expires_at = self.expires_at };
        errdefer t.deinit(gpa);
        t.access_token = try gpa.dupe(u8, self.access_token);
        t.token_type = try gpa.dupe(u8, self.token_type);
        if (self.refresh_token) |s| t.refresh_token = try gpa.dupe(u8, s);
        if (self.scope) |s| t.scope = try gpa.dupe(u8, s);
        return t;
    }

    /// Zeroes and frees the secrets.
    pub fn deinit(self: TokenSet, gpa: Allocator) void {
        wipeFree(gpa, self.access_token);
        gpa.free(self.token_type);
        if (self.refresh_token) |s| wipeFree(gpa, s);
        if (self.scope) |s| gpa.free(s);
    }

    /// True when the access token expires within `skew_s` of `now_s`.
    pub fn expiresWithin(self: TokenSet, now_s: i64, skew_s: i64) bool {
        const at = self.expires_at orelse return false;
        return now_s + skew_s >= at;
    }
};

pub const CodeExchange = struct {
    code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
    client_id: []const u8,
    resource: []const u8,
};

pub const Error = error{ TokenRequestFailed, InvalidTokenResponse };

/// Redeems an authorization code (`grant_type=authorization_code`).
pub fn exchangeCode(client: *http.Client, gpa: Allocator, token_endpoint: []const u8, p: CodeExchange) !TokenSet {
    return tokenRequest(client, gpa, token_endpoint, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", p.code },
        .{ "redirect_uri", p.redirect_uri },
        .{ "client_id", p.client_id },
        .{ "code_verifier", p.code_verifier },
        .{ "resource", p.resource },
    });
}

pub const RefreshGrant = struct {
    refresh_token: []const u8,
    client_id: []const u8,
    resource: []const u8,
    scope: ?[]const u8 = null,
};

/// `grant_type=refresh_token`. A response without `refresh_token` keeps
/// the old one (no rotation).
pub fn refreshTokens(client: *http.Client, gpa: Allocator, token_endpoint: []const u8, p: RefreshGrant) !TokenSet {
    var pairs: [5][2][]const u8 = .{
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", p.refresh_token },
        .{ "client_id", p.client_id },
        .{ "resource", p.resource },
        .{ "scope", p.scope orelse "" },
    };
    var t = try tokenRequest(client, gpa, token_endpoint, pairs[0..if (p.scope != null) 5 else 4]);
    if (t.refresh_token == null) {
        t.refresh_token = gpa.dupe(u8, p.refresh_token) catch |err| {
            t.deinit(gpa);
            return err;
        };
    }
    return t;
}

fn tokenRequest(client: *http.Client, gpa: Allocator, endpoint: []const u8, pairs: []const [2][]const u8) !TokenSet {
    var body: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, body.allocatedSlice());
        body.deinit(gpa);
    }
    try url.appendForm(gpa, &body, pairs);
    var resp = try client.send(gpa, .{
        .method = .POST,
        .url = endpoint,
        .body = body.items,
        .retry = .never,
        .headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "accept", .value = "application/json" },
        },
    });
    defer {
        std.crypto.secureZero(u8, resp.body);
        resp.deinit(gpa);
    }
    if (resp.status.class() != .success) return error.TokenRequestFailed;
    const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(client.io).nanoseconds, std.time.ns_per_s));
    return parseTokenResponse(gpa, resp.body, now_s);
}

/// Parses an RFC 6749 section 5.1 response; `expires_at = now + expires_in`.
pub fn parseTokenResponse(gpa: Allocator, body: []const u8, now_s: i64) !TokenSet {
    const Wire = struct {
        access_token: []const u8,
        token_type: []const u8,
        expires_in: ?i64 = null,
        refresh_token: ?[]const u8 = null,
        scope: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Wire, gpa, body, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidTokenResponse;
    defer parsed.deinit();
    const w = parsed.value;
    if (w.access_token.len == 0) return error.InvalidTokenResponse;
    return (TokenSet{
        .access_token = w.access_token,
        .token_type = w.token_type,
        .expires_at = if (w.expires_in) |e| now_s + e else null,
        .refresh_token = w.refresh_token,
        .scope = w.scope,
    }).clone(gpa);
}

fn wipeFree(gpa: Allocator, s: []const u8) void {
    std.crypto.secureZero(u8, @constCast(s));
    gpa.free(s);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const zg_core = @import("zg_core");
const TestServer = @import("../test_server.zig").TestServer;

test "flow: authorization URL encoding" {
    const u = try buildAuthorizationUrl(testing.allocator, .{
        .authorization_endpoint = "https://as.example/authorize",
        .client_id = "https://app.example/client.json",
        .redirect_uri = "http://127.0.0.1:5000/callback",
        .scope = "files:read files:write",
        .state = "st",
        .code_challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        .resource = "https://mcp.example.com/mcp",
    });
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("https://as.example/authorize?response_type=code" ++
        "&client_id=https%3A%2F%2Fapp.example%2Fclient.json" ++
        "&redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Fcallback&state=st" ++
        "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256" ++
        "&resource=https%3A%2F%2Fmcp.example.com%2Fmcp&scope=files%3Aread%20files%3Awrite", u);

    const v = try buildAuthorizationUrl(testing.allocator, .{
        .authorization_endpoint = "https://as.example/authorize?tenant=a#frag",
        .client_id = "c",
        .redirect_uri = "r",
        .scope = null,
        .state = "s",
        .code_challenge = "x",
        .resource = "https://r",
        .extra = &.{.{ "prompt", "consent" }},
    });
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("https://as.example/authorize?tenant=a&response_type=code&client_id=c" ++
        "&redirect_uri=r&state=s&code_challenge=x&code_challenge_method=S256&resource=https%3A%2F%2Fr&prompt=consent", v);
}

test "flow: token response parsing" {
    const t = try parseTokenResponse(testing.allocator,
        \\{"access_token":"at","token_type":"Bearer","expires_in":3600,"refresh_token":"rt","scope":"a b","extra":1}
    , 1000);
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("at", t.access_token);
    try testing.expectEqual(@as(?i64, 4600), t.expires_at);
    try testing.expectEqualStrings("rt", t.refresh_token.?);
    try testing.expect(t.expiresWithin(4541, 60));
    try testing.expect(!t.expiresWithin(4539, 60));
    try testing.expectError(error.InvalidTokenResponse, parseTokenResponse(testing.allocator, "{\"error\":\"invalid_grant\"}", 0));
    try testing.expectError(error.InvalidTokenResponse, parseTokenResponse(testing.allocator, "nope", 0));
}

test "flow: exchangeCode posts the PKCE grant" {
    const io = testing.io;
    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 2, .handler = struct {
        fn h(_: *TestServer, req: *std.http.Server.Request) !void {
            var bb: [512]u8 = undefined;
            const rd = try req.readerExpectContinue(&bb);
            var got: [512]u8 = undefined;
            const n = try rd.readSliceShort(&got);
            const want = "grant_type=authorization_code&code=c%2B1&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcallback" ++
                "&client_id=cid&code_verifier=ver&resource=https%3A%2F%2Fmcp.example%2Fmcp";
            if (std.mem.eql(u8, got[0..n], want)) {
                try req.respond("{\"access_token\":\"tok\",\"token_type\":\"Bearer\",\"expires_in\":60}", .{ .keep_alive = false });
            } else {
                try req.respond("{\"error\":\"invalid_request\"}", .{ .status = .bad_request, .keep_alive = false });
            }
        }
    }.h };
    try srv.start(io);
    defer srv.stop(io);
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const c = try http.Client.init(&rt, .{ .proxy = .none, .environ_map = &env });
    defer c.deinit();
    var ub: [64]u8 = undefined;
    const ep = srv.url(&ub, "/token");
    const p: CodeExchange = .{ .code = "c+1", .code_verifier = "ver", .redirect_uri = "http://127.0.0.1:9/callback", .client_id = "cid", .resource = "https://mcp.example/mcp" };
    const t = try exchangeCode(c, testing.allocator, ep, p);
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("tok", t.access_token);
    try testing.expect(t.expires_at != null);
    var bad = p;
    bad.code_verifier = "other";
    try testing.expectError(error.TokenRequestFailed, exchangeCode(c, testing.allocator, ep, bad));
}
