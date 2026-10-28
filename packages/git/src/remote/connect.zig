//! Picks the transport for a remote URL (E09.F08): `https://` and
//! `http://` go over smart HTTP; `ssh://` and scp-like `user@host:path`
//! over SSH; local paths and `file://` are not served yet.

const std = @import("std");
const zg_net = @import("zg_net");
const transport = @import("transport.zig");
const http = @import("http.zig");
const credential = @import("credential.zig");
const fetch_mod = @import("fetch.zig");
const Repository = @import("../repository.zig").Repository;

pub const Kind = enum { http, ssh, local };

/// What kind of transport `url` needs, as git decides.
pub fn kindOf(url: []const u8) Kind {
    if (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) return .http;
    if (std.mem.startsWith(u8, url, "ssh://") or std.mem.startsWith(u8, url, "git+ssh://") or std.mem.startsWith(u8, url, "ssh+git://")) return .ssh;
    if (std.mem.startsWith(u8, url, "file://")) return .local;
    // scp-like "host:path": a colon before any slash, and not a drive
    // letter ("C:\\x").
    if (std.mem.indexOfScalar(u8, url, ':')) |colon| {
        const slash = std.mem.indexOfAny(u8, url, "/\\") orelse url.len;
        if (colon < slash and colon > 1) return .ssh;
    }
    return .local;
}

/// The connector apps use: one HTTP client and an optional credential
/// provider shared by every connection.
pub const Default = struct {
    client: *zg_net.http.Client,
    provider: ?credential.Provider = null,

    pub fn connector(d: *Default) fetch_mod.Connector {
        return .{ .ctx = d, .connect = connect };
    }

    fn connect(ctx: ?*anyopaque, repo: *Repository, url: []const u8, service: transport.Service) anyerror!transport.Connection {
        const d: *Default = @ptrCast(@alignCast(ctx.?));
        return switch (kindOf(url)) {
            .http => (try http.Http.connect(repo.gpa, repo.io, url, service, .{
                .client = d.client,
                .credentials = .{ .repo = repo, .provider = d.provider },
                .tmp_dir = repo.git_dir,
            })).connection(),
            .ssh => error.SshTransportUnavailable,
            .local => error.LocalTransportUnavailable,
        };
    }
};

test "kindOf" {
    const t = std.testing;
    try t.expectEqual(Kind.http, kindOf("https://github.com/o/r.git"));
    try t.expectEqual(Kind.ssh, kindOf("git@github.com:o/r.git"));
    try t.expectEqual(Kind.ssh, kindOf("ssh://git@host:22/r"));
    try t.expectEqual(Kind.local, kindOf("../srv"));
    try t.expectEqual(Kind.local, kindOf("C:\\repos\\x"));
    try t.expectEqual(Kind.local, kindOf("file:///tmp/x"));
}
