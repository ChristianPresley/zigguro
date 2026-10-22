//! Roots (E11.F03.S03.T02; ROOTS, deprecated in 2026-07-28): the host's
//! `RootsProvider` lists the workspace folders the user agreed to share
//! with a server, as `file://` URIs. `fileUri` turns an absolute path
//! (POSIX, Windows drive or UNC) into one: the path is normalized,
//! separators become '/', and everything outside RFC 3986 unreserved
//! characters, '/' and a drive's ':' is percent-encoded byte by byte
//! (so UTF-8 names become `%XX` sequences).

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol/root.zig");

const M = protocol.messages;

/// Lists the roots shared with one server, allocated in `arena`.
pub const RootsProvider = struct {
    ctx: ?*anyopaque,
    list: *const fn (ctx: ?*anyopaque, arena: Allocator) anyerror![]const M.Root,
};

/// A provider over a fixed list.
pub const StaticRoots = struct {
    roots: []const M.Root,

    pub fn provider(s: *StaticRoots) RootsProvider {
        return .{ .ctx = s, .list = list };
    }

    fn list(ctx: ?*anyopaque, arena: Allocator) anyerror![]const M.Root {
        const s: *StaticRoots = @ptrCast(@alignCast(ctx.?));
        return arena.dupe(M.Root, s.roots);
    }
};

pub const UriError = error{ NotAbsolute, OutOfMemory };

/// The `file://` URI of an absolute path, allocated in `a`.
pub fn fileUri(a: Allocator, path: []const u8) UriError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    if (isUnc(path)) {
        const norm = try std.fs.path.resolveWindows(a, &.{path});
        // \\server\share\rest => file://server/share/rest
        try encodePath(a, &out, norm[2..]);
    } else if (isDrive(path)) {
        const norm = try std.fs.path.resolveWindows(a, &.{path});
        try out.append(a, '/');
        try out.append(a, std.ascii.toUpper(norm[0]));
        try out.append(a, ':');
        try encodePath(a, &out, norm[2..]);
    } else if (path.len > 0 and path[0] == '/') {
        const norm = try std.fs.path.resolvePosix(a, &.{path});
        try encodePath(a, &out, norm);
    } else return error.NotAbsolute;
    return out.items;
}

fn isDrive(p: []const u8) bool {
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/');
}

fn isUnc(p: []const u8) bool {
    return p.len > 2 and (p[0] == '\\' or p[0] == '/') and p[0] == p[1];
}

fn encodePath(a: Allocator, out: *std.ArrayList(u8), p: []const u8) Allocator.Error!void {
    for (p) |c| {
        if (c == '\\' or c == '/') {
            try out.append(a, '/');
        } else if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(a, c);
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
}

const testing = std.testing;

test "roots: file uri encoding of spaces/unicode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("file:///home/user/projects/myproject", try fileUri(a, "/home/user/projects/myproject"));
    try testing.expectEqualStrings("file:///home/user/My%20Project/na%C3%AFve%20%E2%9C%93", try fileUri(a, "/home/user/My Project/naïve ✓"));
    try testing.expectEqualStrings("file:///home/a%23b%3Fc%25", try fileUri(a, "/home/x/../a#b?c%"));
    try testing.expectEqualStrings("file:///C:/Users/Ana/Code%20Files", try fileUri(a, "c:\\Users\\Ana\\.\\Code Files\\"));
    try testing.expectEqualStrings("file://server/share/dir", try fileUri(a, "\\\\server\\share\\dir"));
    try testing.expectError(error.NotAbsolute, fileUri(a, "relative/dir"));
}

test "roots: ROOTS example from a static provider" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: StaticRoots = .{ .roots = &.{.{ .uri = try fileUri(a, "/home/user/projects/myproject"), .name = "My Project" }} };
    const p = s.provider();
    const roots = try p.list(p.ctx, a);
    const json = try protocol.codec.encodeAlloc(a, M.ListRootsResult{ .roots = roots });
    try testing.expectEqualStrings(
        \\{"roots":[{"uri":"file:///home/user/projects/myproject","name":"My Project"}]}
    , json);
}
