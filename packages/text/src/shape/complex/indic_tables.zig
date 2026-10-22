//! Character categories and positions for the Indic, Khmer and Myanmar
//! shapers (HarfBuzz's `gen-indic-table.py`), computed from the Unicode
//! Indic_Syllabic_Category and Indic_Positional_Category values plus
//! HarfBuzz's overrides.
//!
//! The three shapers share one category numbering (their syllable
//! machines' alphabets), so a category means the same everywhere; the
//! Myanmar-only ones sit at 32 and up. Only characters in the blocks the
//! shapers handle (and a few listed singles) get a category; the rest are
//! `X` at `end`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dfa = @import("syllable_dfa.zig");
const Buffer = @import("../buffer.zig").Buffer;
const GlyphInfo = @import("../buffer.zig").GlyphInfo;
const unicode = @import("../../unicode/root.zig");
const Isc = unicode.IndicSyllabic;
const Ipc = unicode.IndicPositional;

/// Syllable machine categories (HarfBuzz's `OT_*` values).
pub const Category = enum(u6) {
    X = 0,
    C = 1,
    V = 2,
    N = 3,
    H = 4,
    ZWNJ = 5,
    ZWJ = 6,
    M = 7,
    SM = 8,
    /// Also `VD`.
    A = 9,
    PLACEHOLDER = 10,
    DOTTEDCIRCLE = 11,
    RS = 12,
    MPst = 13,
    Repha = 14,
    Ra = 15,
    CM = 16,
    Symbol = 17,
    CS = 18,
    // Khmer and Myanmar matras.
    VAbv = 20,
    VBlw = 21,
    VPre = 22,
    VPst = 23,
    // Khmer.
    Robatic = 25,
    Xgroup = 26,
    Ygroup = 27,
    // Myanmar.
    As = 32,
    MH = 35,
    MR = 36,
    MW = 37,
    MY = 38,
    PT = 39,
    VS = 40,
    ML = 41,
    SMPst = 57,
    _,

    // Myanmar names for shared values.
    pub const IV: Category = .V;
    pub const DB: Category = .N;
    pub const GB: Category = .PLACEHOLDER;
};

/// Where a glyph goes when a syllable is reordered (HarfBuzz's
/// `ot_position_t`), in visual order.
pub const Position = enum(u4) {
    start,
    ra_to_become_reph,
    pre_m,
    pre_c,
    base_c,
    after_main,
    above_c,
    before_sub,
    below_c,
    after_sub,
    before_post,
    post_c,
    after_post,
    smvd,
    end,
};

/// A character's category and position.
pub const Categories = struct { cat: Category, pos: Position };

/// The category a shaper stored in `GlyphInfo.shaper`.
pub inline fn category(g: GlyphInfo) Category {
    return @enumFromInt(@as(u6, @truncate(g.shaper)));
}

/// The position a shaper stored in `GlyphInfo.shaper_aux`.
pub inline fn position(g: GlyphInfo) Position {
    return @enumFromInt(@as(u4, @truncate(g.shaper_aux)));
}

/// Splits `b` into syllables with `Machine` (over the categories in
/// `GlyphInfo.shaper`): each glyph gets `serial << 4 | types[rule]`, the
/// serial counting 1 to 15 and wrapping. A position no rule matches is a
/// syllable of type `types[types.len - 1]`.
pub fn findSyllables(comptime Machine: type, comptime types: []const u4, gpa: Allocator, b: *Buffer) Allocator.Error!void {
    const infos = b.infos.items;
    const cats = try gpa.alloc(Category, infos.len);
    defer gpa.free(cats);
    for (cats, infos) |*c, g| c.* = category(g);
    var serial: u8 = 1;
    var k: usize = 0;
    while (k < cats.len) {
        const m = Machine.longestMatch(cats, k) orelse dfa.Match{ .len = 1, .rule = types.len - 1 };
        const value = serial << 4 | types[m.rule];
        for (infos[k .. k + m.len]) |*g| g.syllable = value;
        serial += 1;
        if (serial == 16) serial = 1;
        k += m.len;
    }
}

const Block = enum {
    basic_latin,
    latin1,
    devanagari,
    bengali,
    gurmukhi,
    gujarati,
    oriya,
    tamil,
    telugu,
    kannada,
    malayalam,
    myanmar,
    khmer,
    vedic,
    general_punctuation,
    super_sub,
    devanagari_ext,
    myanmar_ext,
};

/// The block of `cp` among those the shapers handle.
fn blockOf(cp: u21) ?Block {
    return switch (cp) {
        0x0000...0x007F => .basic_latin,
        0x0080...0x00FF => .latin1,
        0x0900...0x097F => .devanagari,
        0x0980...0x09FF => .bengali,
        0x0A00...0x0A7F => .gurmukhi,
        0x0A80...0x0AFF => .gujarati,
        0x0B00...0x0B7F => .oriya,
        0x0B80...0x0BFF => .tamil,
        0x0C00...0x0C7F => .telugu,
        0x0C80...0x0CFF => .kannada,
        0x0D00...0x0D7F => .malayalam,
        0x1000...0x109F => .myanmar,
        0x1780...0x17FF => .khmer,
        0x1CD0...0x1CFF => .vedic,
        0x2000...0x206F => .general_punctuation,
        0x2070...0x209F => .super_sub,
        0xA8E0...0xA8FF => .devanagari_ext,
        0xA9E0...0xA9FF, 0xAA60...0xAA7F, 0x116D0...0x116FF => .myanmar_ext,
        else => null,
    };
}

/// HarfBuzz's category overrides.
fn override(cp: u21) ?Category {
    return switch (cp) {
        // Variation selectors (in the Myanmar grammar, not Myanmar-specific).
        0xFE00...0xFE0F => .VS,
        // In the Myanmar spec, not Myanmar-specific.
        0x2015, 0x2022, 0x25FB...0x25FE => .PLACEHOLDER,
        // Indic Ra letters.
        0x0930, 0x09B0, 0x09F0, 0x0A30, 0x0AB0, 0x0B30, 0x0BB0, 0x0C30, 0x0CB0, 0x0D30 => .Ra,
        // These act like bindus.
        0x0953, 0x0954 => .SM,
        // GURMUKHI VOWEL SIGN II may follow GURMUKHI SIGN BINDI.
        0x0A40 => .MPst,
        // These act like consonants.
        0x0A72, 0x0A73 => .C,
        // Treated like tone marks.
        0x1CE2...0x1CE8, 0x1CED => .A,
        // These take marks in standalone clusters, like Avagraha.
        0xA8F2...0xA8F7, 0x1CE9...0x1CEC, 0x1CEE...0x1CF1 => .Symbol,
        0x0A51 => .M,
        // Grantha marks also used in Tamil.
        0x11301...0x11303 => .SM,
        0x1133B, 0x1133C => .N,
        0x0AFB, 0x0B55 => .N,
        0x09FC, 0x0C80, 0x0D04 => .PLACEHOLDER,
        0x25CC => .DOTTEDCIRCLE,
        // Khmer.
        0x179A => .Ra,
        0x17C9, 0x17CA, 0x17CC => .Robatic,
        0x17C6, 0x17CB, 0x17CD...0x17D1 => .Xgroup,
        0x17C7, 0x17C8, 0x17D3, 0x17DD => .Ygroup,
        0x17D9 => .PLACEHOLDER,
        // Myanmar.
        0x104E => .C,
        0x1004, 0x101B, 0x105A => .Ra,
        0x1032, 0x1036 => .A,
        0x103A => .As,
        0x103E => .MH,
        0x1060 => .ML,
        0x103C => .MR,
        0x103D, 0x1082 => .MW,
        0x103B, 0x105E, 0x105F => .MY,
        0x1063, 0x1064, 0x1069...0x106D, 0xAA7B => .PT,
        0x1038, 0x1087...0x108D, 0x108F, 0x109A...0x109C => .SM,
        0x104A => .PLACEHOLDER,
        else => null,
    };
}

fn mapCategory(isc: Isc) Category {
    return switch (isc) {
        .Other, .Consonant_Prefixed, .Modifying_Letter, .Tone_Letter, .Reordering_Killer => .X,
        .Avagraha => .Symbol,
        .Bindu, .Gemination_Mark, .Syllable_Modifier, .Visarga => .SM,
        .Brahmi_Joining_Number, .Consonant_Placeholder, .Number, .Number_Joiner => .PLACEHOLDER,
        .Cantillation_Mark => .A,
        .Consonant, .Consonant_Dead, .Consonant_Head_Letter, .Consonant_Initial_Postfixed => .C,
        .Consonant_Killer, .Pure_Killer, .Vowel_Dependent => .M,
        .Consonant_Final, .Consonant_Medial, .Consonant_Subjoined, .Consonant_Succeeding_Repha => .CM,
        .Consonant_Preceding_Repha => .Repha,
        .Consonant_With_Stacker => .CS,
        .Invisible_Stacker, .Virama => .H,
        .Joiner => .ZWJ,
        .Non_Joiner => .ZWNJ,
        .Nukta, .Tone_Mark => .N,
        .Register_Shifter => .RS,
        .Vowel, .Vowel_Independent => .V,
    };
}

fn mapPosition(ipc: Ipc) Position {
    return switch (ipc) {
        .NA => .end,
        .Left => .pre_c,
        .Top, .Top_And_Left => .above_c,
        .Bottom, .Top_And_Bottom, .Top_And_Bottom_And_Left, .Bottom_And_Left => .below_c,
        .Right, .Bottom_And_Right, .Left_And_Right, .Top_And_Bottom_And_Right, .Top_And_Left_And_Right, .Top_And_Right => .post_c,
        .Overstruck => .after_main,
        .Visual_Order_Left => .pre_m,
    };
}

/// Where a dependent vowel of `block` at `pos` goes.
fn matraPosition(cp: u21, pos: Position, block: ?Block) Position {
    const b = block orelse return .after_sub;
    return switch (pos) {
        .pre_c => .pre_m,
        .post_c => switch (b) {
            .devanagari => .after_sub,
            .bengali, .gurmukhi, .gujarati, .oriya, .tamil, .malayalam => .after_post,
            .telugu => if (cp <= 0x0C42) .before_sub else .after_sub,
            .kannada => if (cp < 0x0CC3 or cp > 0x0CD6) .before_sub else .after_sub,
            else => .after_sub,
        },
        // Bengali and Malayalam have no top matras.
        .above_c => switch (b) {
            .gurmukhi => .after_post, // deviates from the spec, like HarfBuzz
            .oriya => .after_main,
            .telugu, .kannada => .before_sub,
            else => .after_sub,
        },
        .below_c => switch (b) {
            .gurmukhi, .gujarati, .tamil, .malayalam => .after_post,
            .telugu, .kannada => .before_sub,
            else => .after_sub,
        },
        else => pos,
    };
}

/// The category and position of `cp`.
pub fn categories(cp: u21) Categories {
    const block = blockOf(cp);
    const ov = override(cp);
    const listed = block != null or cp == 0x00A0 or cp == 0x25CC;
    if (!listed and ov == null) return .{ .cat = .X, .pos = .end };
    const ic = unicode.indicCategories(cp);
    var pos: Position = if (listed) mapPosition(ic.positional) else .end;
    var cat: Category = ov orelse blk: {
        const c = mapCategory(ic.syllabic);
        break :blk if (c == .SM and ic.positional == .NA) .SMPst else c;
    };
    switch (cat) {
        .CM, .SM, .RS, .H, .M, .MPst => {},
        else => pos = .end,
    }
    switch (cat) {
        .C, .CS, .Ra, .CM, .V, .PLACEHOLDER, .DOTTEDCIRCLE => pos = .base_c,
        .M, .MPst => if (block == .khmer or block == .myanmar or block == .myanmar_ext) {
            cat = switch (pos) {
                .pre_c => .VPre,
                .above_c => .VAbv,
                .below_c => .VBlw,
                else => .VPst,
            };
        } else {
            pos = matraPosition(cp, pos, block);
        },
        .SM, .SMPst, .A, .Symbol => pos = .smvd,
        else => {},
    }
    switch (cp) {
        0x0A51 => pos = .below_c,
        // Oriya Bindu is BeforeSub in the spec.
        0x0B01 => pos = .before_sub,
        else => {},
    }
    return .{ .cat = cat, .pos = pos };
}

test "indic categories samples" {
    const t = std.testing;
    const cases = [_]struct { u21, Category, Position }{
        .{ 0x0915, .C, .base_c }, // DEVANAGARI KA
        .{ 0x0930, .Ra, .base_c },
        .{ 0x094D, .H, .below_c }, // VIRAMA
        .{ 0x093F, .M, .pre_m }, // VOWEL SIGN I
        .{ 0x0940, .M, .after_sub }, // VOWEL SIGN II
        .{ 0x0902, .SM, .smvd }, // ANUSVARA
        .{ 0x093C, .N, .end }, // NUKTA
        .{ 0x0905, .V, .base_c },
        .{ 0x0BC6, .M, .pre_m }, // TAMIL VOWEL SIGN E
        .{ 0x0D4D, .H, .above_c },
        .{ 0x200D, .ZWJ, .end },
        .{ 0x200C, .ZWNJ, .end },
        .{ 0x25CC, .DOTTEDCIRCLE, .base_c },
        .{ 0x00A0, .PLACEHOLDER, .base_c },
        .{ 0x1780, .C, .base_c }, // KHMER KA
        .{ 0x17D2, .H, .end }, // COENG
        .{ 0x17C1, .VPre, .pre_c },
        .{ 0x17B8, .VAbv, .above_c },
        .{ 0x17BB, .VBlw, .below_c },
        .{ 0x17B6, .VPst, .post_c },
        .{ 0x17CC, .Robatic, .end },
        .{ 0x17C7, .Ygroup, .end },
        .{ 0x1000, .C, .base_c }, // MYANMAR KA
        .{ 0x1031, .VPre, .pre_c },
        .{ 0x103C, .MR, .end },
        .{ 0x1039, .H, .end },
        .{ 0xFE00, .VS, .end },
        .{ 0x0B01, .SM, .before_sub },
        .{ 0x0041, .X, .end },
        .{ 0x0E01, .X, .end }, // Thai: not handled here
    };
    for (cases) |c| {
        const got = categories(c[0]);
        t.expectEqual(c[1], got.cat) catch |e| {
            std.debug.print("U+{X:0>4}\n", .{c[0]});
            return e;
        };
        t.expectEqual(c[2], got.pos) catch |e| {
            std.debug.print("U+{X:0>4}\n", .{c[0]});
            return e;
        };
    }
}
