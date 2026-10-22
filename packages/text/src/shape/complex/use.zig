//! The Universal Shaping Engine (Microsoft's USE spec, following
//! HarfBuzz's `hb-ot-shaper-use`): characters get USE classes (generated
//! by ucdgen, Microsoft's overrides included), a syllable machine splits
//! the text into clusters, and features run in the spec's groups with
//! reordering between them:
//!
//! 1. Pre-processing, per syllable: `locl`, `ccmp`, `nukt`, `akhn`.
//! 2. Reordering: `rphf` (on the repha or the first three glyphs), then
//!    `pref`; a substituted repha becomes `R` and a substituted pre-base
//!    form `VPre`.
//! 3. Orthographic units, per syllable: `rkrf`, `abvf`, `blwf`, `half`,
//!    `pstf`, `vatu`, `cjct`. Then dotted circles go into broken clusters,
//!    the repha moves before the first post-base glyph and pre-base vowels
//!    and modifiers move to the start (after the last halant).
//! 4. Topographical: `isol`, `init`, `medi`, `fina` by syllable, or by
//!    Arabic joining for the scripts that join.
//! 5. Presentation: `abvs`, `blws`, `haln`, `pres`, `psts`, then the common
//!    features; GPOS as usual, with marks zeroed before it.
//!
//! Scripts routed here (see `default.select`): HarfBuzz's USE list, which
//! covers Tibetan, Mongolian, Sinhala, Balinese, Batak, Buginese, Buhid,
//! Chakma, Cham, Javanese, Kayah Li, Lepcha, Limbu, Meetei Mayek, Rejang,
//! Saurashtra, Sundanese, Tai Tham, Tai Viet and every script encoded since
//! (through Unicode 18), plus the nine Indic scripts when the font uses
//! their `xxx3` tags. Khmer and Myanmar have their own shapers (HarfBuzz
//! does not send them to USE).
//!
//! Before normalization, discouraged vowel spellings get a dotted circle
//! (`vowel_constraints.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const plan_mod = @import("../plan.zig");
const ComplexShaper = plan_mod.ComplexShaper;
const PlanBuilder = plan_mod.PlanBuilder;
const ShapePlan = plan_mod.ShapePlan;
const FeatureFlags = plan_mod.FeatureFlags;
const buffer = @import("../buffer.zig");
const Buffer = buffer.Buffer;
const GlyphInfo = buffer.GlyphInfo;
const GlyphProps = @import("../../ot/gdef.zig").GlyphProps;
const unicode = @import("../../unicode/root.zig");
const Script = unicode.Script;
const tag = @import("../../ot/root.zig").tag;
const arabic = @import("arabic.zig");
const dfa = @import("syllable_dfa.zig");
const dotted = @import("dotted_circle.zig");
const vowel_constraints = @import("vowel_constraints.zig");

/// USE character classes (`unicode.useCategory`).
pub const UseCategory = unicode.UseCategory;

/// The USE class of `cp`.
pub const useCategory = unicode.useCategory;

/// The shaper.
pub const shaper: ComplexShaper = .{
    .name = "use",
    .collectFeatures = collectFeatures,
    .dataInit = dataInit,
    .setupMasks = setupMasks,
    .preprocessText = vowel_constraints.preprocess,
    .normalize_short_circuit = false,
    .compose = compose,
    .zero_marks = .gdef_early,
    .fallback_position = false,
};

/// Syllable types (low 4 bits of `GlyphInfo.syllable`), in machine rule
/// order.
pub const SyllableType = enum(u4) {
    virama_terminated,
    sakot_terminated,
    standard,
    number_joiner_terminated,
    numeral,
    symbol,
    hieroglyph,
    broken,
    non_cluster,
};

// The cluster grammar of HarfBuzz's hb-ot-shaper-use-machine.rl.
const C = UseCategory;
fn one(comptime cs: []const C) dfa.Expr {
    return dfa.one(C, cs);
}
const seq = dfa.seq;
const alt = dfa.alt;
const star = dfa.star;
const opt = dfa.opt;
const plus = dfa.plus;

const g = struct {
    const h = one(&.{ .H, .HVM, .IS, .Sk });
    const consonant_modifiers = seq(&.{
        star(one(&.{.CMAbv})),
        star(one(&.{.CMBlw})),
        star(seq(&.{ alt(&.{ seq(&.{ h, one(&.{.B}) }), one(&.{.SUB}) }), star(one(&.{.CMAbv})), star(one(&.{.CMBlw})) })),
    });
    const medial_consonants = seq(&.{ opt(one(&.{.MPre})), opt(one(&.{.MAbv})), opt(one(&.{.MBlw})), opt(one(&.{.MPst})) });
    const dependent_vowels = alt(&.{
        seq(&.{ star(one(&.{.VPre})), star(one(&.{.VAbv})), star(one(&.{.VBlw})), star(one(&.{.VPst})) }),
        one(&.{.H}),
    });
    const vowel_modifiers = seq(&.{ opt(one(&.{.HVM})), star(one(&.{.VMPre})), star(one(&.{.VMAbv})), star(one(&.{.VMBlw})), star(one(&.{.VMPst})) });
    const final_consonants = seq(&.{ star(one(&.{.FAbv})), star(one(&.{.FBlw})), star(one(&.{.FPst})) });
    const final_modifiers = alt(&.{ seq(&.{ star(one(&.{.FMAbv})), star(one(&.{.FMBlw})) }), opt(one(&.{.FMPst})) });
    const syllable_start = seq(&.{ opt(one(&.{ .R, .CS })), one(&.{ .B, .GB }) });
    const middle = seq(&.{ consonant_modifiers, medial_consonants, dependent_vowels, vowel_modifiers, star(seq(&.{ one(&.{.Sk}), one(&.{.B}) })) });
    const tail = seq(&.{ middle, final_consonants, final_modifiers });
    const number_joiner_tail = seq(&.{ star(seq(&.{ one(&.{.HN}), one(&.{.N}) })), one(&.{.HN}) });
    const numeral_tail = plus(seq(&.{ one(&.{.HN}), one(&.{.N}) }));
    const symbol_tail = alt(&.{ seq(&.{ plus(one(&.{.SMAbv})), star(one(&.{.SMBlw})) }), plus(one(&.{.SMBlw})) });
    const virama_tail = seq(&.{ consonant_modifiers, one(&.{ .IS, .RK }) });
    const sakot_tail = seq(&.{ middle, one(&.{.Sk}) });
    const any_tail = alt(&.{ tail, sakot_tail, symbol_tail, virama_tail });
    const zwnj = opt(one(&.{.ZWNJ}));
    const glyph = seq(&.{ one(&.{.G}), opt(one(&.{.HR})), opt(one(&.{.HM})), star(one(&.{.SE})) });

    /// Rules in the machine's order, with the syllable type of each.
    const rules = [_]dfa.Expr{
        seq(&.{ syllable_start, virama_tail, zwnj }),
        seq(&.{ syllable_start, sakot_tail, zwnj }),
        seq(&.{ syllable_start, tail, zwnj }),
        seq(&.{ one(&.{.N}), number_joiner_tail, zwnj }),
        seq(&.{ one(&.{.N}), opt(numeral_tail), zwnj }),
        seq(&.{ one(&.{ .O, .GB, .SB }), opt(any_tail), zwnj }),
        seq(&.{ star(one(&.{.SB})), glyph, star(seq(&.{ one(&.{.J}), star(one(&.{.SB})), opt(glyph) })), zwnj }),
        one(&.{.FMPst}),
        seq(&.{ opt(one(&.{.R})), alt(&.{ any_tail, number_joiner_tail, numeral_tail }), zwnj }),
        dfa.any,
    };
    const types = [_]SyllableType{ .virama_terminated, .sakot_terminated, .standard, .number_joiner_terminated, .numeral, .symbol, .hieroglyph, .non_cluster, .broken, .non_cluster };
};

/// The USE syllable machine.
pub const Machine = dfa.Machine(C, &g.rules);

inline fn category(gi: GlyphInfo) C {
    return @enumFromInt(@as(u6, @truncate(gi.shaper)));
}

fn setCategory(gi: *GlyphInfo, c: C) void {
    gi.shaper = @intFromEnum(c);
}

/// Splits `b` into syllables (HarfBuzz's `find_syllables_use`): CGJ-class
/// characters, and a ZWNJ before a mark, are left out of the machine's
/// input and join the syllable before them.
pub fn findSyllables(gpa: Allocator, b: *Buffer) Allocator.Error!void {
    const infos = b.infos.items;
    if (infos.len == 0) return;
    var cats: std.ArrayList(C) = .empty;
    defer cats.deinit(gpa);
    var index: std.ArrayList(u32) = .empty;
    defer index.deinit(gpa);
    try cats.ensureTotalCapacity(gpa, infos.len);
    try index.ensureTotalCapacity(gpa, infos.len);
    for (infos, 0..) |gi, i| {
        const c = category(gi);
        if (c == .CGJ) continue;
        if (c == .ZWNJ) {
            const next_is_mark = for (infos[i + 1 ..]) |n| {
                if (category(n) != .CGJ) break n.isUnicodeMark();
            } else false;
            if (next_is_mark) continue;
        }
        cats.appendAssumeCapacity(c);
        index.appendAssumeCapacity(@intCast(i));
    }
    var serial: u8 = 1;
    var k: usize = 0;
    // Characters before the first machine input join the first syllable.
    var from: usize = 0;
    while (k < cats.items.len) {
        const m = Machine.longestMatch(cats.items, k) orelse dfa.Match{ .len = 1, .rule = g.rules.len - 1 };
        const end = k + m.len;
        const to: usize = if (end < cats.items.len) index.items[end] else infos.len;
        const value = serial << 4 | @intFromEnum(g.types[m.rule]);
        for (infos[from..to]) |*gi| gi.syllable = value;
        serial += 1;
        if (serial == 16) serial = 1;
        from = to;
        k = end;
    }
    for (infos[from..]) |*gi| gi.syllable = if (from > 0) infos[from - 1].syllable else 0;
}

fn collectFeatures(b: *PlanBuilder) Allocator.Error!void {
    const per_syllable: FeatureFlags = .{ .per_syllable = true };
    const zwj_syllable: FeatureFlags = .{ .manual_zwj = true, .per_syllable = true };
    // Before any lookup.
    try b.addGsubPause(setupSyllables);
    // Default glyph pre-processing.
    try b.enableFeature(tag("locl"), per_syllable, 1);
    try b.enableFeature(tag("ccmp"), per_syllable, 1);
    try b.enableFeature(tag("nukt"), per_syllable, 1);
    try b.enableFeature(tag("akhn"), zwj_syllable, 1);
    // Reordering.
    try b.addGsubPause(clearSubstitutionFlags);
    try b.addFeature(tag("rphf"), zwj_syllable, 1);
    try b.addGsubPause(recordRphf);
    try b.addGsubPause(clearSubstitutionFlags);
    try b.enableFeature(tag("pref"), zwj_syllable, 1);
    try b.addGsubPause(recordPref);
    // Orthographic units.
    inline for (.{ "rkrf", "abvf", "blwf", "half", "pstf", "vatu", "cjct" }) |f| try b.enableFeature(tag(f), zwj_syllable, 1);
    try b.addGsubPause(reorder);
    try b.addGsubPause(clearSyllables);
    // Topographical.
    for (topographical) |f| try b.addFeature(f, .none, 1);
    try b.addGsubPause(null);
    // Standard typographic presentation.
    inline for (.{ "abvs", "blws", "haln", "pres", "psts" }) |f| try b.enableFeature(tag(f), .{ .manual_zwj = true }, 1);
}

const topographical = [_]u32{ tag("isol"), tag("init"), tag("medi"), tag("fina") };
const Form = enum(u3) { isol, init, medi, fina, none };

/// Scripts whose USE fonts join like Arabic (HarfBuzz's
/// `has_arabic_joining`).
pub fn hasArabicJoining(s: Script) bool {
    return switch (s) {
        .Adlm, .Arab, .Chrs, .Rohg, .Mand, .Mani, .Mong, .Nkoo, .Ougr, .Phag, .Phlp, .Sogd, .Syrc => true,
        else => false,
    };
}

fn dataInit(p: *ShapePlan) Allocator.Error!void {
    if (hasArabicJoining(p.script)) try arabic.dataInit(p);
}

fn setupMasks(p: *const ShapePlan, b: *Buffer) void {
    if (hasArabicJoining(p.script)) arabic.setupMasks(p, b);
    for (b.infos.items) |*gi| setCategory(gi, useCategory(gi.cp));
}

/// Leaves split vowels decomposed: no recomposition onto a mark (shared
/// by the syllabic shapers).
pub fn compose(a: u21, b: u21) ?u21 {
    switch (unicode.props(a).gc) {
        .Mn, .Mc, .Me => return null,
        else => {},
    }
    return @import("../normalize.zig").compose(a, b);
}

fn setupSyllables(p: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    try findSyllables(b.gpa, b);
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        b.unsafeToBreak(s, e);
        s = e;
    }
    setupRphfMask(p, b);
    setupTopographicalMasks(p, b);
}

fn setupRphfMask(p: *const ShapePlan, b: *Buffer) void {
    const mask = p.mask1(tag("rphf"));
    if (mask == 0) return;
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        const limit: usize = if (category(infos[s]) == .R) 1 else @min(3, e - s);
        for (infos[s .. s + limit]) |*gi| gi.mask |= mask;
        s = e;
    }
}

fn setupTopographicalMasks(p: *const ShapePlan, b: *Buffer) void {
    if (hasArabicJoining(p.script)) return;
    var masks: [4]u32 = undefined;
    var all: u32 = 0;
    for (&masks, topographical) |*m, f| {
        m.* = p.mask1(f);
        if (m.* == p.global_mask) m.* = 0;
        all |= m.*;
    }
    if (all == 0) return;
    const other = ~all;
    const infos = b.infos.items;
    var last_start: usize = 0;
    var last_form: Form = .none;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        switch (@as(SyllableType, @enumFromInt(dotted.syllableType(infos[s])))) {
            .hieroglyph, .non_cluster => last_form = .none,
            else => {
                const join = last_form == .fina or last_form == .isol;
                if (join) {
                    // The previous syllable joins this one.
                    last_form = if (last_form == .fina) .medi else .init;
                    for (infos[last_start..s]) |*gi| gi.mask = (gi.mask & other) | masks[@intFromEnum(last_form)];
                }
                last_form = if (join) .fina else .isol;
                for (infos[s..e]) |*gi| gi.mask = (gi.mask & other) | masks[@intFromEnum(last_form)];
            },
        }
        last_start = s;
        s = e;
    }
}

fn clearSubstitutionFlags(_: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    for (b.infos.items) |*gi| gi.glyph_props &= ~GlyphProps.substituted;
}

fn clearSyllables(_: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    for (b.infos.items) |*gi| gi.syllable = 0;
}

/// A substituted repha (inside the `rphf` range) becomes `R`.
fn recordRphf(p: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    const mask = p.mask1(tag("rphf"));
    if (mask == 0) return;
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        for (infos[s..e]) |*gi| {
            if (gi.mask & mask == 0) break;
            if (gi.substituted()) {
                setCategory(gi, .R);
                break;
            }
        }
        s = e;
    }
}

/// A substituted pre-base form behaves like a pre-base vowel.
fn recordPref(_: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        for (infos[s..e]) |*gi| if (gi.substituted()) {
            setCategory(gi, .VPre);
            break;
        };
        s = e;
    }
}

fn isHalant(gi: GlyphInfo) bool {
    return switch (category(gi)) {
        .H, .HVM, .IS => gi.glyph_props & GlyphProps.ligated == 0,
        else => false,
    };
}

fn flag(cs: []const C) u64 {
    var m: u64 = 0;
    for (cs) |c| m |= @as(u64, 1) << @intFromEnum(c);
    return m;
}

const post_base = flag(&.{ .FAbv, .FBlw, .FPst, .FMAbv, .FMBlw, .FMPst, .MAbv, .MBlw, .MPst, .MPre, .VAbv, .VBlw, .VPst, .VPre, .VMAbv, .VMBlw, .VMPst, .VMPre });

fn reorderSyllable(b: *Buffer, start: usize, end: usize) void {
    const infos = b.infos.items;
    switch (@as(SyllableType, @enumFromInt(dotted.syllableType(infos[start])))) {
        .virama_terminated, .sakot_terminated, .standard, .symbol, .broken => {},
        else => return,
    }
    // A repha moves towards the end, before the first post-base glyph.
    if (category(infos[start]) == .R and end - start > 1) {
        var i = start + 1;
        while (i < end) : (i += 1) {
            const is_post_base = (post_base >> @intFromEnum(category(infos[i]))) & 1 != 0 or isHalant(infos[i]);
            if (is_post_base or i == end - 1) {
                if (is_post_base) i -= 1;
                b.mergeClusters(start, i + 1);
                const t = infos[start];
                std.mem.copyForwards(GlyphInfo, infos[start..i], infos[start + 1 .. i + 1]);
                infos[i] = t;
                break;
            }
        }
    }
    // Pre-base vowels and modifiers move to the start, or just after the
    // last halant before them.
    var j = start;
    for (start..end) |i| {
        const c = category(infos[i]);
        if (isHalant(infos[i])) {
            j = i + 1;
        } else if ((c == .VPre or c == .VMPre) and infos[i].ligComp() == 0 and j < i) {
            b.mergeClusters(j, i + 1);
            const t = infos[i];
            std.mem.copyBackwards(GlyphInfo, infos[j + 1 .. i + 1], infos[j..i]);
            infos[j] = t;
        }
    }
}

fn reorder(p: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    _ = try dotted.insertDottedCircles(b, p.inst.face, @intFromEnum(SyllableType.broken), @intFromEnum(C.B), @intFromEnum(C.R), 0);
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        reorderSyllable(b, s, e);
        s = e;
    }
}
