//! `text/uri-list` (RFC 2483) to local paths: CRLF (or LF) separated
//! lines, `#` comments skipped, `file:` URIs percent-decoded, other
//! hosts than empty or `localhost` rejected. Used for pasted and dropped
//! file lists on Wayland and X11.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The local paths in `text`, NUL-separated (each path ends with a NUL),
/// in order. Non-`file:` and remote URIs are skipped.
pub fn paths(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const start = out.items.len;
        if (try appendPath(gpa, &out, line)) {
            try out.append(gpa, 0);
        } else out.shrinkRetainingCapacity(start);
    }
    return out.toOwnedSlice(gpa);
}

/// Appends the decoded path of a `file:` URI; false if `uri` is not a
/// local file URI or is malformed.
fn appendPath(gpa: Allocator, out: *std.ArrayList(u8), uri: []const u8) !bool {
    const scheme = "file:";
    if (uri.len < scheme.len or !std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return false;
    var rest = uri[scheme.len..];
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
        const host = rest[0..slash];
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return false;
        rest = rest[slash..];
    }
    if (rest.len == 0 or rest[0] != '/') return false;
    // Query and fragment are not part of a path.
    if (std.mem.indexOfAny(u8, rest, "?#")) |q| rest = rest[0..q];
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c != '%') {
            try out.append(gpa, c);
            continue;
        }
        if (i + 2 >= rest.len) return false;
        const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return false;
        // A NUL would end the path early.
        if (v == 0) return false;
        try out.append(gpa, v);
        i += 2;
    }
    return true;
}

const testing = std.testing;

test "uri-list parsing: CRLF, comments, percent-encoding, hosts" {
    const text =
        "# copied from Files\r\n" ++
        "file:///home/me/a%20b.txt\r\n" ++
        "file://localhost/tmp/%C3%BC.md\r\n" ++
        "file://otherhost/etc/passwd\r\n" ++
        "https://example.com/x\r\n" ++
        "file:/srv/plain\n" ++
        "file:///bad%2\r\n" ++
        "file:///nul%00x\r\n" ++
        "\r\n" ++
        "FILE:///q?x=1#frag";
    const p = try paths(testing.allocator, text);
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/home/me/a b.txt\x00/tmp/\xc3\xbc.md\x00/srv/plain\x00/q\x00", p);
}

test "uri-list parsing: empty and comment-only lists" {
    const a = try paths(testing.allocator, "");
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = try paths(testing.allocator, "# nothing\r\n");
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 0), b.len);
}
