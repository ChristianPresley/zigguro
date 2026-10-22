//! The egress policy a sandbox's proxy listener or a `ConnectGuard` scope
//! enforces (E16.F05.S01.T01). It is compiled from the E16.F02 domain
//! rules (`network(domain:...)`, `web_fetch(domain:...)`) and the managed
//! `allowed_domains_only` list, and answers allow, deny or ask for a
//! host and port. Address classes are checked separately, after DNS, by
//! the proxy and the guard (see `ipclass.zig`).
//!
//! Decision order:
//! 1. a deny pattern matches → deny;
//! 2. `managed_only` and the host is not in the managed list → deny;
//! 3. the port is outside `ports` and no allow pattern names it → deny;
//! 4. an allow pattern matches → allow;
//! 5. otherwise ask when `ask_unknown`, else deny.

const std = @import("std");
const Allocator = std.mem.Allocator;
const domain = @import("../policy/domain.zig");
const rules = @import("../policy/rules.zig");
const managed_mod = @import("../policy/managed.zig");
const ipclass = @import("ipclass.zig");

pub const DomainPattern = domain.DomainPattern;
pub const Cidr = ipclass.Cidr;

/// The verdict for a host and port.
pub const Verdict = enum { allow, deny, ask };

/// Which caller the policy is for; each scope draws on different rules.
pub const Scope = enum {
    /// Processes inside an agent sandbox (via the proxy).
    sandbox_process,
    /// The agent's `web_fetch` / `web_search` tools.
    web_tool,
    /// HTTP transports of MCP servers.
    mcp_http,
    /// OAuth metadata and token endpoints (https and public only).
    oauth_discovery,
    /// The configured AI provider endpoints.
    provider_api,
    /// The E17 update host.
    update_check,
};

/// A compiled egress policy. Slices are owned by the arena given to
/// `compile` (or by the caller when built by hand).
pub const EgressPolicy = struct {
    allow: []const DomainPattern = &.{},
    deny: []const DomainPattern = &.{},
    /// The rule text behind each `allow` / `deny` entry, for audit records.
    allow_text: []const []const u8 = &.{},
    deny_text: []const []const u8 = &.{},
    ask_unknown: bool = true,
    /// Managed `allowed_domains_only` present: `allow` is the managed list
    /// and nothing else is asked about.
    managed_only: bool = false,
    /// Explicit opt-in for non-public addresses (e.g. a LAN dev server).
    allow_private: []const Cidr = &.{},
    /// CONNECT and forward requests only to these ports unless an allow
    /// pattern names the port.
    ports: []const u16 = &.{ 80, 443 },

    /// The verdict for `host` (already normalised: lower-case, A-labels)
    /// and `port`.
    pub fn classify(p: *const EgressPolicy, host: []const u8, port: u16) Verdict {
        return p.explain(host, port).verdict;
    }

    /// A verdict with the rule that produced it.
    pub const Explained = struct { verdict: Verdict, rule: ?[]const u8 = null, reason: []const u8 };

    /// Like `classify`, also naming the rule and the reason.
    pub fn explain(p: *const EgressPolicy, host: []const u8, port: u16) Explained {
        for (p.deny, 0..) |*d, i| if (d.matches(host, port))
            return .{ .verdict = .deny, .rule = textAt(p.deny_text, i), .reason = "denied by rule" };
        const allow_i: ?usize = for (p.allow, 0..) |*a, i| {
            if (a.matches(host, port)) break i;
        } else null;
        if (p.managed_only and allow_i == null)
            return .{ .verdict = .deny, .reason = "not in the organisation's allowed domains" };
        if (std.mem.findScalar(u16, p.ports, port) == null) {
            const named = if (allow_i) |i| p.allow[i].port != null else false;
            if (!named) return .{ .verdict = .deny, .reason = "port not allowed" };
        }
        if (allow_i) |i| return .{ .verdict = .allow, .rule = textAt(p.allow_text, i), .reason = "allowed by rule" };
        if (p.ask_unknown) return .{ .verdict = .ask, .reason = "unknown domain" };
        return .{ .verdict = .deny, .reason = "unknown domain" };
    }
};

fn textAt(texts: []const []const u8, i: usize) ?[]const u8 {
    return if (i < texts.len) texts[i] else null;
}

/// True when a rule's tool feeds `scope`.
fn toolFeeds(tool: []const u8, scope: Scope) bool {
    if (std.mem.eql(u8, tool, "network")) return true;
    return switch (scope) {
        .web_tool => std.mem.eql(u8, tool, "web_fetch") or std.mem.eql(u8, tool, "web_search"),
        else => false,
    };
}

/// Builds the policy for `scope` from parsed rules (all layers, already
/// ordered) and the managed policy. Only `domain:` specifiers contribute;
/// an allow rule whose host is an IP literal also opts that address in to
/// `allow_private`. `ask` rules leave the host on the ask path.
pub fn compile(arena: Allocator, rule_list: []const rules.Rule, managed: ?*const managed_mod.ManagedPolicy, scope: Scope) !EgressPolicy {
    var allow: std.ArrayList(DomainPattern) = .empty;
    var allow_text: std.ArrayList([]const u8) = .empty;
    var deny: std.ArrayList(DomainPattern) = .empty;
    var deny_text: std.ArrayList([]const u8) = .empty;
    var private: std.ArrayList(Cidr) = .empty;
    var p: EgressPolicy = .{};

    for (rule_list) |*r| {
        const pat = switch (r.spec) {
            .domain => |d| d,
            else => continue,
        };
        if (r.tool.isWildcard()) {
            if (!(r.tool.matches("network") or (scope == .web_tool and r.tool.matches("web_fetch")))) continue;
        } else if (!toolFeeds(r.tool.text, scope)) continue;
        switch (r.kind) {
            .deny => {
                try deny.append(arena, pat);
                try deny_text.append(arena, r.text);
            },
            .allow => {
                try allow.append(arena, pat);
                try allow_text.append(arena, r.text);
                if (!pat.all and !pat.any_subdomain) {
                    if (Cidr.parse(pat.host)) |c| try private.append(arena, c) else |_| {}
                }
            },
            .ask => {},
        }
    }

    if (managed) |m| if (m.allowed_domains_only) |list| {
        // The managed list replaces every other allow source.
        allow.clearRetainingCapacity();
        allow_text.clearRetainingCapacity();
        private.clearRetainingCapacity();
        for (list) |text| {
            const pat = domain.parse(arena, text) catch continue;
            try allow.append(arena, pat);
            try allow_text.append(arena, try std.fmt.allocPrint(arena, "managed: {s}", .{text}));
            if (!pat.all and !pat.any_subdomain) {
                if (Cidr.parse(pat.host)) |c| try private.append(arena, c) else |_| {}
            }
        }
        p.managed_only = true;
        p.ask_unknown = false;
    };

    if (scope == .oauth_discovery and !p.managed_only) {
        // Discovery follows server-provided URLs to any host, but only over
        // https, never asking; the guard then refuses non-public addresses.
        try allow.append(arena, .{ .host = "", .all = true });
        try allow_text.append(arena, "oauth discovery (https, public addresses)");
    }
    if (scope == .oauth_discovery) {
        p.ask_unknown = false;
        p.ports = &.{443};
    }

    p.allow = try allow.toOwnedSlice(arena);
    p.allow_text = try allow_text.toOwnedSlice(arena);
    p.deny = try deny.toOwnedSlice(arena);
    p.deny_text = try deny_text.toOwnedSlice(arena);
    p.allow_private = try private.toOwnedSlice(arena);
    return p;
}

const test_ctx: rules.Context = .{ .anchors = .{ .workspace_root = "/w", .settings_root = "/w", .home = "/h", .windows = false } };

fn parseRules(arena: Allocator, specs: []const struct { rules.RuleKind, []const u8 }) ![]rules.Rule {
    var out: std.ArrayList(rules.Rule) = .empty;
    for (specs, 0..) |s, i| try out.append(arena, try rules.parse(arena, s[1], s[0], .{ .layer = .user, .index = @intCast(i) }, test_ctx));
    return out.items;
}

test "policy: deny beats allow, ask on unknown, ports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rs = try parseRules(a, &.{
        .{ .allow, "network(domain:*.github.com)" },
        .{ .deny, "network(domain:evil.github.com)" },
        .{ .allow, "network(domain:localhost:3000)" },
        .{ .allow, "network(domain:192.168.1.20)" },
        .{ .allow, "web_fetch(domain:docs.example.com)" },
    });
    const p = try compile(a, rs, null, .sandbox_process);
    try std.testing.expectEqual(Verdict.allow, p.classify("api.github.com", 443));
    try std.testing.expectEqual(Verdict.deny, p.classify("evil.github.com", 443));
    try std.testing.expectEqual(Verdict.ask, p.classify("example.org", 443));
    try std.testing.expectEqual(Verdict.deny, p.classify("api.github.com", 22));
    try std.testing.expectEqual(Verdict.allow, p.classify("localhost", 3000));
    // web_fetch rules do not feed sandboxed processes.
    try std.testing.expectEqual(Verdict.ask, p.classify("docs.example.com", 443));
    try std.testing.expectEqual(@as(usize, 1), p.allow_private.len);
    try std.testing.expect(p.allow_private[0].contains(try std.Io.net.IpAddress.parse("192.168.1.20", 0)));
    const e = p.explain("evil.github.com", 443);
    try std.testing.expectEqualStrings("network(domain:evil.github.com)", e.rule.?);

    const web = try compile(a, rs, null, .web_tool);
    try std.testing.expectEqual(Verdict.allow, web.classify("docs.example.com", 443));
}

test "policy: managed_only denies without asking" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rs = try parseRules(a, &.{.{ .allow, "network(domain:example.org)" }});
    const m: managed_mod.ManagedPolicy = .{ .allowed_domains_only = &.{ "*.corp.example", "pypi.org" } };
    const p = try compile(a, rs, &m, .sandbox_process);
    try std.testing.expect(p.managed_only);
    try std.testing.expectEqual(Verdict.allow, p.classify("git.corp.example", 443));
    try std.testing.expectEqual(Verdict.allow, p.classify("pypi.org", 443));
    // User allow rules are ignored under managed_only.
    try std.testing.expectEqual(Verdict.deny, p.classify("example.org", 443));
    try std.testing.expectEqual(Verdict.deny, p.classify("unknown.test", 443));
}

test "policy: oauth discovery is https-only and never asks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try compile(arena.allocator(), &.{}, null, .oauth_discovery);
    try std.testing.expectEqual(Verdict.allow, p.classify("auth.example.com", 443));
    try std.testing.expectEqual(Verdict.deny, p.classify("auth.example.com", 80));
}
