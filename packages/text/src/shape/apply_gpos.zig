//! GPOS application: single (1) and pair (2) adjustment, cursive
//! attachment (3), mark-to-base (4), mark-to-ligature (5), mark-to-mark
//! (6), context (7), chained context (8) and extension (9) positioning,
//! VariationIndex deltas for variable fonts, and the final pass that turns
//! attachment chains into offsets. Positions are in font units.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const reader = ot.reader;
const readAt = reader.readAt;
const lc = @import("../ot/layout_common.zig");
const Lookup = lc.Lookup;
const LookupFlag = lc.LookupFlag;
const skippy = @import("skippy.zig");
const Ctx = skippy.Ctx;
const Skippy = skippy.Skippy;
const context = @import("context.zig");
const digest = @import("digest.zig");
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const GlyphPos = buffer.GlyphPos;
const AttachType = buffer.AttachType;
const Direction = buffer.Direction;

/// Applies `l`'s subtables at `i` until one applies.
pub fn applyAt(c: *Ctx, l: Lookup, i: usize) Allocator.Error!?usize {
    for (0..l.subtable_count) |j| {
        if (!c.budget.take()) return null;
        const st = l.subtable(@intCast(j), 9) catch continue;
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
        2 => applyPair(c, st, i),
        3 => applyCursive(c, st, i),
        4 => applyMarkBase(c, st, i),
        5 => applyMarkLig(c, st, i),
        6 => applyMarkMark(c, st, i),
        7 => try context.applyContext(c, st, i),
        8 => try context.applyChainContext(c, st, i),
        else => null,
    };
}

/// Applies lookup `index` over the whole buffer.
pub fn applyLookup(c: *Ctx, index: u16) Allocator.Error!void {
    const acc: ?*const digest.LookupAccel = if (index < c.accels.len) &c.accels[index] else null;
    const l = if (acc) |a| a.lookup else c.table.lookup(index) catch return;
    if (l.kind == 0) return;
    c.lookup_index = index;
    c.lookup_props = l.props();
    c.nesting_left = skippy.max_nesting;
    const filter = if (acc) |a| a.digest else c.lookup_digest;
    var i: usize = 0;
    while (i < c.buf.len()) {
        if (c.budget.exhausted) return;
        if (!digest.has(filter, c.buf.infos.items[i].gid) or !c.applicable(i)) {
            i += 1;
            continue;
        }
        const applied = if (acc) |a| try applyAtAccel(c, a, i) else try applyAt(c, l, i);
        if (applied) |next| {
            i = if (next <= i) i + 1 else next;
        } else i += 1;
    }
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
        c.random = false;
        c.per_syllable = false;
        try applyLookup(c, lm.index);
        if (c.budget.exhausted) return;
    }
}

fn valueSize(format: u16) usize {
    return @as(usize, @popCount(format & 0xFF)) * 2;
}

/// The rounded VariationIndex delta of the Device/VariationIndex table at
/// `base[off..]` (0 for hinting devices or without coordinates).
fn deviceDelta(c: *const Ctx, base: []const u8, off: u16) i32 {
    if (off == 0 or c.coords.len == 0) return 0;
    const d = reader.sub(base, off) catch return 0;
    if ((readAt(u16, d, 4) catch return 0) != 0x8000) return 0;
    const store = &(c.gdef.var_store orelse return 0);
    const outer = readAt(u16, d, 0) catch return 0;
    const inner = readAt(u16, d, 2) catch return 0;
    const v = if (c.var_scalars.len != 0) store.deltaScaled(outer, inner, c.var_scalars) else store.delta(outer, inner, c.coords);
    return @intFromFloat(@round(v));
}

/// Adds the ValueRecord at `rec` (format `format`; device offsets from
/// `base`) to `p`. True when any field was non-zero.
fn applyValue(c: *const Ctx, base: []const u8, rec: []const u8, format: u16, p: *GlyphPos) bool {
    if (format == 0) return false;
    var ret = false;
    var off: usize = 0;
    const field = struct {
        fn get(r: []const u8, o: *usize, any: *bool) i16 {
            const v = readAt(i16, r, o.*) catch 0;
            o.* += 2;
            if (v != 0) any.* = true;
            return v;
        }
    }.get;
    if (format & 0x1 != 0) p.x_off += field(rec, &off, &ret);
    if (format & 0x2 != 0) p.y_off += field(rec, &off, &ret);
    if (format & 0x4 != 0) p.x_adv += field(rec, &off, &ret);
    if (format & 0x8 != 0) _ = field(rec, &off, &ret); // y advance: vertical only
    if (format & 0xF0 == 0) return ret;
    const dev = struct {
        fn get(r: []const u8, o: *usize, any: *bool) u16 {
            const v = readAt(u16, r, o.*) catch 0;
            o.* += 2;
            if (v != 0) any.* = true;
            return v;
        }
    }.get;
    if (c.coords.len == 0) return ret;
    if (format & 0x10 != 0) p.x_off += deviceDelta(c, base, dev(rec, &off, &ret));
    if (format & 0x20 != 0) p.y_off += deviceDelta(c, base, dev(rec, &off, &ret));
    if (format & 0x40 != 0) p.x_adv += deviceDelta(c, base, dev(rec, &off, &ret));
    return ret;
}

/// An anchor point (formats 1–3; format 3 adds VariationIndex deltas).
fn anchor(c: *const Ctx, base: []const u8, off: u16) ?[2]i32 {
    if (off == 0) return null;
    const a = reader.sub(base, off) catch return null;
    const format = readAt(u16, a, 0) catch return null;
    var x: i32 = readAt(i16, a, 2) catch return null;
    var y: i32 = readAt(i16, a, 4) catch return null;
    switch (format) {
        1, 2 => {},
        3 => {
            x += deviceDelta(c, a, readAt(u16, a, 6) catch 0);
            y += deviceDelta(c, a, readAt(u16, a, 8) catch 0);
        },
        else => return null,
    }
    return .{ x, y };
}

fn cov(st: []const u8, at: usize, gid: ot.GlyphId) ?u16 {
    const c = lc.Coverage.init(st, readAt(u16, st, at) catch return null) catch return null;
    return c.index(gid);
}

fn applySingle(c: *Ctx, st: []const u8, i: usize) ?usize {
    const ci = cov(st, 2, c.buf.infos.items[i].gid) orelse return null;
    const vf = readAt(u16, st, 4) catch return null;
    const p = &c.buf.pos.items[i];
    switch (readAt(u16, st, 0) catch return null) {
        1 => _ = applyValue(c, st, reader.sub(st, 6) catch return null, vf, p),
        2 => {
            const n = readAt(u16, st, 6) catch return null;
            if (ci >= n) return null;
            const rec = reader.subLen(st, 8 + @as(usize, ci) * valueSize(vf), valueSize(vf)) catch return null;
            _ = applyValue(c, st, rec, vf, p);
        },
        else => return null,
    }
    return i + 1;
}

fn applyPair(c: *Ctx, st: []const u8, i: usize) ?usize {
    const infos = c.buf.infos.items;
    const ci = cov(st, 2, infos[i].gid) orelse return null;
    const vf1 = readAt(u16, st, 4) catch return null;
    const vf2 = readAt(u16, st, 6) catch return null;
    const len1 = valueSize(vf1);
    const len2 = valueSize(vf2);
    var it = Skippy.init(c, false);
    it.reset(i, 1);
    const j = it.peekNext() orelse blk: {
        if (!it.next(null)) return null;
        break :blk it.idx;
    };
    const pos = c.buf.pos.items;
    switch (readAt(u16, st, 0) catch return null) {
        1 => {
            const n = readAt(u16, st, 8) catch return null;
            if (ci >= n) return null;
            const set = reader.sub(st, readAt(u16, st, 10 + @as(usize, ci) * 2) catch return null) catch return null;
            const count = readAt(u16, set, 0) catch return null;
            const rec_size = 2 + len1 + len2;
            _ = reader.subLen(set, 2, @as(usize, count) * rec_size) catch return null;
            const second = infos[j].gid;
            var lo: usize = 0;
            var hi: usize = count;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = set[2 + mid * rec_size ..][0..rec_size];
                const g = std.mem.readInt(u16, rec[0..2], .big);
                if (second < g) hi = mid else if (second > g) lo = mid + 1 else {
                    const a = applyValue(c, set, rec[2..], vf1, &pos[i]);
                    const b = applyValue(c, set, rec[2 + len1 ..], vf2, &pos[j]);
                    if (a or b) c.buf.unsafeToBreak(i, j + 1);
                    return if (len2 != 0) j + 1 else j;
                }
            }
            return null;
        },
        2 => {
            const cd1 = lc.ClassDef.init(st, readAt(u16, st, 8) catch return null) catch return null;
            const cd2 = lc.ClassDef.init(st, readAt(u16, st, 10) catch return null) catch return null;
            const n1 = readAt(u16, st, 12) catch return null;
            const n2 = readAt(u16, st, 14) catch return null;
            const k1 = cd1.class(infos[i].gid);
            const k2 = cd2.class(infos[j].gid);
            if (k1 >= n1 or k2 >= n2) return null;
            const rec_size = len1 + len2;
            const rec = reader.subLen(st, 16 + (@as(usize, k1) * n2 + k2) * rec_size, rec_size) catch return null;
            const a = applyValue(c, st, rec, vf1, &pos[i]);
            const b = applyValue(c, st, rec[len1..], vf2, &pos[j]);
            if (a or b) c.buf.unsafeToBreak(i, j + 1);
            return if (len2 != 0) j + 1 else j;
        },
        else => return null,
    }
}

fn applyCursive(c: *Ctx, st: []const u8, j: usize) ?usize {
    if ((readAt(u16, st, 0) catch return null) != 1) return null;
    const infos = c.buf.infos.items;
    const n = readAt(u16, st, 4) catch return null;
    const this_ci = cov(st, 2, infos[j].gid) orelse return null;
    if (this_ci >= n) return null;
    const entry_off = readAt(u16, st, 6 + @as(usize, this_ci) * 4) catch return null;
    if (entry_off == 0) return null;
    var it = Skippy.init(c, false);
    it.reset(j, 1);
    if (!it.prev(null)) return null;
    const i = it.idx;
    const prev_ci = cov(st, 2, infos[i].gid) orelse return null;
    if (prev_ci >= n) return null;
    const exit_off = readAt(u16, st, 6 + @as(usize, prev_ci) * 4 + 2) catch return null;
    if (exit_off == 0) return null;
    const exit = anchor(c, st, exit_off) orelse return null;
    const entry = anchor(c, st, entry_off) orelse return null;
    c.buf.unsafeToBreak(i, j + 1);
    const pos = c.buf.pos.items;
    if (!c.rtl) {
        pos[i].x_adv = exit[0] + pos[i].x_off;
        const d = entry[0] + pos[j].x_off;
        pos[j].x_adv -= d;
        pos[j].x_off -= d;
    } else {
        const d = exit[0] + pos[i].x_off;
        pos[i].x_adv -= d;
        pos[i].x_off -= d;
        pos[j].x_adv = entry[0] + pos[j].x_off;
    }
    // Cross-stream: the child aligns to its parent; RIGHT_TO_LEFT makes
    // the earlier glyph the child.
    var child = i;
    var parent = j;
    var y_offset = entry[1] - exit[1];
    if (c.lookup_props & LookupFlag.right_to_left == 0) {
        child = j;
        parent = i;
        y_offset = -y_offset;
    }
    reverseCursiveMinorOffset(pos, child, parent);
    pos[child].attach_type = AttachType.cursive;
    pos[child].attach_chain = @intCast(@as(isize, @intCast(parent)) - @as(isize, @intCast(child)));
    pos[child].y_off = y_offset;
    if (pos[parent].attach_chain == -pos[child].attach_chain) {
        pos[parent].attach_chain = 0;
        pos[parent].y_off = 0;
    }
    c.buf.has_attachments = true;
    return j + 1;
}

fn reverseCursiveMinorOffset(pos: []GlyphPos, i: usize, new_parent: usize) void {
    const chain = pos[i].attach_chain;
    const kind = pos[i].attach_type;
    if (chain == 0 or kind & AttachType.cursive == 0) return;
    pos[i].attach_chain = 0;
    const j: usize = @intCast(@as(isize, @intCast(i)) + chain);
    if (j == new_parent or j >= pos.len) return;
    reverseCursiveMinorOffset(pos, j, new_parent);
    pos[j].y_off = -pos[i].y_off;
    pos[j].attach_chain = -chain;
    pos[j].attach_type = kind;
}

/// HarfBuzz's MarkArray::apply: attaches the mark at `i` to the anchor
/// `row` of the matrix at `matrix` (`cols` classes) on the glyph at `target`.
fn attachMark(c: *Ctx, mark_array: []const u8, mark_index: u16, matrix: []const u8, row: usize, cols: u16, target: usize, i: usize) ?usize {
    const n = readAt(u16, mark_array, 0) catch return null;
    if (mark_index >= n) return null;
    const rec = 2 + @as(usize, mark_index) * 4;
    const class = readAt(u16, mark_array, rec) catch return null;
    if (class >= cols) return null;
    const mark_anchor_off = readAt(u16, mark_array, rec + 2) catch return null;
    const rows = readAt(u16, matrix, 0) catch return null;
    if (row >= rows) return null;
    const off = readAt(u16, matrix, 2 + (row * cols + class) * 2) catch return null;
    if (off == 0) return null; // no anchor: let later subtables try
    const base_pt = anchor(c, matrix, off) orelse return null;
    const mark_pt = anchor(c, mark_array, mark_anchor_off) orelse return null;
    c.buf.unsafeToBreak(target, i + 1);
    const p = &c.buf.pos.items[i];
    p.x_off = base_pt[0] - mark_pt[0];
    p.y_off = base_pt[1] - mark_pt[1];
    p.attach_type = AttachType.mark;
    p.attach_chain = @intCast(@as(isize, @intCast(target)) - @as(isize, @intCast(i)));
    c.buf.has_attachments = true;
    return i + 1;
}

/// The previous glyph a mark can attach to (skipping marks), HarfBuzz's
/// search. `base_cov`, when given, also accepts a non-first component of a
/// multiple substitution if the coverage lists it.
fn findBase(c: *Ctx, i: usize, base_cov: ?lc.Coverage) ?usize {
    var it = Skippy.init(c, false);
    it.props = LookupFlag.ignore_marks;
    const infos = c.buf.infos.items;
    var j = i;
    while (j > 0) : (j -= 1) {
        var m = it.match(infos[j - 1]);
        if (m == .match) if (base_cov) |bc| {
            if (!accept(infos, j - 1) and bc.index(infos[j - 1].gid) == null) m = .skip;
        };
        if (m == .match) return j - 1;
    }
    return null;
}

/// Attach only to the first glyph of a multiple substitution, unless a
/// mark separates the sequence (HarfBuzz issues 740 and 1020).
fn accept(infos: []const buffer.GlyphInfo, idx: usize) bool {
    const g = infos[idx];
    if (!g.multiplied() or g.ligComp() == 0 or idx == 0) return true;
    const p = infos[idx - 1];
    return p.isMark() or !p.multiplied() or g.ligId() != p.ligId() or @as(u32, g.ligComp()) != @as(u32, p.ligComp()) + 1;
}

fn applyMarkBase(c: *Ctx, st: []const u8, i: usize) ?usize {
    if ((readAt(u16, st, 0) catch return null) != 1) return null;
    const infos = c.buf.infos.items;
    const mark_index = cov(st, 2, infos[i].gid) orelse return null;
    const base_cov = lc.Coverage.init(st, readAt(u16, st, 4) catch return null) catch return null;
    const target = findBase(c, i, base_cov) orelse return null;
    const base_index = base_cov.index(infos[target].gid) orelse return null;
    const cols = readAt(u16, st, 6) catch return null;
    const mark_array = reader.sub(st, readAt(u16, st, 8) catch return null) catch return null;
    const base_array = reader.sub(st, readAt(u16, st, 10) catch return null) catch return null;
    return attachMark(c, mark_array, mark_index, base_array, base_index, cols, target, i);
}

fn applyMarkLig(c: *Ctx, st: []const u8, i: usize) ?usize {
    if ((readAt(u16, st, 0) catch return null) != 1) return null;
    const infos = c.buf.infos.items;
    const mark_index = cov(st, 2, infos[i].gid) orelse return null;
    const target = findBase(c, i, null) orelse return null;
    const lig_index = cov(st, 4, infos[target].gid) orelse return null;
    const cols = readAt(u16, st, 6) catch return null;
    const mark_array = reader.sub(st, readAt(u16, st, 8) catch return null) catch return null;
    const lig_array = reader.sub(st, readAt(u16, st, 10) catch return null) catch return null;
    const n = readAt(u16, lig_array, 0) catch return null;
    if (lig_index >= n) return null;
    const attach = reader.sub(lig_array, readAt(u16, lig_array, 2 + @as(usize, lig_index) * 2) catch return null) catch return null;
    const comp_count = readAt(u16, attach, 0) catch return null;
    if (comp_count == 0) return null;
    const lig_id = infos[target].ligId();
    const mark_id = infos[i].ligId();
    const mark_comp = infos[i].ligComp();
    const comp: usize = if (lig_id != 0 and lig_id == mark_id and mark_comp > 0) @as(usize, @min(comp_count, mark_comp)) - 1 else comp_count - 1;
    return attachMark(c, mark_array, mark_index, attach, comp, cols, target, i);
}

fn applyMarkMark(c: *Ctx, st: []const u8, i: usize) ?usize {
    if ((readAt(u16, st, 0) catch return null) != 1) return null;
    const infos = c.buf.infos.items;
    const mark1_index = cov(st, 2, infos[i].gid) orelse return null;
    var it = Skippy.init(c, false);
    it.props = c.lookup_props & ~@as(u32, LookupFlag.ignore_flags);
    it.reset(i, 1);
    if (!it.prev(null)) return null;
    const j = it.idx;
    if (!infos[j].isMark()) return null;
    const id1 = infos[i].ligId();
    const id2 = infos[j].ligId();
    const comp1 = infos[i].ligComp();
    const comp2 = infos[j].ligComp();
    const good = if (id1 == id2) (id1 == 0 or comp1 == comp2) else ((id1 > 0 and comp1 == 0) or (id2 > 0 and comp2 == 0));
    if (!good) return null;
    const mark2_index = cov(st, 4, infos[j].gid) orelse return null;
    const cols = readAt(u16, st, 6) catch return null;
    const mark1_array = reader.sub(st, readAt(u16, st, 8) catch return null) catch return null;
    const mark2_array = reader.sub(st, readAt(u16, st, 10) catch return null) catch return null;
    return attachMark(c, mark1_array, mark1_index, mark2_array, mark2_index, cols, j, i);
}

/// Resolves attachment chains into offsets: a mark takes its target's
/// offset minus (LTR) or plus (RTL) the advances between them; a cursive
/// child takes its parent's cross-stream offset. Positions are in logical
/// order.
pub fn resolveAttachments(b: *Buffer, dir: Direction) void {
    if (!b.has_attachments) return;
    const pos = b.pos.items;
    for (0..pos.len) |i| propagate(pos, i, dir, 64);
}

fn propagate(pos: []GlyphPos, i: usize, dir: Direction, nesting: u8) void {
    const chain = pos[i].attach_chain;
    const kind = pos[i].attach_type;
    if (chain == 0) return;
    pos[i].attach_chain = 0;
    const ji = @as(isize, @intCast(i)) + chain;
    if (ji < 0 or ji >= pos.len) return;
    if (nesting == 0) return;
    const j: usize = @intCast(ji);
    propagate(pos, j, dir, nesting - 1);
    if (kind & AttachType.cursive != 0) {
        pos[i].y_off += pos[j].y_off;
        return;
    }
    pos[i].x_off += pos[j].x_off;
    pos[i].y_off += pos[j].y_off;
    if (j >= i) return;
    if (dir == .ltr) {
        for (j..i) |k| {
            pos[i].x_off -= pos[k].x_adv;
            pos[i].y_off -= pos[k].y_adv;
        }
    } else {
        for (j + 1..i + 1) |k| {
            pos[i].x_off += pos[k].x_adv;
            pos[i].y_off += pos[k].y_adv;
        }
    }
}
