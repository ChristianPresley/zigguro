//! `org.freedesktop.portal.OpenURI` for `Command.open_uri`: web and mail
//! links go to `OpenURI`; local files go to `OpenFile` as an O_PATH fd,
//! which also works from inside a sandbox.

const std = @import("std");
const linux = std.os.linux;
const request = @import("request.zig");
const Bus = @import("../dbus/conn.zig").Bus;
const Value = @import("../dbus/variant.zig").Value;

/// The interface name.
pub const interface = "org.freedesktop.portal.OpenURI";

/// Decides which URI schemes may be opened (the E16 policy hook).
pub const SchemePolicy = struct {
    ctx: ?*anyopaque = null,
    allow: *const fn (ctx: ?*anyopaque, name: []const u8) bool = defaultAllow,

    fn defaultAllow(_: ?*anyopaque, name: []const u8) bool {
        for ([_][]const u8{ "http", "https", "mailto", "file" }) |s| {
            if (std.ascii.eqlIgnoreCase(s, name)) return true;
        }
        return false;
    }
};

/// The scheme of `uri` (before ':'), or null when it has none.
pub fn scheme(uri: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return null;
    if (colon == 0 or !std.ascii.isAlphabetic(uri[0])) return null;
    for (uri[0..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
    }
    return uri[0..colon];
}

/// Asks the portal to open `uri`. The callback (optional) receives the
/// response; free the returned request after it ran, or at once when no
/// callback was given and the answer does not matter.
pub fn open(gpa: std.mem.Allocator, bus: *Bus, parent: []const u8, uri: []const u8, policy: SchemePolicy, cb: ?request.Callback) !*request.Request {
    const s = scheme(uri) orelse return error.InvalidUri;
    if (!policy.allow(policy.ctx, s)) return error.SchemeNotAllowed;
    const r = try request.Request.begin(gpa, bus, cb);
    errdefer r.deinit();
    const options = [_]struct { []const u8, Value }{.{ "handle_token", .{ .string = r.token() } }};
    if (std.ascii.eqlIgnoreCase(s, "file")) {
        var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
        const path = request.fileUriToPath(buf[0 .. buf.len - 1], uri) orelse return error.InvalidUri;
        buf[path.len] = 0;
        const rc = linux.open(buf[0..path.len :0], .{ .PATH = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.FileNotFound;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        try bus.callAsync(request.destination, request.object_path, interface, "OpenFile", "sha{sv}", .{ parent, fd, &options }, r.replyHandler());
    } else {
        try bus.callAsync(request.destination, request.object_path, interface, "OpenURI", "ssa{sv}", .{ parent, uri, &options }, r.replyHandler());
    }
    return r;
}

test "schemes and the default policy" {
    try std.testing.expectEqualStrings("https", scheme("https://ziglang.org").?);
    try std.testing.expectEqualStrings("mailto", scheme("mailto:a@b.c").?);
    try std.testing.expectEqual(null, scheme("no-scheme"));
    try std.testing.expectEqual(null, scheme(":x"));
    try std.testing.expectEqual(null, scheme("1abc:x"));
    const p: SchemePolicy = .{};
    try std.testing.expect(p.allow(p.ctx, "HTTPS"));
    try std.testing.expect(!p.allow(p.ctx, "javascript"));
}
