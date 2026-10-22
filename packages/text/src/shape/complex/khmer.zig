//! The Khmer shaper (Microsoft's Khmer spec, following HarfBuzz's
//! `hb-ot-shaper-khmer`): a syllable machine finds clusters, a coeng + RO
//! pair moves before the base with `pref`, a pre-base vowel moves to the
//! start, and the basic features run per syllable without pauses between
//! them (Uniscribe applies them together):
//!
//! 1. `locl`, `ccmp`, then `pref`, `blwf`, `abvf`, `pstf`, `cfar` (the
//!    last only after a coeng + RO), each per syllable.
//! 2. `pres`, `abvs`, `blws`, `psts`, `clig` and the common features;
//!    `liga` is off.
//!
//! Split vowels without Unicode decompositions (U+17BE..U+17C0, U+17C4,
//! U+17C5) are split into U+17C1 and themselves, and are not recomposed.

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
const tag = @import("../../ot/root.zig").tag;
const normalize = @import("../normalize.zig");
const tables = @import("indic_tables.zig");
const C = tables.Category;
const category = tables.category;
const dfa = @import("syllable_dfa.zig");
const dotted = @import("dotted_circle.zig");
const use = @import("use.zig");

/// The shaper.
pub const shaper: ComplexShaper = .{
    .name = "khmer",
    .collectFeatures = collectFeatures,
    .overrideFeatures = overrideFeatures,
    .setupMasks = setupMasks,
    .normalize_short_circuit = false,
    .decompose = decompose,
    .compose = use.compose,
    .zero_marks = .none,
    .fallback_position = false,
};

/// Syllable types (low 4 bits of `GlyphInfo.syllable`).
pub const SyllableType = enum(u4) { consonant, broken, non_khmer };

// The grammar of HarfBuzz's hb-ot-shaper-khmer-machine.rl (experimentally
// extracted from what Uniscribe allows).
fn one(comptime cs: []const C) dfa.Expr {
    return dfa.one(C, cs);
}
const seq = dfa.seq;
const alt = dfa.alt;
const star = dfa.star;
const opt = dfa.opt;

const g = struct {
    const c = one(&.{ .C, .Ra, .V });
    const joiner = one(&.{ .ZWJ, .ZWNJ });
    const cn = seq(&.{ c, opt(seq(&.{ opt(joiner), one(&.{.Robatic}) })) });
    const xgroup = star(seq(&.{ star(joiner), one(&.{.Xgroup}) }));
    const ygroup = star(one(&.{.Ygroup}));
    const matra_group = seq(&.{
        opt(one(&.{.VPre})),                         xgroup,
        opt(one(&.{.VBlw})),                         xgroup,
        opt(seq(&.{ opt(joiner), one(&.{.VAbv}) })), xgroup,
        opt(one(&.{.VPst})),
    });
    const syllable_tail = seq(&.{ xgroup, matra_group, xgroup, opt(seq(&.{ one(&.{.H}), c })), ygroup });
    const broken = seq(&.{ opt(one(&.{.Robatic})), star(seq(&.{ one(&.{.H}), cn })), alt(&.{ one(&.{.H}), syllable_tail }) });
    const consonant = seq(&.{ alt(&.{ cn, one(&.{ .PLACEHOLDER, .DOTTEDCIRCLE }) }), broken });

    const rules = [_]dfa.Expr{ consonant, broken, dfa.any };
    const types = [_]u4{ @intFromEnum(SyllableType.consonant), @intFromEnum(SyllableType.broken), @intFromEnum(SyllableType.non_khmer) };
};

/// The Khmer syllable machine.
pub const Machine = dfa.Machine(C, &g.rules);

/// Splits `b` into syllables.
pub fn findSyllables(gpa: Allocator, b: *Buffer) Allocator.Error!void {
    try tables.findSyllables(Machine, &g.types, gpa, b);
}

fn collectFeatures(b: *PlanBuilder) Allocator.Error!void {
    // Before any lookup.
    try b.addGsubPause(setupSyllables);
    try b.addGsubPause(reorder);
    // Uniscribe does not pause between the basic features.
    try b.enableFeature(tag("locl"), .{ .per_syllable = true }, 1);
    try b.enableFeature(tag("ccmp"), .{ .per_syllable = true }, 1);
    const basic: FeatureFlags = .{ .manual_zwj = true, .manual_zwnj = true, .per_syllable = true };
    inline for (.{ "pref", "blwf", "abvf", "pstf", "cfar" }) |f| try b.addFeature(tag(f), basic, 1);
    try b.addGsubPause(clearSyllables);
    inline for (.{ "pres", "abvs", "blws", "psts" }) |f| try b.addFeature(tag(f), .manual_joiners, 1);
}

/// The Khmer spec requires `clig`; `liga` is off.
fn overrideFeatures(b: *PlanBuilder) Allocator.Error!void {
    try b.enableFeature(tag("clig"), .none, 1);
    try b.disableFeature(tag("liga"));
}

fn setupMasks(_: *const ShapePlan, b: *Buffer) void {
    for (b.infos.items) |*gi| gi.shaper = @intFromEnum(tables.categories(gi.cp).cat);
}

/// Splits the split vowels that have no Unicode decomposition.
fn decompose(ab: u21) ?normalize.Pair {
    return switch (ab) {
        0x17BE, 0x17BF, 0x17C0, 0x17C4, 0x17C5 => .{ .a = 0x17C1, .b = ab },
        else => normalize.decompose(ab),
    };
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

fn reorderConsonantSyllable(p: *const ShapePlan, b: *Buffer, start: usize, end: usize) void {
    const infos = b.infos.items;
    // Post-base forms may apply to anything after the base.
    const post = p.mask1(tag("blwf")) | p.mask1(tag("abvf")) | p.mask1(tag("pstf"));
    for (infos[start + 1 .. end]) |*gi| gi.mask |= post;

    var num_coengs: usize = 0;
    var i = start + 1;
    while (i < end) : (i += 1) {
        const c = category(infos[i]);
        if (c == .H and num_coengs <= 2 and i + 1 < end) {
            num_coengs += 1;
            if (category(infos[i + 1]) == .Ra) {
                // Subscript type 2: coeng + RO moves before the base and
                // takes `pref`.
                const pref = p.mask1(tag("pref"));
                infos[i].mask |= pref;
                infos[i + 1].mask |= pref;
                b.mergeClusters(start, i + 2);
                const t0 = infos[i];
                const t1 = infos[i + 1];
                std.mem.copyBackwards(GlyphInfo, infos[start + 2 .. i + 2], infos[start..i]);
                infos[start] = t0;
                infos[start + 1] = t1;
                // What follows takes `cfar` (it tells apart KA + COENG RO +
                // COENG X from KA + COENG X + COENG RO in MS fonts).
                const cfar = p.mask1(tag("cfar"));
                if (cfar != 0) for (infos[i + 2 .. end]) |*gi| {
                    gi.mask |= cfar;
                };
                num_coengs = 2;
            }
        } else if (c == .VPre) {
            // The left part of a vowel moves to the start.
            b.mergeClusters(start, i + 1);
            const t = infos[i];
            std.mem.copyBackwards(GlyphInfo, infos[start + 1 .. i + 1], infos[start..i]);
            infos[start] = t;
        }
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
            .consonant, .broken => reorderConsonantSyllable(p, b, s, e),
            .non_khmer => {},
        }
        s = e;
    }
}
