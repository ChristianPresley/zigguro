//! The Indic shaper for Devanagari, Bengali, Gurmukhi, Gujarati, Oriya,
//! Tamil, Telugu, Kannada and Malayalam (Microsoft's Indic specs, following
//! HarfBuzz's `hb-ot-shaper-indic`):
//!
//! 1. A syllable machine finds consonant, vowel, standalone, symbol and
//!    broken clusters; broken ones get a dotted circle.
//! 2. Initial reordering, per syllable: the font decides which consonants
//!    have below-base or post-base forms (by asking `blwf`, `pstf`, `pref`
//!    and `vatu` whether they would substitute consonant + virama), which
//!    fixes the base consonant and a reph; then the syllable is sorted into
//!    visual order (pre-base matras first) and the basic features' masks
//!    are set.
//! 3. The basic features one at a time, per syllable: `nukt`, `akhn`,
//!    `rphf`, `rkrf`, `pref`, `blwf`, `abvf`, `half`, `pstf`, `vatu`,
//!    `cjct`.
//! 4. Final reordering, by what the font formed: pre-base matras move after
//!    the last half form, the reph moves to its script's position, a
//!    pre-base form moves before the base, `init` marks a word-initial
//!    pre-base matra.
//! 5. `init`, `pres`, `abvs`, `blws`, `psts`, `haln` and the common
//!    features; `liga` is off.
//!
//! Fonts with the old script tags (`deva`, ...) get the old-spec behaviour:
//! halants move after the last consonant, below-base forms only apply after
//! the base, and would-substitute checks allow context. Fonts with `xxx3`
//! tags go to USE (see `default.select`).
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
const ot = @import("../../ot/root.zig");
const GlyphId = ot.GlyphId;
const tag = ot.tag;
const Script = @import("../../unicode/root.zig").Script;
const normalize = @import("../normalize.zig");
const would_apply = @import("../would_apply.zig");
const tables = @import("indic_tables.zig");
const C = tables.Category;
const Position = tables.Position;
const category = tables.category;
const position = tables.position;
const dfa = @import("syllable_dfa.zig");
const dotted = @import("dotted_circle.zig");
const vowel_constraints = @import("vowel_constraints.zig");

/// The shaper.
pub const shaper: ComplexShaper = .{
    .name = "indic",
    .collectFeatures = collectFeatures,
    .overrideFeatures = overrideFeatures,
    .dataInit = dataInit,
    .setupMasks = setupMasks,
    .preprocessText = vowel_constraints.preprocess,
    .normalize_short_circuit = false,
    .decompose = decompose,
    .compose = compose,
    .zero_marks = .none,
    .fallback_position = false,
};

/// Where a reph goes in final reordering.
pub const RephPosition = enum { after_main, before_sub, after_sub, before_post, after_post };

/// How a reph is written.
pub const RephMode = enum {
    /// Ra + halant.
    implicit,
    /// Ra + halant + ZWJ.
    explicit,
    /// An encoded repha character in logical order.
    log_repha,
};

/// Whether `blwf` also applies before the base.
pub const BlwfMode = enum { pre_and_post, post_only };

/// Per-script behaviour (HarfBuzz's `indic_configs`).
pub const IndicConfig = struct {
    has_old_spec: bool = false,
    virama: u21 = 0,
    reph_pos: RephPosition = .before_post,
    reph_mode: RephMode = .implicit,
    blwf_mode: BlwfMode = .pre_and_post,
};

/// The configuration of `s`.
pub fn configFor(s: Script) IndicConfig {
    return switch (s) {
        .Deva => .{ .has_old_spec = true, .virama = 0x094D, .reph_pos = .before_post },
        .Beng => .{ .has_old_spec = true, .virama = 0x09CD, .reph_pos = .after_sub },
        .Guru => .{ .has_old_spec = true, .virama = 0x0A4D, .reph_pos = .before_sub },
        .Gujr => .{ .has_old_spec = true, .virama = 0x0ACD, .reph_pos = .before_post },
        .Orya => .{ .has_old_spec = true, .virama = 0x0B4D, .reph_pos = .after_main },
        .Taml => .{ .has_old_spec = true, .virama = 0x0BCD, .reph_pos = .after_post },
        .Telu => .{ .has_old_spec = true, .virama = 0x0C4D, .reph_pos = .after_post, .reph_mode = .explicit, .blwf_mode = .post_only },
        .Knda => .{ .has_old_spec = true, .virama = 0x0CCD, .reph_pos = .after_post, .blwf_mode = .post_only },
        .Mlym => .{ .has_old_spec = true, .virama = 0x0D4D, .reph_pos = .after_main, .reph_mode = .log_repha },
        else => .{},
    };
}

fn rephTarget(r: RephPosition) Position {
    return switch (r) {
        .after_main => .after_main,
        .before_sub => .before_sub,
        .after_sub => .after_sub,
        .before_post => .before_post,
        .after_post => .after_post,
    };
}

/// Syllable types (low 4 bits of `GlyphInfo.syllable`).
pub const SyllableType = enum(u4) { consonant, vowel, standalone, symbol, broken, non_indic };

// The grammar of HarfBuzz's hb-ot-shaper-indic-machine.rl.
fn one(comptime cs: []const C) dfa.Expr {
    return dfa.one(C, cs);
}
const seq = dfa.seq;
const alt = dfa.alt;
const star = dfa.star;
const opt = dfa.opt;

const g = struct {
    const c = one(&.{ .C, .Ra });
    const n = seq(&.{ opt(seq(&.{ opt(one(&.{.ZWNJ})), one(&.{.RS}) })), opt(seq(&.{ one(&.{.N}), opt(one(&.{.N})) })) });
    const z = one(&.{ .ZWJ, .ZWNJ });
    const reph = alt(&.{ seq(&.{ one(&.{.Ra}), one(&.{.H}) }), one(&.{.Repha}) });
    const sm = one(&.{ .SM, .SMPst });
    const cn = seq(&.{ c, opt(one(&.{.ZWJ})), opt(n) });
    const symbol = seq(&.{ one(&.{.Symbol}), opt(one(&.{.N})) });
    const matra_group = seq(&.{ star(z), alt(&.{ one(&.{.M}), seq(&.{ opt(sm), one(&.{.MPst}) }) }), opt(one(&.{.N})), opt(one(&.{.H})) });
    const syllable_tail = seq(&.{ opt(seq(&.{ opt(z), sm, opt(sm), opt(one(&.{.ZWNJ})) })), star(one(&.{.A})) });
    const halant_group = seq(&.{ opt(z), one(&.{.H}), opt(seq(&.{ one(&.{.ZWJ}), opt(one(&.{.N})) })) });
    const final_halant_group = alt(&.{ halant_group, seq(&.{ one(&.{.H}), one(&.{.ZWNJ}) }) });
    const medial_group = opt(one(&.{.CM}));
    const halant_or_matra_group = alt(&.{ final_halant_group, star(matra_group) });
    const complex_tail = seq(&.{ star(seq(&.{ halant_group, cn })), medial_group, halant_or_matra_group, syllable_tail });
    const repha_cs = opt(one(&.{ .Repha, .CS }));

    const consonant = seq(&.{ repha_cs, cn, complex_tail });
    const vowel = seq(&.{ opt(reph), one(&.{.V}), opt(n), alt(&.{ one(&.{.ZWJ}), complex_tail }) });
    const standalone = seq(&.{
        alt(&.{ seq(&.{ repha_cs, one(&.{.PLACEHOLDER}) }), seq(&.{ opt(reph), one(&.{.DOTTEDCIRCLE}) }) }),
        opt(n),
        complex_tail,
    });
    const symbol_cluster = seq(&.{ symbol, syllable_tail });
    const broken = seq(&.{ opt(reph), opt(n), complex_tail });

    const rules = [_]dfa.Expr{ consonant, vowel, standalone, symbol_cluster, one(&.{.SMPst}), broken, dfa.any };
    const types = [_]u4{
        @intFromEnum(SyllableType.consonant),
        @intFromEnum(SyllableType.vowel),
        @intFromEnum(SyllableType.standalone),
        @intFromEnum(SyllableType.symbol),
        @intFromEnum(SyllableType.non_indic),
        @intFromEnum(SyllableType.broken),
        @intFromEnum(SyllableType.non_indic),
    };
};

/// The Indic syllable machine.
pub const Machine = dfa.Machine(C, &g.rules);

/// Splits `b` into syllables.
pub fn findSyllables(gpa: Allocator, b: *Buffer) Allocator.Error!void {
    try tables.findSyllables(Machine, &g.types, gpa, b);
}

// The features with masks set by the shaper, in `ShapePlan.shaper_masks`.
const Mask = enum { rphf, pref, blwf, abvf, half, pstf, init };

inline fn mask(p: *const ShapePlan, m: Mask) u32 {
    return p.shaper_masks[@intFromEnum(m)];
}

fn collectFeatures(b: *PlanBuilder) Allocator.Error!void {
    // Before any lookup.
    try b.addGsubPause(setupSyllables);
    try b.enableFeature(tag("locl"), .{ .per_syllable = true }, 1);
    // Not in the specs, but fonts that use it want it first.
    try b.enableFeature(tag("ccmp"), .{ .per_syllable = true }, 1);
    try b.addGsubPause(initialReordering);
    const manual: FeatureFlags = .{ .manual_zwj = true, .manual_zwnj = true, .per_syllable = true };
    const global: FeatureFlags = .{ .global = true, .manual_zwj = true, .manual_zwnj = true, .per_syllable = true };
    // Basic features, one stage each.
    inline for (.{
        .{ "nukt", global }, .{ "akhn", global }, .{ "rphf", manual }, .{ "rkrf", global },
        .{ "pref", manual }, .{ "blwf", manual }, .{ "abvf", manual }, .{ "half", manual },
        .{ "pstf", manual }, .{ "vatu", global }, .{ "cjct", global },
    }) |f| {
        try b.addFeature(tag(f[0]), f[1], 1);
        try b.addGsubPause(null);
    }
    try b.addGsubPause(finalReordering);
    // Presentation features, together (some fonts mix their lookups).
    inline for (.{
        .{ "init", manual }, .{ "pres", global }, .{ "abvs", global },
        .{ "blws", global }, .{ "psts", global }, .{ "haln", global },
    }) |f| try b.addFeature(tag(f[0]), f[1], 1);
}

fn overrideFeatures(b: *PlanBuilder) Allocator.Error!void {
    try b.disableFeature(tag("liga"));
    // Syllables are kept through the common features.
    try b.addGsubPause(clearSyllables);
}

fn dataInit(p: *ShapePlan) void {
    inline for (@typeInfo(Mask).@"enum".fields) |f| p.shaper_masks[f.value] = p.mask1(tag(f.name[0..4]));
}

fn setupMasks(_: *const ShapePlan, b: *Buffer) void {
    for (b.infos.items) |*gi| {
        const t = tables.categories(gi.cp);
        gi.shaper = @intFromEnum(t.cat);
        gi.shaper_aux = @intFromEnum(t.pos);
    }
}

/// Keeps letters whose decompositions fonts draw differently.
fn decompose(ab: u21) ?normalize.Pair {
    return switch (ab) {
        // DEVANAGARI RRA, BENGALI RRA and RHA, TAMIL AU.
        0x0931, 0x09DC, 0x09DD, 0x0B94 => null,
        else => normalize.decompose(ab),
    };
}

/// No recomposition onto a mark (split matras stay split); BENGALI YA +
/// NUKTA recomposes despite its composition exclusion.
fn compose(a: u21, b: u21) ?u21 {
    switch (@import("../../unicode/root.zig").props(a).gc) {
        .Mn, .Mc, .Me => return null,
        else => {},
    }
    if (a == 0x09AF and b == 0x09BC) return 0x09DF;
    return normalize.compose(a, b);
}

fn clearSyllables(_: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    for (b.infos.items) |*gi| gi.syllable = 0;
}

fn setupSyllables(_: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    try findSyllables(b.gpa, b);
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        b.unsafeToBreak(s, e);
        s = e;
    }
}

fn flags(comptime cs: []const C) u64 {
    var m: u64 = 0;
    for (cs) |c| m |= @as(u64, 1) << @intFromEnum(c);
    return m;
}

inline fn in(gi: GlyphInfo, set: u64) bool {
    return (set >> @intFromEnum(category(gi))) & 1 != 0;
}

/// `in`, except that a ligature is none of them.
inline fn isOneOf(gi: GlyphInfo, set: u64) bool {
    if (gi.glyph_props & GlyphProps.ligated != 0) return false;
    return in(gi, set);
}

const consonant_flags = flags(&.{ .C, .CS, .Ra, .CM, .V, .PLACEHOLDER, .DOTTEDCIRCLE });
const joiner_flags = flags(&.{ .ZWJ, .ZWNJ });
const matra_flags = flags(&.{ .M, .MPst });

fn isConsonant(gi: GlyphInfo) bool {
    return isOneOf(gi, consonant_flags);
}
fn isJoiner(gi: GlyphInfo) bool {
    return isOneOf(gi, joiner_flags);
}
fn isHalant(gi: GlyphInfo) bool {
    return isOneOf(gi, flags(&.{.H}));
}

fn ligatedAndDidntMultiply(gi: GlyphInfo) bool {
    return gi.glyph_props & GlyphProps.ligated != 0 and gi.glyph_props & GlyphProps.multiplied == 0;
}

fn setPosition(gi: *GlyphInfo, pos: Position) void {
    gi.shaper_aux = @intFromEnum(pos);
}

/// The shaping context of one buffer.
const Ctx = struct {
    p: *const ShapePlan,
    b: *Buffer,
    config: IndicConfig,
    old_spec: bool,
    /// Whether would-substitute checks forbid context.
    zero_context: bool,

    fn init(p: *const ShapePlan, b: *Buffer) Ctx {
        const config = configFor(p.script);
        const chosen = p.chosen_script[0] orelse 0;
        const old_spec = config.has_old_spec and chosen & 0xFF != '2';
        return .{
            .p = p,
            .b = b,
            .config = config,
            .old_spec = old_spec,
            // Bengali new-spec fonts expect no context, Malayalam ones do.
            .zero_context = !old_spec and p.script != .Mlym,
        };
    }

    fn virama(c: *const Ctx) GlyphId {
        if (c.config.virama == 0) return 0;
        return c.p.inst.face.glyphIndex(c.config.virama);
    }

    /// Whether a lookup in `feature`'s stage would substitute `glyphs`.
    fn wouldSubstitute(c: *const Ctx, comptime feature: *const [4]u8, glyphs: []const GlyphId) bool {
        const gsub = c.p.gsub orelse return false;
        for (c.p.gsubStageLookups(tag(feature))) |l|
            if (would_apply.wouldSubstitute(gsub, l.index, glyphs, c.zero_context)) return true;
        return false;
    }

    /// The position a consonant's forms give it. Both consonant + virama
    /// and virama + consonant are tried (old-spec lookups copied into
    /// new-spec tables still work in Uniscribe).
    fn consonantPosition(c: *const Ctx, consonant: GlyphId, virama_gid: GlyphId) Position {
        const glyphs = [3]GlyphId{ virama_gid, consonant, virama_gid };
        const a = glyphs[0..2];
        const z = glyphs[1..3];
        if (c.wouldSubstitute("blwf", a) or c.wouldSubstitute("blwf", z) or c.wouldSubstitute("vatu", a) or c.wouldSubstitute("vatu", z)) return .below_c;
        if (c.wouldSubstitute("pstf", a) or c.wouldSubstitute("pstf", z)) return .post_c;
        if (c.wouldSubstitute("pref", a) or c.wouldSubstitute("pref", z)) return .post_c;
        return .base_c;
    }
};

fn initialReordering(p: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    const c = Ctx.init(p, b);
    const virama_gid = c.virama();
    if (virama_gid != 0) {
        for (b.infos.items) |*gi| if (position(gi.*) == .base_c) setPosition(gi, c.consonantPosition(gi.gid, virama_gid));
    }
    _ = try dotted.insertDottedCircles(b, p.inst.face, @intFromEnum(SyllableType.broken), @intFromEnum(C.DOTTEDCIRCLE), @intFromEnum(C.Repha), @intFromEnum(Position.end));
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        switch (@as(SyllableType, @enumFromInt(dotted.syllableType(infos[s])))) {
            // Vowels act like consonants, broken clusters have their dotted
            // circle by now.
            .consonant, .vowel, .standalone, .broken => initialReorderSyllable(&c, s, e),
            .symbol, .non_indic => {},
        }
        s = e;
    }
}

fn initialReorderSyllable(c: *const Ctx, start: usize, end: usize) void {
    const p = c.p;
    const b = c.b;
    const infos = b.infos.items;

    // Kannada Ra + halant + ZWJ behaves like Ra + ZWJ + halant (legacy use).
    if (p.script == .Knda and start + 3 <= end and isOneOf(infos[start], flags(&.{.Ra})) and
        isOneOf(infos[start + 1], flags(&.{.H})) and isOneOf(infos[start + 2], flags(&.{.ZWJ})))
    {
        b.mergeClusters(start + 1, start + 3);
        std.mem.swap(GlyphInfo, &infos[start + 1], &infos[start + 2]);
    }

    // 1. Find the base consonant: from the end, the first consonant
    // without a below-base or post-base form, or the first consonant. A
    // leading Ra + halant that forms a reph is not a candidate.
    var base = end;
    var has_reph = false;
    var limit = start;
    if (mask(p, .rphf) != 0 and start + 3 <= end and
        ((c.config.reph_mode == .implicit and !isJoiner(infos[start + 2])) or
            (c.config.reph_mode == .explicit and category(infos[start + 2]) == .ZWJ)))
    {
        const glyphs = [3]GlyphId{ infos[start].gid, infos[start + 1].gid, if (c.config.reph_mode == .explicit) infos[start + 2].gid else 0 };
        if (c.wouldSubstitute("rphf", glyphs[0..2]) or (c.config.reph_mode == .explicit and c.wouldSubstitute("rphf", glyphs[0..3]))) {
            limit += 2;
            while (limit < end and isJoiner(infos[limit])) limit += 1;
            base = start;
            has_reph = true;
        }
    } else if (c.config.reph_mode == .log_repha and category(infos[start]) == .Repha) {
        limit += 1;
        while (limit < end and isJoiner(infos[limit])) limit += 1;
        base = start;
        has_reph = true;
    }
    {
        var i = end;
        var seen_below = false;
        while (true) {
            i -= 1;
            if (isConsonant(infos[i])) {
                const pos = position(infos[i]);
                if (pos != .below_c and (pos != .post_c or seen_below)) {
                    base = i;
                    break;
                }
                if (pos == .below_c) seen_below = true;
                // Pre-base-reordering Ra is post_c, so skipped above.
                base = i;
            } else if (start < i and category(infos[i]) == .ZWJ and category(infos[i - 1]) == .H) {
                // Halant + ZWJ asks for a half form: the search stops. (ZWJ +
                // halant asks for a subjoined form and the search goes on.)
                break;
            }
            if (i <= limit) break;
        }
    }
    // Without another consonant there is no reph: Ra is the base.
    if (has_reph and base == start and limit - base <= 2) has_reph = false;

    // 2./3. Matras are decomposed and marks ordered by normalization.
    for (infos[start..base]) |*gi| setPosition(gi, @enumFromInt(@min(@intFromEnum(Position.pre_c), gi.shaper_aux)));
    if (base < end) setPosition(&infos[base], .base_c);
    if (has_reph) setPosition(&infos[start], .ra_to_become_reph);

    // Old-spec fonts: the first post-base halant moves after the last
    // consonant (Kannada not after a halant already there).
    if (c.old_spec) {
        const no_double = p.script == .Knda;
        var i = base + 1;
        while (i < end) : (i += 1) {
            if (category(infos[i]) != .H) continue;
            var j = end - 1;
            while (j > i) : (j -= 1) {
                if (isConsonant(infos[j]) or (no_double and category(infos[j]) == .H)) break;
            }
            if (category(infos[j]) != .H and j > i) {
                const t = infos[i];
                std.mem.copyForwards(GlyphInfo, infos[i..j], infos[i + 1 .. j + 1]);
                infos[j] = t;
            }
            break;
        }
    }

    // Marks move with the character before them.
    {
        var last_pos: Position = .start;
        for (start..end) |i| {
            if (in(infos[i], joiner_flags | flags(&.{ .N, .RS, .CM, .H }))) {
                setPosition(&infos[i], last_pos);
                if (category(infos[i]) == .H and last_pos == .pre_m) {
                    // Uniscribe does not move a halant with a left matra.
                    var j = i;
                    while (j > start) : (j -= 1) {
                        if (position(infos[j - 1]) != .pre_m) {
                            infos[i].shaper_aux = infos[j - 1].shaper_aux;
                            break;
                        }
                    }
                }
            } else if (position(infos[i]) != .smvd) {
                if (category(infos[i]) == .MPst and i > start and category(infos[i - 1]) == .SM)
                    infos[i - 1].shaper_aux = infos[i].shaper_aux;
                last_pos = position(infos[i]);
            }
        }
    }
    // Post-base consonants own what is before them back to the last
    // consonant or matra.
    {
        var last = base;
        var i = base + 1;
        while (i < end) : (i += 1) {
            if (isConsonant(infos[i])) {
                for (infos[last + 1 .. i]) |*gi| {
                    if (gi.shaper_aux < @intFromEnum(Position.smvd)) gi.shaper_aux = infos[i].shaper_aux;
                }
                last = i;
            } else if (in(infos[i], matra_flags)) {
                last = i;
            }
        }
    }

    {
        // `syllable` holds each glyph's original index while sorting.
        const syllable = infos[start].syllable;
        for (infos[start..end], 0..) |*gi, k| gi.syllable = @truncate(k);
        // A stable sort without merging clusters.
        var i = start + 1;
        while (i < end) : (i += 1) {
            var j = i;
            while (j > start and infos[j - 1].shaper_aux > infos[i].shaper_aux) j -= 1;
            if (i == j) continue;
            const t = infos[i];
            std.mem.copyBackwards(GlyphInfo, infos[j + 1 .. i + 1], infos[j..i]);
            infos[j] = t;
        }
        // Find the base again; flip a run of pre-base matras (HarfBuzz
        // issue 3863), then flip each back with its nuktas.
        var first: usize = end;
        var last: usize = end;
        base = end;
        for (start..end) |k| {
            const pos = position(infos[k]);
            if (pos == .base_c) {
                base = k;
                break;
            } else if (pos == .pre_m) {
                if (first == end) first = k;
                last = k;
            }
        }
        if (first < last) {
            b.reverseRange(first, last + 1);
            var from = first;
            for (first..last + 1) |k| if (in(infos[k], matra_flags)) {
                b.reverseRange(from, k + 1);
                from = k + 1;
            };
        }
        // After the base, merge the clusters of glyphs that moved past each
        // other (old-spec halants move freely: merge all). Before the base,
        // final reordering merges.
        if (c.old_spec or end - start > 127) {
            b.mergeClusters(base, end);
        } else {
            var k = base;
            while (k < end) : (k += 1) {
                if (infos[k].syllable == 255) continue;
                var min = k;
                var max = k;
                var j = start + infos[k].syllable;
                while (j != k) {
                    min = @min(min, j);
                    max = @max(max, j);
                    const next = start + infos[j].syllable;
                    infos[j].syllable = 255;
                    j = next;
                }
                b.mergeClusters(@max(base, min), max + 1);
            }
        }
        for (infos[start..end]) |*gi| gi.syllable = syllable;
    }

    // Masks.
    for (infos[start..end]) |*gi| {
        if (position(gi.*) != .ra_to_become_reph) break;
        gi.mask |= mask(p, .rphf);
    }
    {
        var pre = mask(p, .half);
        if (!c.old_spec and c.config.blwf_mode == .pre_and_post) pre |= mask(p, .blwf);
        for (infos[start..base]) |*gi| gi.mask |= pre;
        const post = mask(p, .blwf) | mask(p, .abvf) | mask(p, .pstf);
        var i = base + 1;
        while (i < end) : (i += 1) infos[i].mask |= post;
    }
    if (c.old_spec and p.script == .Deva) {
        // Old-spec eyelash Ra: Ra + halant before the base takes `blwf`,
        // unless a ZWJ asks for the eyelash form.
        var i = start;
        while (i + 1 < base) : (i += 1) {
            if (category(infos[i]) == .Ra and category(infos[i + 1]) == .H and (i + 2 == base or category(infos[i + 2]) != .ZWJ)) {
                infos[i].mask |= mask(p, .blwf);
                infos[i + 1].mask |= mask(p, .blwf);
            }
        }
    }
    if (mask(p, .pref) != 0 and base + 2 < end) {
        // The halant + Ra pair the font reorders before the base.
        var i = base + 1;
        while (i + 1 < end) : (i += 1) {
            if (c.wouldSubstitute("pref", &.{ infos[i].gid, infos[i + 1].gid })) {
                infos[i].mask |= mask(p, .pref);
                infos[i + 1].mask |= mask(p, .pref);
                break;
            }
        }
    }
    // A ZWNJ turns off half forms before it (ZWJ and ZWNJ also stop `cjct`
    // just by being there).
    {
        var i = start + 1;
        while (i < end) : (i += 1) {
            if (!isJoiner(infos[i])) continue;
            const non_joiner = category(infos[i]) == .ZWNJ;
            var j = i;
            while (true) {
                j -= 1;
                if (non_joiner) infos[j].mask &= ~mask(p, .half);
                if (!(j > start and !isConsonant(infos[j]))) break;
            }
        }
    }
}

fn finalReordering(p: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    if (b.len() == 0) return;
    const c = Ctx.init(p, b);
    const virama_gid = c.virama();
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        finalReorderSyllable(&c, virama_gid, s, e);
        s = e;
    }
}

fn finalReorderSyllable(c: *const Ctx, virama_gid: GlyphId, start: usize, end: usize) void {
    const p = c.p;
    const b = c.b;
    const infos = b.infos.items;
    const tamil_like = p.script == .Mlym or p.script == .Taml;

    // A virama a ligature split back out keeps its halant class.
    if (virama_gid != 0) for (infos[start..end]) |*gi| {
        if (gi.gid == virama_gid and gi.glyph_props & GlyphProps.ligated != 0 and gi.glyph_props & GlyphProps.multiplied != 0) {
            gi.shaper = @intFromEnum(C.H);
            gi.glyph_props &= ~(GlyphProps.ligated | GlyphProps.multiplied);
        }
    };

    // Find the base again.
    var try_pref = mask(p, .pref) != 0;
    var base = start;
    while (base < end) : (base += 1) {
        if (@intFromEnum(position(infos[base])) < @intFromEnum(Position.base_c)) continue;
        if (try_pref and base + 1 < end) {
            for (base + 1..end) |i| if (infos[i].mask & mask(p, .pref) != 0) {
                if (!(infos[i].substituted() and ligatedAndDidntMultiply(infos[i]))) {
                    // A `pref` candidate that formed nothing: the base is
                    // around here.
                    base = i;
                    while (base < end and isHalant(infos[base])) base += 1;
                    if (base < end) setPosition(&infos[base], .base_c);
                    try_pref = false;
                }
                break;
            };
            if (base == end) break;
        }
        // Malayalam: skip unformed below-base (not post-base) forms.
        if (p.script == .Mlym) {
            var i = base + 1;
            while (i < end) : (i += 1) {
                while (i < end and isJoiner(infos[i])) i += 1;
                if (i == end or !isHalant(infos[i])) break;
                i += 1;
                while (i < end and isJoiner(infos[i])) i += 1;
                if (i < end and isConsonant(infos[i]) and position(infos[i]) == .below_c) {
                    base = i;
                    setPosition(&infos[base], .base_c);
                }
            }
        }
        if (start < base and @intFromEnum(position(infos[base])) > @intFromEnum(Position.base_c)) base -= 1;
        break;
    }
    if (base == end and start < base and isOneOf(infos[base - 1], flags(&.{.ZWJ}))) base -= 1;
    if (base < end) {
        while (start < base and isOneOf(infos[base], flags(&.{ .N, .H }))) base -= 1;
    }

    // Pre-base matras move after the last standalone halant before the
    // base; a halant + ZWJ keeps them before it (Uniscribe).
    if (start + 1 < end and start < base) {
        var new_pos = if (base == end) base - 2 else base - 1;
        if (!tamil_like) {
            // Malayalam and Tamil `half` forms are chillus and explicit
            // viramas: the matra goes after them, so no search there.
            while (true) {
                while (new_pos > start and !isOneOf(infos[new_pos], matra_flags | flags(&.{.H}))) new_pos -= 1;
                if (isHalant(infos[new_pos]) and position(infos[new_pos]) != .pre_m) {
                    if (new_pos + 1 < end and category(infos[new_pos + 1]) == .ZWJ and new_pos > start) {
                        new_pos -= 1;
                        continue;
                    }
                    // A halant + ZWNJ ends the syllable already.
                } else {
                    new_pos = start;
                }
                break;
            }
        }
        if (start < new_pos and position(infos[new_pos]) != .pre_m) {
            var i = new_pos;
            while (i > start) : (i -= 1) {
                if (position(infos[i - 1]) != .pre_m) continue;
                const old_pos = i - 1;
                if (old_pos < base and base <= new_pos) base -= 1;
                const t = infos[old_pos];
                std.mem.copyForwards(GlyphInfo, infos[old_pos..new_pos], infos[old_pos + 1 .. new_pos + 1]);
                infos[new_pos] = t;
                // Merged after moving, deliberately.
                b.mergeClusters(new_pos, @min(end, base + 1));
                new_pos -= 1;
            }
        } else {
            for (start..base) |i| if (position(infos[i]) == .pre_m) {
                b.mergeClusters(i, @min(end, base + 1));
                break;
            };
        }
    }

    // The reph moves when Ra + halant ligated into it, or when an encoded
    // repha did not ligate (a ligated one is the font's own placement).
    if (start + 1 < end and position(infos[start]) == .ra_to_become_reph and
        ((category(infos[start]) == .Repha) != ligatedAndDidntMultiply(infos[start])))
    {
        const reph_pos = rephTarget(c.config.reph_pos);
        const new_reph_pos = rephPosition(c, start, end, base, reph_pos);
        b.mergeClusters(start, new_reph_pos + 1);
        const reph = infos[start];
        std.mem.copyForwards(GlyphInfo, infos[start..new_reph_pos], infos[start + 1 .. new_reph_pos + 1]);
        infos[new_reph_pos] = reph;
        if (start < base and base <= new_reph_pos) base -= 1;
    }

    // A pre-base form the font made (from `pref`) moves before the base:
    // after the last halant (and a joiner after it), like pre-base matras.
    if (try_pref and base + 1 < end) {
        for (base + 1..end) |i| if (infos[i].mask & mask(p, .pref) != 0) {
            if (ligatedAndDidntMultiply(infos[i])) {
                var new_pos = base;
                if (!tamil_like) {
                    while (new_pos > start and !isOneOf(infos[new_pos - 1], matra_flags | flags(&.{.H}))) new_pos -= 1;
                }
                if (new_pos > start and isHalant(infos[new_pos - 1])) {
                    if (new_pos < end and isJoiner(infos[new_pos])) new_pos += 1;
                }
                const old_pos = i;
                b.mergeClusters(new_pos, old_pos + 1);
                const t = infos[old_pos];
                std.mem.copyBackwards(GlyphInfo, infos[new_pos + 1 .. old_pos + 1], infos[new_pos..old_pos]);
                infos[new_pos] = t;
                if (new_pos <= base and base < old_pos) base += 1;
            }
            break;
        };
    }

    // `init` on a word-initial pre-base matra.
    if (position(infos[start]) == .pre_m) {
        const word_start = start == 0 or switch (infos[start - 1].gc) {
            .Cf, .Cn, .Co, .Cs, .Ll, .Lm, .Lo, .Lt, .Lu, .Mc, .Me, .Mn => false,
            else => true,
        };
        if (word_start) {
            infos[start].mask |= mask(p, .init);
        } else {
            b.unsafeToBreak(start - 1, start + 1);
        }
    }
}

/// Where the reph at `start` goes (the spec's steps 1-6).
fn rephPosition(c: *const Ctx, start: usize, end: usize, base: usize, reph_pos: Position) usize {
    const infos = c.b.infos.items;
    // 2. (and 5.) After the first explicit halant between the reph and the
    // base, and after a joiner following it.
    const after_halant = struct {
        fn f(is: []const GlyphInfo, s: usize, bs: usize) ?usize {
            var r = s + 1;
            while (r < bs and !isHalant(is[r])) r += 1;
            if (r < bs and isHalant(is[r])) {
                if (r + 1 < bs and isJoiner(is[r + 1])) r += 1;
                return r;
            }
            return null;
        }
    }.f;
    // 1. After post-base forms: straight to step 5.
    if (reph_pos != .after_post) {
        if (after_halant(infos, start, base)) |r| return r;
        // 3. After the main consonant and what sits on it.
        if (reph_pos == .after_main) {
            var r = base;
            while (r + 1 < end and @intFromEnum(position(infos[r + 1])) <= @intFromEnum(Position.after_main)) r += 1;
            if (r < end) return r;
        }
        // 4. Before the first post-base form, matra or sign.
        if (reph_pos == .after_sub) {
            var r = base;
            while (r + 1 < end) : (r += 1) {
                switch (position(infos[r + 1])) {
                    .post_c, .after_post, .smvd => break,
                    else => {},
                }
            }
            if (r < end) return r;
        }
    }
    // 5.
    if (after_halant(infos, start, base)) |r| return r;
    // 6. The end of the syllable, before trailing signs; before a final
    // halant that follows a matra, so the two can interact.
    var r = end - 1;
    while (r > start and position(infos[r]) == .smvd) r -= 1;
    if (isHalant(infos[r])) {
        var i = base + 1;
        while (i < r) : (i += 1) {
            if (in(infos[i], matra_flags)) r -= 1;
        }
    }
    return r;
}
