//! GSUB application: single (1), multiple (2), alternate (3), ligature
//! (4), context (5), chained context (6), extension (7) and reverse
//! chaining single (8) substitution, editing the buffer in place with
//! HarfBuzz's cluster merging and ligature component bookkeeping.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const reader = ot.reader;
const readAt = reader.readAt;
const lc = @import("../ot/layout_common.zig");
const Lookup = lc.Lookup;
const U16Array = lc.U16Array;
const GlyphProps = @import("../ot/gdef.zig").GlyphProps;
const skippy = @import("skippy.zig");
const Ctx = skippy.Ctx;
const Skippy = skippy.Skippy;
const context = @import("context.zig");
const digest = @import("digest.zig");
const GlyphInfo = @import("buffer.zig").GlyphInfo;

const log = std.log.scoped(.zg_text);

/// Largest per-feature value; `rand` uses it to ask for a random alternate.
pub const max_feature_value = 255;

/// Applies `l`'s subtables at `i` until one applies; returns where the
/// lookup continues, or null when none applied.
pub fn applyAt(c: *Ctx, l: Lookup, i: usize) Allocator.Error!?usize {
    for (0..l.subtable_count) |j| {
        if (!c.budget.take()) return null;
        const st = l.subtable(@intCast(j), 7) catch continue;
        if (try applySubtable(c, st.kind, st.data, i)) |next| return next;
    }
    return null;
}

/// `applyAt` through a lookup accelerator: subtables whose first-glyph
/// set misses the glyph are not tried.
pub fn applyAtAccel(c: *Ctx, acc: *const digest.LookupAccel, i: usize) Allocator.Error!?usize {
    const gid = c.buf.infos.items[i].gid;
    for (acc.subtables) |sa| {
        if (!digest.has(sa.digest, gid)) continue;
        if (!c.budget.take()) return null;
        if (try applySubtable(c, sa.kind, sa.data, i)) |next| return next;
    }
    return null;
}

fn applySubtable(c: *Ctx, kind: u16, st: []const u8, i: usize) Allocator.Error!?usize {
    return switch (kind) {
        1 => applySingle(c, st, i),
        2 => try applyMultiple(c, st, i),
        3 => applyAlternate(c, st, i),
        4 => applyLigature(c, st, i),
        5 => try context.applyContext(c, st, i),
        6 => try context.applyChainContext(c, st, i),
        // Reverse chaining never runs as a nested lookup.
        8 => if (c.nesting_left == skippy.max_nesting) applyReverse(c, st, i) else null,
        else => null,
    };
}

/// The lookup's effective type (an Extension's target type).
pub fn lookupKind(l: Lookup) u16 {
    if (l.kind != 7) return l.kind;
    const st = l.subtable(0, 7) catch return 0;
    return st.kind;
}

/// Applies lookup `index` over the whole buffer with the context's mask
/// and joiner settings.
pub fn applyLookup(c: *Ctx, index: u16) Allocator.Error!void {
    const acc: ?*const digest.LookupAccel = if (index < c.accels.len) &c.accels[index] else null;
    const l = if (acc) |a| a.lookup else c.table.lookup(index) catch return;
    if (l.kind == 0) return;
    c.lookup_index = index;
    c.lookup_props = l.props();
    c.nesting_left = skippy.max_nesting;
    const filter = if (acc) |a| a.digest else c.lookup_digest;
    if (lookupKind(l) == 8) {
        var i = c.buf.len();
        while (i > 0) {
            i -= 1;
            if (digest.has(filter, c.buf.infos.items[i].gid) and c.applicable(i)) {
                _ = if (acc) |a| try applyAtAccel(c, a, i) else try applyAt(c, l, i);
            }
            if (c.budget.exhausted) return;
        }
        return;
    }
    var i: usize = 0;
    while (i < c.buf.len()) {
        if (c.budget.exhausted) return;
        if (!digest.has(filter, c.buf.infos.items[i].gid) or !c.applicable(i)) {
            i += 1;
            continue;
        }
        const before = c.buf.len();
        const applied = if (acc) |a| try applyAtAccel(c, a, i) else try applyAt(c, l, i);
        if (applied) |next| {
            // A rule that consumed nothing and removed nothing must still
            // move on.
            i = if (next <= i and c.buf.len() >= before) i + 1 else next;
        } else i += 1;
    }
}

fn replace(c: *Ctx, i: usize, gid: GlyphId) void {
    const g = &c.buf.infos.items[i];
    c.setGlyphClass(g, gid, 0, false, false);
    g.gid = gid;
}

fn coverageIndex(st: []const u8, i: usize, c: *Ctx) ?u16 {
    const cov = lc.Coverage.init(st, readAt(u16, st, 2) catch return null) catch return null;
    return cov.index(c.buf.infos.items[i].gid);
}

fn applySingle(c: *Ctx, st: []const u8, i: usize) ?usize {
    const ci = coverageIndex(st, i, c) orelse return null;
    const gid = c.buf.infos.items[i].gid;
    switch (readAt(u16, st, 0) catch return null) {
        1 => {
            const delta = readAt(i16, st, 4) catch return null;
            replace(c, i, @truncate(@as(u32, gid) +% @as(u32, @bitCast(@as(i32, delta)))));
        },
        2 => {
            const n = readAt(u16, st, 4) catch return null;
            if (ci >= n) return null;
            replace(c, i, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return null);
        },
        else => return null,
    }
    return i + 1;
}

fn applyMultiple(c: *Ctx, st: []const u8, i: usize) Allocator.Error!?usize {
    if ((readAt(u16, st, 0) catch return null) != 1) return null;
    const ci = coverageIndex(st, i, c) orelse return null;
    const n = readAt(u16, st, 4) catch return null;
    if (ci >= n) return null;
    const seq = reader.sub(st, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return null) catch return null;
    const count = readAt(u16, seq, 0) catch return null;
    const subs = U16Array.init(seq, 2, count) catch return null;
    switch (count) {
        0 => {
            // Deletion (Uniscribe allows it).
            c.buf.deleteAt(i);
            return i;
        },
        1 => {
            replace(c, i, subs.get(0));
            return i + 1;
        },
        else => {},
    }
    if (count > skippy.max_context_length * 4) return null;
    try c.buf.infos.ensureUnusedCapacity(c.buf.gpa, count - 1);
    const orig = c.buf.infos.items[i];
    const klass: u16 = if (orig.isLigature()) GlyphProps.base else 0;
    const lig_id = orig.ligId();
    var k: usize = count;
    // Insert from the back so every copy starts from the original glyph.
    while (k > 0) {
        k -= 1;
        var g = orig;
        if (lig_id == 0) g.setLigPropsForMark(0, @intCast(k));
        c.setGlyphClass(&g, subs.get(k), klass, false, true);
        g.gid = subs.get(k);
        if (k == 0) c.buf.infos.items[i] = g else c.buf.infos.insertAssumeCapacity(i + 1, g);
    }
    return i + count;
}

fn applyAlternate(c: *Ctx, st: []const u8, i: usize) ?usize {
    if ((readAt(u16, st, 0) catch return null) != 1) return null;
    const ci = coverageIndex(st, i, c) orelse return null;
    const n = readAt(u16, st, 4) catch return null;
    if (ci >= n) return null;
    const set = reader.sub(st, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return null) catch return null;
    const count = readAt(u16, set, 0) catch return null;
    if (count == 0) return null;
    const alts = U16Array.init(set, 2, count) catch return null;
    const shift: u5 = @intCast(@ctz(c.lookup_mask));
    var alt = (c.lookup_mask & c.buf.infos.items[i].mask) >> shift;
    if (alt == max_feature_value and c.random) {
        c.buf.unsafeToBreak(0, c.buf.len());
        alt = c.buf.randomNumber() % count + 1;
    }
    if (alt == 0 or alt > count) return null;
    replace(c, i, alts.get(alt - 1));
    return i + 1;
}

fn applyLigature(c: *Ctx, st: []const u8, i: usize) ?usize {
    if ((readAt(u16, st, 0) catch return null) != 1) return null;
    const ci = coverageIndex(st, i, c) orelse return null;
    const n = readAt(u16, st, 4) catch return null;
    if (ci >= n) return null;
    const set = reader.sub(st, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return null) catch return null;
    const nl = readAt(u16, set, 0) catch return null;
    // With many ligatures, peek at the second glyph once and only try the
    // ligatures that start with it (HarfBuzz's LigatureSet fast path).
    var second: ?GlyphId = null;
    if (nl > 4) {
        var it = Skippy.init(c, false);
        it.reset(i, 1);
        if (it.peekNext()) |j| second = c.buf.infos.items[j].gid;
    }
    for (0..nl) |li| {
        const lig = reader.sub(set, readAt(u16, set, 2 + li * 2) catch return null) catch return null;
        const glyph = readAt(u16, lig, 0) catch continue;
        const count = readAt(u16, lig, 2) catch continue;
        if (count == 0) continue;
        if (count == 1) {
            replace(c, i, glyph);
            return i + 1;
        }
        const comps = U16Array.init(lig, 4, count - 1) catch continue;
        if (second) |g| if (comps.get(0) != g) continue;
        var positions: context.Positions = undefined;
        var match_end: usize = 0;
        var total: u32 = 0;
        if (!context.matchInput(c, i, count, comps, .glyph, &positions, &match_end, &total)) continue;
        return ligate(c, count, &positions, match_end, glyph, total);
    }
    return null;
}

/// HarfBuzz's `ligate_input`, in place: the first component becomes the
/// ligature, the other components are removed, marks between them stay
/// and are re-attached to the right ligature component.
fn ligate(c: *Ctx, count: usize, positions: *const context.Positions, match_end: usize, lig_glyph: GlyphId, total_comps: u32) usize {
    const b = c.buf;
    const infos = b.infos.items;
    const i = positions[0];
    b.mergeClusters(i, match_end);
    var is_base_ligature = infos[i].isBase();
    var is_mark_ligature = infos[i].isMark();
    for (positions[1..count]) |p| if (!infos[p].isMark()) {
        is_base_ligature = false;
        is_mark_ligature = false;
        break;
    };
    const is_ligature = !is_base_ligature and !is_mark_ligature;
    const klass: u16 = if (is_ligature) GlyphProps.ligature else 0;
    const lig_id: u3 = if (is_ligature) b.allocateLigId() else 0;
    var last_lig_id: u3 = infos[i].ligId();
    var last_num: u32 = infos[i].ligNumComps();
    var so_far: u32 = last_num;
    if (is_ligature) {
        infos[i].setLigPropsForLigature(lig_id, total_comps);
        if (infos[i].gc == .Mn) infos[i].gc = .Lo;
    }
    c.setGlyphClass(&infos[i], lig_glyph, klass, true, false);
    infos[i].gid = lig_glyph;
    var at = i + 1;
    for (positions[1..count]) |p| {
        while (at < p) : (at += 1) {
            if (is_ligature) {
                var this_comp: u32 = infos[at].ligComp();
                if (this_comp == 0) this_comp = last_num;
                infos[at].setLigPropsForMark(lig_id, so_far - last_num + @min(this_comp, last_num));
            }
        }
        last_lig_id = infos[p].ligId();
        last_num = infos[p].ligNumComps();
        so_far += last_num;
        at = p + 1;
    }
    if (!is_mark_ligature and last_lig_id != 0) {
        // Marks after the last component that belonged to it follow it
        // into the new ligature.
        var k = positions[count - 1] + 1;
        while (k < infos.len) : (k += 1) {
            if (infos[k].ligId() != last_lig_id) break;
            const this_comp: u32 = infos[k].ligComp();
            if (this_comp == 0) break;
            infos[k].setLigPropsForMark(lig_id, so_far - last_num + @min(this_comp, last_num));
        }
    }
    var r = count;
    while (r > 1) {
        r -= 1;
        _ = b.infos.orderedRemove(positions[r]);
    }
    return positions[count - 1] - (count - 1) + 1;
}

fn applyReverse(c: *Ctx, st: []const u8, i: usize) ?usize {
    if ((readAt(u16, st, 0) catch return null) != 1) return null;
    const ci = coverageIndex(st, i, c) orelse return null;
    var off: usize = 4;
    const nb = readAt(u16, st, off) catch return null;
    const back = U16Array.init(st, off + 2, nb) catch return null;
    off += 2 + @as(usize, nb) * 2;
    const na = readAt(u16, st, off) catch return null;
    const ahead = U16Array.init(st, off + 2, na) catch return null;
    off += 2 + @as(usize, na) * 2;
    const ns = readAt(u16, st, off) catch return null;
    if (ci >= ns) return null;
    const sub = readAt(u16, st, off + 2 + @as(usize, ci) * 2) catch return null;
    var start: usize = 0;
    var end: usize = 0;
    if (!context.matchBacktrack(c, i, back, .{ .coverage = st }, &start)) return null;
    if (!context.matchLookahead(c, i + 1, ahead, .{ .coverage = st }, &end)) return null;
    c.buf.unsafeToBreak(start, end);
    replace(c, i, sub);
    return i;
}

/// Applies `lookups` (one stage) in order.
pub fn applyLookups(c: *Ctx, lookups: anytype) Allocator.Error!void {
    for (lookups) |lm| {
        if (!digest.intersects(c.buf.glyph_set.items, lm.digest)) continue;
        c.lookup_digest = lm.digest;
        defer c.lookup_digest = &.{};
        c.lookup_mask = lm.mask;
        c.auto_zwj = lm.auto_zwj;
        c.auto_zwnj = lm.auto_zwnj;
        c.random = lm.random;
        c.per_syllable = lm.per_syllable;
        try applyLookup(c, lm.index);
        if (c.budget.exhausted) {
            log.warn("shaping op budget exhausted; GSUB stopped early", .{});
            return;
        }
    }
}
