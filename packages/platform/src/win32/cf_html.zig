//! The Windows "HTML Format" clipboard encoding (CF_HTML): a UTF-8
//! payload whose header gives byte offsets of the HTML document and of
//! the copied fragment. Pure functions; they build and test on every OS.

const std = @import("std");
const Allocator = std.mem.Allocator;

const prefix = "<html><body>\r\n<!--StartFragment-->";
const suffix = "<!--EndFragment-->\r\n</body>\r\n</html>";
/// "Version:0.9\r\n" plus four "Key:0000000000\r\n" lines.
const header_len = 13 + (10 + 12) + (8 + 12) + (14 + 12) + (12 + 12);

/// Wraps `fragment` (UTF-8 HTML) in a CF_HTML document, NUL-terminated
/// (the NUL is not counted by the offsets).
pub fn encode(gpa: Allocator, fragment: []const u8) ![]u8 {
    const start_html = header_len;
    const start_frag = start_html + prefix.len;
    const end_frag = start_frag + fragment.len;
    const end_html = end_frag + suffix.len;
    const out = try gpa.alloc(u8, end_html + 1);
    const hdr = std.fmt.bufPrint(out[0..header_len], "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n", .{ start_html, end_html, start_frag, end_frag }) catch unreachable;
    std.debug.assert(hdr.len == header_len);
    @memcpy(out[start_html..start_frag], prefix);
    @memcpy(out[start_frag..end_frag], fragment);
    @memcpy(out[end_frag..end_html], suffix);
    out[end_html] = 0;
    return out;
}

/// The fragment of a CF_HTML document (a view into `bytes`), or null when
/// the header is missing or its offsets do not fit.
pub fn decode(bytes_in: []const u8) ?[]const u8 {
    // Clipboard blocks are rounded up and NUL-terminated.
    const bytes = if (std.mem.indexOfScalar(u8, bytes_in, 0)) |z| bytes_in[0..z] else bytes_in;
    var start: ?usize = null;
    var end: ?usize = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var consumed: usize = 0;
    while (lines.next()) |raw| {
        consumed += raw.len + 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse break;
        const key = line[0..colon];
        // The header ends at the first line that is not "Key:value".
        if (key.len == 0 or std.mem.indexOfAny(u8, key, "<> ") != null) break;
        const val = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.mem.eql(u8, key, "StartFragment")) start = std.fmt.parseInt(usize, val, 10) catch return null;
        if (std.mem.eql(u8, key, "EndFragment")) end = std.fmt.parseInt(usize, val, 10) catch return null;
        if (consumed >= bytes.len) break;
    }
    const s = start orelse return null;
    const e = end orelse return null;
    if (s > e or e > bytes.len) return null;
    return bytes[s..e];
}

const testing = std.testing;

test "CF_HTML header offsets roundtrip incl. multi-byte UTF-8" {
    const frag = "<b>zigguro ✓ — 日本</b>";
    const doc = try encode(testing.allocator, frag);
    defer testing.allocator.free(doc);
    try testing.expectEqual(@as(u8, 0), doc[doc.len - 1]);
    try testing.expect(std.mem.startsWith(u8, doc, "Version:0.9\r\nStartHTML:0000000105\r\n"));
    try testing.expectEqualStrings(frag, decode(doc).?);
    // The offsets name the document too.
    const end_html = std.fmt.parseInt(usize, doc[13 + 10 + 12 + 8 ..][0..10], 10) catch unreachable;
    try testing.expectEqual(doc.len - 1, end_html);
}

test "CF_HTML decode rejects out-of-range offsets" {
    try testing.expectEqual(@as(?[]const u8, null), decode("Version:0.9\r\nStartFragment:0000000050\r\nEndFragment:0000009999\r\n<html>"));
    try testing.expectEqual(@as(?[]const u8, null), decode("Version:0.9\r\nStartFragment:0000000040\r\nEndFragment:0000000030\r\n<html></html>"));
    try testing.expectEqual(@as(?[]const u8, null), decode("<html>no header</html>"));
    try testing.expectEqual(@as(?[]const u8, null), decode("Version:0.9\r\nStartFragment:x\r\n"));
}

test "CF_HTML from another producer (StartHTML -1, extra keys)" {
    const doc = "Version:1.0\r\nStartHTML:-1\r\nEndHTML:-1\r\nStartFragment:0000000105\r\nEndFragment:0000000110\r\nSourceURL:x\r\n<p>hello</p>";
    try testing.expectEqual(@as(usize, 105), std.mem.indexOf(u8, doc, "hello").?);
    try testing.expectEqualStrings("hello", decode(doc).?);
}
