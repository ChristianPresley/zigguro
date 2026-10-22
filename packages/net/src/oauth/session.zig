//! The high-level OAuth 2.1 client used by MCP (E11) and OAuth-protected
//! providers: from a 401 challenge to a stored token, refresh, and a `send`
//! that attaches the bearer token and recovers from a 401 once.
//!
//! Credentials are keyed by issuer: tokens live in the `TokenStore` under
//! (issuer, resource) and dynamically registered client ids are kept per
//! issuer, so neither is ever presented to another authorization server.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const http = @import("../http.zig");
const flow = @import("flow.zig");
const discovery = @import("discovery.zig");
const pkce = @import("pkce.zig");
const Loopback = @import("loopback.zig").Loopback;
const TokenStore = @import("token_store.zig").TokenStore;
const TokenSet = flow.TokenSet;

/// How the client identifies itself. Strings are borrowed and must outlive
/// the session.
pub const ClientRegistration = union(enum) {
    /// A client id issued out of band; used with every server.
    preregistered: []const u8,
    /// A Client ID Metadata Document URL, used where the server advertises
    /// `client_id_metadata_document_supported`; dynamic registration
    /// (as "zigguro") elsewhere.
    metadata_document_url: []const u8,
    /// RFC 7591 dynamic registration (deprecated by MCP, still supported).
    dynamic: struct { client_name: []const u8 },
};

pub const Error = error{
    NoChallenge,
    AuthorizationDenied,
    MissingCode,
    RegistrationUnsupported,
    RegistrationFailed,
    NotRegistered,
    NoRefreshToken,
    UnknownResource,
};

/// Seconds before expiry at which `bearer` refreshes.
pub const expiry_skew_s = 60;

pub const Session = struct {
    c: *http.Client,
    store: TokenStore,
    open_url: flow.OpenUrlFn,
    open_ctx: ?*anyopaque,
    client: ClientRegistration,
    /// How long `authorize` waits for the browser redirect.
    callback_timeout: Io.Duration = .fromSeconds(300),
    mutex: Io.Mutex = .init,
    /// Canonical resource -> issuer (both owned).
    issuers: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Issuer -> dynamically registered client id (both owned).
    registered: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(c: *http.Client, store: TokenStore, open_url: flow.OpenUrlFn, open_ctx: ?*anyopaque, client: ClientRegistration) Session {
        return .{ .c = c, .store = store, .open_url = open_url, .open_ctx = open_ctx, .client = client };
    }

    pub fn deinit(self: *Session) void {
        inline for (.{ &self.issuers, &self.registered }) |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                self.c.gpa.free(e.key_ptr.*);
                self.c.gpa.free(e.value_ptr.*);
            }
            m.deinit(self.c.gpa);
        }
    }

    /// Records which issuer guards `resource` (restoring state persisted
    /// by the caller; `authorize` records it too).
    pub fn remember(self: *Session, resource: []const u8, issuer: []const u8) !void {
        const key = try discovery.canonicalResource(self.c.gpa, resource);
        defer self.c.gpa.free(key);
        self.mutex.lockUncancelable(self.c.io);
        defer self.mutex.unlock(self.c.io);
        try putOwned(self.c.gpa, &self.issuers, key, issuer);
    }

    /// A copy of the issuer recorded for `resource`, or null.
    pub fn issuerFor(self: *Session, gpa: Allocator, resource: []const u8) !?[]u8 {
        const key = try discovery.canonicalResource(gpa, resource);
        defer gpa.free(key);
        self.mutex.lockUncancelable(self.c.io);
        defer self.mutex.unlock(self.c.io);
        const v = self.issuers.get(key) orelse return null;
        return try gpa.dupe(u8, v);
    }

    /// The full flow from a 401's `WWW-Authenticate` value to a stored
    /// token set (returned, owned by `gpa`).
    pub fn authorize(self: *Session, gpa: Allocator, resource_in: []const u8, challenge: []const u8) !TokenSet {
        const io = self.c.io;
        const resource = try discovery.canonicalResource(gpa, resource_in);
        defer gpa.free(resource);
        const ch = discovery.parseWwwAuthenticate(challenge) orelse discovery.Challenge{};

        const prm = try discovery.fetchProtectedResourceMetadata(self.c, gpa, resource, ch.resource_metadata);
        defer prm.deinit();
        const issuer = prm.value.authorization_servers[0];
        const as = try discovery.fetchAuthServerMetadata(self.c, gpa, issuer);
        defer as.deinit();
        const meta = as.value;

        const previous = try self.store.load(gpa, issuer, resource);
        defer if (previous) |p| p.deinit(gpa);
        const scope = try discovery.selectScope(gpa, ch.scope, prm.value.scopes_supported, if (previous) |p| p.scope else null);
        defer if (scope) |s| gpa.free(s);

        const client_id = try self.clientId(gpa, meta, true);
        defer gpa.free(client_id);

        var pk = try pkce.Pkce.generate(io);
        defer pk.wipe();
        var state_buf: [pkce.encoded_len]u8 = undefined;
        const state = try pkce.randomState(io, &state_buf);

        var lb = try Loopback.listen(io);
        var lb_open = true;
        defer if (lb_open) lb.close();
        var rb: [64]u8 = undefined;
        const redirect_uri = lb.redirectUri(&rb);

        const auth_url = try flow.buildAuthorizationUrl(gpa, .{
            .authorization_endpoint = meta.authorization_endpoint,
            .client_id = client_id,
            .redirect_uri = redirect_uri,
            .scope = scope,
            .state = state,
            .code_challenge = &pk.challenge,
            .resource = resource,
        });
        defer gpa.free(auth_url);
        try self.open_url(self.open_ctx, auth_url);

        const cb = try lb.awaitCallback(gpa, state, .after(io, self.callback_timeout));
        defer cb.deinit(gpa);
        lb.close();
        lb_open = false;
        // On a mismatch the error fields are neither used nor shown.
        try discovery.validateIss(meta.authorization_response_iss_parameter_supported, meta.issuer, cb.iss);
        if (cb.err != null) return error.AuthorizationDenied;
        const code = cb.code orelse return error.MissingCode;

        const tokens = try flow.exchangeCode(self.c, gpa, meta.token_endpoint, .{
            .code = code,
            .code_verifier = &pk.verifier,
            .redirect_uri = redirect_uri,
            .client_id = client_id,
            .resource = resource,
        });
        errdefer tokens.deinit(gpa);
        try self.store.save(issuer, resource, tokens);
        try self.remember(resource, issuer);
        return tokens;
    }

    /// Exchanges the stored refresh token for a new set, stores it (with
    /// the rotated refresh token when the server sent one) and returns it.
    pub fn refresh(self: *Session, gpa: Allocator, issuer: []const u8, resource_in: []const u8) !TokenSet {
        const resource = try discovery.canonicalResource(gpa, resource_in);
        defer gpa.free(resource);
        const old = (try self.store.load(gpa, issuer, resource)) orelse return error.NoRefreshToken;
        defer old.deinit(gpa);
        const rt = old.refresh_token orelse return error.NoRefreshToken;
        const as = try discovery.fetchAuthServerMetadata(self.c, gpa, issuer);
        defer as.deinit();
        const client_id = try self.clientId(gpa, as.value, false);
        defer gpa.free(client_id);
        const tokens = try flow.refreshTokens(self.c, gpa, as.value.token_endpoint, .{
            .refresh_token = rt,
            .client_id = client_id,
            .resource = resource,
        });
        errdefer tokens.deinit(gpa);
        var stored = tokens;
        if (stored.scope == null) stored.scope = old.scope;
        try self.store.save(issuer, resource, stored);
        return tokens;
    }

    /// The stored access token for `resource` (owned), refreshed first when
    /// it expires within a minute; null when there is none or the refresh
    /// fails.
    pub fn bearer(self: *Session, gpa: Allocator, resource: []const u8) !?[]u8 {
        const issuer = (try self.issuerFor(gpa, resource)) orelse return null;
        defer gpa.free(issuer);
        const t = (try self.store.load(gpa, issuer, resource)) orelse return null;
        defer t.deinit(gpa);
        const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(self.c.io).nanoseconds, std.time.ns_per_s));
        if (!t.expiresWithin(now_s, expiry_skew_s)) return try gpa.dupe(u8, t.access_token);
        if (t.refresh_token == null) return null;
        const fresh = self.refresh(gpa, issuer, resource) catch return null;
        defer fresh.deinit(gpa);
        return try gpa.dupe(u8, fresh.access_token);
    }

    /// Sends `req` with the bearer token for `resource`. On a 401 it
    /// refreshes once and retries, then runs `authorize` and retries once
    /// more.
    pub fn send(self: *Session, gpa: Allocator, resource: []const u8, req: http.Request) !http.Response {
        const tok = try self.bearer(gpa, resource);
        defer if (tok) |t| wipeFree(gpa, t);
        var resp = try self.sendWith(gpa, req, tok);
        if (resp.status != .unauthorized) return resp;

        if (tok != null) {
            if (try self.issuerFor(gpa, resource)) |issuer| {
                defer gpa.free(issuer);
                if (self.refresh(gpa, issuer, resource)) |fresh| {
                    defer fresh.deinit(gpa);
                    resp.deinit(gpa);
                    resp = try self.sendWith(gpa, req, fresh.access_token);
                    if (resp.status != .unauthorized) return resp;
                } else |_| {}
            }
        }

        const challenge = try gpa.dupe(u8, resp.headers.get("www-authenticate") orelse "Bearer");
        defer gpa.free(challenge);
        resp.deinit(gpa);
        const fresh = try self.authorize(gpa, resource, challenge);
        defer fresh.deinit(gpa);
        return self.sendWith(gpa, req, fresh.access_token);
    }

    fn sendWith(self: *Session, gpa: Allocator, req: http.Request, token: ?[]const u8) !http.Response {
        const t = token orelse return self.c.send(gpa, req);
        const value = try std.fmt.allocPrint(gpa, "Bearer {s}", .{t});
        defer wipeFree(gpa, value);
        const headers = try gpa.alloc(std.http.Header, req.headers.len + 1);
        defer gpa.free(headers);
        var n: usize = 0;
        for (req.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) continue;
            headers[n] = h;
            n += 1;
        }
        headers[n] = .{ .name = "authorization", .value = value };
        var r = req;
        r.headers = headers[0 .. n + 1];
        return self.c.send(gpa, r);
    }

    /// The client id to present to `meta.issuer` (owned by `gpa`).
    fn clientId(self: *Session, gpa: Allocator, meta: discovery.AuthServerMetadata, allow_register: bool) ![]u8 {
        switch (self.client) {
            .preregistered => |id| return gpa.dupe(u8, id),
            .metadata_document_url => |u| if (meta.client_id_metadata_document_supported) return gpa.dupe(u8, u),
            .dynamic => {},
        }
        {
            self.mutex.lockUncancelable(self.c.io);
            defer self.mutex.unlock(self.c.io);
            if (self.registered.get(meta.issuer)) |id| return gpa.dupe(u8, id);
        }
        if (!allow_register) return error.NotRegistered;
        const name = switch (self.client) {
            .dynamic => |d| d.client_name,
            else => "zigguro",
        };
        const id = try register(self.c, gpa, meta, name);
        errdefer gpa.free(id);
        self.mutex.lockUncancelable(self.c.io);
        defer self.mutex.unlock(self.c.io);
        try putOwned(self.c.gpa, &self.registered, meta.issuer, id);
        return id;
    }
};

/// RFC 7591 registration of a native public client. The loopback redirect
/// omits the port: RFC 8252 section 7.3 requires servers to accept any.
fn register(c: *http.Client, gpa: Allocator, meta: discovery.AuthServerMetadata, client_name: []const u8) ![]u8 {
    const endpoint = meta.registration_endpoint orelse return error.RegistrationUnsupported;
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .client_name = client_name,
        .application_type = "native",
        .redirect_uris = &[_][]const u8{"http://127.0.0.1/callback"},
        .grant_types = &[_][]const u8{ "authorization_code", "refresh_token" },
        .response_types = &[_][]const u8{"code"},
        .token_endpoint_auth_method = "none",
    }, .{});
    defer gpa.free(body);
    var resp = try c.send(gpa, .{
        .method = .POST,
        .url = endpoint,
        .body = body,
        .retry = .never,
        .headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
        },
    });
    defer resp.deinit(gpa);
    if (resp.status.class() != .success) return error.RegistrationFailed;
    const parsed = std.json.parseFromSlice(struct { client_id: []const u8 }, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch
        return error.RegistrationFailed;
    defer parsed.deinit();
    return gpa.dupe(u8, parsed.value.client_id);
}

fn putOwned(gpa: Allocator, m: *std.StringHashMapUnmanaged([]u8), key: []const u8, value: []const u8) !void {
    const v = try gpa.dupe(u8, value);
    errdefer gpa.free(v);
    const gop = try m.getOrPut(gpa, key);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, key) catch |err| {
            m.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = v;
}

fn wipeFree(gpa: Allocator, s: []const u8) void {
    std.crypto.secureZero(u8, @constCast(s));
    gpa.free(s);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const url = @import("../url.zig");
const TestServer = @import("../test_server.zig").TestServer;
const MemoryTokenStore = @import("token_store.zig").MemoryTokenStore;

/// A fake MCP server (resource at /mcp) and authorization server (issuer
/// at /as) on one loopback port.
const Fake = struct {
    port: u16 = 0,
    wrong_iss: bool = false,
    advertise_iss: bool = true,
    cimd: bool = false,
    valid_token: []const u8 = "",
    challenge: [43]u8 = undefined,
    auth_resource: [128]u8 = undefined,
    auth_resource_len: usize = 0,
    auth_scope: [128]u8 = undefined,
    auth_scope_len: usize = 0,
    auth_client: [128]u8 = undefined,
    auth_client_len: usize = 0,
    token_calls: u32 = 0,
    refresh_calls: u32 = 0,
    registrations: u32 = 0,
    resource_hits: u32 = 0,

    fn issuer(self: *Fake, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/as", .{self.port}) catch unreachable;
    }

    fn handler(s: *TestServer, req: *std.http.Server.Request) anyerror!void {
        const f: *Fake = @ptrCast(@alignCast(s.ctx.?));
        const gpa = testing.allocator;
        const target = req.head.target;
        const q = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. q orelse target.len];
        const query = if (q) |i| target[i + 1 ..] else "";
        var ib: [64]u8 = undefined;
        const iss = f.issuer(&ib);
        var body_buf: [2048]u8 = undefined;
        const json: std.http.Header = .{ .name = "content-type", .value = "application/json" };

        if (std.mem.eql(u8, path, "/mcp")) {
            f.resource_hits += 1;
            var authorized = false;
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization") and h.value.len > 7 and
                    std.mem.eql(u8, h.value[7..], f.valid_token) and f.valid_token.len > 0) authorized = true;
            }
            if (authorized) return req.respond("hello", .{ .keep_alive = false });
            const wa = try std.fmt.bufPrint(&body_buf, "Bearer resource_metadata=\"http://127.0.0.1:{d}/.well-known/oauth-protected-resource/mcp\", scope=\"files:read\"", .{f.port});
            return req.respond("", .{ .status = .unauthorized, .keep_alive = false, .extra_headers = &.{.{ .name = "www-authenticate", .value = wa }} });
        }
        if (std.mem.eql(u8, path, "/.well-known/oauth-protected-resource/mcp")) {
            const b = try std.fmt.bufPrint(&body_buf, "{{\"resource\":\"http://127.0.0.1:{d}/mcp\",\"authorization_servers\":[\"{s}\"],\"scopes_supported\":[\"files:read\",\"files:write\"]}}", .{ f.port, iss });
            return req.respond(b, .{ .keep_alive = false, .extra_headers = &.{json} });
        }
        if (std.mem.eql(u8, path, "/.well-known/oauth-authorization-server/as")) {
            const b = try std.fmt.bufPrint(&body_buf,
                \\{{"issuer":"{s}","authorization_endpoint":"{s}/authorize","token_endpoint":"{s}/token",
                \\"registration_endpoint":"{s}/register","code_challenge_methods_supported":["S256"],
                \\"authorization_response_iss_parameter_supported":{},"client_id_metadata_document_supported":{}}}
            , .{ iss, iss, iss, iss, f.advertise_iss, f.cimd });
            return req.respond(b, .{ .keep_alive = false, .extra_headers = &.{json} });
        }
        if (std.mem.eql(u8, path, "/as/authorize")) {
            const get = struct {
                fn get(qs: []const u8, name: []const u8) ![]u8 {
                    return (try url.queryParam(testing.allocator, qs, name)) orelse error.MissingParam;
                }
            }.get;
            const rt = try get(query, "response_type");
            defer gpa.free(rt);
            const method = try get(query, "code_challenge_method");
            defer gpa.free(method);
            if (!std.mem.eql(u8, rt, "code") or !std.mem.eql(u8, method, "S256")) return error.BadAuthorizeRequest;
            const ch = try get(query, "code_challenge");
            defer gpa.free(ch);
            if (ch.len != 43) return error.BadChallenge;
            @memcpy(&f.challenge, ch);
            inline for (.{ .{ "resource", &f.auth_resource, &f.auth_resource_len }, .{ "scope", &f.auth_scope, &f.auth_scope_len }, .{ "client_id", &f.auth_client, &f.auth_client_len } }) |e| {
                const v = try get(query, e[0]);
                defer gpa.free(v);
                @memcpy(e[1][0..v.len], v);
                e[2].* = v.len;
            }
            const redirect = try get(query, "redirect_uri");
            defer gpa.free(redirect);
            const state = try get(query, "state");
            defer gpa.free(state);
            var loc: std.ArrayList(u8) = .empty;
            defer loc.deinit(gpa);
            try loc.print(gpa, "{s}?", .{redirect});
            try url.appendForm(gpa, &loc, &.{ .{ "code", "code-1" }, .{ "state", state }, .{ "iss", if (f.wrong_iss) "http://evil.example" else iss } });
            if (f.wrong_iss) try url.appendForm(gpa, &loc, &.{ .{ "error", "access_denied" }, .{ "error_description", "click evil.example" } });
            return req.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = loc.items }} });
        }
        if (std.mem.eql(u8, path, "/as/register")) {
            f.registrations += 1;
            var rb: [1024]u8 = undefined;
            const rd = try req.readerExpectContinue(&rb);
            const n = try rd.readSliceShort(&body_buf);
            if (std.mem.indexOf(u8, body_buf[0..n], "\"application_type\":\"native\"") == null) return error.NotNative;
            return req.respond("{\"client_id\":\"dyn-1\"}", .{ .status = .created, .keep_alive = false, .extra_headers = &.{json} });
        }
        if (std.mem.eql(u8, path, "/as/token")) {
            f.token_calls += 1;
            var rb: [1024]u8 = undefined;
            const rd = try req.readerExpectContinue(&rb);
            const n = try rd.readSliceShort(&body_buf);
            const form = body_buf[0..n];
            const grant = (try url.queryParam(gpa, form, "grant_type")).?;
            defer gpa.free(grant);
            const res = (try url.queryParam(gpa, form, "resource")) orelse return error.NoResource;
            defer gpa.free(res);
            var want_res: [64]u8 = undefined;
            if (!std.mem.eql(u8, res, try std.fmt.bufPrint(&want_res, "http://127.0.0.1:{d}/mcp", .{f.port}))) return error.WrongResource;
            if (std.mem.eql(u8, grant, "authorization_code")) {
                const ver = (try url.queryParam(gpa, form, "code_verifier")).?;
                defer gpa.free(ver);
                const code = (try url.queryParam(gpa, form, "code")).?;
                defer gpa.free(code);
                if (ver.len != 43 or !std.mem.eql(u8, code, "code-1")) return error.BadGrant;
                const p = pkce.Pkce.fromVerifier(ver[0..43].*);
                if (!std.mem.eql(u8, &p.challenge, &f.challenge)) {
                    return req.respond("{\"error\":\"invalid_grant\"}", .{ .status = .bad_request, .keep_alive = false, .extra_headers = &.{json} });
                }
                f.valid_token = "at-1";
                return req.respond("{\"access_token\":\"at-1\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"rt-1\",\"scope\":\"files:read\"}", .{ .keep_alive = false, .extra_headers = &.{json} });
            }
            f.refresh_calls += 1;
            const rt = (try url.queryParam(gpa, form, "refresh_token")).?;
            defer gpa.free(rt);
            if (!std.mem.eql(u8, rt, "rt-1")) {
                return req.respond("{\"error\":\"invalid_grant\"}", .{ .status = .bad_request, .keep_alive = false, .extra_headers = &.{json} });
            }
            f.valid_token = "at-2";
            return req.respond("{\"access_token\":\"at-2\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"rt-2\"}", .{ .keep_alive = false, .extra_headers = &.{json} });
        }
        return req.respond("", .{ .status = .not_found, .keep_alive = false });
    }
};

/// Plays the browser: follows the authorization URL (and its redirect to
/// the loopback listener) from a concurrent task.
const Browser = struct {
    c: *http.Client,
    future: ?Io.Future(anyerror!void) = null,
    opened: u32 = 0,

    fn open(ctx: ?*anyopaque, u: []const u8) anyerror!void {
        const b: *Browser = @ptrCast(@alignCast(ctx.?));
        b.opened += 1;
        const copy = try testing.allocator.dupe(u8, u);
        b.future = try b.c.io.concurrent(visit, .{ b.c, copy });
    }

    fn visit(c: *http.Client, u: []u8) anyerror!void {
        defer testing.allocator.free(u);
        var r = try c.send(testing.allocator, .{ .url = u });
        r.deinit(testing.allocator);
    }

    fn finish(b: *Browser) !void {
        var f = b.future orelse return;
        b.future = null;
        try f.await(b.c.io);
    }
};

const Harness = struct {
    rt: zg_core.Runtime,
    env: std.process.Environ.Map,
    c: *http.Client,
    srv: TestServer,
    fake: Fake,
    mem: MemoryTokenStore,
    browser: Browser,

    fn init(h: *Harness) !void {
        h.rt.initTesting();
        h.env = .init(testing.allocator);
        h.c = try http.Client.init(&h.rt, .{ .proxy = .none, .environ_map = &h.env, .max_retries = 0 });
        h.fake = .{};
        h.srv = .{ .server = undefined, .port = 0, .max = 1000, .handler = Fake.handler, .ctx = &h.fake };
        try h.srv.start(testing.io);
        h.fake.port = h.srv.port;
        h.mem = .init(testing.allocator, testing.io);
        h.browser = .{ .c = h.c };
    }

    fn deinit(h: *Harness) void {
        h.browser.finish() catch {};
        h.mem.deinit();
        h.srv.stop(testing.io);
        h.c.deinit();
        h.env.deinit();
        _ = h.rt.deinit();
    }

    fn resource(h: *Harness, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/mcp", .{h.fake.port}) catch unreachable;
    }
};

test "session: 401 to token, then refresh once on a revoked token" {
    const gpa = testing.allocator;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var s = Session.init(h.c, h.mem.store(), Browser.open, &h.browser, .{ .preregistered = "app-1" });
    defer s.deinit();
    s.callback_timeout = .fromSeconds(10);
    var rb: [64]u8 = undefined;
    const res = h.resource(&rb);

    var r = try s.send(gpa, res, .{ .url = res });
    defer r.deinit(gpa);
    try h.browser.finish();
    try testing.expectEqualStrings("hello", r.body);
    try testing.expectEqual(@as(u32, 1), h.browser.opened);
    try testing.expectEqualStrings(res, h.fake.auth_resource[0..h.fake.auth_resource_len]);
    try testing.expectEqualStrings("files:read", h.fake.auth_scope[0..h.fake.auth_scope_len]);
    try testing.expectEqualStrings("app-1", h.fake.auth_client[0..h.fake.auth_client_len]);
    var ib: [64]u8 = undefined;
    const iss = h.fake.issuer(&ib);
    const stored = (try h.mem.store().load(gpa, iss, res)).?;
    defer stored.deinit(gpa);
    try testing.expectEqualStrings("at-1", stored.access_token);
    try testing.expectEqualStrings("rt-1", stored.refresh_token.?);
    try testing.expectEqual(@as(u32, 0), h.fake.registrations);

    // The server stops accepting at-1 before it expires: one refresh, one retry.
    h.fake.valid_token = "at-2";
    h.fake.resource_hits = 0;
    var r2 = try s.send(gpa, res, .{ .url = res });
    defer r2.deinit(gpa);
    try testing.expectEqualStrings("hello", r2.body);
    try testing.expectEqual(@as(u32, 1), h.fake.refresh_calls);
    try testing.expectEqual(@as(u32, 2), h.fake.resource_hits);
    try testing.expectEqual(@as(u32, 1), h.browser.opened);
    const rotated = (try h.mem.store().load(gpa, iss, res)).?;
    defer rotated.deinit(gpa);
    try testing.expectEqualStrings("rt-2", rotated.refresh_token.?);
    try testing.expectEqualStrings("files:read", rotated.scope.?);

    const b = (try s.bearer(gpa, res)).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("at-2", b);
}

test "session: iss mismatch is not redeemed" {
    const gpa = testing.allocator;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fake.wrong_iss = true;
    var s = Session.init(h.c, h.mem.store(), Browser.open, &h.browser, .{ .dynamic = .{ .client_name = "zigguro test" } });
    defer s.deinit();
    s.callback_timeout = .fromSeconds(10);
    var rb: [64]u8 = undefined;
    const res = h.resource(&rb);
    try testing.expectError(error.IssuerMismatch, s.send(gpa, res, .{ .url = res }));
    try h.browser.finish();
    try testing.expectEqual(@as(u32, 0), h.fake.token_calls);
    try testing.expectEqual(@as(u32, 1), h.fake.registrations);
    try testing.expectEqualStrings("dyn-1", h.fake.auth_client[0..h.fake.auth_client_len]);
    var ib: [64]u8 = undefined;
    try testing.expectEqual(@as(?TokenSet, null), try h.mem.store().load(gpa, h.fake.issuer(&ib), res));
}

test "session: client id metadata document preferred when supported" {
    const gpa = testing.allocator;
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.fake.cimd = true;
    var s = Session.init(h.c, h.mem.store(), Browser.open, &h.browser, .{ .metadata_document_url = "https://app.example/client.json" });
    defer s.deinit();
    s.callback_timeout = .fromSeconds(10);
    var rb: [64]u8 = undefined;
    const res = h.resource(&rb);
    var ch_buf: [160]u8 = undefined;
    const ch = try std.fmt.bufPrint(&ch_buf, "Bearer resource_metadata=\"http://127.0.0.1:{d}/.well-known/oauth-protected-resource/mcp\"", .{h.fake.port});
    const t = try s.authorize(gpa, res, ch);
    defer t.deinit(gpa);
    try h.browser.finish();
    try testing.expectEqualStrings("https://app.example/client.json", h.fake.auth_client[0..h.fake.auth_client_len]);
    try testing.expectEqual(@as(u32, 0), h.fake.registrations);
    // No challenge scope: the resource's scopes_supported.
    try testing.expectEqualStrings("files:read files:write", h.fake.auth_scope[0..h.fake.auth_scope_len]);
}
