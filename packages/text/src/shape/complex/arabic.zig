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
//! Arabic fonts without GSUB forms are shaped through the Presentation
//! Forms (`arabic_fallback.zig`). `stch` (Syriac Abbreviation Mark and
//! the Arabic subtending marks) records the pieces it decomposes a mark
//! into, and they are tiled to the width of the word after positioning.

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
const Direction = buffer.Direction;
const fallback = @import("arabic_fallback.zig");

/// The shaper for Arabic and the scripts that join like it.
pub const shaper: ComplexShaper = .{
    .name = "arabic",
    .collectFeatures = collectFeatures,
    .dataInit = dataInit,
    .setupMasks = setupMasks,
    .reorderMarks = reorderMarks,
    .postprocessGlyphs = applyStch,
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
    try b.addGsubPause(recordStch);
    try b.enableFeature(tag("ccmp"), manual_zwj, 1);
    try b.enableFeature(tag("locl"), manual_zwj, 1);
    try b.addGsubPause(null);
    inline for (form_features) |f| {
        const syriac = comptime (f[3] == '2' or f[3] == '3');
        const has_fallback = b.script == .Arab and !syriac;
        try b.addFeature(tag(f), .{ .has_fallback = has_fallback }, 1);
        try b.addGsubPause(null);
    }
    try b.addGsubPause(null);
    try b.enableFeature(tag("rlig"), .{ .manual_zwj = true, .has_fallback = true }, 1);
    if (b.script == .Arab) try b.addGsubPause(fallbackShape);
    try b.enableFeature(tag("rclt"), manual_zwj, 1);
    try b.enableFeature(tag("calt"), manual_zwj, 1);
    try b.addGsubPause(null);
    try b.enableFeature(tag("mset"), .none, 1);
}

/// Sets the per-form masks (also used by USE for joining scripts) and,
/// for an Arabic font none of whose tables has the non-Syriac forms,
/// builds the fallback lookups.
pub fn dataInit(p: *ShapePlan) std.mem.Allocator.Error!void {
    inline for (form_features, 0..) |f, i| p.shaper_masks[i] = p.mask1(tag(f));
    p.shaper_masks[@intFromEnum(Action.none)] = 0;
    if (p.script != .Arab) return;
    inline for (form_features) |f| {
        const syriac = comptime (f[3] == '2' or f[3] == '3');
        if (!syriac and !p.maskOf(tag(f)).needs_fallback) return;
    }
    p.shaper_data = try fallback.build(p, p.arena.allocator());
}

fn fallbackShape(p: *const ShapePlan, b: *Buffer) std.mem.Allocator.Error!void {
    const fb: *const fallback.Fallback = @ptrCast(@alignCast(p.shaper_data orelse return));
    try fallback.apply(p, fb, b);
}

/// `stch` tiles in `GlyphInfo.shaper` (after the joining actions).
const stch_fixed: u8 = 8;
const stch_repeating: u8 = 9;

fn isStch(g: GlyphInfo) bool {
    return g.shaper == stch_fixed or g.shaper == stch_repeating;
}

/// After `stch`: the pieces it multiplied a glyph into are tiles, the
/// odd-numbered components repeating and the others fixed.
fn recordStch(p: *const ShapePlan, b: *Buffer) std.mem.Allocator.Error!void {
    if (p.mask1(tag("stch")) == 0) return;
    for (b.infos.items) |*g| if (g.multiplied()) {
        g.shaper = if (g.ligComp() % 2 != 0) stch_repeating else stch_fixed;
        b.shaper_flag = true;
    };
}

/// Characters a stretched mark spans: the rest of its word.
fn isWord(g: GlyphInfo) bool {
    return switch (g.gc) {
        .Cn, .Co, .Lm, .Lo, .Mc, .Me, .Mn, .Nd, .Nl, .No, .Sc, .Sk, .Sm, .So => true,
        else => false,
    };
}

/// Most tiles one stretch may produce.
const stch_max_glyphs = 256;

/// Tiles each recorded `stch` sequence across the width of the word before
/// it (in visual order: to its right in RTL text): fixed tiles once, the
/// repeating ones as often as fits, squeezed to fill (HarfBuzz's
/// `apply_stch`). Measures first, then grows the buffer and copies from
/// the end.
fn applyStch(p: *const ShapePlan, b: *Buffer, dir: Direction) std.mem.Allocator.Error!void {
    if (!b.shaper_flag) return;
    const rtl = dir == .rtl;
    if (!rtl) b.reverseRange(0, b.len());
    defer if (!rtl) b.reverseRange(0, b.len());

    var extra: usize = 0;
    const count = b.len();
    inline for (.{ false, true }) |cut| {
        if (cut) {
            try b.infos.resize(b.gpa, count + extra);
            try b.pos.resize(b.gpa, count + extra);
        }
        const infos = b.infos.items;
        const pos = b.pos.items;
        var j = count + extra;
        var i = count;
        while (i > 0) : (i -= 1) {
            if (!isStch(infos[i - 1])) {
                if (cut) {
                    j -= 1;
                    infos[j] = infos[i - 1];
                    pos[j] = pos[i - 1];
                }
                continue;
            }
            var w_total: i32 = 0;
            var w_fixed: i32 = 0;
            var w_repeating: i32 = 0;
            var n_fixed: i64 = 0;
            var n_repeating: i64 = 0;
            const end = i;
            while (i > 0 and isStch(infos[i - 1])) {
                i -= 1;
                const width = advance(p, infos[i]);
                if (infos[i].shaper == stch_fixed) {
                    w_fixed +|= width;
                    n_fixed += 1;
                } else {
                    w_repeating +|= width;
                    n_repeating += 1;
                }
            }
            const start = i;
            var ctx = i;
            while (ctx > 0 and !isStch(infos[ctx - 1]) and (infos[ctx - 1].isDefaultIgnorable() or isWord(infos[ctx - 1]))) {
                ctx -= 1;
                w_total +|= pos[ctx].x_adv;
            }
            i += 1; // the loop's decrement lands on `start`

            // Additional copies of each repeating tile.
            var n_copies: i64 = 0;
            const w_remaining_signed = @as(i64, w_total) - w_fixed;
            const w_repeating_signed: i64 = w_repeating;
            var w_remaining: i32 = w_total -| w_fixed;
            if (w_remaining_signed > w_repeating_signed and w_repeating_signed > 0)
                n_copies = @divTrunc(w_remaining_signed, w_repeating_signed) - 1;
            // An extra repeat, squeezed, may fit better.
            var overlap: i32 = 0;
            const shortfall = w_remaining_signed - w_repeating_signed * (n_copies + 1);
            if (shortfall > 0 and n_repeating > 0) {
                n_copies += 1;
                const excess = (n_copies + 1) * w_repeating_signed - w_remaining_signed;
                if (excess > 0) {
                    overlap = @intCast(std.math.clamp(@divTrunc(excess, n_copies * n_repeating), std.math.minInt(i32), std.math.maxInt(i32)));
                    w_remaining = 0;
                }
            }
            var max_copies: i64 = 0;
            if (n_repeating > 0) {
                const base_glyphs = n_fixed + n_repeating;
                if (base_glyphs < stch_max_glyphs) max_copies = @divTrunc(stch_max_glyphs - base_glyphs, n_repeating);
            }
            n_copies = @min(n_copies, max_copies);

            if (!cut) {
                extra += @intCast(n_copies * n_repeating);
            } else {
                b.unsafeToBreak(ctx, end);
                var x_offset: i32 = @divTrunc(w_remaining, 2);
                var k = end;
                while (k > start) : (k -= 1) {
                    const width = advance(p, infos[k - 1]);
                    var repeat: i64 = 1;
                    if (infos[k - 1].shaper == stch_repeating) repeat += n_copies;
                    pos[k - 1].x_adv = 0;
                    var n: i64 = 0;
                    while (n < repeat) : (n += 1) {
                        if (rtl) {
                            x_offset -|= width;
                            if (n > 0) x_offset +|= overlap;
                        }
                        pos[k - 1].x_off = x_offset;
                        j -= 1;
                        infos[j] = infos[k - 1];
                        pos[j] = pos[k - 1];
                        if (!rtl) {
                            x_offset +|= width;
                            if (n > 0) x_offset -|= overlap;
                        }
                    }
                }
            }
        }
        if (cut) std.debug.assert(j == 0);
    }
}

fn advance(p: *const ShapePlan, g: GlyphInfo) i32 {
    return @intFromFloat(@round(p.inst.advance(g.gid)));
}

/// Assigns joining forms and their masks (also used by USE).
pub fn setupMasks(p: *const ShapePlan, b: *Buffer) void {
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
