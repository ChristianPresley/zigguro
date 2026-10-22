//! Tests for display width.

const std = @import("std");
const testing = std.testing;
const width = @import("width.zig");

const narrow: width.WidthOptions = .{};
const wide: width.WidthOptions = .{ .ambiguous_wide = true };

test "wcwidth table" {
    const cases = [_]struct { u21, i8 }{
        // Controls.
        .{ 0x00, 0 },    .{ 0x01, -1 },   .{ 0x07, -1 },   .{ 0x1B, -1 },   .{ 0x1F, -1 },
        .{ 0x7F, -1 },   .{ 0x80, -1 },   .{ 0x85, -1 },   .{ 0x9F, -1 },
        // ASCII and Latin.
          .{ ' ', 1 },
        .{ 'A', 1 },     .{ '~', 1 },     .{ 0xA0, 1 },    .{ 0xF1, 1 },    .{ 0x16A0, 1 },
        .{ 0x2E3A, 1 },
        // SOFT HYPHEN stays visible.
         .{ 0xAD, 1 },
        // Combining marks and format characters.
           .{ 0x0300, 0 },  .{ 0x036F, 0 },  .{ 0x0483, 0 },
        .{ 0x0488, 0 },  .{ 0x0E31, 0 },  .{ 0x200B, 0 },  .{ 0x200C, 0 },  .{ 0x200D, 0 },
        .{ 0x200E, 0 },  .{ 0x2060, 0 },  .{ 0xFEFF, 0 },  .{ 0xFE0E, 0 },  .{ 0xFE0F, 0 },
        .{ 0xE0001, 0 }, .{ 0xE0100, 0 },
        // Hangul: initial Jamo wide, medial/final zero, syllables wide.
        .{ 0x1100, 2 },  .{ 0x1160, 0 },  .{ 0x11A8, 0 },
        .{ 0x11FF, 0 },  .{ 0xD7B0, 0 },  .{ 0xD7FB, 0 },  .{ 0xAC00, 2 },  .{ 0xD7A3, 2 },
        // East Asian wide and fullwidth, halfwidth.
        .{ 0x4E00, 2 },  .{ 0x9FFF, 2 },  .{ 0x3400, 2 },  .{ 0x20000, 2 }, .{ 0x3000, 2 },
        .{ 0xFF01, 2 },  .{ 0xFF61, 1 },  .{ 0x2329, 2 },
        // Unassigned ideographic planes default to wide.
         .{ 0x2FFFD, 2 }, .{ 0x3FFFD, 2 },
        // Emoji: presentation wide, text-default narrow.
        .{ 0x1F600, 2 }, .{ 0x231A, 2 },  .{ 0x1F3FB, 2 }, .{ 0x2764, 1 },  .{ 0x2603, 1 },
        .{ 0x1F1E6, 1 },
        // Ambiguous, narrow by default.
        .{ 0xB1, 1 },    .{ 0x3B1, 1 },   .{ 0x2010, 1 },  .{ 0xE000, 1 },
        .{ 0xFFFD, 1 },
    };
    try testing.expect(cases.len >= 60);
    for (cases) |c| {
        testing.expectEqual(c[1], width.wcwidth(c[0], narrow)) catch |e| {
            std.debug.print("U+{X:0>4}\n", .{c[0]});
            return e;
        };
    }
}

test "ambiguous option" {
    for ([_]u21{ 0xB1, 0x3B1, 0x2010, 0xE000, 0xFFFD, 0xE9 }) |cp| {
        try testing.expectEqual(@as(i8, 1), width.wcwidth(cp, narrow));
        try testing.expectEqual(@as(i8, 2), width.wcwidth(cp, wide));
    }
    try testing.expectEqual(@as(i8, 1), width.wcwidth('a', wide));
    try testing.expectEqual(@as(usize, 4), width.stringWidth("\u{3B1}\u{3B2}", wide, .grapheme));
    try testing.expectEqual(@as(usize, 2), width.stringWidth("\u{3B1}\u{3B2}", narrow, .grapheme));
}

test "graphemeWidth emoji VS15/VS16/ZWJ/RI" {
    // ❤ is narrow, ❤️ (VS16) wide, ☺︎ (VS15) narrow; ⌚︎ narrowed by VS15.
    try testing.expectEqual(@as(u2, 1), width.graphemeWidth("\u{2764}", narrow));
    try testing.expectEqual(@as(u2, 2), width.graphemeWidth("\u{2764}\u{FE0F}", narrow));
    try testing.expectEqual(@as(u2, 1), width.graphemeWidth("\u{263A}\u{FE0E}", narrow));
    try testing.expectEqual(@as(u2, 1), width.graphemeWidth("\u{231A}\u{FE0E}", narrow));
    // ZWJ family and skin-tone modifier.
    try testing.expectEqual(@as(u2, 2), width.graphemeWidth("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", narrow));
    try testing.expectEqual(@as(u2, 2), width.graphemeWidth("\u{1F44D}\u{1F3FD}", narrow));
    // Flag (RI pair) is wide, a lone RI narrow.
    try testing.expectEqual(@as(u2, 2), width.graphemeWidth("\u{1F1FA}\u{1F1F8}", narrow));
    try testing.expectEqual(@as(u2, 1), width.graphemeWidth("\u{1F1FA}", narrow));
    // Base plus combining marks; Hangul syllable from Jamo.
    try testing.expectEqual(@as(u2, 1), width.graphemeWidth("e\u{301}\u{308}", narrow));
    try testing.expectEqual(@as(u2, 2), width.graphemeWidth("\u{1100}\u{1161}\u{11A8}", narrow));
    // Controls and empty clusters take no cells.
    try testing.expectEqual(@as(u2, 0), width.graphemeWidth("\t", narrow));
    try testing.expectEqual(@as(u2, 0), width.graphemeWidth("", narrow));
    try testing.expectEqual(@as(u2, 0), width.graphemeWidth("\r\n", narrow));
}

test "stringWidth modes" {
    const s = "a\u{1F468}\u{200D}\u{1F469} \u{4E2D}\u{6587}e\u{301}";
    // Per code point: 1 + 2 + 0 + 2 + 1 + 2 + 2 + 1 + 0.
    try testing.expectEqual(@as(usize, 11), width.stringWidth(s, narrow, .codepoint));
    // Per grapheme: the ZWJ sequence is one wide cluster.
    try testing.expectEqual(@as(usize, 9), width.stringWidth(s, narrow, .grapheme));
    try testing.expectEqual(@as(usize, 0), width.stringWidth("", narrow, .grapheme));
}
