//! SSH remote URLs as git reads them: `ssh://[user@]host[:port]/path`
//! (also `git+ssh://` and `ssh+git://`) and scp-like `[user@]host:path`,
//! and the remote command git runs for a service.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Target = struct {
    user: ?[]const u8 = null,
    host: []const u8,
    port: ?u16 = null,
    path: []const u8,
};

/// Splits an SSH remote URL. Slices borrow from `url`.
pub fn parse(url: []const u8) !Target {
    for ([_][]const u8{ "ssh://", "git+ssh://", "ssh+git://" }) |scheme| {
        if (!std.mem.startsWith(u8, url, scheme)) continue;
        const rest = url[scheme.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidSshUrl;
        var t = try authority(rest[0..slash], true);
        var path = rest[slash..];
        // "ssh://host/~user/repo" means "~user/repo".
        if (std.mem.startsWith(u8, path, "/~")) path = path[1..];
        t.path = path;
        return t;
    }
    // scp-like: the first colon outside brackets.
    var i: usize = 0;
    var depth: usize = 0;
    while (i < url.len) : (i += 1) switch (url[i]) {
        '[' => depth += 1,
        ']' => depth -|= 1,
        ':' => if (depth == 0) break,
        '/' => if (depth == 0) return error.InvalidSshUrl,
        else => {},
    };
    if (i == url.len) return error.InvalidSshUrl;
    var t = try authority(url[0..i], false);
    t.path = url[i + 1 ..];
    if (t.path.len == 0) return error.InvalidSshUrl;
    return t;
}

fn authority(s: []const u8, allow_port: bool) !Target {
    var t: Target = .{ .host = s, .path = "" };
    var hp = s;
    if (std.mem.lastIndexOfScalar(u8, s, '@')) |at| {
        t.user = s[0..at];
        hp = s[at + 1 ..];
    }
    if (hp.len > 0 and hp[0] == '[') {
        const close = std.mem.indexOfScalar(u8, hp, ']') orelse return error.InvalidSshUrl;
        t.host = hp[1..close];
        const after = hp[close + 1 ..];
        if (after.len > 0) {
            if (!allow_port or after[0] != ':') return error.InvalidSshUrl;
            t.port = std.fmt.parseInt(u16, after[1..], 10) catch return error.InvalidSshUrl;
        }
    } else if (allow_port and std.mem.indexOfScalar(u8, hp, ':') != null) {
        const colon = std.mem.indexOfScalar(u8, hp, ':').?;
        t.host = hp[0..colon];
        if (colon + 1 < hp.len) t.port = std.fmt.parseInt(u16, hp[colon + 1 ..], 10) catch return error.InvalidSshUrl;
    } else t.host = hp;
    if (t.host.len == 0 or t.host[0] == '-') return error.InvalidSshUrl;
    if (t.user) |u| if (u.len > 0 and u[0] == '-') return error.InvalidSshUrl;
    return t;
}

/// `git-upload-pack '<path>'`, quoted as git's sq_quote does.
pub fn command(gpa: Allocator, program: []const u8, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, program);
    try out.appendSlice(gpa, " '");
    for (path) |c| switch (c) {
        '\'' => try out.appendSlice(gpa, "'\\''"),
        '!' => try out.appendSlice(gpa, "'\\!'"),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '\'');
    return out.toOwnedSlice(gpa);
}

test "parse ssh urls" {
    const t = std.testing;
    var x = try parse("git@github.com:o/r.git");
    try t.expectEqualStrings("git", x.user.?);
    try t.expectEqualStrings("github.com", x.host);
    try t.expectEqualStrings("o/r.git", x.path);
    x = try parse("ssh://git@host:2222/srv/r");
    try t.expectEqual(@as(u16, 2222), x.port.?);
    try t.expectEqualStrings("/srv/r", x.path);
    x = try parse("ssh://[::1]:22/~u/r");
    try t.expectEqualStrings("::1", x.host);
    try t.expectEqualStrings("~u/r", x.path);
    try t.expectError(error.InvalidSshUrl, parse("ssh://-oProxyCommand=x/r"));
    const c = try command(t.allocator, "git-upload-pack", "it's!");
    defer t.allocator.free(c);
    try t.expectEqualStrings("git-upload-pack 'it'\\''s'\\!''", c);
}
