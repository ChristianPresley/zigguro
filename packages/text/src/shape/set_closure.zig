//! Can a lookup fire on text whose glyphs all come from a set? Layout uses
//! this once per (instance, feature set) to decide that ASCII text needs
//! no shaping. The answer is conservative: `true` unless every way the
//! lookup could match needs a glyph outside the set. Coverage-based
//! contexts (format 3) are checked position by position, which clears the
//! usual `ccmp` rules such as "i or j before a combining mark".

const std = @import("std");
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const readAt = ot.reader.readAt;
const lc = @import("../ot/layout_common.zig");
const LayoutTable = lc.LayoutTable;
const digest = @import("digest.zig");

/// True when lookup `index` of `t` may change or move glyphs of a sequence
/// drawn only from `set` (a glyph bitset). `ext_kind`: 7 GSUB, 9 GPOS.
pub fn lookupMayFire(t: LayoutTable, index: u16, set: []const u64, ext_kind: u16) bool {
    const l = t.lookup(index) catch return true;
    for (0..l.subtable_count) |i| {
        const st = l.subtable(@intCast(i), ext_kind) catch return true;
        if (subtableMayFire(st.kind, st.data, set, ext_kind == 9)) return true;
    }
    return false;
}

/// Adds to `hot` the glyphs of `set` at which lookup `index` may start
/// matching, counting only subtables that `lookupMayFire` would. Text with
/// no hot glyph is left alone by the lookup.
pub fn hotGlyphs(t: LayoutTable, index: u16, set: []const u64, ext_kind: u16, hot: []u64) void {
    const l = t.lookup(index) catch return addAll(set, hot);
    for (0..l.subtable_count) |i| {
        const st = l.subtable(@intCast(i), ext_kind) catch return addAll(set, hot);
        if (!subtableMayFire(st.kind, st.data, set, ext_kind == 9)) continue;
        const at = firstInputAt(st.kind, st.data, ext_kind == 9) orelse return addAll(set, hot);
        const off = readAt(u16, st.data, at) catch return addAll(set, hot);
        const c = lc.Coverage.init(st.data, off) catch return addAll(set, hot);
        var adder: Adder = .{ .set = set, .hot = hot };
        c.forEach(&adder, Adder.visit);
    }
}

fn addAll(set: []const u64, hot: []u64) void {
    for (hot, set) |*h, s| h.* |= s;
}

const Adder = struct {
    set: []const u64,
    hot: []u64,

    fn visit(a: *Adder, gid: GlyphId) void {
        if (digest.has(a.set, gid)) digest.add(a.hot, gid);
    }
};

/// Where the offset of a subtable's first input coverage is stored.
fn firstInputAt(kind: u16, st: []const u8, gpos: bool) ?usize {
    const context = if (gpos) kind == 7 else kind == 5;
    const chain = if (gpos) kind == 8 else kind == 6;
    if (!context and !chain) return 2;
    const format = readAt(u16, st, 0) catch return null;
    if (format != 3) return 2;
    if (context) return 6;
    const nb = readAt(u16, st, 2) catch return null;
    return 4 + @as(usize, nb) * 2 + 2;
}

const Probe = struct {
    set: []const u64,
    hit: bool = false,

    fn visit(p: *Probe, gid: GlyphId) void {
        if (!p.hit and digest.has(p.set, gid)) p.hit = true;
    }
};

/// True when the coverage at the offset stored at `st[at..]` shares a
/// glyph with `set` (or cannot be read).
fn meets(st: []const u8, at: usize, set: []const u64) bool {
    const off = readAt(u16, st, at) catch return true;
    const c = lc.Coverage.init(st, off) catch return true;
    var p: Probe = .{ .set = set };
    c.forEach(&p, Probe.visit);
    return p.hit;
}

fn subtableMayFire(kind: u16, st: []const u8, set: []const u64, gpos: bool) bool {
    if (!gpos) return switch (kind) {
        1, 2, 3, 4 => meets(st, 2, set),
        5 => contextMayFire(st, set),
        6 => chainMayFire(st, set),
        else => meets(st, 2, set),
    };
    return switch (kind) {
        1, 2, 3 => meets(st, 2, set),
        // Mark attachment needs both a mark and a base (or ligature, mark).
        4, 5, 6 => meets(st, 2, set) and meets(st, 4, set),
        7 => contextMayFire(st, set),
        8 => chainMayFire(st, set),
        else => true,
    };
}

/// Context format 3: every input coverage must meet the set. Formats 1
/// and 2 count when their first coverage does.
fn contextMayFire(st: []const u8, set: []const u64) bool {
    const format = readAt(u16, st, 0) catch return true;
    if (format != 3) return meets(st, 2, set);
    const n = readAt(u16, st, 2) catch return true;
    for (0..n) |i| if (!meets(st, 6 + i * 2, set)) return false;
    return true;
}

/// Chained context format 3: every backtrack, input and lookahead
/// coverage must meet the set.
fn chainMayFire(st: []const u8, set: []const u64) bool {
    const format = readAt(u16, st, 0) catch return true;
    if (format != 3) return meets(st, 2, set);
    var off: usize = 2;
    for (0..3) |_| {
        const n = readAt(u16, st, off) catch return true;
        for (0..n) |i| if (!meets(st, off + 2 + i * 2, set)) return false;
        off += 2 + @as(usize, n) * 2;
    }
    return true;
}

test "set closure: chain format 3 needs every position" {
    var b: lc.TestBytes = .{ .gpa = std.testing.allocator };
    defer b.deinit();
    // ChainContextSubst format 3: no backtrack, input {5}, lookahead {9},
    // no lookup records.
    b.u16s(&.{ 3, 0, 1, 14, 1, 20, 0 });
    b.u16s(&.{ 1, 1, 5 }); // @14
    b.u16s(&.{ 1, 1, 9 }); // @20
    var set = [1]u64{0};
    digest.add(&set, 5);
    try std.testing.expect(!chainMayFire(b.buf.items, &set));
    digest.add(&set, 9);
    try std.testing.expect(chainMayFire(b.buf.items, &set));
}
