//! Sequence context and chained sequence context matching (GSUB 5/6,
//! GPOS 7/8, formats 1–3), input/backtrack/lookahead matching with
//! HarfBuzz's ligature-component rules, and nested lookup application
//! that tracks match positions through buffer edits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const reader = ot.reader;
const readAt = reader.readAt;
const lc = @import("../ot/layout_common.zig");
const U16Array = lc.U16Array;
const LookupRecords = lc.LookupRecords;
const skippy = @import("skippy.zig");
const Ctx = skippy.Ctx;
const UFlags = @import("buffer.zig").UFlags;
const Skippy = skippy.Skippy;
const Matcher = skippy.Matcher;
const max_context_length = skippy.max_context_length;
const apply_gsub = @import("apply_gsub.zig");
const apply_gpos = @import("apply_gpos.zig");
const digest = @import("digest.zig");

/// Match positions of an input sequence (absolute buffer indices).
pub const Positions = [max_context_length]usize;

/// Matches `count - 1` glyphs after the one at `start` (which already
/// matched) against `values`. Fills `positions` and `end` (one past the
/// last matched glyph). `total_comps` receives the ligature component total.
pub fn matchInput(c: *Ctx, start: usize, count: usize, values: U16Array, m: Matcher, positions: *Positions, end: *usize, total_comps: ?*u32) bool {
    if (count > max_context_length) return false;
    const infos = c.buf.infos.items;
    var it = Skippy.init(c, false);
    it.reset(start, count - 1);
    it.setMatch(m, values);
    var total: u32 = 0;
    const first = infos[start];
    const first_lig_id = first.ligId();
    const first_lig_comp = first.ligComp();
    var ligbase: enum { not_checked, may_not_skip, may_skip } = .not_checked;
    for (1..count) |i| {
        var unsafe_to: usize = 0;
        if (!it.next(&unsafe_to)) {
            end.* = unsafe_to;
            return false;
        }
        positions[i] = it.idx;
        const g = infos[it.idx];
        const this_id = g.ligId();
        const this_comp = g.ligComp();
        if (first_lig_id != 0 and first_lig_comp != 0) {
            // Attached to a previous ligature's component: every component
            // must be attached to that same component, unless that
            // ligature is itself skipped by this lookup.
            if (first_lig_id != this_id or first_lig_comp != this_comp) {
                if (ligbase == .not_checked) {
                    var found = false;
                    var j = start;
                    while (j > 0 and (infos[j - 1].uflags & UFlags.deleted != 0 or infos[j - 1].ligId() == first_lig_id)) {
                        if (infos[j - 1].uflags & UFlags.deleted != 0) {
                            j -= 1;
                            continue;
                        }
                        if (infos[j - 1].ligComp() == 0) {
                            j -= 1;
                            found = true;
                            break;
                        }
                        j -= 1;
                    }
                    ligbase = if (found and !c.checkGlyphProperty(infos[j], it.props)) .may_skip else .may_not_skip;
                }
                if (ligbase == .may_not_skip) return false;
            }
        } else if (this_id != 0 and this_comp != 0 and this_id != first_lig_id) {
            // Not attached: no later component may be attached to another
            // ligature's component.
            return false;
        }
        total += g.ligNumComps();
    }
    end.* = it.idx + 1;
    if (total_comps) |t| t.* = total + first.ligNumComps();
    positions[0] = start;
    return true;
}

/// Matches `values` backwards from the glyph before `start`; `out` is the
/// first glyph of the backtrack on success.
pub fn matchBacktrack(c: *Ctx, start: usize, values: U16Array, m: Matcher, out: *usize) bool {
    var it = Skippy.init(c, true);
    it.reset(start, values.len);
    it.setMatch(m, values);
    for (0..values.len) |_| {
        var unsafe_from: usize = 0;
        if (!it.prev(&unsafe_from)) {
            out.* = unsafe_from;
            return false;
        }
    }
    out.* = it.idx;
    return true;
}

/// Matches `values` forward from `start` (one past the input); `end` is
/// one past the last lookahead glyph on success.
pub fn matchLookahead(c: *Ctx, start: usize, values: U16Array, m: Matcher, end: *usize) bool {
    var it = Skippy.init(c, true);
    it.reset(start - 1, values.len);
    it.setMatch(m, values);
    for (0..values.len) |_| {
        var unsafe_to: usize = 0;
        if (!it.next(&unsafe_to)) {
            end.* = unsafe_to;
            return false;
        }
    }
    end.* = it.idx + 1;
    return true;
}

/// Applies lookup `index` once at buffer position `i` (a nested lookup).
pub fn recurse(c: *Ctx, index: u16, i: usize) Allocator.Error!bool {
    if (c.nesting_left == 0 or !c.budget.take()) return false;
    const acc: ?*const digest.LookupAccel = if (index < c.accels.len) &c.accels[index] else null;
    const l = if (acc) |a| a.lookup else c.table.lookup(index) catch return false;
    if (l.kind == 0) return false;
    const saved_props = c.lookup_props;
    const saved_index = c.lookup_index;
    c.lookup_props = l.props();
    c.lookup_index = index;
    c.nesting_left -= 1;
    defer {
        c.lookup_props = saved_props;
        c.lookup_index = saved_index;
        c.nesting_left += 1;
    }
    if (acc) |a| return switch (c.kind) {
        .gsub => (try apply_gsub.applyAtAccel(c, a, i)) != null,
        .gpos => (try apply_gpos.applyAtAccel(c, a, i)) != null,
    };
    return switch (c.kind) {
        .gsub => (try apply_gsub.applyAt(c, l, i)) != null,
        .gpos => (try apply_gpos.applyAt(c, l, i)) != null,
    };
}

/// Applies the rule's lookup records to the matched `positions` (count
/// glyphs; `match_end` one past the last) and returns where the caller's
/// lookup continues. Positions are moved as nested lookups grow or shrink
/// the buffer (HarfBuzz's `apply_lookup`).
pub fn applyRecords(c: *Ctx, count_in: usize, positions: *Positions, records: LookupRecords, match_end: usize) Allocator.Error!usize {
    var count = count_in;
    var end: isize = @intCast(match_end);
    for (0..records.count) |ri| {
        const rec = records.get(ri);
        const idx: usize = rec.seq;
        if (idx >= count) continue;
        const orig_len = c.buf.len();
        if (positions[idx] >= orig_len) continue;
        if (c.budget.remaining <= 0) break;
        if (!try recurse(c, rec.lookup, positions[idx])) continue;
        const new_len = c.buf.len();
        var delta: isize = @as(isize, @intCast(new_len)) - @as(isize, @intCast(orig_len));
        if (delta == 0) continue;
        end += delta;
        const here: isize = @intCast(positions[idx]);
        if (end < here) {
            delta += here - end;
            end = here;
        }
        var next: usize = idx + 1;
        if (delta > 0) {
            if (@as(usize, @intCast(delta)) + count > max_context_length) break;
        } else {
            delta = @max(delta, @as(isize, @intCast(next)) - @as(isize, @intCast(count)));
            next = @intCast(@as(isize, @intCast(next)) - delta);
        }
        // Shift positions[next..count] by delta.
        const dst: usize = @intCast(@as(isize, @intCast(next)) + delta);
        const n = count - next;
        if (dst > next) {
            std.mem.copyBackwards(usize, positions[dst..][0..n], positions[next..][0..n]);
        } else {
            std.mem.copyForwards(usize, positions[dst..][0..n], positions[next..][0..n]);
        }
        next = dst;
        count = @intCast(@as(isize, @intCast(count)) + delta);
        var j = idx + 1;
        while (j < next) : (j += 1) positions[j] = positions[j - 1] + 1;
        while (next < count) : (next += 1) positions[next] = @intCast(@as(isize, @intCast(positions[next])) + delta);
    }
    return @intCast(@max(end, 0));
}

fn ruleApply(c: *Ctx, i: usize, input_count: u16, input: U16Array, m: Matcher, records: LookupRecords) Allocator.Error!?usize {
    if (input_count == 0) return null;
    var positions: Positions = undefined;
    var match_end: usize = 0;
    if (!matchInput(c, i, input_count, input, m, &positions, &match_end, null)) return null;
    c.buf.unsafeToBreak(i, match_end);
    return try applyRecords(c, input_count, &positions, records, match_end);
}

const ChainMatchers = struct { back: Matcher, input: Matcher, ahead: Matcher };

fn chainRuleApply(c: *Ctx, i: usize, back: U16Array, input_count: u16, input: U16Array, ahead: U16Array, ms: ChainMatchers, records: LookupRecords) Allocator.Error!?usize {
    if (input_count == 0) return null;
    var positions: Positions = undefined;
    var match_end: usize = 0;
    if (!matchInput(c, i, input_count, input, ms.input, &positions, &match_end, null)) return null;
    var end_index = match_end;
    if (!matchLookahead(c, match_end, ahead, ms.ahead, &end_index)) return null;
    var start_index = i;
    if (!matchBacktrack(c, i, back, ms.back, &start_index)) return null;
    c.buf.unsafeToBreak(start_index, end_index);
    return try applyRecords(c, input_count, &positions, records, match_end);
}

/// A (Class)SequenceRule at `rule`: input count, record count, input
/// values and records.
fn applyRuleAt(c: *Ctx, i: usize, set: []const u8, rule_off: u16, m: Matcher) Allocator.Error!?usize {
    const rule = reader.sub(set, rule_off) catch return null;
    const glyph_count = readAt(u16, rule, 0) catch return null;
    const rec_count = readAt(u16, rule, 2) catch return null;
    if (glyph_count == 0) return null;
    const input = U16Array.init(rule, 4, glyph_count - 1) catch return null;
    const recs = LookupRecords.init(rule, 4 + @as(usize, glyph_count - 1) * 2, rec_count) catch return null;
    return ruleApply(c, i, glyph_count, input, m, recs);
}

fn applyRuleSet(c: *Ctx, i: usize, st: []const u8, set_off: u16, m: Matcher) Allocator.Error!?usize {
    if (set_off == 0) return null;
    const set = reader.sub(st, set_off) catch return null;
    const n = readAt(u16, set, 0) catch return null;
    for (0..n) |r| {
        const off = readAt(u16, set, 2 + r * 2) catch return null;
        if (try applyRuleAt(c, i, set, off, m)) |next| return next;
    }
    return null;
}

/// GSUB 5 / GPOS 7 at `i`.
pub fn applyContext(c: *Ctx, st: []const u8, i: usize) Allocator.Error!?usize {
    const gid = c.buf.infos.items[i].gid;
    const format = readAt(u16, st, 0) catch return null;
    switch (format) {
        1 => {
            const cov = lc.Coverage.init(st, readAt(u16, st, 2) catch return null) catch return null;
            const ci = cov.index(gid) orelse return null;
            const n = readAt(u16, st, 4) catch return null;
            if (ci >= n) return null;
            return applyRuleSet(c, i, st, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return null, .glyph);
        },
        2 => {
            const cov = lc.Coverage.init(st, readAt(u16, st, 2) catch return null) catch return null;
            _ = cov.index(gid) orelse return null;
            const cd = lc.ClassDef.init(st, readAt(u16, st, 4) catch return null) catch return null;
            const n = readAt(u16, st, 6) catch return null;
            const class = cd.class(gid);
            if (class >= n) return null;
            return applyRuleSet(c, i, st, readAt(u16, st, 8 + @as(usize, class) * 2) catch return null, .{ .class = cd });
        },
        3 => {
            const glyph_count = readAt(u16, st, 2) catch return null;
            const rec_count = readAt(u16, st, 4) catch return null;
            if (glyph_count == 0) return null;
            const covs = U16Array.init(st, 6, glyph_count) catch return null;
            const cov = lc.Coverage.init(st, covs.get(0)) catch return null;
            _ = cov.index(gid) orelse return null;
            const input = U16Array.init(st, 8, glyph_count - 1) catch return null;
            const recs = LookupRecords.init(st, 6 + @as(usize, glyph_count) * 2, rec_count) catch return null;
            return ruleApply(c, i, glyph_count, input, .{ .coverage = st }, recs);
        },
        else => return null,
    }
}

fn applyChainRuleAt(c: *Ctx, i: usize, set: []const u8, rule_off: u16, ms: ChainMatchers) Allocator.Error!?usize {
    const rule = reader.sub(set, rule_off) catch return null;
    var off: usize = 0;
    const nb = readAt(u16, rule, off) catch return null;
    const back = U16Array.init(rule, off + 2, nb) catch return null;
    off += 2 + @as(usize, nb) * 2;
    const ni = readAt(u16, rule, off) catch return null;
    if (ni == 0) return null;
    const input = U16Array.init(rule, off + 2, ni - 1) catch return null;
    off += 2 + @as(usize, ni - 1) * 2;
    const na = readAt(u16, rule, off) catch return null;
    const ahead = U16Array.init(rule, off + 2, na) catch return null;
    off += 2 + @as(usize, na) * 2;
    const nr = readAt(u16, rule, off) catch return null;
    const recs = LookupRecords.init(rule, off + 2, nr) catch return null;
    return chainRuleApply(c, i, back, ni, input, ahead, ms, recs);
}

fn applyChainRuleSet(c: *Ctx, i: usize, st: []const u8, set_off: u16, ms: ChainMatchers) Allocator.Error!?usize {
    if (set_off == 0) return null;
    const set = reader.sub(st, set_off) catch return null;
    const n = readAt(u16, set, 0) catch return null;
    for (0..n) |r| {
        const off = readAt(u16, set, 2 + r * 2) catch return null;
        if (try applyChainRuleAt(c, i, set, off, ms)) |next| return next;
    }
    return null;
}

/// GSUB 6 / GPOS 8 at `i`.
pub fn applyChainContext(c: *Ctx, st: []const u8, i: usize) Allocator.Error!?usize {
    const gid = c.buf.infos.items[i].gid;
    const format = readAt(u16, st, 0) catch return null;
    switch (format) {
        1 => {
            const cov = lc.Coverage.init(st, readAt(u16, st, 2) catch return null) catch return null;
            const ci = cov.index(gid) orelse return null;
            const n = readAt(u16, st, 4) catch return null;
            if (ci >= n) return null;
            return applyChainRuleSet(c, i, st, readAt(u16, st, 6 + @as(usize, ci) * 2) catch return null, .{ .back = .glyph, .input = .glyph, .ahead = .glyph });
        },
        2 => {
            const cov = lc.Coverage.init(st, readAt(u16, st, 2) catch return null) catch return null;
            _ = cov.index(gid) orelse return null;
            const back = lc.ClassDef.init(st, readAt(u16, st, 4) catch return null) catch return null;
            const input = lc.ClassDef.init(st, readAt(u16, st, 6) catch return null) catch return null;
            const ahead = lc.ClassDef.init(st, readAt(u16, st, 8) catch return null) catch return null;
            const n = readAt(u16, st, 10) catch return null;
            const class = input.class(gid);
            if (class >= n) return null;
            return applyChainRuleSet(c, i, st, readAt(u16, st, 12 + @as(usize, class) * 2) catch return null, .{ .back = .{ .class = back }, .input = .{ .class = input }, .ahead = .{ .class = ahead } });
        },
        3 => {
            var off: usize = 2;
            const nb = readAt(u16, st, off) catch return null;
            const back = U16Array.init(st, off + 2, nb) catch return null;
            off += 2 + @as(usize, nb) * 2;
            const ni = readAt(u16, st, off) catch return null;
            if (ni == 0) return null;
            const in_covs = U16Array.init(st, off + 2, ni) catch return null;
            const cov = lc.Coverage.init(st, in_covs.get(0)) catch return null;
            _ = cov.index(gid) orelse return null;
            const input = U16Array.init(st, off + 4, ni - 1) catch return null;
            off += 2 + @as(usize, ni) * 2;
            const na = readAt(u16, st, off) catch return null;
            const ahead = U16Array.init(st, off + 2, na) catch return null;
            off += 2 + @as(usize, na) * 2;
            const nr = readAt(u16, st, off) catch return null;
            const recs = LookupRecords.init(st, off + 2, nr) catch return null;
            const m: Matcher = .{ .coverage = st };
            return chainRuleApply(c, i, back, ni, input, ahead, .{ .back = m, .input = m, .ahead = m }, recs);
        },
        else => return null,
    }
}
