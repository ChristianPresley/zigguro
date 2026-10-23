//! The note search tokenizer (E08.F06.S03.T01). Words are UAX #29 word
//! and number segments (so `don't` and `snake_case` stay whole),
//! case-folded. Han, Hiragana and Katakana runs become character bigrams
//! (a lone character stays a unigram), so CJK text is searchable without
//! a dictionary. Tokens over 64 bytes are dropped. No stemming in v1.

const std = @import("std");
const zg_text = @import("zg_text");

const Allocator = std.mem.Allocator;
const word = zg_text.unicode.word;

pub const max_token = 64;

pub const Token = struct {
    /// The folded text (valid until the tokenizer runs again).
    text: []const u8,
    /// Source byte range.
    start: u32,
    end: u32,
};

/// Reusable token buffers.
pub const Tokenizer = struct {
    buf: std.ArrayList(u8) = .empty,
    toks: std.ArrayList(Raw) = .empty,

    const Raw = struct { off: u32, len: u32, start: u32, end: u32 };

    pub fn deinit(t: *Tokenizer, gpa: Allocator) void {
        t.buf.deinit(gpa);
        t.toks.deinit(gpa);
    }

    pub fn len(t: *const Tokenizer) usize {
        return t.toks.items.len;
    }

    pub fn get(t: *const Tokenizer, i: usize) Token {
        const r = t.toks.items[i];
        return .{ .text = t.buf.items[r.off..][0..r.len], .start = r.start, .end = r.end };
    }

    /// Tokenizes `bytes`, replacing the previous tokens.
    pub fn run(t: *Tokenizer, gpa: Allocator, bytes: []const u8) !void {
        t.buf.clearRetainingCapacity();
        t.toks.clearRetainingCapacity();
        try t.append(gpa, bytes, 0);
    }

    /// Appends the tokens of `bytes`, offsetting source ranges by `base`.
    pub fn append(t: *Tokenizer, gpa: Allocator, bytes: []const u8, base: u32) !void {
        var it = word.WordIterator.init(bytes);
        // The pending CJK run: code point starts, plus its end.
        var cjk: std.ArrayList(u32) = .empty;
        defer cjk.deinit(gpa);
        var run_end: u32 = 0;
        while (it.next()) |span| {
            const s: u32 = @intCast(span.start);
            const e: u32 = @intCast(span.start + span.len);
            if (span.kind == .word or span.kind == .other) {
                if (isCjk(firstCp(bytes[s..e]))) {
                    if (cjk.items.len > 0 and run_end != s) try t.flushRun(gpa, bytes, base, &cjk, run_end);
                    var i = s;
                    while (i < e) {
                        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
                        try cjk.append(gpa, i);
                        i += @min(n, e - i);
                    }
                    run_end = e;
                    continue;
                }
            }
            if (cjk.items.len > 0) try t.flushRun(gpa, bytes, base, &cjk, run_end);
            if (span.kind != .word and span.kind != .number) continue;
            if (span.len > max_token) continue;
            try t.push(gpa, bytes[s..e], base + s, base + e);
        }
        if (cjk.items.len > 0) try t.flushRun(gpa, bytes, base, &cjk, run_end);
    }

    fn flushRun(t: *Tokenizer, gpa: Allocator, bytes: []const u8, base: u32, cjk: *std.ArrayList(u32), end: u32) !void {
        const starts = cjk.items;
        if (starts.len == 1) {
            try t.push(gpa, bytes[starts[0]..end], base + starts[0], base + end);
        } else for (0..starts.len - 1) |i| {
            const e = if (i + 2 < starts.len) starts[i + 2] else end;
            try t.push(gpa, bytes[starts[i]..e], base + starts[i], base + e);
        }
        cjk.clearRetainingCapacity();
    }

    fn push(t: *Tokenizer, gpa: Allocator, raw: []const u8, start: u32, end: u32) !void {
        const off: u32 = @intCast(t.buf.items.len);
        try foldInto(&t.buf, gpa, raw);
        try t.toks.append(gpa, .{ .off = off, .len = @intCast(t.buf.items.len - off), .start = start, .end = end });
    }
};

/// Appends the case-folded `s` (ASCII fast path).
pub fn foldInto(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    for (s) |c| if (c >= 0x80) return zg_text.unicode.casefold.foldAppend(out, gpa, s, .full);
    try out.ensureUnusedCapacity(gpa, s.len);
    for (s) |c| out.appendAssumeCapacity(std.ascii.toLower(c));
}

fn firstCp(s: []const u8) u21 {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0xFFFD;
    if (n > s.len) return 0xFFFD;
    return std.unicode.utf8Decode(s[0..n]) catch 0xFFFD;
}

/// Han, Hiragana and Katakana (including half-width and extensions).
pub fn isCjk(cp: u21) bool {
    return switch (cp) {
        0x3040...0x30FF, // Hiragana, Katakana
        0x31F0...0x31FF, // Katakana phonetic extensions
        0x3400...0x4DBF, // CJK extension A
        0x4E00...0x9FFF, // CJK unified ideographs
        0xF900...0xFAFF, // compatibility ideographs
        0xFF66...0xFF9F, // half-width Katakana
        0x20000...0x3FFFF, // extensions B and later
        => true,
        else => false,
    };
}

fn expectTokens(src: []const u8, want: []const []const u8) !void {
    const gpa = std.testing.allocator;
    var t: Tokenizer = .{};
    defer t.deinit(gpa);
    try t.run(gpa, src);
    errdefer for (0..t.len()) |i| std.debug.print("token {d}: '{s}'\n", .{ i, t.get(i).text });
    try std.testing.expectEqual(want.len, t.len());
    for (want, 0..) |w, i| try std.testing.expectEqualStrings(w, t.get(i).text);
}

test "tokenize: unicode words, apostrophes, CJK bigrams" {
    try expectTokens("Hello, World! don't snake_case 3.14 v2", &.{ "hello", "world", "don't", "snake_case", "3.14", "v2" });
    try expectTokens("Straße ÉCOLE naïve", &.{ "strasse", "école", "naïve" });
    try expectTokens("東京都に行く", &.{ "東京", "京都", "都に", "に行", "行く" });
    try expectTokens("漢 字", &.{ "漢", "字" });
    try expectTokens("カタカナ and 中文", &.{ "カタ", "タカ", "カナ", "and", "中文" });
    const long = "a" ** 65;
    try expectTokens("ok " ++ long ++ " fine", &.{ "ok", "fine" });
    try expectTokens("#tag [[Link]] `code`", &.{ "tag", "link", "code" });
    // Source ranges.
    const gpa = std.testing.allocator;
    var t: Tokenizer = .{};
    defer t.deinit(gpa);
    try t.run(gpa, "ab 東京都");
    try std.testing.expectEqual(@as(u32, 3), t.get(1).start);
    try std.testing.expectEqual(@as(u32, 9), t.get(1).end);
    try std.testing.expectEqual(@as(u32, 12), t.get(2).end);
}
