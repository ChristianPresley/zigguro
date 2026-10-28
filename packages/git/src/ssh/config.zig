//! The ssh_config(5) subset git remotes need: per-`Host` HostName, Port,
//! User, IdentityFile, IdentitiesOnly, IdentityAgent, UserKnownHostsFile,
//! StrictHostKeyChecking, and whether ProxyJump/ProxyCommand is set.
//! The first value obtained wins, except IdentityFile, which adds up.
//! `Match` blocks and `Include` are not followed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const known_hosts = @import("known_hosts.zig");

pub const Strict = enum { yes, no, accept_new, ask };

pub const HostConfig = struct {
    host_name: ?[]const u8 = null,
    port: ?u16 = null,
    user: ?[]const u8 = null,
    identity_files: []const []const u8 = &.{},
    identities_only: ?bool = null,
    identity_agent: ?[]const u8 = null,
    known_hosts_files: ?[]const []const u8 = null,
    strict: ?Strict = null,
    /// ProxyJump or ProxyCommand is set (and not `none`).
    proxy: ?bool = null,
};

fn hostMatches(patterns: []const u8, host: []const u8) bool {
    var hit = false;
    var it = std.mem.tokenizeAny(u8, patterns, " \t");
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, "\"");
        if (p.len > 0 and p[0] == '!') {
            if (known_hosts.glob(p[1..], host)) return false;
        } else if (known_hosts.glob(p, host)) hit = true;
    }
    return hit;
}

fn yesNo(v: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "true")) return true;
    if (std.ascii.eqlIgnoreCase(v, "no") or std.ascii.eqlIgnoreCase(v, "false")) return false;
    return null;
}

/// Resolves the options for `host` from a config file's text. Strings
/// are allocated in `arena`.
pub fn resolve(arena: Allocator, text: []const u8, host: []const u8) !HostConfig {
    var c: HostConfig = .{};
    var ids: std.ArrayList([]const u8) = .empty;
    var active = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const ksep = std.mem.indexOfAny(u8, line, " \t=") orelse continue;
        const key = line[0..ksep];
        var val = std.mem.trimStart(u8, line[ksep..], " \t");
        if (val.len > 0 and val[0] == '=') val = std.mem.trimStart(u8, val[1..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Host")) {
            active = hostMatches(val, host);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key, "Match")) {
            active = std.ascii.eqlIgnoreCase(std.mem.trim(u8, val, " \t"), "all");
            continue;
        }
        if (!active) continue;
        const v = std.mem.trim(u8, val, "\"");
        if (std.ascii.eqlIgnoreCase(key, "HostName")) {
            if (c.host_name == null) c.host_name = try arena.dupe(u8, v);
        } else if (std.ascii.eqlIgnoreCase(key, "Port")) {
            if (c.port == null) c.port = std.fmt.parseInt(u16, v, 10) catch null;
        } else if (std.ascii.eqlIgnoreCase(key, "User")) {
            if (c.user == null) c.user = try arena.dupe(u8, v);
        } else if (std.ascii.eqlIgnoreCase(key, "IdentityFile")) {
            try ids.append(arena, try arena.dupe(u8, v));
        } else if (std.ascii.eqlIgnoreCase(key, "IdentitiesOnly")) {
            if (c.identities_only == null) c.identities_only = yesNo(v);
        } else if (std.ascii.eqlIgnoreCase(key, "IdentityAgent")) {
            if (c.identity_agent == null) c.identity_agent = try arena.dupe(u8, v);
        } else if (std.ascii.eqlIgnoreCase(key, "UserKnownHostsFile")) {
            if (c.known_hosts_files == null) {
                var files: std.ArrayList([]const u8) = .empty;
                var rest = val;
                while (true) {
                    rest = std.mem.trimStart(u8, rest, " \t");
                    if (rest.len == 0) break;
                    const quoted = rest[0] == '"';
                    if (quoted) rest = rest[1..];
                    const stop = std.mem.indexOfAny(u8, rest, if (quoted) "\"" else " \t") orelse rest.len;
                    try files.append(arena, try arena.dupe(u8, rest[0..stop]));
                    rest = rest[@min(rest.len, stop + 1)..];
                }
                c.known_hosts_files = files.items;
            }
        } else if (std.ascii.eqlIgnoreCase(key, "StrictHostKeyChecking")) {
            if (c.strict == null) c.strict = if (std.ascii.eqlIgnoreCase(v, "accept-new"))
                .accept_new
            else if (std.ascii.eqlIgnoreCase(v, "ask"))
                .ask
            else if (std.ascii.eqlIgnoreCase(v, "off"))
                .no
            else if (yesNo(v)) |b| (if (b) .yes else .no) else null;
        } else if (std.ascii.eqlIgnoreCase(key, "ProxyJump") or std.ascii.eqlIgnoreCase(key, "ProxyCommand")) {
            if (c.proxy == null) c.proxy = !std.ascii.eqlIgnoreCase(v, "none");
        }
    }
    c.identity_files = ids.items;
    return c;
}

/// Expands `~` and the `%d %h %r %u %%` tokens in a path option.
pub fn expand(arena: Allocator, path: []const u8, home: []const u8, host: []const u8, remote_user: []const u8, local_user: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var p = path;
    if (std.mem.startsWith(u8, p, "~/") or std.mem.eql(u8, p, "~")) {
        try out.appendSlice(arena, home);
        p = p[1..];
    }
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] != '%' or i + 1 == p.len) {
            try out.append(arena, p[i]);
            continue;
        }
        i += 1;
        switch (p[i]) {
            'd' => try out.appendSlice(arena, home),
            'h' => try out.appendSlice(arena, host),
            'r' => try out.appendSlice(arena, remote_user),
            'u' => try out.appendSlice(arena, local_user),
            '%' => try out.append(arena, '%'),
            else => try out.appendSlice(arena, p[i - 1 .. i + 1]),
        }
    }
    return out.items;
}

test "resolve host options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\# work
        \\Host gh github.com
        \\  HostName github.com
        \\  User git
        \\  IdentityFile ~/.ssh/work_ed25519
        \\  IdentitiesOnly yes
        \\Host *.internal !bad.internal
        \\  Port 2222
        \\  ProxyJump bastion
        \\Host *
        \\  User someone
        \\  IdentityFile=~/.ssh/id_ed25519
        \\  StrictHostKeyChecking accept-new
        \\  UserKnownHostsFile ~/.ssh/kh "/etc/kh 2"
    ;
    const gh = try resolve(a, text, "gh");
    try std.testing.expectEqualStrings("github.com", gh.host_name.?);
    try std.testing.expectEqualStrings("git", gh.user.?);
    try std.testing.expectEqual(@as(usize, 2), gh.identity_files.len);
    try std.testing.expectEqualStrings("~/.ssh/work_ed25519", gh.identity_files[0]);
    try std.testing.expect(gh.identities_only.?);
    try std.testing.expectEqual(Strict.accept_new, gh.strict.?);
    try std.testing.expectEqual(@as(usize, 2), gh.known_hosts_files.?.len);
    const box = try resolve(a, text, "box.internal");
    try std.testing.expectEqual(@as(u16, 2222), box.port.?);
    try std.testing.expect(box.proxy.?);
    const bad = try resolve(a, text, "bad.internal");
    try std.testing.expect(bad.port == null);
    try std.testing.expectEqualStrings("/home/u/.ssh/id_h", try expand(a, "~/.ssh/id_%h", "/home/u", "h", "git", "u"));
}
