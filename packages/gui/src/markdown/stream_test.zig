//! Streaming parses (E04.F06.S01.T01): any chunking, including splits
//! inside UTF-8 sequences, gives the same document as a batch parse;
//! deltas name the changed blocks; zigguro extensions; pathological
//! inputs stay linear.

const std = @import("std");
const ast = @import("ast.zig");
const stream = @import("stream.zig");
const serializer = @import("html_test_serializer.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn html(d: *const @import("doc.zig").Doc) ![]u8 {
    return serializer.render(gpa, d);
}

fn expectRender(src: []const u8, opts: ast.Options, expected: []const u8) !void {
    var d = try stream.parse(gpa, src, opts);
    defer d.deinit();
    const got = try html(&d);
    defer gpa.free(got);
    try testing.expectEqualStrings(expected, got);
}

fn streamed(src: []const u8, opts: ast.Options, rng: std.Random) ![]u8 {
    var d = stream.init(gpa, opts);
    defer d.deinit();
    var i: usize = 0;
    while (i < src.len) {
        const n = @min(src.len - i, rng.intRangeAtMost(usize, 1, 12));
        _ = try stream.append(&d, src[i .. i + n]);
        i += n;
    }
    _ = try stream.finish(&d);
    return html(&d);
}

const corpus =
    \\---
    \\title: Notes
    \\---
    \\# Heading with *emph* and `code`
    \\
    \\A paragraph with [a link][ref], ~~strike~~, and www.example.com/path.
    \\Ünïcödé — 漢字 and emoji 🚀 split anywhere.
    \\
    \\> [!NOTE]
    \\> A callout with **strong** text.
    \\
    \\- [ ] task one
    \\- [x] task two
    \\  continued
    \\
    \\1. first
    \\2. second
    \\
    \\```zig
    \\const x = 1;
    \\```
    \\
    \\| a | b |
    \\|:--|--:|
    \\| 1 | 2 |
    \\
    \\$$
    \\e = mc^2
    \\$$
    \\
    \\Inline $x^2$ math and [[Wiki Page|alias]] and ![[embed.png]].
    \\
    \\[ref]: https://example.com "Title"
    \\
;

test "streaming matches batch under random chunking" {
    const opts: ast.Options = .{};
    var d = try stream.parse(gpa, corpus, opts);
    defer d.deinit();
    const batch = try html(&d);
    defer gpa.free(batch);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    for (0..200) |_| {
        const got = try streamed(corpus, opts, prng.random());
        defer gpa.free(got);
        try testing.expectEqualStrings(batch, got);
    }
}

test "byte-at-a-time streaming matches batch" {
    const opts: ast.Options = .{};
    var d = try stream.parse(gpa, corpus, opts);
    defer d.deinit();
    const batch = try html(&d);
    defer gpa.free(batch);
    var s = stream.init(gpa, opts);
    defer s.deinit();
    for (0..corpus.len) |i| _ = try stream.append(&s, corpus[i .. i + 1]);
    _ = try stream.finish(&s);
    const got = try html(&s);
    defer gpa.free(got);
    try testing.expectEqualStrings(batch, got);
}

test "stable blocks keep their indices and deltas name the tail" {
    var d = stream.init(gpa, .{});
    defer d.deinit();
    _ = try stream.append(&d, "# One\n\npara one\n\n");
    const first = d.blocks.items[0].first_child;
    try testing.expect(first != ast.none);
    const delta = try stream.append(&d, "para two\n\n# Three\n");
    try testing.expectEqual(first, d.blocks.items[0].first_child);
    try testing.expect(delta.first_changed_block >= 1);
    _ = try stream.finish(&d);
}

test "a late reference definition marks earlier blocks changed" {
    var d = stream.init(gpa, .{});
    defer d.deinit();
    _ = try stream.append(&d, "see [x]\n\nmore text\n\n");
    const delta = try stream.append(&d, "[x]: /dest\n\n");
    try testing.expectEqual(@as(u32, 0), delta.first_changed_block);
    _ = try stream.finish(&d);
    const got = try html(&d);
    defer gpa.free(got);
    try testing.expectEqualStrings("<p>see <a href=\"/dest\">x</a></p>\n<p>more text</p>\n", got);
}

test "zigguro extensions" {
    try expectRender("> [!WARNING]\n> careful\n", .{}, "<blockquote>\n<p>careful</p>\n</blockquote>\n");
    try expectRender("---\na: 1\n---\nbody\n", .{}, "<pre><code class=\"language-math\">a: 1\n</code></pre>\n<p>body</p>\n");
    try expectRender("$$\nx\n$$\n", .{}, "<pre><code class=\"language-math\">x\n</code></pre>\n");
    try expectRender("$a+b$\n", .{}, "<p><span class=\"math\">a+b</span></p>\n");
    try expectRender("[[Page]]\n", .{}, "<p><a class=\"wikilink\" href=\"Page\">Page</a></p>\n");
    // Extensions off: plain CommonMark.
    try expectRender("$a$ [[P]]\n", .{ .math = false, .wikilinks = false }, "<p>$a$ [[P]]</p>\n");
}

test "callout kind and front matter are recorded" {
    var d = try stream.parse(gpa, "---\nk: v\n---\n> [!TIP] Title\n> body\n", .{});
    defer d.deinit();
    var kinds: [4]ast.BlockKind = undefined;
    var n: usize = 0;
    var c = d.blocks.items[0].first_child;
    while (c != ast.none and n < kinds.len) : (c = d.blocks.items[c].next) {
        kinds[n] = d.blocks.items[c].kind;
        n += 1;
    }
    try testing.expectEqualSlices(ast.BlockKind, &.{ .front_matter, .callout }, kinds[0..n]);
}

test "document size limit" {
    try testing.expectError(error.DocumentTooLarge, stream.parse(gpa, "abcdef", .{ .max_bytes = 4 }));
    var d = stream.init(gpa, .{ .max_bytes = 4 });
    defer d.deinit();
    _ = try stream.append(&d, "abc");
    try testing.expectError(error.DocumentTooLarge, stream.append(&d, "de"));
}

fn timed(src: []const u8) !u64 {
    const t0 = std.Io.Timestamp.now(testing.io, .awake);
    var d = try stream.parse(gpa, src, .{});
    d.deinit();
    return @intCast(t0.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds());
}

fn repeat(a: std.mem.Allocator, s: []const u8, n: usize) ![]u8 {
    const out = try a.alloc(u8, s.len * n);
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

test "pathological inputs parse in linear time" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const patterns = [_][]const u8{ "*a", "_a", "[", "a]", "`a", "<", "![", "[a](", "*a**", "> ", "- ", "~~a", "[]: ", "\\", "&#", "$", "[[" };
    for (patterns) |p| {
        const small = try repeat(a, p, 5_000);
        const big = try repeat(a, p, 50_000);
        _ = try timed(small);
        const t_small = try timed(small);
        const t_big = try timed(big);
        // 10x input: allow generous slack, but quadratic would be ~100x.
        if (t_big > t_small * 40 + 20 * std.time.ns_per_ms) {
            std.debug.print("pattern {s}: {d}ns vs {d}ns\n", .{ p, t_small, t_big });
            return error.NotLinear;
        }
    }
}
