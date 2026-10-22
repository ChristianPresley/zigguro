//! Tests for html2md.zig (E10.F06.S03.T03): goldens over the pages in
//! testdata/html, URL resolution, and random input.

const std = @import("std");
const golden = @import("zg_core").testkit.golden;
const h2m = @import("html2md.zig");

const testing = std.testing;
const io = testing.io;

const pages = [_][]const u8{
    "docs_page", "table",        "nested_lists",   "entities",
    "malformed", "script_style", "relative_links", "blockquote_code",
    "article",   "headings",     "nested_table",   "no_main",
};

test "html2md goldens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = @import("zg_options").package_root;
    for (pages) |name| {
        const path = try std.fmt.allocPrint(a, "{s}/testdata/html/{s}.html", .{ root, name });
        const html = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
        const md = try h2m.htmlToMarkdown(a, html, "https://example.com/docs/guide/page.html", .{});
        try golden.expectGoldenOpts(io, @src(), name, md, .{ .root = root, .dir = "testdata/golden/tools/html2md" });
    }
}

test "resolve urls" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "https://h.org/a/b/c.html?q=1#f";
    const cases = [_][2][]const u8{
        .{ "d.html", "https://h.org/a/b/d.html" },
        .{ "../d.html", "https://h.org/a/d.html" },
        .{ "../../../d.html", "https://h.org/d.html" },
        .{ "./", "https://h.org/a/b/" },
        .{ "/x", "https://h.org/x" },
        .{ "//cdn.org/y", "https://cdn.org/y" },
        .{ "?p=2", "https://h.org/a/b/c.html?p=2" },
        .{ "#top", "https://h.org/a/b/c.html?q=1#top" },
        .{ "http://other/z", "http://other/z" },
        .{ "e.html?x=1#y", "https://h.org/a/b/e.html?x=1#y" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try h2m.resolveUrl(a, base, c[0]));
    try testing.expectEqualStrings("https://h.org/z", try h2m.resolveUrl(a, "https://h.org", "z"));
}

test "random input never panics and stays bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    const alphabet = "<>/=\"' &#;!-abpliulotrdhn1x\n\t";
    const tags = [_][]const u8{ "<p>", "</p>", "<li>", "<ul>", "</ul>", "<pre>", "</pre>", "<a href=x>", "</a>", "<table>", "<td>", "</table>", "<blockquote>", "<main>", "</main>", "<script>", "<!--", "&amp;", "<b>", "</i>", "<code>" };
    var buf: [4096]u8 = undefined;
    for (0..400) |_| {
        _ = arena.reset(.retain_capacity);
        var n: usize = 0;
        const len = r.uintLessThan(usize, buf.len - 32);
        while (n < len) {
            if (r.boolean()) {
                const t = tags[r.uintLessThan(usize, tags.len)];
                @memcpy(buf[n .. n + t.len], t);
                n += t.len;
            } else {
                buf[n] = alphabet[r.uintLessThan(usize, alphabet.len)];
                n += 1;
            }
        }
        const md = try h2m.htmlToMarkdown(arena.allocator(), buf[0..n], "https://e.com/", .{ .max_bytes = 8192 });
        try testing.expect(md.len <= 8192);
    }
    // Deep nesting is flattened, not a stack overflow.
    const deep = try arena.allocator().alloc(u8, 4 * 2000);
    for (0..2000) |i| @memcpy(deep[i * 4 ..][0..4], "<ul>");
    _ = try h2m.htmlToMarkdown(arena.allocator(), deep, "https://e.com/", .{});
}

test "fuzz: html2md" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const n = s.slice(&buf);
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const md = try h2m.htmlToMarkdown(arena.allocator(), buf[0..n], "https://e.com/a/b", .{ .max_bytes = 16 * 1024 });
            try testing.expect(md.len <= 16 * 1024);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "html2md") });
}
