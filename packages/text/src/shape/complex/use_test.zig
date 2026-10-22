//! Universal Shaping Engine tests: classes, the syllable machine, dotted
//! circles and shaper selection. Shaped goldens are in `shaper_test.zig`.

const std = @import("std");
const testing = std.testing;
const use = @import("use.zig");
const C = use.UseCategory;
const default = @import("default.zig");
const dotted = @import("dotted_circle.zig");
const Buffer = @import("../buffer.zig").Buffer;
const ot = @import("../../ot/root.zig");
const fonts = @import("../../testing/fonts.zig");
const unicode = @import("../../unicode/root.zig");

test "use category mapping samples" {
    const cases = [_]struct { u21, C }{
        // Javanese.
        .{ 0xA98F, .B }, // KA
        .{ 0xA9BA, .VPre }, // TALING
        .{ 0xA9BC, .VAbv }, // PEPET
        .{ 0xA9B8, .VBlw }, // SUKU
        .{ 0xA9B4, .VPst }, // TARUNG
        .{ 0xA9C0, .H }, // PANGKON
        .{ 0xA9BE, .MPst }, // PENGKAL
        .{ 0xA9BF, .MBlw }, // CAKRA
        .{ 0xA982, .FAbv }, // LAYAR
        .{ 0xA983, .VMPst }, // WIGNYAN
        .{ 0xA981, .VMAbv }, // CECAK
        .{ 0xA9B3, .CMAbv }, // CECAK TELU
        // Tibetan.
        .{ 0x0F40, .B },
        .{ 0x0F90, .SUB },
        .{ 0x0FB2, .SUB },
        .{ 0x0F72, .VBlw }, // Bottom per Microsoft (see below)
        .{ 0x0F74, .VAbv }, // Top per Microsoft
        .{ 0x0F7E, .VMAbv },
        .{ 0x0F84, .VBlw }, // HALANTA: a pure killer
        .{ 0x0F39, .CMAbv },
        .{ 0x0F0B, .O },
        // Balinese.
        .{ 0x1B13, .B },
        .{ 0x1B3E, .VPre },
        .{ 0x1B44, .H },
        .{ 0x1B03, .FAbv },
        // Sundanese.
        .{ 0x1B8A, .B },
        .{ 0x1BA1, .SUB },
        .{ 0x1BAA, .VPst }, // PAMAAEH: a pure killer
        .{ 0x1BA6, .VPre },
        // Tai Tham.
        .{ 0x1A20, .B },
        .{ 0x1A60, .Sk },
        .{ 0x1A6E, .VPre },
        // Khmer (classes only; Khmer does not shape with USE).
        .{ 0x1780, .B },
        .{ 0x17D2, .IS },
        .{ 0x17C1, .VPre },
        // Sinhala.
        .{ 0x0D9A, .B },
        .{ 0x0DCA, .HVM },
        .{ 0x0DD9, .VPre },
        // Joiners and others.
        .{ 0x200C, .ZWNJ },
        .{ 0x200D, .CGJ },
        .{ 0x034F, .CGJ },
        .{ 0x2060, .WJ },
        .{ 0x25CC, .B },
        .{ 'a', .O },
        // Scripts USE does not handle stay O.
        .{ 0x0628, .O },
        .{ 0x0E01, .O },
    };
    for (cases) |c| {
        if (use.useCategory(c[0]) != c[1]) std.debug.print("U+{X:0>4}: got {t}, want {t}\n", .{ c[0], use.useCategory(c[0]), c[1] });
        try testing.expectEqual(c[1], use.useCategory(c[0]));
    }
}

test "override file applied" {
    // IndicPositionalCategory.txt has U+0F72 TIBETAN VOWEL SIGN I as Top;
    // the Microsoft file moves it to Bottom so it orders after U+0F71.
    try testing.expectEqual(unicode.IndicPositional.Top, unicode.indicCategories(0x0F72).positional);
    try testing.expectEqual(C.VBlw, use.useCategory(0x0F72));
    // U+1C36 LEPCHA SIGN RAN becomes a final consonant modifier (as a
    // syllable modifier) and U+25CC DOTTED CIRCLE a consonant.
    try testing.expectEqual(C.FMAbv, use.useCategory(0x1C36));
    try testing.expectEqual(C.B, use.useCategory(0x25CC));
    // Hieroglyph classes exist only in the Microsoft file.
    try testing.expectEqual(C.J, use.useCategory(0x13430));
    try testing.expectEqual(C.G, use.useCategory(0x13000));
}

fn syllables(cats: []const C) ![]const struct { usize, use.SyllableType } {
    const S = struct {
        var out: [32]struct { usize, use.SyllableType } = undefined;
    };
    var n: usize = 0;
    var k: usize = 0;
    while (k < cats.len) {
        const m = use.Machine.longestMatch(cats, k).?;
        S.out[n] = .{ m.len, g_types[m.rule] };
        n += 1;
        k += m.len;
    }
    return S.out[0..n];
}

const g_types = [_]use.SyllableType{ .virama_terminated, .sakot_terminated, .standard, .number_joiner_terminated, .numeral, .symbol, .hieroglyph, .non_cluster, .broken, .non_cluster };

fn expectSyllables(cats: []const C, want: []const struct { usize, use.SyllableType }) !void {
    const got = try syllables(cats);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, x| {
        try testing.expectEqual(w[0], x[0]);
        try testing.expectEqual(w[1], x[1]);
    }
}

test "cluster DFA accepts spec examples" {
    // Base + pre-base vowel + post vowel.
    try expectSyllables(&.{ .B, .VPre, .VPst }, &.{.{ 3, .standard }});
    // Repha, base, halant, base (a conjunct), vowel, final.
    try expectSyllables(&.{ .R, .B, .H, .B, .VAbv, .FAbv }, &.{.{ 6, .standard }});
    // Virama-terminated: base + invisible stacker.
    try expectSyllables(&.{ .B, .IS }, &.{.{ 2, .virama_terminated }});
    // Sakot-terminated.
    try expectSyllables(&.{ .B, .Sk }, &.{.{ 2, .sakot_terminated }});
    // Base + sakot + base continues the syllable.
    try expectSyllables(&.{ .B, .Sk, .B, .VAbv }, &.{.{ 4, .standard }});
    // Numerals.
    try expectSyllables(&.{ .N, .HN, .N }, &.{.{ 3, .numeral }});
    try expectSyllables(&.{ .N, .HN }, &.{.{ 2, .number_joiner_terminated }});
    // Symbol with modifiers.
    try expectSyllables(&.{ .O, .SMAbv }, &.{.{ 2, .symbol }});
    // Hieroglyphs joined.
    try expectSyllables(&.{ .G, .J, .G }, &.{.{ 3, .hieroglyph }});
    // Two syllables; a trailing ZWNJ stays with the first.
    try expectSyllables(&.{ .B, .VAbv, .ZWNJ, .B }, &.{ .{ 3, .standard }, .{ 1, .standard } });
    // A lone final modifier.
    try expectSyllables(&.{.FMPst}, &.{.{ 1, .non_cluster }});
}

test "cluster DFA rejects broken sequences" {
    // A vowel sign with no base.
    try expectSyllables(&.{ .VPre, .VPst }, &.{.{ 2, .broken }});
    // A repha before a vowel.
    try expectSyllables(&.{ .R, .VAbv }, &.{.{ 2, .broken }});
    // A halant after a base, then a stray vowel: the halant ends the
    // standard cluster (dependent vowels may be a halant) and the vowel
    // starts a broken one.
    try expectSyllables(&.{ .B, .H, .VBlw }, &.{ .{ 2, .standard }, .{ 1, .broken } });
    // Out-of-order vowels.
    try expectSyllables(&.{ .B, .VPst, .VPre }, &.{ .{ 2, .standard }, .{ 1, .broken } });
}

test "dotted circle insertion" {
    const gpa = testing.allocator;
    const bytes = try fonts.font(gpa, "NotoSansJavanese-Subset.ttf");
    defer gpa.free(bytes);
    const face = try ot.Face.init(bytes, 0);
    var b = Buffer.init(gpa);
    defer b.deinit();
    // KA TARUNG | TALING (a pre-base vowel after a post-base one: broken).
    for ([_]u21{ 0xA98F, 0xA9B4, 0xA9BA }, 0..) |cp, i| try b.addCodepoint(cp, @intCast(i * 3));
    for (b.infos.items) |*gi| gi.shaper = @intFromEnum(use.useCategory(gi.cp));
    try use.findSyllables(gpa, &b);
    try testing.expectEqual(@intFromEnum(use.SyllableType.standard), dotted.syllableType(b.infos.items[0]));
    try testing.expectEqual(@intFromEnum(use.SyllableType.broken), dotted.syllableType(b.infos.items[2]));
    try testing.expect(try dotted.insertDottedCircles(&b, &face, @intFromEnum(use.SyllableType.broken), @intFromEnum(C.B), @intFromEnum(C.R), 0));
    try testing.expectEqual(@as(usize, 4), b.len());
    const dc = b.infos.items[2];
    try testing.expectEqual(dotted.dotted_circle, dc.cp);
    try testing.expectEqual(face.glyphIndex(0x25CC), dc.gid);
    try testing.expectEqual(@as(u32, 6), dc.cluster);
    try testing.expectEqual(b.infos.items[3].syllable, dc.syllable);
    // No broken syllable left to fix: nothing more is inserted.
    for (b.infos.items) |*gi| gi.shaper = @intFromEnum(use.useCategory(gi.cp));
    try use.findSyllables(gpa, &b);
    try testing.expect(!try dotted.insertDottedCircles(&b, &face, @intFromEnum(use.SyllableType.broken), @intFromEnum(C.B), @intFromEnum(C.R), 0));
}

test "use shaper selection" {
    try testing.expectEqualStrings("use", default.select(.Java, ot.tag("java")).name);
    try testing.expectEqualStrings("use", default.select(.Tibt, null).name);
    try testing.expectEqualStrings("default", default.select(.Java, ot.tag("DFLT")).name);
    try testing.expectEqualStrings("default", default.select(.Bali, ot.tag("latn")).name);
    try testing.expectEqualStrings("use", default.select(.Deva, ot.tag("dev3")).name);
    try testing.expectEqualStrings("indic", default.select(.Deva, ot.tag("dev2")).name);
    try testing.expectEqualStrings("indic", default.select(.Taml, null).name);
    try testing.expectEqualStrings("default", default.select(.Beng, ot.tag("DFLT")).name);
    try testing.expectEqualStrings("use", default.select(.Nkoo, null).name);
    try testing.expectEqualStrings("arabic", default.select(.Arab, null).name);
}
