//! UAX #29 conformance (GraphemeBreakTest, WordBreakTest) and consistency
//! tests for the grapheme and word segmenters.

const std = @import("std");
const testing = std.testing;
const grapheme = @import("grapheme.zig");
const word = @import("word.zig");
const props = @import("props.zig");
const options = @import("zg_options");

/// Reads `ucd/<version>/<rel>`.
pub fn readUcd(gpa: std.mem.Allocator, rel: []const u8) ![]u8 {
    const io = testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "ucd/" ++ props.unicode_version, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, rel, gpa, .limited(64 << 20));
}

/// One conformance case: UTF-8 text and the expected boundary offsets
/// (excluding 0 and the end).
pub const Case = struct {
    text: [1024]u8 = undefined,
    len: usize = 0,
    breaks: [256]usize = undefined,
    nbreaks: usize = 0,
    line: usize = 0,

    /// The UTF-8 text.
    pub fn bytes(c: *const Case) []const u8 {
        return c.text[0..c.len];
    }
};

/// Parses a `÷ XXXX × YYYY ÷` line; null for comments and blank lines.
pub fn parseCase(raw: []const u8, line: usize) !?Case {
    var s = raw;
    if (std.mem.indexOfScalar(u8, s, '#')) |h| s = s[0..h];
    s = std.mem.trim(u8, s, " \t\r");
    if (s.len == 0) return null;
    var c: Case = .{ .line = line };
    var it = std.mem.tokenizeAny(u8, s, " \t");
    var first = true;
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "÷")) {
            if (!first and c.len > 0) {
                c.breaks[c.nbreaks] = c.len;
                c.nbreaks += 1;
            }
        } else if (std.mem.eql(u8, tok, "×")) {} else {
            const cp = try std.fmt.parseInt(u21, tok, 16);
            c.len += try std.unicode.utf8Encode(cp, c.text[c.len..]);
        }
        first = false;
    }
    // The final ÷ (end of text) is implicit.
    if (c.nbreaks > 0 and c.breaks[c.nbreaks - 1] == c.len) c.nbreaks -= 1;
    return c;
}

fn expectBreaks(c: *const Case, got: []const usize) !void {
    testing.expectEqualSlices(usize, c.breaks[0..c.nbreaks], got) catch |e| {
        std.debug.print("line {d}: text {x}\n", .{ c.line, c.bytes() });
        return e;
    };
}

test "GraphemeBreakTest.txt conformance" {
    const data = try readUcd(testing.allocator, "auxiliary/GraphemeBreakTest.txt");
    defer testing.allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    var cases: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const c = (try parseCase(raw, n)) orelse continue;
        cases += 1;
        var got: [64]usize = undefined;
        var k: usize = 0;
        var it = grapheme.Iterator.init(c.bytes());
        while (it.next()) |sp| if (sp.start + sp.len < c.len) {
            got[k] = sp.start + sp.len;
            k += 1;
        };
        try expectBreaks(&c, got[0..k]);
        try testing.expectEqual(k + 1, grapheme.count(c.bytes()));
        // Streaming API agrees.
        var st: grapheme.State = .{};
        var view = std.unicode.Utf8View.initUnchecked(c.bytes()).iterator();
        var k2: usize = 0;
        var prev: u21 = 0;
        var pos: usize = 0;
        while (view.nextCodepoint()) |cp| {
            if (grapheme.isBoundary(&st, prev, cp) and pos != 0) {
                try testing.expectEqual(got[k2], pos);
                k2 += 1;
            }
            prev = cp;
            pos = view.i;
        }
        try testing.expectEqual(k, k2);
    }
    try testing.expect(cases > 800);
}

test "WordBreakTest.txt conformance" {
    const data = try readUcd(testing.allocator, "auxiliary/WordBreakTest.txt");
    defer testing.allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    var cases: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const c = (try parseCase(raw, n)) orelse continue;
        cases += 1;
        var got: [64]usize = undefined;
        var k: usize = 0;
        var it = word.WordIterator.init(c.bytes());
        while (it.next()) |sp| if (sp.start + sp.len < c.len) {
            got[k] = sp.start + sp.len;
            k += 1;
        };
        try expectBreaks(&c, got[0..k]);
    }
    try testing.expect(cases > 1800);
}

/// Weighted random text: ASCII, emoji ZWJ sequences, RIs, Hangul, Indic
/// conjuncts, combining marks, CR/LF and invalid bytes.
fn randomText(r: std.Random, buf: []u8) []u8 {
    const pieces = [_][]const u8{
        "a",        "Z",        "1",         " ",        "\r",       "\n",        "\r\n",      ".",         "'",        "_",
        "\u{301}",  "\u{200D}", "\u{1F468}", "\u{2764}", "\u{FE0F}", "\u{1F3FD}", "\u{1F1FA}", "\u{1F1F8}", "\u{1100}", "\u{1161}",
        "\u{11A8}", "\u{AC00}", "\u{915}",   "\u{94D}",  "\u{937}",  "\u{9CD}",   "\u{995}",   "\u{600}",   "\u{5D0}",  "\u{30A2}",
        "\u{4E00}", "\u{3000}", "\xFF",      "\xE0\x80", "\xC3",
    };
    var n: usize = 0;
    while (true) {
        const piece = pieces[r.uintLessThan(usize, pieces.len)];
        if (n + piece.len > buf.len) break;
        @memcpy(buf[n..][0..piece.len], piece);
        n += piece.len;
        if (r.uintLessThan(u8, 24) == 0) break;
    }
    return buf[0..n];
}

fn checkConsistency(text: []const u8) !void {
    // Grapheme: forward boundaries, prevBoundary at every code point start.
    var bounds: [512]usize = undefined;
    var nb: usize = 0;
    var it = grapheme.Iterator.init(text);
    while (it.next()) |sp| {
        bounds[nb] = sp.start;
        nb += 1;
        try testing.expect(sp.len > 0);
    }
    try testing.expectEqual(nb, grapheme.count(text));
    var off: usize = 0;
    while (off <= text.len) : (off += 1) {
        // Expected: the last forward boundary < snapped offset.
        const snapped = @import("decode.zig").snap(text, off);
        var want: usize = 0;
        for (bounds[0..nb]) |b| if (b < snapped) {
            want = b;
        };
        try testing.expectEqual(want, grapheme.prevBoundary(text, off));
    }
    // Word: iterator spans agree with isBoundary.
    var wit = word.WordIterator.init(text);
    while (wit.next()) |sp| {
        try testing.expect(word.isBoundary(text, sp.start));
        try testing.expect(sp.len > 0);
        if (sp.start > 0) try testing.expectEqual(word.prevBoundary(text, sp.start + sp.len - 1) <= sp.start, true);
    }
}

test "prevBoundary equals forward iteration on random text" {
    var prng: std.Random.DefaultPrng = .init(0x29);
    var buf: [200]u8 = undefined;
    for (0..10_000) |_| try checkConsistency(randomText(prng.random(), &buf));
}

test "ascii fast path equals slow path" {
    const text = "Hello, world!\r\nfoo\rbar\n\n  x";
    var s: grapheme.State = .{};
    var i: usize = 0;
    var slow: [64]usize = undefined;
    var n: usize = 0;
    while (i < text.len) : (i += 1) {
        if (s.feed(.of(text[i], true)) and i != 0) {
            slow[n] = i;
            n += 1;
        }
    }
    var fast: [64]usize = undefined;
    var m: usize = 0;
    var it = grapheme.Iterator.init(text);
    while (it.next()) |sp| if (sp.start != 0) {
        fast[m] = sp.start;
        m += 1;
    };
    try testing.expectEqualSlices(usize, slow[0..n], fast[0..m]);
    try testing.expectEqual(n + 1, grapheme.count(text ** 3) / 3 + 0 * n);
}

test "invalid utf8 clusters" {
    // Each maximal ill-formed subsequence is its own cluster, even before
    // a combining mark (Control semantics).
    const text = "a\xFF\u{301}\xE0\x80b";
    var it = grapheme.Iterator.init(text);
    const spans = [_][2]usize{ .{ 0, 1 }, .{ 1, 1 }, .{ 2, 2 }, .{ 4, 1 }, .{ 5, 1 }, .{ 6, 1 } };
    for (spans) |sp| {
        const got = it.next().?;
        try testing.expectEqual(sp[0], got.start);
        try testing.expectEqual(sp[1], got.len);
    }
    try testing.expect(it.next() == null);
}

test "grapheme samples" {
    // Family emoji, flag pair, Devanagari and Bengali conjuncts (GB9c).
    try testing.expectEqual(@as(usize, 1), grapheme.count("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
    try testing.expectEqual(@as(usize, 2), grapheme.count("\u{1F1FA}\u{1F1F8}\u{1F1EB}\u{1F1F7}"));
    try testing.expectEqual(@as(usize, 1), grapheme.count("\u{915}\u{94D}\u{937}"));
    try testing.expectEqual(@as(usize, 1), grapheme.count("\u{995}\u{9CD}\u{9B7}"));
    try testing.expectEqual(@as(usize, 1), grapheme.count("\u{995}\u{9CD}\u{200D}\u{9B7}"));
    try testing.expectEqual(@as(usize, 1), grapheme.count("\r\n"));
}

test "wordAt identifier with underscore" {
    const text = "let my_var2 = foo.bar(3.14);";
    const w = word.wordAt(text, 6);
    try testing.expectEqualStrings("my_var2", text[w.start..][0..w.len]);
    try testing.expectEqual(word.WordSpan.Kind.word, w.kind);
    const num = word.wordAt(text, 23);
    try testing.expectEqualStrings("3.14", text[num.start..][0..num.len]);
    try testing.expectEqual(word.WordSpan.Kind.number, num.kind);
    try testing.expectEqual(word.WordSpan.Kind.space, word.wordAt(text, 3).kind);
    try testing.expectEqual(word.WordSpan.Kind.punct, word.wordAt(text, 21).kind);
    try testing.expectEqual(word.WordSpan.Kind.other, word.wordAt(text, 12).kind);
    try testing.expectEqualStrings("foo.bar", text[14..][0..word.wordAt(text, 16).len]);
    try testing.expectEqual(@as(usize, 4), word.nextWordStart(text, 0));
    try testing.expectEqual(@as(usize, 14), word.nextWordStart(text, 4));
    try testing.expectEqual(@as(usize, 14), word.prevWordStart(text, 21));
    try testing.expectEqual(@as(usize, 0), word.prevWordStart(text, 3));
    const e = word.wordAt("", 0);
    try testing.expectEqual(@as(usize, 0), e.len);
}

/// Normalization invariants: every form is idempotent and NFC(NFD(x)) is
/// NFC(x).
fn checkNormalize(input: []const u8) !void {
    const norm = @import("normalize.zig");
    const gpa = testing.allocator;
    for ([_]norm.Form{ .nfc, .nfd, .nfkc, .nfkd }) |form| {
        const once = try norm.normalize(gpa, input, form);
        defer gpa.free(once);
        const twice = try norm.normalize(gpa, once, form);
        defer gpa.free(twice);
        try testing.expectEqualSlices(u8, once, twice);
    }
    const nfd = try norm.normalize(gpa, input, .nfd);
    defer gpa.free(nfd);
    const a = try norm.normalize(gpa, nfd, .nfc);
    defer gpa.free(a);
    const b = try norm.normalize(gpa, input, .nfc);
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, b, a);
}

test "fuzz: unicode-segment" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [200]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            try checkConsistency(input);
            try checkNormalize(input);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "unicode-segment") });
}
