//! Canonical URLs and dedupe keys.

const std = @import("std");
const canon = @import("canon_url.zig");

const testing = std.testing;

test "canonicalize table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "https://example.com/a", "https://example.com/a" },
        .{ "HTTPS://Example.COM/A", "https://example.com/A" },
        .{ "https://example.com", "https://example.com/" },
        .{ "https://example.com:443/x", "https://example.com/x" },
        .{ "http://example.com:80/x", "http://example.com/x" },
        .{ "https://example.com:8443/x", "https://example.com:8443/x" },
        .{ "http://example.com:443/x", "http://example.com:443/x" },
        .{ "https://example.com/x#section", "https://example.com/x" },
        .{ "https://example.com/x?utm_source=tw&utm_medium=social", "https://example.com/x" },
        .{ "https://example.com/x?b=2&a=1", "https://example.com/x?a=1&b=2" },
        .{ "https://example.com/x?a=1&utm_campaign=z&b=2", "https://example.com/x?a=1&b=2" },
        .{ "https://example.com/x?gclid=abc", "https://example.com/x" },
        .{ "https://example.com/x?fbclid=abc&id=7", "https://example.com/x?id=7" },
        .{ "https://example.com/x?mc_cid=1&mc_eid=2", "https://example.com/x" },
        .{ "https://example.com/x?ref=hn", "https://example.com/x" },
        .{ "https://example.com/x?ref_src=twsrc", "https://example.com/x" },
        .{ "https://example.com/x?UTM_Source=up", "https://example.com/x" },
        .{ "https://example.com/x?referrer=keep", "https://example.com/x?referrer=keep" },
        .{ "https://example.com/x?", "https://example.com/x" },
        .{ "https://example.com/x?&&a=1&", "https://example.com/x?a=1" },
        .{ "https://example.com//a///b", "https://example.com/a/b" },
        .{ "https://example.com/docs/index.html", "https://example.com/docs/" },
        .{ "https://example.com/index.html", "https://example.com/" },
        .{ "https://example.com/docs/INDEX.HTML", "https://example.com/docs/" },
        .{ "https://example.com/docs/index.htm", "https://example.com/docs/" },
        .{ "https://example.com/docs/index.html?x=1", "https://example.com/docs/?x=1" },
        .{ "https://example.com/myindex.html", "https://example.com/myindex.html" },
        .{ "https://www.example.com/a", "https://www.example.com/a" },
        .{ "https://xn--bcher-kva.example/a", "https://xn--bcher-kva.example/a" },
        .{ "https://user:pass@example.com/a", "https://example.com/a" },
        .{ "https://example.com./a", "https://example.com/a" },
        .{ "https://[2001:db8::1]:443/a", "https://[2001:db8::1]/a" },
        .{ "https://[2001:db8::1]:8080/a", "https://[2001:db8::1]:8080/a" },
        .{ "  https://example.com/a  ", "https://example.com/a" },
        .{ "https://example.com/a%20b", "https://example.com/a%20b" },
        .{ "https://example.com/A/B/", "https://example.com/A/B/" },
        .{ "https://example.com/x?q=a+b&p=1#frag", "https://example.com/x?p=1&q=a+b" },
        .{ "ftp://example.com/file", "ftp://example.com/file" },
        .{ "mailto:a@b.c", "mailto:a@b.c" },
        .{ "not a url", "not a url" },
    };
    try testing.expectEqual(@as(usize, 40), cases.len);
    for (cases) |c| {
        const got = try canon.canonicalize(a, c[0]);
        testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("input {s}\n", .{c[0]});
            return e;
        };
        // Canonical forms are fixed points.
        try testing.expectEqualStrings(got, try canon.canonicalize(a, got));
    }
}

test "dedupe keys fold www and http" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const k1 = try canon.dedupeKey(a, try canon.canonicalize(a, "http://www.Example.com/a?utm_source=x#top"));
    const k2 = try canon.dedupeKey(a, try canon.canonicalize(a, "https://example.com/a"));
    try testing.expectEqualStrings("https://example.com/a", k1);
    try testing.expectEqualStrings(k1, k2);
    try testing.expectEqualStrings(&canon.sourceId(k1), &canon.sourceId(k2));
    try testing.expect(!std.mem.eql(u8, &canon.sourceId(k1), &canon.sourceId("https://example.com/b")));
    try testing.expect(canon.sameSite("https://www.example.com/a", "http://example.com/b"));
    try testing.expect(!canon.sameSite("https://example.com/a", "https://example.org/a"));
    try testing.expectEqualStrings("example.com", try canon.site(a, "https://WWW.Example.com/x"));
    try testing.expectEqualStrings("https://e.org/a/c", try canon.resolve(a, "https://e.org/a/b", "c"));
    try testing.expectEqualStrings("https://e.org/c", try canon.resolve(a, "https://e.org/a/b", "/c"));
    try testing.expectEqualStrings("https://f.org/c", try canon.resolve(a, "https://e.org/a/b", "//f.org/c"));
    try testing.expectEqualStrings("https://g.org/", try canon.resolve(a, "https://e.org/a/b", "https://g.org/"));
}
