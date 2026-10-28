//! Refspecs (`[+]<src>:<dst>`, `^<negative>`) as in `remote.<name>.fetch`
//! and on the push and fetch command lines: one `*` per side, matching
//! any run of characters (git's rule), a leading `+` to allow
//! non-fast-forward updates, an empty src to delete on push.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Refspec = struct {
    force: bool = false,
    /// `^<src>`: matching refs are left out.
    negative: bool = false,
    src: []const u8,
    /// Empty when the refspec names only a source (`main`, `tag v1`).
    dst: []const u8 = "",

    pub fn isGlob(r: Refspec) bool {
        return std.mem.indexOfScalar(u8, r.src, '*') != null;
    }

    /// The destination for `name` when it matches `src`, allocated in
    /// `a` for globs.
    pub fn map(r: Refspec, a: Allocator, name: []const u8) !?[]const u8 {
        const star = std.mem.indexOfScalar(u8, r.src, '*') orelse return if (std.mem.eql(u8, r.src, name)) r.dst else null;
        const pre = r.src[0..star];
        const post = r.src[star + 1 ..];
        if (name.len < pre.len + post.len or !std.mem.startsWith(u8, name, pre) or !std.mem.endsWith(u8, name, post)) return null;
        const mid = name[pre.len .. name.len - post.len];
        const dstar = std.mem.indexOfScalar(u8, r.dst, '*') orelse return r.dst;
        return try std.mem.concat(a, u8, &.{ r.dst[0..dstar], mid, r.dst[dstar + 1 ..] });
    }

    /// Whether `name` matches `src`.
    pub fn matches(r: Refspec, name: []const u8) bool {
        const star = std.mem.indexOfScalar(u8, r.src, '*') orelse return std.mem.eql(u8, r.src, name);
        const pre = r.src[0..star];
        const post = r.src[star + 1 ..];
        return name.len >= pre.len + post.len and std.mem.startsWith(u8, name, pre) and std.mem.endsWith(u8, name, post);
    }

    /// The `ref-prefix` to ask a server for (protocol v2 ls-refs).
    pub fn prefix(r: Refspec) []const u8 {
        return if (std.mem.indexOfScalar(u8, r.src, '*')) |star| r.src[0..star] else r.src;
    }

    pub fn format(r: Refspec, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (r.negative) try w.writeByte('^');
        if (r.force) try w.writeByte('+');
        try w.writeAll(r.src);
        if (r.dst.len > 0) try w.print(":{s}", .{r.dst});
    }
};

pub const ParseError = error{InvalidRefspec};

/// Parses one refspec; slices point into `text`.
pub fn parse(text: []const u8) ParseError!Refspec {
    var s = std.mem.trim(u8, text, " \t");
    var r: Refspec = .{ .src = "" };
    if (std.mem.startsWith(u8, s, "^")) {
        r.negative = true;
        s = s[1..];
        if (std.mem.indexOfScalar(u8, s, ':') != null) return error.InvalidRefspec;
    } else if (std.mem.startsWith(u8, s, "+")) {
        r.force = true;
        s = s[1..];
    }
    if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
        r.src = s[0..colon];
        r.dst = s[colon + 1 ..];
    } else r.src = s;
    const ss = std.mem.count(u8, r.src, "*");
    const ds = std.mem.count(u8, r.dst, "*");
    if (ss > 1 or ds > 1) return error.InvalidRefspec;
    if (r.dst.len > 0 and ss != ds) return error.InvalidRefspec;
    if (r.src.len == 0 and r.dst.len == 0) return error.InvalidRefspec;
    return r;
}

/// The default fetch refspec of a remote.
pub fn defaultFetch(a: Allocator, remote: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "+refs/heads/*:refs/remotes/{s}/*", .{remote});
}

test "refspec: parse, map and format" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse("+refs/heads/*:refs/remotes/origin/*");
    try t.expect(r.force and r.isGlob());
    try t.expectEqualStrings("refs/remotes/origin/feat/x", (try r.map(a, "refs/heads/feat/x")).?);
    try t.expect((try r.map(a, "refs/tags/v1")) == null);
    try t.expectEqualStrings("refs/heads/", r.prefix());
    const del = try parse(":refs/heads/old");
    try t.expectEqualStrings("", del.src);
    const neg = try parse("^refs/heads/wip/*");
    try t.expect(neg.negative and neg.matches("refs/heads/wip/a"));
    try t.expectError(error.InvalidRefspec, parse("refs/heads/*:refs/x"));
    try t.expectError(error.InvalidRefspec, parse("^a:b"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", try std.fmt.bufPrint(&buf, "{f}", .{r}));
}
