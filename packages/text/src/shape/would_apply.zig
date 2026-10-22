//! Would a GSUB lookup substitute this glyph sequence? (HarfBuzz's
//! `hb_ot_layout_lookup_would_substitute`.) The Indic shaper asks it of
//! `rphf`, `pref`, `blwf`, `pstf` and `vatu` to find which consonants
//! take which forms in the font.
//!
//! The sequence must be the whole input of a rule: a single glyph for
//! single, multiple, alternate and reverse substitutions, the exact
//! components of a ligature, the exact input of a context rule. With
//! `zero_context`, chaining rules with backtrack or lookahead do not count.

const std = @import("std");
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const readAt = ot.reader.readAt;
const sub = ot.reader.sub;
const lc = @import("../ot/layout_common.zig");
const LayoutTable = lc.LayoutTable;
const U16Array = lc.U16Array;
const Matcher = @import("skippy.zig").Matcher;

/// True when lookup `index` of `gsub` would substitute `glyphs`.
pub fn wouldSubstitute(gsub: LayoutTable, index: u16, glyphs: []const GlyphId, zero_context: bool) bool {
    if (glyphs.len == 0) return false;
    const l = gsub.lookup(index) catch return false;
    for (0..l.subtable_count) |j| {
        const st = l.subtable(@intCast(j), 7) catch continue;
        if (subtableWouldApply(st.kind, st.data, glyphs, zero_context)) return true;
    }
    return false;
}

fn covered(st: []const u8, cov_off_at: usize, gid: GlyphId) ?u16 {
    const cov = lc.Coverage.init(st, readAt(u16, st, cov_off_at) catch return null) catch return null;
    return cov.index(gid);
}

fn subtableWouldApply(kind: u16, st: []const u8, glyphs: []const GlyphId, zero_context: bool) bool {
    return switch (kind) {
        1, 2, 3, 8 => glyphs.len == 1 and covered(st, 2, glyphs[0]) != null,
        4 => ligatureWouldApply(st, glyphs),
        5 => contextWouldApply(st, glyphs),
        6 => chainWouldApply(st, glyphs, zero_context),
        else => false,
    };
}

fn ligatureWouldApply(st: []const u8, glyphs: []const GlyphId) bool {
    const ci = covered(st, 2, glyphs[0]) orelse return false;
    const n = readAt(u16, st, 4) catch return false;
    if (ci >= n) return false;
    const set = sub(st, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return false) catch return false;
    const nl = readAt(u16, set, 0) catch return false;
    for (0..nl) |li| {
        const lig = sub(set, readAt(u16, set, 2 + li * 2) catch return false) catch return false;
        const count = readAt(u16, lig, 2) catch continue;
        if (count != glyphs.len) continue;
        const comps = U16Array.init(lig, 4, count - 1) catch continue;
        if (inputMatches(glyphs, comps, .glyph)) return true;
    }
    return false;
}

/// `glyphs[1..]` against the rule's input values (the first glyph was
/// checked by coverage or class).
fn inputMatches(glyphs: []const GlyphId, input: U16Array, m: Matcher) bool {
    if (input.len + 1 != glyphs.len) return false;
    for (glyphs[1..], 0..) |g, k| if (!m.matches(g, input.get(k))) return false;
    return true;
}

fn ruleSetWouldApply(st: []const u8, set_off: u16, glyphs: []const GlyphId, m: Matcher) bool {
    if (set_off == 0) return false;
    const set = sub(st, set_off) catch return false;
    const n = readAt(u16, set, 0) catch return false;
    for (0..n) |r| {
        const rule = sub(set, readAt(u16, set, 2 + r * 2) catch return false) catch return false;
        const count = readAt(u16, rule, 0) catch continue;
        if (count == 0) continue;
        const input = U16Array.init(rule, 4, count - 1) catch continue;
        if (inputMatches(glyphs, input, m)) return true;
    }
    return false;
}

fn contextWouldApply(st: []const u8, glyphs: []const GlyphId) bool {
    switch (readAt(u16, st, 0) catch return false) {
        1 => {
            const ci = covered(st, 2, glyphs[0]) orelse return false;
            const n = readAt(u16, st, 4) catch return false;
            if (ci >= n) return false;
            return ruleSetWouldApply(st, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return false, glyphs, .glyph);
        },
        2 => {
            _ = covered(st, 2, glyphs[0]) orelse return false;
            const cd = lc.ClassDef.init(st, readAt(u16, st, 4) catch return false) catch return false;
            const n = readAt(u16, st, 6) catch return false;
            const class = cd.class(glyphs[0]);
            if (class >= n) return false;
            return ruleSetWouldApply(st, readAt(u16, st, 8 + @as(usize, class) * 2) catch return false, glyphs, .{ .class = cd });
        },
        3 => {
            const count = readAt(u16, st, 2) catch return false;
            if (count == 0) return false;
            _ = covered(st, 6, glyphs[0]) orelse return false;
            const input = U16Array.init(st, 8, count - 1) catch return false;
            return inputMatches(glyphs, input, .{ .coverage = st });
        },
        else => return false,
    }
}

fn chainRuleSetWouldApply(st: []const u8, set_off: u16, glyphs: []const GlyphId, m: Matcher, zero_context: bool) bool {
    if (set_off == 0) return false;
    const set = sub(st, set_off) catch return false;
    const n = readAt(u16, set, 0) catch return false;
    for (0..n) |r| {
        const rule = sub(set, readAt(u16, set, 2 + r * 2) catch return false) catch return false;
        const nb = readAt(u16, rule, 0) catch continue;
        var off: usize = 2 + @as(usize, nb) * 2;
        const ni = readAt(u16, rule, off) catch continue;
        if (ni == 0) continue;
        const input = U16Array.init(rule, off + 2, ni - 1) catch continue;
        off += 2 + @as(usize, ni - 1) * 2;
        const na = readAt(u16, rule, off) catch continue;
        if (zero_context and (nb != 0 or na != 0)) continue;
        if (inputMatches(glyphs, input, m)) return true;
    }
    return false;
}

fn chainWouldApply(st: []const u8, glyphs: []const GlyphId, zero_context: bool) bool {
    switch (readAt(u16, st, 0) catch return false) {
        1 => {
            const ci = covered(st, 2, glyphs[0]) orelse return false;
            const n = readAt(u16, st, 4) catch return false;
            if (ci >= n) return false;
            return chainRuleSetWouldApply(st, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return false, glyphs, .glyph, zero_context);
        },
        2 => {
            _ = covered(st, 2, glyphs[0]) orelse return false;
            const input = lc.ClassDef.init(st, readAt(u16, st, 6) catch return false) catch return false;
            const n = readAt(u16, st, 10) catch return false;
            const class = input.class(glyphs[0]);
            if (class >= n) return false;
            return chainRuleSetWouldApply(st, readAt(u16, st, 12 + @as(usize, class) * 2) catch return false, glyphs, .{ .class = input }, zero_context);
        },
        3 => {
            const nb = readAt(u16, st, 2) catch return false;
            var off: usize = 4 + @as(usize, nb) * 2;
            const ni = readAt(u16, st, off) catch return false;
            if (ni == 0) return false;
            _ = covered(st, off + 2, glyphs[0]) orelse return false;
            const input = U16Array.init(st, off + 4, ni - 1) catch return false;
            off += 2 + @as(usize, ni) * 2;
            const na = readAt(u16, st, off) catch return false;
            if (zero_context and (nb != 0 or na != 0)) return false;
            return inputMatches(glyphs, input, .{ .coverage = st });
        },
        else => return false,
    }
}

test "would substitute: single and ligature" {
    var b: lc.TestBytes = .{ .gpa = std.testing.allocator };
    defer b.deinit();
    // A ligature subtable: coverage {5}, one set with ligature 9 = 5 6.
    b.u16s(&.{ 1, 8, 1, 14 }); // format, coverage offset, set count, set offset
    b.u16s(&.{ 1, 1, 5 }); // coverage format 1, one glyph
    b.u16s(&.{ 1, 4 }); // set: one ligature at 4
    b.u16s(&.{ 9, 2, 6 }); // ligature glyph, component count, component
    const st = b.buf.items;
    try std.testing.expect(ligatureWouldApply(st, &.{ 5, 6 }));
    try std.testing.expect(!ligatureWouldApply(st, &.{ 5, 7 }));
    try std.testing.expect(!ligatureWouldApply(st, &.{ 5, 6, 6 }));
    try std.testing.expect(!ligatureWouldApply(st, &.{6}));
    try std.testing.expect(subtableWouldApply(1, st, &.{5}, true));
    try std.testing.expect(!subtableWouldApply(1, st, &.{ 5, 6 }, true));
}
