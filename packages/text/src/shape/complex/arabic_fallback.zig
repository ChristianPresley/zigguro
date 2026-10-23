//! Arabic fallback shaping (HarfBuzz's `hb-ot-shaper-arabic-fallback`):
//! for an Arabic font whose GSUB has none of `isol`, `fina`, `medi` and
//! `init`, lookups are synthesized from the font's cmap entries for the
//! Arabic Presentation Forms and run after `rlig`'s stage. Four single
//! substitutions turn each letter into its initial, medial, final or
//! isolated form, then three ligature lookups (`rlig`) join three-letter
//! and two-letter forms (lam-alef and others) and shadda with a vowel.
//!
//! The tables are derived from UnicodeData.txt's `<initial>`, `<medial>`,
//! `<final>` and `<isolated>` decompositions as HarfBuzz's
//! gen-arabic-table.py does (its curated ligature list, plus its three
//! private-use ligatures), and are identical to HarfBuzz's.
//!
//! HarfBuzz's second fallback, a hand-written GSUB for fonts in the
//! Windows-1256 encoding, is not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("../plan.zig");
const ShapePlan = plan_mod.ShapePlan;
const buffer = @import("../buffer.zig");
const Buffer = buffer.Buffer;
const ot = @import("../../ot/root.zig");
const GlyphId = ot.GlyphId;
const tag = ot.tag;
const lc = @import("../../ot/layout_common.zig");
const skippy = @import("../skippy.zig");
const apply_gsub = @import("../apply_gsub.zig");

/// The features whose masks the synthesized lookups run under, in order
/// (the first four index `Shape.forms`).
const features = [_]ot.Tag{ tag("init"), tag("medi"), tag("fina"), tag("isol"), tag("rlig"), tag("rlig"), tag("rlig") };
const ignore_marks: u16 = 0x0008;

/// The synthesized lookups of one font: a GSUB table holding them and
/// each one's mask.
pub const Fallback = struct {
    gsub: lc.LayoutTable,
    masks: [features.len]u32,
    count: u16,
};

/// Builds the fallback lookups of `p`'s font into its arena; null when the
/// font has none of the forms.
pub fn build(p: *const ShapePlan, arena: Allocator) Allocator.Error!?*const Fallback {
    const face = p.inst.face;
    var lookups: std.ArrayList([]const u8) = .empty;
    var masks: [features.len]u32 = undefined;
    for (features, 0..) |f, i| {
        const mask = p.mask1(f);
        if (mask == 0) continue;
        const bytes = switch (i) {
            0...3 => try singleLookup(arena, face, i),
            4 => try ligatureLookup(arena, face, 2, &ligatures_3, ignore_marks),
            5 => try ligatureLookup(arena, face, 1, &ligatures_2, ignore_marks),
            else => try ligatureLookup(arena, face, 1, &ligatures_mark, 0),
        } orelse continue;
        masks[lookups.items.len] = mask;
        try lookups.append(arena, bytes);
    }
    if (lookups.items.len == 0) return null;

    // GSUB 1.0 with no scripts or features, the LookupList at 10.
    var w: Writer = .{ .gpa = arena };
    try w.u16s(&.{ 1, 0, 0, 0, 10 });
    const n: u16 = @intCast(lookups.items.len);
    try w.u16s(&.{n});
    var off: usize = 2 + 2 * @as(usize, n);
    for (lookups.items) |l| {
        try w.u16s(&.{@intCast(off)});
        off += l.len;
    }
    for (lookups.items) |l| try w.bytes.appendSlice(arena, l);
    const fb = try arena.create(Fallback);
    fb.* = .{
        .gsub = lc.LayoutTable.init(w.bytes.items) catch unreachable,
        .masks = masks,
        .count = n,
    };
    return fb;
}

/// Applies the fallback lookups (a pause after `rlig`'s stage).
pub fn apply(p: *const ShapePlan, fb: *const Fallback, b: *Buffer) Allocator.Error!void {
    var budget = skippy.OpBudget.init(b.len());
    var c: skippy.Ctx = .{ .buf = b, .table = fb.gsub, .kind = .gsub, .gdef = &p.gdef, .budget = &budget };
    for (fb.masks[0..fb.count], 0..) |mask, i| {
        c.lookup_mask = mask;
        try apply_gsub.applyLookup(&c, @intCast(i));
    }
}

const Writer = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn u16s(w: *Writer, vs: []const u16) Allocator.Error!void {
        for (vs) |v| {
            var be: [2]u8 = undefined;
            std.mem.writeInt(u16, &be, v, .big);
            try w.bytes.appendSlice(w.gpa, &be);
        }
    }
};

const Pair = struct { from: GlyphId, to: GlyphId };

fn pairLess(_: void, a: Pair, b: Pair) bool {
    return a.from < b.from;
}

/// A single substitution (format 2) to presentation form `form`, ignoring
/// marks; null when the font maps none.
fn singleLookup(arena: Allocator, face: *const ot.Face, form: usize) Allocator.Error!?[]const u8 {
    var pairs: [shaping.len]Pair = undefined;
    var n: usize = 0;
    for (shaping) |s| {
        const to_cp = s.forms[form];
        if (to_cp == 0) continue;
        const from = face.glyphIndex(s.cp);
        const to = face.glyphIndex(to_cp);
        if (from == 0 or to == 0 or from == to) continue;
        pairs[n] = .{ .from = from, .to = to };
        n += 1;
    }
    std.sort.insertion(Pair, pairs[0..n], {}, pairLess);
    // One entry per glyph (the first, as a coverage lookup finds).
    var m: usize = 0;
    for (pairs[0..n]) |pr| {
        if (m > 0 and pairs[m - 1].from == pr.from) continue;
        pairs[m] = pr;
        m += 1;
    }
    if (m == 0) return null;

    var w: Writer = .{ .gpa = arena };
    const count: u16 = @intCast(m);
    try w.u16s(&.{ 1, ignore_marks, 1, 8 }); // lookup: type, flag, one subtable at 8
    try w.u16s(&.{ 2, 6 + 2 * count, count });
    for (pairs[0..m]) |pr| try w.u16s(&.{pr.to});
    try w.u16s(&.{ 1, count });
    for (pairs[0..m]) |pr| try w.u16s(&.{pr.from});
    return w.bytes.items;
}

/// A ligature substitution over `table` (entries grouped by first
/// character); null when the font has none of the ligatures.
fn ligatureLookup(arena: Allocator, face: *const ot.Face, comptime k: usize, table: []const Ligature(k), flag: u16) Allocator.Error!?[]const u8 {
    const Lig = struct { glyph: GlyphId, comps: [k]GlyphId };
    const Set = struct { first: GlyphId, ligs: std.ArrayList(Lig) = .empty };
    var sets: std.ArrayList(Set) = .empty;
    var i: usize = 0;
    while (i < table.len) {
        var j = i;
        while (j < table.len and table[j].first == table[i].first) j += 1;
        defer i = j;
        const first = face.glyphIndex(table[i].first);
        if (first == 0) continue;
        var set: Set = .{ .first = first };
        for (table[i..j]) |l| {
            const g = face.glyphIndex(l.ligature);
            if (g == 0) continue;
            var comps: [k]GlyphId = undefined;
            for (l.components, &comps) |cp, *cg| cg.* = face.glyphIndex(cp);
            if (std.mem.indexOfScalar(GlyphId, &comps, 0) != null) continue;
            try set.ligs.append(arena, .{ .glyph = g, .comps = comps });
        }
        if (set.ligs.items.len == 0) continue;
        // Two first characters on one glyph share its set.
        for (sets.items) |*o| {
            if (o.first == first) {
                try o.ligs.appendSlice(arena, set.ligs.items);
                break;
            }
        } else try sets.append(arena, set);
    }
    if (sets.items.len == 0) return null;
    std.sort.insertion(Set, sets.items, {}, struct {
        fn lt(_: void, a: Set, b: Set) bool {
            return a.first < b.first;
        }
    }.lt);

    // Subtable: format, coverage, set count and offsets; the sets, each
    // with its ligatures; then the coverage.
    const ns: u16 = @intCast(sets.items.len);
    var set_offs: std.ArrayList(u16) = .empty;
    var off: usize = 6 + 2 * @as(usize, ns);
    for (sets.items) |s| {
        try set_offs.append(arena, @intCast(off));
        off += 2 + s.ligs.items.len * (2 + 4 + 2 * k);
    }
    var w: Writer = .{ .gpa = arena };
    try w.u16s(&.{ 4, flag, 1, 8 }); // lookup: type, flag, one subtable at 8
    try w.u16s(&.{ 1, @intCast(off), ns });
    try w.u16s(set_offs.items);
    for (sets.items) |s| {
        const nl: u16 = @intCast(s.ligs.items.len);
        try w.u16s(&.{nl});
        for (0..nl) |li| try w.u16s(&.{@intCast(2 + 2 * nl + li * (4 + 2 * k))});
        for (s.ligs.items) |l| {
            try w.u16s(&.{ l.glyph, k + 1 });
            try w.u16s(&l.comps);
        }
    }
    try w.u16s(&.{ 1, ns });
    for (sets.items) |s| try w.u16s(&.{s.first});
    return w.bytes.items;
}

/// A letter and its presentation forms.
pub const Shape = struct { cp: u21, forms: [4]u16 };

/// A ligature of `first` and `k` following presentation forms (or marks).
pub fn Ligature(comptime k: usize) type {
    return struct { first: u16, components: [k]u16, ligature: u16 };
}

/// The presentation forms of U+0621..U+06D3 (initial, medial, final,
/// isolated; 0: none), for the characters that have any.
pub const shaping = [_]Shape{
    .{ .cp = 0x0621, .forms = .{ 0x0000, 0x0000, 0x0000, 0xFE80 } },
    .{ .cp = 0x0622, .forms = .{ 0x0000, 0x0000, 0xFE82, 0xFE81 } },
    .{ .cp = 0x0623, .forms = .{ 0x0000, 0x0000, 0xFE84, 0xFE83 } },
    .{ .cp = 0x0624, .forms = .{ 0x0000, 0x0000, 0xFE86, 0xFE85 } },
    .{ .cp = 0x0625, .forms = .{ 0x0000, 0x0000, 0xFE88, 0xFE87 } },
    .{ .cp = 0x0626, .forms = .{ 0xFE8B, 0xFE8C, 0xFE8A, 0xFE89 } },
    .{ .cp = 0x0627, .forms = .{ 0x0000, 0x0000, 0xFE8E, 0xFE8D } },
    .{ .cp = 0x0628, .forms = .{ 0xFE91, 0xFE92, 0xFE90, 0xFE8F } },
    .{ .cp = 0x0629, .forms = .{ 0x0000, 0x0000, 0xFE94, 0xFE93 } },
    .{ .cp = 0x062A, .forms = .{ 0xFE97, 0xFE98, 0xFE96, 0xFE95 } },
    .{ .cp = 0x062B, .forms = .{ 0xFE9B, 0xFE9C, 0xFE9A, 0xFE99 } },
    .{ .cp = 0x062C, .forms = .{ 0xFE9F, 0xFEA0, 0xFE9E, 0xFE9D } },
    .{ .cp = 0x062D, .forms = .{ 0xFEA3, 0xFEA4, 0xFEA2, 0xFEA1 } },
    .{ .cp = 0x062E, .forms = .{ 0xFEA7, 0xFEA8, 0xFEA6, 0xFEA5 } },
    .{ .cp = 0x062F, .forms = .{ 0x0000, 0x0000, 0xFEAA, 0xFEA9 } },
    .{ .cp = 0x0630, .forms = .{ 0x0000, 0x0000, 0xFEAC, 0xFEAB } },
    .{ .cp = 0x0631, .forms = .{ 0x0000, 0x0000, 0xFEAE, 0xFEAD } },
    .{ .cp = 0x0632, .forms = .{ 0x0000, 0x0000, 0xFEB0, 0xFEAF } },
    .{ .cp = 0x0633, .forms = .{ 0xFEB3, 0xFEB4, 0xFEB2, 0xFEB1 } },
    .{ .cp = 0x0634, .forms = .{ 0xFEB7, 0xFEB8, 0xFEB6, 0xFEB5 } },
    .{ .cp = 0x0635, .forms = .{ 0xFEBB, 0xFEBC, 0xFEBA, 0xFEB9 } },
    .{ .cp = 0x0636, .forms = .{ 0xFEBF, 0xFEC0, 0xFEBE, 0xFEBD } },
    .{ .cp = 0x0637, .forms = .{ 0xFEC3, 0xFEC4, 0xFEC2, 0xFEC1 } },
    .{ .cp = 0x0638, .forms = .{ 0xFEC7, 0xFEC8, 0xFEC6, 0xFEC5 } },
    .{ .cp = 0x0639, .forms = .{ 0xFECB, 0xFECC, 0xFECA, 0xFEC9 } },
    .{ .cp = 0x063A, .forms = .{ 0xFECF, 0xFED0, 0xFECE, 0xFECD } },
    .{ .cp = 0x0641, .forms = .{ 0xFED3, 0xFED4, 0xFED2, 0xFED1 } },
    .{ .cp = 0x0642, .forms = .{ 0xFED7, 0xFED8, 0xFED6, 0xFED5 } },
    .{ .cp = 0x0643, .forms = .{ 0xFEDB, 0xFEDC, 0xFEDA, 0xFED9 } },
    .{ .cp = 0x0644, .forms = .{ 0xFEDF, 0xFEE0, 0xFEDE, 0xFEDD } },
    .{ .cp = 0x0645, .forms = .{ 0xFEE3, 0xFEE4, 0xFEE2, 0xFEE1 } },
    .{ .cp = 0x0646, .forms = .{ 0xFEE7, 0xFEE8, 0xFEE6, 0xFEE5 } },
    .{ .cp = 0x0647, .forms = .{ 0xFEEB, 0xFEEC, 0xFEEA, 0xFEE9 } },
    .{ .cp = 0x0648, .forms = .{ 0x0000, 0x0000, 0xFEEE, 0xFEED } },
    .{ .cp = 0x0649, .forms = .{ 0xFBE8, 0xFBE9, 0xFEF0, 0xFEEF } },
    .{ .cp = 0x064A, .forms = .{ 0xFEF3, 0xFEF4, 0xFEF2, 0xFEF1 } },
    .{ .cp = 0x0671, .forms = .{ 0x0000, 0x0000, 0xFB51, 0xFB50 } },
    .{ .cp = 0x0677, .forms = .{ 0x0000, 0x0000, 0x0000, 0xFBDD } },
    .{ .cp = 0x0679, .forms = .{ 0xFB68, 0xFB69, 0xFB67, 0xFB66 } },
    .{ .cp = 0x067A, .forms = .{ 0xFB60, 0xFB61, 0xFB5F, 0xFB5E } },
    .{ .cp = 0x067B, .forms = .{ 0xFB54, 0xFB55, 0xFB53, 0xFB52 } },
    .{ .cp = 0x067E, .forms = .{ 0xFB58, 0xFB59, 0xFB57, 0xFB56 } },
    .{ .cp = 0x067F, .forms = .{ 0xFB64, 0xFB65, 0xFB63, 0xFB62 } },
    .{ .cp = 0x0680, .forms = .{ 0xFB5C, 0xFB5D, 0xFB5B, 0xFB5A } },
    .{ .cp = 0x0683, .forms = .{ 0xFB78, 0xFB79, 0xFB77, 0xFB76 } },
    .{ .cp = 0x0684, .forms = .{ 0xFB74, 0xFB75, 0xFB73, 0xFB72 } },
    .{ .cp = 0x0686, .forms = .{ 0xFB7C, 0xFB7D, 0xFB7B, 0xFB7A } },
    .{ .cp = 0x0687, .forms = .{ 0xFB80, 0xFB81, 0xFB7F, 0xFB7E } },
    .{ .cp = 0x0688, .forms = .{ 0x0000, 0x0000, 0xFB89, 0xFB88 } },
    .{ .cp = 0x068C, .forms = .{ 0x0000, 0x0000, 0xFB85, 0xFB84 } },
    .{ .cp = 0x068D, .forms = .{ 0x0000, 0x0000, 0xFB83, 0xFB82 } },
    .{ .cp = 0x068E, .forms = .{ 0x0000, 0x0000, 0xFB87, 0xFB86 } },
    .{ .cp = 0x0691, .forms = .{ 0x0000, 0x0000, 0xFB8D, 0xFB8C } },
    .{ .cp = 0x0698, .forms = .{ 0x0000, 0x0000, 0xFB8B, 0xFB8A } },
    .{ .cp = 0x06A4, .forms = .{ 0xFB6C, 0xFB6D, 0xFB6B, 0xFB6A } },
    .{ .cp = 0x06A6, .forms = .{ 0xFB70, 0xFB71, 0xFB6F, 0xFB6E } },
    .{ .cp = 0x06A9, .forms = .{ 0xFB90, 0xFB91, 0xFB8F, 0xFB8E } },
    .{ .cp = 0x06AD, .forms = .{ 0xFBD5, 0xFBD6, 0xFBD4, 0xFBD3 } },
    .{ .cp = 0x06AF, .forms = .{ 0xFB94, 0xFB95, 0xFB93, 0xFB92 } },
    .{ .cp = 0x06B1, .forms = .{ 0xFB9C, 0xFB9D, 0xFB9B, 0xFB9A } },
    .{ .cp = 0x06B3, .forms = .{ 0xFB98, 0xFB99, 0xFB97, 0xFB96 } },
    .{ .cp = 0x06BA, .forms = .{ 0x0000, 0x0000, 0xFB9F, 0xFB9E } },
    .{ .cp = 0x06BB, .forms = .{ 0xFBA2, 0xFBA3, 0xFBA1, 0xFBA0 } },
    .{ .cp = 0x06BE, .forms = .{ 0xFBAC, 0xFBAD, 0xFBAB, 0xFBAA } },
    .{ .cp = 0x06C0, .forms = .{ 0x0000, 0x0000, 0xFBA5, 0xFBA4 } },
    .{ .cp = 0x06C1, .forms = .{ 0xFBA8, 0xFBA9, 0xFBA7, 0xFBA6 } },
    .{ .cp = 0x06C5, .forms = .{ 0x0000, 0x0000, 0xFBE1, 0xFBE0 } },
    .{ .cp = 0x06C6, .forms = .{ 0x0000, 0x0000, 0xFBDA, 0xFBD9 } },
    .{ .cp = 0x06C7, .forms = .{ 0x0000, 0x0000, 0xFBD8, 0xFBD7 } },
    .{ .cp = 0x06C8, .forms = .{ 0x0000, 0x0000, 0xFBDC, 0xFBDB } },
    .{ .cp = 0x06C9, .forms = .{ 0x0000, 0x0000, 0xFBE3, 0xFBE2 } },
    .{ .cp = 0x06CB, .forms = .{ 0x0000, 0x0000, 0xFBDF, 0xFBDE } },
    .{ .cp = 0x06CC, .forms = .{ 0xFBFE, 0xFBFF, 0xFBFD, 0xFBFC } },
    .{ .cp = 0x06D0, .forms = .{ 0xFBE6, 0xFBE7, 0xFBE5, 0xFBE4 } },
    .{ .cp = 0x06D2, .forms = .{ 0x0000, 0x0000, 0xFBAF, 0xFBAE } },
    .{ .cp = 0x06D3, .forms = .{ 0x0000, 0x0000, 0xFBB1, 0xFBB0 } },
};

/// Three-component ligatures over presentation forms (`rlig`, ignoring
/// marks).
pub const ligatures_3 = [_]Ligature(2){
    .{ .first = 0xFEDF, .components = .{ 0xFEE4, 0xFEA4 }, .ligature = 0xFD88 },
    .{ .first = 0xFEDF, .components = .{ 0xFEE0, 0xFEEA }, .ligature = 0xF201 },
    .{ .first = 0xFEDF, .components = .{ 0xFEE4, 0xFEA0 }, .ligature = 0xF211 },
};

/// Two-component ligatures over presentation forms (`rlig`, ignoring
/// marks).
pub const ligatures_2 = [_]Ligature(1){
    .{ .first = 0xFE91, .components = .{0xFEE2}, .ligature = 0xFC08 },
    .{ .first = 0xFE91, .components = .{0xFEE4}, .ligature = 0xFC9F },
    .{ .first = 0xFE91, .components = .{0xFEA0}, .ligature = 0xFC9C },
    .{ .first = 0xFE91, .components = .{0xFEA4}, .ligature = 0xFC9D },
    .{ .first = 0xFE91, .components = .{0xFEA8}, .ligature = 0xFC9E },
    .{ .first = 0xFE92, .components = .{0xFEAE}, .ligature = 0xFC6A },
    .{ .first = 0xFE92, .components = .{0xFEE6}, .ligature = 0xFC6D },
    .{ .first = 0xFE92, .components = .{0xFEF2}, .ligature = 0xFC6F },
    .{ .first = 0xFE97, .components = .{0xFEE2}, .ligature = 0xFC0E },
    .{ .first = 0xFE97, .components = .{0xFEE4}, .ligature = 0xFCA4 },
    .{ .first = 0xFE97, .components = .{0xFEA0}, .ligature = 0xFCA1 },
    .{ .first = 0xFE97, .components = .{0xFEA4}, .ligature = 0xFCA2 },
    .{ .first = 0xFE97, .components = .{0xFEA8}, .ligature = 0xFCA3 },
    .{ .first = 0xFE98, .components = .{0xFEAE}, .ligature = 0xFC70 },
    .{ .first = 0xFE98, .components = .{0xFEE6}, .ligature = 0xFC73 },
    .{ .first = 0xFE98, .components = .{0xFEF2}, .ligature = 0xFC75 },
    .{ .first = 0xFE9B, .components = .{0xFEE2}, .ligature = 0xFC12 },
    .{ .first = 0xFE9F, .components = .{0xFEE4}, .ligature = 0xFCA8 },
    .{ .first = 0xFEA3, .components = .{0xFEE4}, .ligature = 0xFCAA },
    .{ .first = 0xFEA7, .components = .{0xFEE4}, .ligature = 0xFCAC },
    .{ .first = 0xFEB3, .components = .{0xFEE4}, .ligature = 0xFCB0 },
    .{ .first = 0xFEB7, .components = .{0xFEE4}, .ligature = 0xFD30 },
    .{ .first = 0xFED3, .components = .{0xFEF2}, .ligature = 0xFC32 },
    .{ .first = 0xFEDF, .components = .{0xFE9E}, .ligature = 0xFC3F },
    .{ .first = 0xFEDF, .components = .{0xFEA0}, .ligature = 0xFCC9 },
    .{ .first = 0xFEDF, .components = .{0xFEA2}, .ligature = 0xFC40 },
    .{ .first = 0xFEDF, .components = .{0xFEA4}, .ligature = 0xFCCA },
    .{ .first = 0xFEDF, .components = .{0xFEA6}, .ligature = 0xFC41 },
    .{ .first = 0xFEDF, .components = .{0xFEA8}, .ligature = 0xFCCB },
    .{ .first = 0xFEDF, .components = .{0xFEE2}, .ligature = 0xFC42 },
    .{ .first = 0xFEDF, .components = .{0xFEE4}, .ligature = 0xFCCC },
    .{ .first = 0xFEDF, .components = .{0xFEF0}, .ligature = 0xFC43 },
    .{ .first = 0xFEDF, .components = .{0xFEF2}, .ligature = 0xFC44 },
    .{ .first = 0xFEDF, .components = .{0xFEEC}, .ligature = 0xFCCD },
    .{ .first = 0xFEDF, .components = .{0xFE82}, .ligature = 0xFEF5 },
    .{ .first = 0xFEDF, .components = .{0xFE84}, .ligature = 0xFEF7 },
    .{ .first = 0xFEDF, .components = .{0xFE88}, .ligature = 0xFEF9 },
    .{ .first = 0xFEDF, .components = .{0xFE8E}, .ligature = 0xFEFB },
    .{ .first = 0xFEE0, .components = .{0xFEF0}, .ligature = 0xFC86 },
    .{ .first = 0xFEE0, .components = .{0xFE82}, .ligature = 0xFEF6 },
    .{ .first = 0xFEE0, .components = .{0xFE84}, .ligature = 0xFEF8 },
    .{ .first = 0xFEE0, .components = .{0xFE88}, .ligature = 0xFEFA },
    .{ .first = 0xFEE0, .components = .{0xFE8E}, .ligature = 0xFEFC },
    .{ .first = 0xFEE3, .components = .{0xFEA0}, .ligature = 0xFCCE },
    .{ .first = 0xFEE3, .components = .{0xFEA4}, .ligature = 0xFCCF },
    .{ .first = 0xFEE3, .components = .{0xFEA8}, .ligature = 0xFCD0 },
    .{ .first = 0xFEE3, .components = .{0xFEE4}, .ligature = 0xFCD1 },
    .{ .first = 0xFEE7, .components = .{0xFEE2}, .ligature = 0xFC4E },
    .{ .first = 0xFEE7, .components = .{0xFEE4}, .ligature = 0xFCD5 },
    .{ .first = 0xFEE7, .components = .{0xFEA0}, .ligature = 0xFCD2 },
    .{ .first = 0xFEE7, .components = .{0xFEA4}, .ligature = 0xFCD3 },
    .{ .first = 0xFEE8, .components = .{0xFEF2}, .ligature = 0xFC8F },
    .{ .first = 0xFEF3, .components = .{0xFEA0}, .ligature = 0xFCDA },
    .{ .first = 0xFEF3, .components = .{0xFEA4}, .ligature = 0xFCDB },
    .{ .first = 0xFEF3, .components = .{0xFEA8}, .ligature = 0xFCDC },
    .{ .first = 0xFEF3, .components = .{0xFEE4}, .ligature = 0xFCDD },
    .{ .first = 0xFEF4, .components = .{0xFEAE}, .ligature = 0xFC91 },
    .{ .first = 0xFEF4, .components = .{0xFEE6}, .ligature = 0xFC94 },
};

/// Shadda ligatures (`rlig`, marks included).
pub const ligatures_mark = [_]Ligature(1){
    .{ .first = 0x0651, .components = .{0x064C}, .ligature = 0xFC5E },
    .{ .first = 0x0651, .components = .{0x064E}, .ligature = 0xFC60 },
    .{ .first = 0x0651, .components = .{0x064F}, .ligature = 0xFC61 },
    .{ .first = 0x0651, .components = .{0x0650}, .ligature = 0xFC62 },
    .{ .first = 0x0651, .components = .{0x064B}, .ligature = 0xF2EE },
};
