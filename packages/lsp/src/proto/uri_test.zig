const std = @import("std");
const uri = @import("uri.zig");
const testing = std.testing;

fn expectPath(u: []const u8, style: uri.Style, want: ?[]const u8) !void {
    const got = try uri.pathFromUriStyle(testing.allocator, u, style);
    defer if (got) |g| testing.allocator.free(g);
    if (want) |w| {
        try testing.expectEqualStrings(w, got orelse return error.TestExpectedPath);
    } else try testing.expect(got == null);
}

fn expectUri(path: []const u8, style: uri.Style, want: []const u8) !void {
    const got = try uri.uriFromPathStyle(testing.allocator, path, style);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "uri: table" {
    // POSIX
    try expectUri("/home/u/a b.zig", .posix, "file:///home/u/a%20b.zig");
    try expectUri("/x/#?%.zig", .posix, "file:///x/%23%3F%25.zig");
    try expectUri("/x/caf\u{e9}", .posix, "file:///x/caf%C3%A9");
    try expectPath("file:///home/u/a%20b.zig", .posix, "/home/u/a b.zig");
    try expectPath("file:///x/%23%3F%25.zig", .posix, "/x/#?%.zig");
    try expectPath("file:///x/caf%C3%A9", .posix, "/x/caf\u{e9}");
    // NFD bytes stay as they are.
    try expectPath("file:///x/cafe%CC%81", .posix, "/x/cafe\u{301}");
    try expectPath("file://localhost/etc/hosts", .posix, "/etc/hosts");
    try expectPath("FILE:///etc/hosts", .posix, "/etc/hosts");
    try expectPath("file:///a/b?query#frag", .posix, "/a/b");
    try testing.expectError(error.UnsupportedAuthority, uri.pathFromUriStyle(testing.allocator, "file://server/share/x", .posix));
    try expectPath("untitled:Untitled-1", .posix, null);
    try expectPath("jdt://contents/rt.jar/java.lang/String.class", .posix, null);

    // Windows
    try expectUri("C:\\Users\\u\\a b.zig", .windows, "file:///c%3A/Users/u/a%20b.zig");
    try expectUri("\\\\Server\\share\\x.zig", .windows, "file://server/share/x.zig");
    try expectPath("file:///c%3A/x", .windows, "C:\\x");
    try expectPath("file:///C:/x", .windows, "C:\\x");
    try expectPath("file:///c:/Users/u/a%20b.zig", .windows, "C:\\Users\\u\\a b.zig");
    try expectPath("file://server/share/x", .windows, "\\\\server\\share\\x");
    try expectPath("file://localhost/c:/x", .windows, "C:\\x");
}

test "uri: round trip" {
    const paths = [_][]const u8{ "/", "/a", "/a b/c%d/e#f", "/\u{1F600}/x" };
    for (paths) |p| {
        const u = try uri.uriFromPathStyle(testing.allocator, p, .posix);
        defer testing.allocator.free(u);
        try expectPath(u, .posix, p);
    }
}

test "uri: eqlUri" {
    try testing.expect(uri.eqlUri("file:///c%3A/x", "file:///C:/x"));
    try testing.expect(uri.eqlUri("file:///c%3a/x", "file:///c%3A/x"));
    try testing.expect(uri.eqlUri("file:///a/b/", "file:///a/b"));
    try testing.expect(uri.eqlUri("file:///a%20b", "file:///a b"));
    try testing.expect(!uri.eqlUri("file:///a/b", "file:///a/c"));
    try testing.expect(!uri.eqlUri("file:///A/b", "file:///a/b"));
}

fn expectDoc(u: []const u8, style: uri.Style, comptime tag: std.meta.Tag(uri.DocUri), want: []const u8) !void {
    const d = try uri.docUriFromLspStyle(testing.allocator, u, style);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(tag, std.meta.activeTag(d));
    try testing.expectEqualStrings(want, @field(d, @tagName(tag)));
}

test "uri: docUriFromLsp classifies files, untitled and virtual documents" {
    try expectDoc("file:///home/u/a%20b.zig", .posix, .file, "/home/u/a b.zig");
    try expectDoc("file:///c%3A/x/y.rs", .windows, .file, "C:\\x\\y.rs");
    try expectDoc("untitled:Untitled-1", .posix, .untitled, "Untitled-1");
    try expectDoc("Untitled:My%20Notes", .posix, .untitled, "My Notes");
    try expectDoc("rust-analyzer:/expand/macro.rs", .posix, .virtual, "rust-analyzer:/expand/macro.rs");
    try expectDoc("jdt://contents/rt.jar/java.lang/String.class", .posix, .virtual, "jdt://contents/rt.jar/java.lang/String.class");
    try expectDoc("zigguro-virtual:/agent/1/plan.md", .posix, .virtual, "zigguro-virtual:/agent/1/plan.md");
    try testing.expectError(error.InvalidUri, uri.docUriFromLspStyle(testing.allocator, "no scheme", .posix));
    try testing.expectError(error.UnsupportedAuthority, uri.docUriFromLspStyle(testing.allocator, "file://server/share/x", .posix));
}
