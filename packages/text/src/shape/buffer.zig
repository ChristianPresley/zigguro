//! The shaping buffer: one `GlyphInfo` and one `GlyphPos` per glyph, in
//! logical order until the shaper reverses RTL runs at the very end.
//!
//! GSUB edits the buffer in place (insert, remove, replace); context
//! lookups track their match positions through those edits the way
//! HarfBuzz's out-buffer does. Clusters are byte offsets into the run text
//! and are merged HarfBuzz-style (a merged range takes its minimum).

const std = @import("std");
const zg_core = @import("zg_core");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const Tag = ot.Tag;
const unicode = @import("../unicode/root.zig");
const GeneralCategory = unicode.GeneralCategory;
const Script = unicode.Script;
const GlyphProps = @import("../ot/gdef.zig").GlyphProps;

/// Text direction of a run.
pub const Direction = enum { ltr, rtl };

/// A user feature over a byte range of the run text (`start`..`end`).
pub const Feature = struct {
    tag: Tag,
    value: u16 = 1,
    start: u32 = 0,
    end: u32 = std.math.maxInt(u32),

    /// True when the feature covers the whole run.
    pub fn isGlobal(f: Feature) bool {
        return f.start == 0 and f.end == std.math.maxInt(u32);
    }
};

/// Unicode-derived flags of a glyph.
pub const UFlags = struct {
    pub const default_ignorable: u8 = 0x01;
    pub const zwj: u8 = 0x02;
    pub const zwnj: u8 = 0x04;
    /// Hidden default-ignorables (CGJ, Mongolian FVS, tags) are not skipped
    /// by GSUB matching.
    pub const hidden: u8 = 0x08;
    /// Continues the previous grapheme (marks, ZWJ sequences, modifiers).
    pub const continuation: u8 = 0x10;
    /// A variation selector kept as its own glyph.
    pub const variation_selector: u8 = 0x20;
};

const lig_base_flag: u8 = 0x10;

/// One glyph.
pub const GlyphInfo = struct {
    gid: GlyphId = 0,
    /// Byte offset of the cluster's first character in the run text.
    cluster: u32,
    /// Feature mask bits (allocated by the plan).
    mask: u32 = 0,
    /// The code point this glyph came from (valid before substitutions).
    cp: u21,
    /// `GlyphProps` bits.
    glyph_props: u16 = 0,
    /// Ligature id (high 3 bits) and component index or count (low 4).
    lig_props: u8 = 0,
    /// Syllable serial for complex shapers.
    syllable: u8 = 0,
    gc: GeneralCategory = .Cn,
    /// Canonical combining class, HarfBuzz-modified (marks only).
    ccc: u8 = 0,
    uflags: u8 = 0,
    /// A lookup matched across this glyph's cluster boundary.
    unsafe_to_break: bool = false,
    /// Complex-shaper scratch (joining action, Indic category, ...).
    shaper: u8 = 0,
    /// The fallback width rule of a space mapped to U+0020's glyph.
    space: SpaceFallback = .none,

    /// True for a GDEF (or synthesized) mark.
    pub inline fn isMark(g: GlyphInfo) bool {
        return g.glyph_props & GlyphProps.mark != 0;
    }
    /// True for a GDEF ligature.
    pub inline fn isLigature(g: GlyphInfo) bool {
        return g.glyph_props & GlyphProps.ligature != 0;
    }
    /// True for a GDEF base glyph.
    pub inline fn isBase(g: GlyphInfo) bool {
        return g.glyph_props & GlyphProps.base != 0;
    }
    /// True once any GSUB lookup substituted the glyph.
    pub inline fn substituted(g: GlyphInfo) bool {
        return g.glyph_props & GlyphProps.substituted != 0;
    }
    /// True for a multiple-substitution output.
    pub inline fn multiplied(g: GlyphInfo) bool {
        return g.glyph_props & GlyphProps.multiplied != 0;
    }
    /// A default-ignorable character not substituted by GSUB.
    pub inline fn isDefaultIgnorable(g: GlyphInfo) bool {
        return g.uflags & UFlags.default_ignorable != 0 and !g.substituted();
    }
    /// True for ZWJ.
    pub inline fn isZwj(g: GlyphInfo) bool {
        return g.uflags & UFlags.zwj != 0;
    }
    /// True for ZWNJ.
    pub inline fn isZwnj(g: GlyphInfo) bool {
        return g.uflags & UFlags.zwnj != 0;
    }
    /// True for a hidden default-ignorable.
    pub inline fn isHidden(g: GlyphInfo) bool {
        return g.uflags & UFlags.hidden != 0;
    }
    /// True for a Unicode mark (Mn, Mc, Me).
    pub inline fn isUnicodeMark(g: GlyphInfo) bool {
        return g.gc == .Mn or g.gc == .Mc or g.gc == .Me;
    }
    /// The ligature id (0 when not part of a ligature).
    pub inline fn ligId(g: GlyphInfo) u3 {
        return @intCast(g.lig_props >> 5);
    }
    inline fn ligatedInternal(g: GlyphInfo) bool {
        return g.lig_props & lig_base_flag != 0;
    }
    /// The ligature component a mark or component belongs to (0 for the
    /// ligature glyph itself).
    pub inline fn ligComp(g: GlyphInfo) u4 {
        if (g.ligatedInternal()) return 0;
        return @intCast(g.lig_props & 0x0F);
    }
    /// The number of components of a ligature glyph (1 otherwise).
    pub inline fn ligNumComps(g: GlyphInfo) u4 {
        if (g.isLigature() and g.ligatedInternal()) return @intCast(g.lig_props & 0x0F);
        return 1;
    }
    /// Marks the glyph as a ligature with `n` components.
    pub inline fn setLigPropsForLigature(g: *GlyphInfo, id: u3, n: u32) void {
        g.lig_props = @as(u8, id) << 5 | lig_base_flag | @as(u8, @intCast(n & 0x0F));
    }
    /// Attaches the glyph to component `comp` of ligature `id`.
    pub inline fn setLigPropsForMark(g: *GlyphInfo, id: u3, comp: u32) void {
        g.lig_props = @as(u8, id) << 5 | @as(u8, @intCast(comp & 0x0F));
    }
};

/// Attachment kinds of `GlyphPos.attach_type`.
pub const AttachType = struct {
    pub const none: u8 = 0;
    pub const mark: u8 = 1;
    pub const cursive: u8 = 2;
};

/// How a space character without its own glyph is sized (HarfBuzz's
/// `space_t`); `em_n` kinds are 1/n of an em.
pub const SpaceFallback = enum(u8) {
    none = 0,
    em_1 = 1,
    em_2 = 2,
    em_3 = 3,
    em_4 = 4,
    em_5 = 5,
    em_6 = 6,
    em_16 = 16,
    em_4_18 = 17,
    space = 18,
    figure = 19,
    punctuation = 20,
    narrow = 21,

    /// The fallback kind of `cp` (only Zs characters have one).
    pub fn of(cp: u21) SpaceFallback {
        return switch (cp) {
            0x0020, 0x00A0 => .space,
            0x2000, 0x2002 => .em_2,
            0x2001, 0x2003, 0x3000 => .em_1,
            0x2004 => .em_3,
            0x2005 => .em_4,
            0x2006 => .em_6,
            0x2007 => .figure,
            0x2008 => .punctuation,
            0x2009 => .em_5,
            0x200A => .em_16,
            0x202F => .narrow,
            0x205F => .em_4_18,
            else => .none,
        };
    }
};

/// One glyph's position in font units.
pub const GlyphPos = struct {
    x_adv: i32 = 0,
    y_adv: i32 = 0,
    x_off: i32 = 0,
    y_off: i32 = 0,
    /// Offset to the glyph this one is attached to (0: none).
    attach_chain: i16 = 0,
    attach_type: u8 = AttachType.none,
};

/// The shaping buffer. Reuse it across runs: `reset` keeps capacity.
pub const Buffer = struct {
    gpa: Allocator,
    infos: std.ArrayList(GlyphInfo) = .empty,
    pos: std.ArrayList(GlyphPos) = .empty,
    /// Scratch output for passes that rewrite the glyph string.
    out: std.ArrayList(GlyphInfo) = .empty,
    /// Bitset of glyph ids present (see `digest.zig`); empty: unknown.
    glyph_set: std.ArrayList(u64) = .empty,
    dir: Direction = .ltr,
    script: Script = .Zyyy,
    lang: Tag = ot.tag("dflt"),
    /// Next ligature id.
    serial: u32 = 1,
    /// HarfBuzz's minstd state for the `rand` feature.
    random_state: u32 = 1,
    has_default_ignorables: bool = false,
    has_attachments: bool = false,
    has_non_ascii: bool = false,

    /// An empty buffer.
    pub fn init(gpa: Allocator) Buffer {
        return .{ .gpa = gpa };
    }

    /// Frees the arrays.
    pub fn deinit(b: *Buffer) void {
        b.infos.deinit(b.gpa);
        b.pos.deinit(b.gpa);
        b.out.deinit(b.gpa);
        b.glyph_set.deinit(b.gpa);
        b.* = undefined;
    }

    /// Empties the buffer, keeping its capacity.
    pub fn reset(b: *Buffer) void {
        b.infos.clearRetainingCapacity();
        b.pos.clearRetainingCapacity();
        b.serial = 1;
        b.random_state = 1;
        b.has_default_ignorables = false;
        b.has_attachments = false;
        b.has_non_ascii = false;
    }

    /// Number of glyphs.
    pub inline fn len(b: *const Buffer) usize {
        return b.infos.items.len;
    }

    /// Appends `text` (lossy UTF-8) with clusters at each character's byte
    /// offset plus `base`.
    pub fn addUtf8(b: *Buffer, text: []const u8, base: u32) Allocator.Error!void {
        try b.infos.ensureUnusedCapacity(b.gpa, text.len);
        var it: zg_core.utf8.LossyIterator = .{ .bytes = text };
        while (true) {
            const at = it.i;
            const cp = it.next() orelse break;
            b.infos.appendAssumeCapacity(.{ .cluster = base + @as(u32, @intCast(at)), .cp = cp });
        }
    }

    /// Appends one code point (tests, tools).
    pub fn addCodepoint(b: *Buffer, cp: u21, cluster: u32) Allocator.Error!void {
        try b.infos.append(b.gpa, .{ .cluster = cluster, .cp = cp });
    }

    /// A new ligature id (never 0).
    pub fn allocateLigId(b: *Buffer) u3 {
        var id: u3 = @truncate(b.serial);
        b.serial +%= 1;
        if (id == 0) {
            id = @truncate(b.serial);
            b.serial +%= 1;
        }
        return id;
    }

    /// The next `rand` value (HarfBuzz's minstd generator).
    pub fn randomNumber(b: *Buffer) u32 {
        b.random_state = @intCast(@as(u64, b.random_state) * 48271 % 2147483647);
        return b.random_state;
    }

    /// Sets every cluster in [`start`, `end`) to their minimum, widening
    /// the range to whole clusters first.
    pub fn mergeClusters(b: *Buffer, start_in: usize, end_in: usize) void {
        if (end_in -| start_in < 2) return;
        const infos = b.infos.items;
        var start = start_in;
        var end = end_in;
        var cluster = infos[start].cluster;
        for (infos[start + 1 .. end]) |g| cluster = @min(cluster, g.cluster);
        if (cluster != infos[end - 1].cluster) {
            while (end < infos.len and infos[end - 1].cluster == infos[end].cluster) end += 1;
        }
        if (cluster != infos[start].cluster) {
            while (start > 0 and infos[start - 1].cluster == infos[start].cluster) start -= 1;
        }
        // A glyph that joins a bigger cluster drops its break flag (inside
        // a cluster there is no boundary to protect).
        for (infos[start..end]) |*g| if (g.cluster != cluster) {
            g.unsafe_to_break = false;
            g.cluster = cluster;
        };
    }

    /// Marks [`start`, `end`) as unsafe to break: glyphs whose cluster is
    /// not the range's first cluster get the flag (HarfBuzz semantics).
    pub fn unsafeToBreak(b: *Buffer, start: usize, end_in: usize) void {
        const end = @min(end_in, b.infos.items.len);
        if (end -| start < 2) return;
        const infos = b.infos.items;
        var cluster = infos[start].cluster;
        for (infos[start..end]) |g| cluster = @min(cluster, g.cluster);
        for (infos[start..end]) |*g| if (g.cluster != cluster) {
            g.unsafe_to_break = true;
        };
    }

    /// Inserts `g` at `i`.
    pub fn insertAt(b: *Buffer, i: usize, g: GlyphInfo) Allocator.Error!void {
        try b.infos.insert(b.gpa, i, g);
    }

    /// Removes the glyph at `i`, merging its cluster into a neighbour so no
    /// byte loses its cluster (HarfBuzz's `delete_glyph`).
    pub fn deleteAt(b: *Buffer, i: usize) void {
        const infos = b.infos.items;
        const cluster = infos[i].cluster;
        if (i + 1 < infos.len and infos[i + 1].cluster == cluster) {
            _ = b.infos.orderedRemove(i);
            return;
        }
        if (i > 0) {
            // Merge backward.
            if (cluster < infos[i - 1].cluster) {
                const old = infos[i - 1].cluster;
                var k = i;
                while (k > 0 and infos[k - 1].cluster == old) : (k -= 1) infos[k - 1].cluster = cluster;
            }
        } else if (i + 1 < infos.len) {
            // Merge forward.
            b.mergeClusters(i, i + 2);
        }
        _ = b.infos.orderedRemove(i);
    }

    /// Recomputes `glyph_set` for a face of `num_glyphs` glyphs.
    pub fn computeGlyphSet(b: *Buffer, num_glyphs: usize) Allocator.Error!void {
        try b.glyph_set.resize(b.gpa, (num_glyphs + 63) / 64);
        @memset(b.glyph_set.items, 0);
        for (b.infos.items) |g| {
            const w = g.gid >> 6;
            if (w < b.glyph_set.items.len) b.glyph_set.items[w] |= @as(u64, 1) << @intCast(g.gid & 63);
        }
    }

    /// Makes the scratch output the glyph string (after a rewriting pass).
    pub fn swapOut(b: *Buffer) void {
        std.mem.swap(std.ArrayList(GlyphInfo), &b.infos, &b.out);
        b.out.clearRetainingCapacity();
    }

    /// Reverses glyphs and positions in [`start`, `end`).
    pub fn reverseRange(b: *Buffer, start: usize, end: usize) void {
        std.mem.reverse(GlyphInfo, b.infos.items[start..end]);
        if (b.pos.items.len == b.infos.items.len) std.mem.reverse(GlyphPos, b.pos.items[start..end]);
    }
};

/// HarfBuzz's default-ignorable set (Default_Ignorable_Code_Point minus
/// the Hangul fillers, which fonts draw).
pub fn isDefaultIgnorable(cp: u21) bool {
    return switch (cp) {
        0x00AD, 0x034F, 0x061C, 0x17B4...0x17B5, 0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F => true,
        0xFE00...0xFE0F, 0xFEFF, 0xFFF0...0xFFF8, 0x1D173...0x1D17A, 0xE0000...0xE0FFF => true,
        else => false,
    };
}

/// True for a variation selector (FE00..FE0F, E0100..E01EF, Mongolian FVS).
pub fn isVariationSelector(cp: u21) bool {
    return switch (cp) {
        0xFE00...0xFE0F, 0xE0100...0xE01EF, 0x180B...0x180D, 0x180F => true,
        else => false,
    };
}

/// HarfBuzz's modified combining class: reorders Hebrew points to the SBL
/// order, Arabic shadda before other harakat, and a few Indic/Thai/Tibetan
/// classes.
pub fn modifiedCombiningClass(cp: u21, ccc: u8) u8 {
    // Telugu length marks and Tai Tham / Tibetan special cases.
    if (cp == 0x1A60) return 254; // Tai Tham SAKOT: HarfBuzz keeps it last
    if (cp == 0x0FC6) return 254; // Tibetan PADMA GDAN
    if (cp == 0x0F39) return 127; // Tibetan LENG TSHAD: like a nukta
    return switch (ccc) {
        10 => 22, // sheva
        11 => 15,
        12 => 16,
        13 => 17,
        14 => 23,
        15 => 18,
        16 => 19,
        17 => 20,
        18 => 21,
        19 => 14,
        20 => 24,
        21 => 12,
        22 => 25,
        23 => 13,
        24 => 10,
        25 => 11,
        26 => 26,
        27 => 28, // fathatan
        28 => 29,
        29 => 30,
        30 => 31,
        31 => 32,
        32 => 33,
        33 => 27, // shadda
        34 => 34,
        35 => 35,
        84 => 4, // Telugu length mark
        91 => 5,
        103 => 3, // Thai sara u / uu
        130 => 132, // Tibetan sign i
        132 => 131, // Tibetan sign u
        else => ccc,
    };
}

/// Sets each glyph's Unicode properties (general category, modified
/// combining class, default-ignorable, joiner and continuation flags),
/// HarfBuzz's `hb_set_unicode_props`.
pub fn setUnicodeProps(b: *Buffer) void {
    const infos = b.infos.items;
    var i: usize = 0;
    while (i < infos.len) : (i += 1) {
        setProps(b, &infos[i]);
        const g = &infos[i];
        switch (g.gc) {
            .Ll, .Lu, .Lt, .Lm, .Lo, .Nd, .Nl, .No, .Pc, .Pd, .Pe, .Pf, .Pi, .Po, .Ps, .Sc, .Sm, .So, .Zl, .Zp, .Zs => continue,
            else => {},
        }
        if (g.gc == .Sk and g.cp >= 0x1F3FB and g.cp <= 0x1F3FF) {
            g.uflags |= UFlags.continuation;
        } else if (i > 0 and isRegionalIndicator(g.cp)) {
            if (isRegionalIndicator(infos[i - 1].cp) and infos[i - 1].uflags & UFlags.continuation == 0) g.uflags |= UFlags.continuation;
        } else if (g.isZwj()) {
            g.uflags |= UFlags.continuation;
            if (i + 1 < infos.len and unicode.props(infos[i + 1].cp).ext_pict) {
                i += 1;
                setProps(b, &infos[i]);
                infos[i].uflags |= UFlags.continuation;
            }
        } else if ((g.cp >= 0xFF9E and g.cp <= 0xFF9F) or (g.cp >= 0xE0020 and g.cp <= 0xE007F)) {
            g.uflags |= UFlags.continuation;
        }
    }
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// Sets one glyph's general category, combining class and ignorable,
/// joiner and mark-continuation flags from its code point.
pub fn setProps(b: *Buffer, g: *GlyphInfo) void {
    const p = unicode.props(g.cp);
    g.gc = p.gc;
    g.uflags = 0;
    g.ccc = 0;
    if (g.cp < 0x80) return;
    b.has_non_ascii = true;
    if (isDefaultIgnorable(g.cp)) {
        b.has_default_ignorables = true;
        g.uflags |= UFlags.default_ignorable;
        switch (g.cp) {
            0x200C => g.uflags |= UFlags.zwnj,
            0x200D => g.uflags |= UFlags.zwj,
            0x180B...0x180D, 0x180F, 0xE0020...0xE007F, 0x034F => g.uflags |= UFlags.hidden,
            else => {},
        }
    }
    if (g.gc == .Mn or g.gc == .Mc or g.gc == .Me) {
        g.uflags |= UFlags.continuation;
        g.ccc = modifiedCombiningClass(g.cp, p.ccc);
    }
}

/// Merges each grapheme (a glyph and its continuations) into one cluster
/// (HarfBuzz's monotone-graphemes cluster level).
pub fn formClusters(b: *Buffer) void {
    if (!b.has_non_ascii) return;
    const infos = b.infos.items;
    var start: usize = 0;
    var i: usize = 1;
    while (i <= infos.len) : (i += 1) {
        if (i < infos.len and infos[i].uflags & UFlags.continuation != 0) continue;
        b.mergeClusters(start, i);
        start = i;
    }
}

test "buffer: utf8 clusters are byte offsets" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.addUtf8("aé€\xff😀", 0);
    const want = [_]struct { u21, u32 }{ .{ 'a', 0 }, .{ 0xE9, 1 }, .{ 0x20AC, 3 }, .{ 0xFFFD, 6 }, .{ 0x1F600, 7 } };
    try std.testing.expectEqual(want.len, b.len());
    for (want, b.infos.items) |w, g| {
        try std.testing.expectEqual(w[0], g.cp);
        try std.testing.expectEqual(w[1], g.cluster);
    }
}

test "buffer: grapheme clusters merge marks and zwj sequences" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    // a + combining acute, x, 👩 ZWJ 💻
    try b.addUtf8("a\u{301}x\u{1F469}\u{200D}\u{1F4BB}", 0);
    setUnicodeProps(&b);
    formClusters(&b);
    const got = [_]u32{ b.infos.items[0].cluster, b.infos.items[1].cluster, b.infos.items[2].cluster, b.infos.items[3].cluster, b.infos.items[4].cluster, b.infos.items[5].cluster };
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 3, 4, 4, 4 }, &got);
    try std.testing.expect(b.infos.items[4].isZwj() and b.infos.items[4].isDefaultIgnorable());
    try std.testing.expectEqual(@as(u8, 230), b.infos.items[1].ccc);
}

test "buffer: delete keeps every cluster" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.addUtf8("abc", 0);
    b.deleteAt(1); // b merges back into a's cluster? no: a's cluster is lower
    try std.testing.expectEqual(@as(usize, 2), b.len());
    b.deleteAt(0); // first glyph: merged forward into c
    try std.testing.expectEqual(@as(u32, 0), b.infos.items[0].cluster);
}

test "buffer: modified combining classes" {
    try std.testing.expectEqual(@as(u8, 27), modifiedCombiningClass(0x0651, 33));
    try std.testing.expectEqual(@as(u8, 230), modifiedCombiningClass(0x0301, 230));
    try std.testing.expect(isDefaultIgnorable(0x200D) and !isDefaultIgnorable(0x3164) and !isDefaultIgnorable('a'));
}
