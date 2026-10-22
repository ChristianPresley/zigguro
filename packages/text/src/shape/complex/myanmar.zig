//! The Myanmar shaper (Microsoft's Myanmar spec for `mym2` fonts,
//! following HarfBuzz's `hb-ot-shaper-myanmar`): a syllable machine finds
//! clusters, each syllable is sorted into visual order (kinzi after the
//! base, medial ra and pre-base vowels before it), then the basic features
//! run one at a time per syllable:
//!
//! 1. `locl`, `ccmp` per syllable, then reordering.
//! 2. `rphf`, `pref`, `blwf`, `pstf`, each its own stage.
//! 3. `pres`, `abvs`, `blws`, `psts`, then the common features.
//!
//! Fonts with only the old `mymr` tag (or DFLT/latn) use the default
//! shaper (see `default.select`).

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
const tag = @import("../../ot/root.zig").tag;
const tables = @import("indic_tables.zig");
const C = tables.Category;
const Position = tables.Position;
const category = tables.category;
const position = tables.position;
const dfa = @import("syllable_dfa.zig");
const dotted = @import("dotted_circle.zig");

/// The shaper.
pub const shaper: ComplexShaper = .{
    .name = "myanmar",
    .collectFeatures = collectFeatures,
    .setupMasks = setupMasks,
    .normalize_short_circuit = false,
    .zero_marks = .gdef_early,
    .fallback_position = false,
};

/// Syllable types (low 4 bits of `GlyphInfo.syllable`).
pub const SyllableType = enum(u4) { consonant, broken, non_myanmar };

// The grammar of HarfBuzz's hb-ot-shaper-myanmar-machine.rl.
fn one(comptime cs: []const C) dfa.Expr {
    return dfa.one(C, cs);
}
const seq = dfa.seq;
const alt = dfa.alt;
const star = dfa.star;
const opt = dfa.opt;

const g = struct {
    const j = one(&.{ .ZWJ, .ZWNJ });
    const kinzi = seq(&.{ one(&.{.Ra}), one(&.{.As}), one(&.{.H}) });
    const sm = one(&.{ .SM, .SMPst });
    const c = one(&.{ .C, .Ra });
    const as = one(&.{.As});
    const vs = opt(one(&.{.VS}));
    const db_as = opt(seq(&.{ one(&.{C.DB}), opt(as) }));
    const medial_group = seq(&.{
        opt(one(&.{.MY})),
        opt(as),
        opt(one(&.{.MR})),
        opt(seq(&.{
            alt(&.{
                seq(&.{ one(&.{.MW}), opt(one(&.{.MH})), opt(one(&.{.ML})) }),
                seq(&.{ one(&.{.MH}), opt(one(&.{.ML})) }),
                one(&.{.ML}),
            }),
            opt(as),
        })),
    });
    const main_vowel_group = seq(&.{ star(seq(&.{ one(&.{.VPre}), vs })), star(one(&.{.VAbv})), star(one(&.{.VBlw})), star(one(&.{.A})), db_as });
    const post_vowel_group = seq(&.{ one(&.{.VPst}), opt(one(&.{.MH})), opt(one(&.{.ML})), star(as), star(one(&.{.VAbv})), star(one(&.{.A})), db_as });
    const tone_group = alt(&.{ sm, seq(&.{ one(&.{.PT}), star(one(&.{.A})), opt(one(&.{C.DB})), opt(as) }) });
    const complex_tail = seq(&.{ star(as), medial_group, main_vowel_group, star(post_vowel_group), star(tone_group), opt(j) });
    const tail = seq(&.{ star(seq(&.{ one(&.{.H}), one(&.{ .C, .Ra, C.IV }), vs })), alt(&.{ one(&.{.H}), complex_tail }) });
    const consonant = seq(&.{ opt(alt(&.{ kinzi, one(&.{.CS}) })), one(&.{ .C, .Ra, C.IV, C.GB, .DOTTEDCIRCLE }), vs, tail });
    const broken = seq(&.{ opt(kinzi), vs, tail });

    const rules = [_]dfa.Expr{ consonant, one(&.{ .ZWJ, .ZWNJ, .SMPst }), broken, dfa.any };
    const types = [_]u4{
        @intFromEnum(SyllableType.consonant),
        @intFromEnum(SyllableType.non_myanmar),
        @intFromEnum(SyllableType.broken),
        @intFromEnum(SyllableType.non_myanmar),
    };
};

/// The Myanmar syllable machine.
pub const Machine = dfa.Machine(C, &g.rules);

/// Splits `b` into syllables.
pub fn findSyllables(gpa: Allocator, b: *Buffer) Allocator.Error!void {
    try tables.findSyllables(Machine, &g.types, gpa, b);
}

fn collectFeatures(b: *PlanBuilder) Allocator.Error!void {
    // Before any lookup.
    try b.addGsubPause(setupSyllables);
    try b.enableFeature(tag("locl"), .{ .per_syllable = true }, 1);
    // Not in the spec, but fonts that use it want it first.
    try b.enableFeature(tag("ccmp"), .{ .per_syllable = true }, 1);
    try b.addGsubPause(reorder);
    inline for (.{ "rphf", "pref", "blwf", "pstf" }) |f| {
        try b.enableFeature(tag(f), .{ .manual_zwj = true, .per_syllable = true }, 1);
        try b.addGsubPause(null);
    }
    try b.addGsubPause(clearSyllables);
    inline for (.{ "pres", "abvs", "blws", "psts" }) |f| try b.enableFeature(tag(f), .{ .manual_zwj = true }, 1);
}

fn setupMasks(_: *const ShapePlan, b: *Buffer) void {
    for (b.infos.items) |*gi| gi.shaper = @intFromEnum(tables.categories(gi.cp).cat);
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

fn clearSyllables(_: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    for (b.infos.items) |*gi| gi.syllable = 0;
}

fn isConsonant(gi: GlyphInfo) bool {
    // A ligature is no longer a consonant.
    if (gi.glyph_props & GlyphProps.ligated != 0) return false;
    return switch (category(gi)) {
        .C, .CS, .Ra, C.IV, C.GB, .DOTTEDCIRCLE => true,
        else => false,
    };
}

fn setPosition(gi: *GlyphInfo, p: Position) void {
    gi.shaper_aux = @intFromEnum(p);
}

fn positionKey(gi: GlyphInfo) u8 {
    return gi.shaper_aux;
}

fn reorderConsonantSyllable(b: *Buffer, start: usize, end: usize) void {
    const infos = b.infos.items;
    var base = end;
    var has_kinzi = false;
    var limit = start;
    if (start + 3 <= end and category(infos[start]) == .Ra and category(infos[start + 1]) == .As and category(infos[start + 2]) == .H) {
        limit += 3;
        base = start;
        has_kinzi = true;
    }
    if (!has_kinzi) base = limit;
    for (limit..end) |i| if (isConsonant(infos[i])) {
        base = i;
        break;
    };

    var i = start;
    while (i < start + @as(usize, if (has_kinzi) 3 else 0)) : (i += 1) setPosition(&infos[i], .after_main);
    while (i < base) : (i += 1) setPosition(&infos[i], .pre_c);
    if (i < end) {
        setPosition(&infos[i], .base_c);
        i += 1;
    }
    var pos: Position = .after_main;
    while (i < end) : (i += 1) {
        const c = category(infos[i]);
        if (c == .MR) {
            // Medial ra goes before the base.
            setPosition(&infos[i], .pre_c);
        } else if (c == .VPre) {
            setPosition(&infos[i], .pre_m);
        } else if (c == .VS) {
            infos[i].shaper_aux = infos[i - 1].shaper_aux;
        } else if (pos == .after_main and c == .VBlw) {
            pos = .below_c;
            setPosition(&infos[i], pos);
        } else if (pos == .below_c and c == .A) {
            setPosition(&infos[i], .before_sub);
        } else if (pos == .below_c and c == .VBlw) {
            setPosition(&infos[i], pos);
        } else if (pos == .below_c) {
            pos = .after_sub;
            setPosition(&infos[i], pos);
        } else {
            setPosition(&infos[i], pos);
        }
    }

    b.sortBy(start, end, positionKey);

    // Several pre-base vowels go in reverse logical order (HarfBuzz issue
    // 3863): flip the run, then flip each vowel back together with the
    // selectors after it.
    var first: usize = end;
    var last: usize = end;
    for (start..end) |k| if (position(infos[k]) == .pre_m) {
        if (first == end) first = k;
        last = k;
    };
    if (first < last) {
        b.reverseRange(first, last + 1);
        var from = first;
        for (first..last + 1) |k| if (category(infos[k]) == .VPre) {
            b.reverseRange(from, k + 1);
            from = k + 1;
        };
    }
}

fn reorder(p: *const ShapePlan, b: *Buffer) Allocator.Error!void {
    _ = try dotted.insertDottedCircles(b, p.inst.face, @intFromEnum(SyllableType.broken), @intFromEnum(C.DOTTEDCIRCLE), null);
    const infos = b.infos.items;
    var s: usize = 0;
    while (s < infos.len) {
        const e = dotted.syllableEnd(infos, s);
        switch (@as(SyllableType, @enumFromInt(dotted.syllableType(infos[s])))) {
            // Broken clusters have their dotted circle by now.
            .consonant, .broken => reorderConsonantSyllable(b, s, e),
            .non_myanmar => {},
        }
        s = e;
    }
}
