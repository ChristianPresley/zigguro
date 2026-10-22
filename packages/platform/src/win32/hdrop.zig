//! `CF_HDROP` file lists ↔ `text/uri-list`: the `DROPFILES` block
//! (20-byte header, then NUL-terminated UTF-16 paths and a final NUL),
//! and Windows paths ↔ `file:` URIs. Shared by the clipboard and drag and
//! drop (E01.F02.S04.T02). Pure functions; they build and test on every
//! OS.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bytes in the `DROPFILES` header.
pub const header_len = 20;

/// A `file:` URI for a Windows path: `C:\a b` → `file:///C:/a%20b`,
/// `\\server\share\x` → `file://server/share/x`. Bytes outside the
/// unreserved set (and `/`, `:` of the drive) are percent-encoded.
pub fn pathToUri(gpa: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = path;
    if (std.mem.startsWith(u8, path, "\\\\")) {
        try out.appendSlice(gpa, "file://");
        rest = path[2..];
    } else try out.appendSlice(gpa, "file:///");
    for (rest) |c| {
        const ch: u8 = if (c == '\\') '/' else c;
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~/:", ch) != null) {
            try out.append(gpa, ch);
        } else try out.print(gpa, "%{X:0>2}", .{ch});
    }
    return out.toOwnedSlice(gpa);
}

/// The Windows path of a `file:` URI, or null for other schemes and
/// malformed escapes.
pub fn uriToPath(gpa: Allocator, uri: []const u8) !?[]u8 {
    const scheme = "file://";
    if (uri.len < scheme.len or !std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return null;
    const after = uri[scheme.len..];
    var out: std.ArrayList(u8) = .empty;
    var done = false;
    defer if (!done) out.deinit(gpa);
    var body: []const u8 = undefined;
    if (std.mem.startsWith(u8, after, "/")) {
        // file:///C:/x (an empty host), or file:////server/share.
        body = after[1..];
        if (std.mem.startsWith(u8, body, "//")) {
            try out.appendSlice(gpa, "\\\\");
            body = body[2..];
        }
    } else if (std.ascii.startsWithIgnoreCase(after, "localhost/")) {
        body = after["localhost/".len..];
    } else {
        // A host: a UNC path.
        try out.appendSlice(gpa, "\\\\");
        body = after;
    }
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '%') {
            if (i + 3 > body.len) return null;
            const v = std.fmt.parseInt(u8, body[i + 1 .. i + 3], 16) catch return null;
            try out.append(gpa, if (v == '/') '\\' else v);
            i += 2;
        } else try out.append(gpa, if (c == '/') '\\' else c);
    }
    done = true;
    return try out.toOwnedSlice(gpa);
}

/// A `DROPFILES` block (wide paths) for the `file:` URIs in `uri_list`
/// (CRLF or LF separated; `#` lines and other schemes are skipped).
pub fn encode(gpa: Allocator, uri_list: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var hdr: [header_len]u8 = @splat(0);
    std.mem.writeInt(u32, hdr[0..4], header_len, .little); // pFiles
    std.mem.writeInt(u32, hdr[16..20], 1, .little); // fWide
    try out.appendSlice(gpa, &hdr);
    var lines = std.mem.splitScalar(u8, uri_list, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const path = (try uriToPath(gpa, line)) orelse continue;
        defer gpa.free(path);
        const w = std.unicode.utf8ToUtf16LeAlloc(gpa, path) catch continue;
        defer gpa.free(w);
        try out.appendSlice(gpa, std.mem.sliceAsBytes(w));
        try out.appendSlice(gpa, &.{ 0, 0 });
    }
    try out.appendSlice(gpa, &.{ 0, 0 });
    return out.toOwnedSlice(gpa);
}

/// The `text/uri-list` (CRLF separated) for a `DROPFILES` block, or null
/// when the block is malformed.
pub fn decode(gpa: Allocator, block: []const u8) !?[]u8 {
    if (block.len < header_len) return null;
    const off = std.mem.readInt(u32, block[0..4], .little);
    const wide = std.mem.readInt(u32, block[16..20], .little) != 0;
    if (off < header_len or off > block.len) return null;
    var out: std.ArrayList(u8) = .empty;
    var done = false;
    defer if (!done) out.deinit(gpa);
    var pos: usize = off;
    while (true) {
        var path_utf8: []u8 = undefined;
        if (wide) {
            const start = pos;
            while (pos + 2 <= block.len and std.mem.readInt(u16, block[pos..][0..2], .little) != 0) pos += 2;
            if (pos + 2 > block.len) return null;
            if (pos == start) break;
            const units = try gpa.alloc(u16, (pos - start) / 2);
            defer gpa.free(units);
            for (units, 0..) |*u, k| u.* = std.mem.readInt(u16, block[start + k * 2 ..][0..2], .little);
            path_utf8 = std.unicode.utf16LeToUtf8Alloc(gpa, units) catch return null;
            pos += 2;
        } else {
            const end = std.mem.indexOfScalarPos(u8, block, pos, 0) orelse return null;
            if (end == pos) break;
            path_utf8 = try gpa.dupe(u8, block[pos..end]);
            pos = end + 1;
        }
        defer gpa.free(path_utf8);
        const uri = try pathToUri(gpa, path_utf8);
        defer gpa.free(uri);
        try out.appendSlice(gpa, uri);
        try out.appendSlice(gpa, "\r\n");
    }
    done = true;
    return try out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "uri-list ↔ paths incl. UNC, spaces, non-ASCII" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "C:\\Users\\zg\\a b.txt", "file:///C:/Users/zg/a%20b.txt" },
        .{ "C:\\Ünïcode\\日本.zig", "file:///C:/%C3%9Cn%C3%AFcode/%E6%97%A5%E6%9C%AC.zig" },
        .{ "\\\\server\\share\\x#1", "file://server/share/x%231" },
    };
    for (cases) |c| {
        const uri = try pathToUri(gpa, c[0]);
        defer gpa.free(uri);
        try testing.expectEqualStrings(c[1], uri);
        const back = (try uriToPath(gpa, uri)).?;
        defer gpa.free(back);
        try testing.expectEqualStrings(c[0], back);
    }
    const lh = (try uriToPath(gpa, "file://localhost/D:/x")).?;
    defer gpa.free(lh);
    try testing.expectEqualStrings("D:\\x", lh);
    try testing.expectEqual(@as(?[]u8, null), try uriToPath(gpa, "https://example.com/"));
    try testing.expectEqual(@as(?[]u8, null), try uriToPath(gpa, "file:///C:/bad%2"));
}

test "DROPFILES encode/decode" {
    const gpa = testing.allocator;
    const list = "# comment\r\nfile:///C:/a%20b.txt\r\nhttps://skip.me/\r\nfile://srv/share/%C3%BC\n";
    const block = try encode(gpa, list);
    defer gpa.free(block);
    try testing.expectEqual(@as(u32, 20), std.mem.readInt(u32, block[0..4], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, block[16..20], .little));
    // "C:\a b.txt" + NUL, "\\srv\share\ü" + NUL, final NUL; in UTF-16.
    try testing.expectEqual(@as(usize, 20 + (10 + 1 + 13 + 1 + 1) * 2), block.len);
    const back = (try decode(gpa, block)).?;
    defer gpa.free(back);
    try testing.expectEqualStrings("file:///C:/a%20b.txt\r\nfile://srv/share/%C3%BC\r\n", back);
    try testing.expectEqual(@as(?[]u8, null), try decode(gpa, block[0..10]));
    // An unterminated list is rejected.
    try testing.expectEqual(@as(?[]u8, null), try decode(gpa, block[0 .. block.len - 4]));
}

test "DROPFILES with ANSI paths" {
    const gpa = testing.allocator;
    var block: [header_len + 12]u8 = @splat(0);
    std.mem.writeInt(u32, block[0..4], header_len, .little);
    @memcpy(block[header_len..][0..8], "C:\\a.txt");
    const back = (try decode(gpa, &block)).?;
    defer gpa.free(back);
    try testing.expectEqualStrings("file:///C:/a.txt\r\n", back);
}
