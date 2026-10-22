//! The Arabic-joining shaper (HarfBuzz's `hb-ot-shaper-arabic`): joining
//! forms from Unicode joining types, one mask bit per form feature, the
//! Microsoft Arabic feature order and modifier combining mark reordering
//! (UTR #53).
//!
//! Joining groups: only Syriac Alaph and the Dalath/Rish group change the
//! state machine, so they are hard-coded (U+0710; U+0715, U+0716, U+072A,
//! U+072F) instead of carrying ArabicShaping.txt's group column in the UCD
//! tables.
//!
//! Not yet done: HarfBuzz's fallback shaping through the Presentation Forms
//! for Arabic fonts without GSUB forms, and Syriac `stch` stretching.

const std = @import("std");
const plan_mod = @import("../plan.zig");
const ComplexShaper = plan_mod.ComplexShaper;
const PlanBuilder = plan_mod.PlanBuilder;
const ShapePlan = plan_mod.ShapePlan;
const FeatureFlags = plan_mod.FeatureFlags;
const buffer = @import("../buffer.zig");
const Buffer = buffer.Buffer;
const GlyphInfo = buffer.GlyphInfo;
const unicode = @import("../../unicode/root.zig");
const Script = unicode.Script;
const tag = @import("../../ot/root.zig").tag;

/// The shaper for Arabic and the scripts that join like it.
pub const shaper: ComplexShaper = .{
    .name = "arabic",
    .collectFeatures = collectFeatures,
    .dataInit = dataInit,
    .setupMasks = setupMasks,
    .reorderMarks = reorderMarks,
    .zero_marks = .gdef_late,
    .fallback_position = true,
};

/// What joining does to one character: the form feature it gets.
pub const Action = enum(u3) { isol, fina, fin2, fin3, medi, med2, init, none };

/// The form features, in `Action` order.
pub const form_features = [_]*const [4]u8{ "isol", "fina", "fin2", "fin3", "medi", "med2", "init" };

/// State machine columns: joining types, with the two Syriac groups split
/// out, and T (transparent, skipped).
const Col = enum(u3) { u, l, r, d, alaph, dalath_rish, t };

/// The joining column of `cp`.
pub fn column(cp: u21) Col {
    switch (cp) {
        0x0710 => return .alaph,
        0x0715, 0x0716, 0x072A, 0x072F => return .dalath_rish,
        else => {},
    }
    return switch (unicode.props(cp).jt) {
        .U => .u,
        .L => .l,
        .R => .r,
        .D, .C => .d,
        .T => .t,
    };
}

const Entry = struct { prev: Action, curr: Action, next: u3 };

fn e(prev: Action, curr: Action, next: u3) Entry {
    return .{ .prev = prev, .curr = curr, .next = next };
}

/// HarfBuzz's `arabic_state_table`, by state then column (u, l, r, d,
/// alaph, dalath_rish).
const state_table = [7][6]Entry{
    // 0: prev was U, not willing to join.
    .{ e(.none, .none, 0), e(.none, .isol, 2), e(.none, .isol, 1), e(.none, .isol, 2), e(.none, .isol, 1), e(.none, .isol, 6) },
    // 1: prev was R or ISOL/ALAPH, not willing to join.
    .{ e(.none, .none, 0), e(.none, .isol, 2), e(.none, .isol, 1), e(.none, .isol, 2), e(.none, .fin2, 5), e(.none, .isol, 6) },
    // 2: prev was D/L in ISOL form, willing to join.
    .{ e(.none, .none, 0), e(.none, .isol, 2), e(.init, .fina, 1), e(.init, .fina, 3), e(.init, .fina, 4), e(.init, .fina, 6) },
    // 3: prev was D in FINA form, willing to join.
    .{ e(.none, .none, 0), e(.none, .isol, 2), e(.medi, .fina, 1), e(.medi, .fina, 3), e(.medi, .fina, 4), e(.medi, .fina, 6) },
    // 4: prev was FINA ALAPH, not willing to join.
    .{ e(.none, .none, 0), e(.none, .isol, 2), e(.med2, .isol, 1), e(.med2, .isol, 2), e(.med2, .fin2, 5), e(.med2, .isol, 6) },
    // 5: prev was FIN2/FIN3 ALAPH, not willing to join.
    .{ e(.none, .none, 0), e(.none, .isol, 2), e(.isol, .isol, 1), e(.isol, .isol, 2), e(.isol, .fin2, 5), e(.isol, .isol, 6) },
    // 6: prev was DALATH/RISH, not willing to join.
    .{ e(.none, .none, 0), e(.none, .isol, 2), e(.none, .isol, 1), e(.none, .isol, 2), e(.none, .fin3, 5), e(.none, .isol, 6) },
};

/// The action of each glyph, stored in `GlyphInfo.shaper`.
pub fn actionOf(g: GlyphInfo) Action {
    return @enumFromInt(@as(u3, @truncate(g.shaper)));
}

/// Assigns joining actions in logical order; transparent characters get
/// `none` and are skipped.
pub fn joining(b: *Buffer) void {
    const infos = b.infos.items;
    var prev: ?usize = null;
    var state: u3 = 0;
    for (infos, 0..) |*g, i| {
        const col = column(g.cp);
        if (col == .t) {
            g.shaper = @intFromEnum(Action.none);
            continue;
        }
        const entry = state_table[state][@intFromEnum(col)];
        if (entry.prev != .none) if (prev) |p| {
            // Breaking here would change the previous form.
            infos[p].shaper = @intFromEnum(entry.prev);
            b.unsafeToBreak(p, i + 1);
        };
        g.shaper = @intFromEnum(entry.curr);
        prev = i;
        state = entry.next;
    }
}

/// Mongolian free variation selectors take their base's form.
fn mongolianVariationSelectors(b: *Buffer) void {
    const infos = b.infos.items;
    if (infos.len < 2) return;
    for (1..infos.len) |i| switch (infos[i].cp) {
        0x180B...0x180D, 0x180F => infos[i].shaper = infos[i - 1].shaper,
        else => {},
    };
}

fn collectFeatures(b: *PlanBuilder) std.mem.Allocator.Error!void {
    const manual_zwj: FeatureFlags = .{ .manual_zwj = true };
    try b.enableFeature(tag("stch"), .none, 1);
    try b.addGsubPause(null);
    try b.enableFeature(tag("ccmp"), manual_zwj, 1);
    try b.enableFeature(tag("locl"), manual_zwj, 1);
    try b.addGsubPause(null);
    inline for (form_features) |f| {
        const syriac = comptime (f[3] == '2' or f[3] == '3');
        const fallback = b.script == .Arab and !syriac;
        try b.addFeature(tag(f), .{ .has_fallback = fallback }, 1);
        try b.addGsubPause(null);
    }
    try b.addGsubPause(null);
    try b.enableFeature(tag("rlig"), .{ .manual_zwj = true, .has_fallback = true }, 1);
    if (b.script == .Arab) try b.addGsubPause(null);
    try b.enableFeature(tag("rclt"), manual_zwj, 1);
    try b.enableFeature(tag("calt"), manual_zwj, 1);
    try b.addGsubPause(null);
    try b.enableFeature(tag("mset"), .none, 1);
}

fn dataInit(p: *ShapePlan) void {
    inline for (form_features, 0..) |f, i| p.shaper_masks[i] = p.mask1(tag(f));
    p.shaper_masks[@intFromEnum(Action.none)] = 0;
}

fn setupMasks(p: *const ShapePlan, b: *Buffer) void {
    joining(b);
    if (p.script == .Mong) mongolianVariationSelectors(b);
    for (b.infos.items) |*g| g.mask |= p.shaper_masks[@intFromEnum(actionOf(g.*))];
}

/// Modifier combining marks (UTR #53), moved to the front of their run.
fn isMcm(cp: u21) bool {
    return switch (cp) {
        0x0654, 0x0655, 0x0658, 0x06DC, 0x06E3, 0x06E7, 0x06E8, 0x08CA, 0x08CB, 0x08CD, 0x08CE, 0x08CF, 0x08D3, 0x08F3 => true,
        else => false,
    };
}

/// Moves modifier combining marks of class 220, then 230, to the start of
/// the sorted mark run [start, end) and renumbers them 22 and 26 so the run
/// stays sorted.
fn reorderMarks(b: *Buffer, start_in: usize, end: usize) void {
    const infos = b.infos.items;
    var start = start_in;
    var i = start;
    var cc: u8 = 220;
    while (cc <= 230) : (cc += 10) {
        while (i < end and infos[i].ccc < cc) i += 1;
        if (i == end) break;
        if (infos[i].ccc > cc) continue;
        var j = i;
        while (j < end and infos[j].ccc == cc and isMcm(infos[j].cp)) j += 1;
        if (i == j) continue;
        b.mergeClusters(start, j);
        // Rotate [start, j) so [i, j) comes first.
        std.mem.rotate(GlyphInfo, infos[start..j], i - start);
        const new_start = start + j - i;
        const new_cc: u8 = if (cc == 220) 22 else 26;
        while (start < new_start) : (start += 1) infos[start].ccc = new_cc;
        i = j;
    }
}
