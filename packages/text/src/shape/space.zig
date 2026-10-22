//! Does a lookup ever look at the space glyph? Used once per plan to decide
//! whether text can be shaped (and cached) word by word. The answer is
//! conservative: any coverage, class or glyph sequence that can match the
//! space counts.

const std = @import("std");
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const reader = ot.reader;
const readAt = reader.readAt;
const lc = @import("../ot/layout_common.zig");
const LayoutTable = lc.LayoutTable;

/// True when lookup `index` of `t` can match or position `space`.
/// `ext_kind` is the table's Extension type (7 GSUB, 9 GPOS).
pub fn lookupInvolves(t: LayoutTable, index: u16, space: GlyphId, ext_kind: u16) bool {
    const l = t.lookup(index) catch return false;
    for (0..l.subtable_count) |i| {
        const st = l.subtable(@intCast(i), ext_kind) catch continue;
        if (subtableInvolves(st.kind, st.data, space, ext_kind == 9)) return true;
    }
    return false;
}

fn covers(st: []const u8, at: usize, gid: GlyphId) bool {
    const off = readAt(u16, st, at) catch return false;
    const c = lc.Coverage.init(st, off) catch return false;
    return c.index(gid) != null;
}

fn subtableInvolves(kind: u16, st: []const u8, space: GlyphId, gpos: bool) bool {
    if (!gpos) return switch (kind) {
        1, 2, 3 => covers(st, 2, space),
        4 => covers(st, 2, space) or ligatureComponents(st, space),
        5 => contextInvolves(st, space),
        6 => chainInvolves(st, space),
        8 => reverseInvolves(st, space),
        else => false,
    };
    return switch (kind) {
        1, 3 => covers(st, 2, space),
        2 => covers(st, 2, space) or pairSecond(st, space),
        4, 5, 6 => covers(st, 2, space) or covers(st, 4, space),
        7 => contextInvolves(st, space),
        8 => chainInvolves(st, space),
        else => false,
    };
}

fn ligatureComponents(st: []const u8, space: GlyphId) bool {
    const n = readAt(u16, st, 4) catch return false;
    for (0..n) |s| {
        const set = reader.sub(st, readAt(u16, st, 6 + s * 2) catch return false) catch continue;
        const nl = readAt(u16, set, 0) catch continue;
        for (0..nl) |k| {
            const lig = reader.sub(set, readAt(u16, set, 2 + k * 2) catch break) catch continue;
            const comps = readAt(u16, lig, 2) catch continue;
            if (comps < 2) continue;
            const arr = lc.U16Array.init(lig, 4, comps - 1) catch continue;
            if (seqHas(arr, space)) return true;
        }
    }
    return false;
}

fn pairSecond(st: []const u8, space: GlyphId) bool {
    const vf1 = readAt(u16, st, 4) catch return false;
    const vf2 = readAt(u16, st, 6) catch return false;
    const len1 = @as(usize, @popCount(vf1 & 0xFF)) * 2;
    const len2 = @as(usize, @popCount(vf2 & 0xFF)) * 2;
    switch (readAt(u16, st, 0) catch return false) {
        1 => {
            const n = readAt(u16, st, 8) catch return false;
            const rec_size = 2 + len1 + len2;
            for (0..n) |s| {
                const set = reader.sub(st, readAt(u16, st, 10 + s * 2) catch return false) catch continue;
                const count = readAt(u16, set, 0) catch continue;
                const recs = reader.subLen(set, 2, @as(usize, count) * rec_size) catch continue;
                for (0..count) |r| if (std.mem.readInt(u16, recs[r * rec_size ..][0..2], .big) == space) return true;
            }
            return false;
        },
        2 => {
            const cd2 = lc.ClassDef.init(st, readAt(u16, st, 10) catch return false) catch return false;
            const k2 = cd2.class(space);
            if (k2 != 0) return true;
            // Class 0 collects every glyph not listed; it matters only when
            // some row adjusts it.
            const n1 = readAt(u16, st, 12) catch return false;
            const n2 = readAt(u16, st, 14) catch return false;
            const rec_size = len1 + len2;
            for (0..n1) |r| {
                const rec = reader.subLen(st, 16 + r * @as(usize, n2) * rec_size, rec_size) catch return true;
                for (rec) |byte| if (byte != 0) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn seqHas(a: lc.U16Array, v: u16) bool {
    for (0..a.len) |i| if (a.get(i) == v) return true;
    return false;
}

fn classOf(st: []const u8, at: usize, gid: GlyphId) u16 {
    const off = readAt(u16, st, at) catch return 0;
    const cd = lc.ClassDef.init(st, off) catch return 0;
    return cd.class(gid);
}

/// Every rule of every rule set at `st[sets_at..]` (`count` offsets); `cb`
/// gets each rule's bytes.
fn anyRule(st: []const u8, count_at: usize, sets_at: usize, ctx: anytype, comptime cb: fn (@TypeOf(ctx), []const u8) bool) bool {
    const n = readAt(u16, st, count_at) catch return false;
    for (0..n) |s| {
        const so = readAt(u16, st, sets_at + s * 2) catch return false;
        if (so == 0) continue;
        const set = reader.sub(st, so) catch continue;
        const nr = readAt(u16, set, 0) catch continue;
        for (0..nr) |r| {
            const rule = reader.sub(set, readAt(u16, set, 2 + r * 2) catch break) catch continue;
            if (cb(ctx, rule)) return true;
        }
    }
    return false;
}

const Values = struct { input: u16, back: u16, ahead: u16 };

fn contextRule(v: Values, rule: []const u8) bool {
    const ni = readAt(u16, rule, 0) catch return false;
    if (ni < 2) return false;
    const input = lc.U16Array.init(rule, 4, ni - 1) catch return false;
    return seqHas(input, v.input);
}

fn chainRule(v: Values, rule: []const u8) bool {
    var off: usize = 0;
    const nb = readAt(u16, rule, off) catch return false;
    const back = lc.U16Array.init(rule, off + 2, nb) catch return false;
    if (seqHas(back, v.back)) return true;
    off += 2 + @as(usize, nb) * 2;
    const ni = readAt(u16, rule, off) catch return false;
    if (ni > 1) {
        const input = lc.U16Array.init(rule, off + 2, ni - 1) catch return false;
        if (seqHas(input, v.input)) return true;
    }
    off += 2 + @as(usize, ni -| 1) * 2;
    const na = readAt(u16, rule, off) catch return false;
    const ahead = lc.U16Array.init(rule, off + 2, na) catch return false;
    return seqHas(ahead, v.ahead);
}

fn contextInvolves(st: []const u8, space: GlyphId) bool {
    switch (readAt(u16, st, 0) catch return false) {
        1 => return covers(st, 2, space) or anyRule(st, 4, 6, Values{ .input = space, .back = space, .ahead = space }, contextRule),
        2 => {
            if (covers(st, 2, space)) return true;
            const k = classOf(st, 4, space);
            return anyRule(st, 6, 8, Values{ .input = k, .back = k, .ahead = k }, contextRule);
        },
        3 => {
            const n = readAt(u16, st, 2) catch return false;
            for (0..n) |i| if (covers(st, 6 + i * 2, space)) return true;
            return false;
        },
        else => return false,
    }
}

fn chainInvolves(st: []const u8, space: GlyphId) bool {
    switch (readAt(u16, st, 0) catch return false) {
        1 => return covers(st, 2, space) or anyRule(st, 4, 6, Values{ .input = space, .back = space, .ahead = space }, chainRule),
        2 => {
            if (covers(st, 2, space)) return true;
            const v: Values = .{ .back = classOf(st, 4, space), .input = classOf(st, 6, space), .ahead = classOf(st, 8, space) };
            return anyRule(st, 10, 12, v, chainRule);
        },
        3 => {
            var off: usize = 2;
            for (0..3) |_| {
                const n = readAt(u16, st, off) catch return false;
                for (0..n) |i| if (covers(st, off + 2 + i * 2, space)) return true;
                off += 2 + @as(usize, n) * 2;
            }
            return false;
        },
        else => return false,
    }
}

fn reverseInvolves(st: []const u8, space: GlyphId) bool {
    if (covers(st, 2, space)) return true;
    var off: usize = 4;
    for (0..2) |_| {
        const n = readAt(u16, st, off) catch return false;
        for (0..n) |i| if (covers(st, off + 2 + i * 2, space)) return true;
        off += 2 + @as(usize, n) * 2;
    }
    return false;
}
