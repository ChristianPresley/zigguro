//! Glyph sets as bitsets over a face's glyph ids. A lookup's set holds the
//! glyphs it can start matching at (its subtables' first coverages); the
//! buffer's set holds the glyphs present. Lookups whose set misses the
//! buffer are skipped outright and glyphs outside it are never tried,
//! which is how HarfBuzz's digests keep 400-lookup `calt` features cheap.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const GlyphId = ot.GlyphId;
const readAt = ot.reader.readAt;
const lc = @import("../ot/layout_common.zig");
const LayoutTable = lc.LayoutTable;

/// Words for `num_glyphs` bits.
pub fn words(num_glyphs: usize) usize {
    return (num_glyphs + 63) / 64;
}

/// True when `gid` is in `set` (an empty set means "no filter": always).
pub inline fn has(set: []const u64, gid: GlyphId) bool {
    if (set.len == 0) return true;
    const w = gid >> 6;
    if (w >= set.len) return false;
    return set[w] >> @intCast(gid & 63) & 1 != 0;
}

/// Adds `gid` (ignored when out of range).
pub inline fn add(set: []u64, gid: GlyphId) void {
    const w = gid >> 6;
    if (w < set.len) set[w] |= @as(u64, 1) << @intCast(gid & 63);
}

/// True when the sets share a glyph (or either is "no filter").
pub fn intersects(a: []const u64, b: []const u64) bool {
    if (a.len == 0 or b.len == 0) return true;
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| if (x & y != 0) return true;
    return false;
}

fn addCoverage(set: []u64, st: []const u8, at: usize) bool {
    const off = readAt(u16, st, at) catch return false;
    const c = lc.Coverage.init(st, off) catch return false;
    c.forEach(set, struct {
        fn cb(s: []u64, g: GlyphId) void {
            add(s, g);
        }
    }.cb);
    return true;
}

/// Offset (within the subtable) of the coverage of a match's first glyph.
fn firstCoverageAt(kind: u16, st: []const u8, gpos: bool) ?usize {
    const context: u16 = if (gpos) 7 else 5;
    const chain: u16 = if (gpos) 8 else 6;
    if (kind == context) {
        return switch (readAt(u16, st, 0) catch return null) {
            1, 2 => 2,
            3 => 6,
            else => null,
        };
    }
    if (kind == chain) {
        return switch (readAt(u16, st, 0) catch return null) {
            1, 2 => 2,
            3 => blk: {
                const nb = readAt(u16, st, 2) catch return null;
                break :blk 6 + @as(usize, nb) * 2;
            },
            else => null,
        };
    }
    const max: u16 = if (gpos) 6 else 8;
    if (kind == 0 or kind > max) return null;
    return 2;
}

/// One subtable, extension resolved, with its first-glyph set.
pub const SubAccel = struct {
    kind: u16,
    data: []const u8,
    /// Empty: unknown (always try the subtable).
    digest: []const u64,
};

/// A lookup with its subtables pre-resolved (HarfBuzz's accelerator).
pub const LookupAccel = struct {
    lookup: lc.Lookup,
    subtables: []const SubAccel,
    /// Union of the subtables' sets; empty when any is unknown.
    digest: []const u64,
};

/// Accelerators for every lookup of `t` (a malformed lookup gets none:
/// `subtables` empty and kind 0).
pub fn buildAccels(a: Allocator, t: LayoutTable, gpos: bool, num_glyphs: usize) Allocator.Error![]const LookupAccel {
    const out = try a.alloc(LookupAccel, t.lookup_count);
    const ext: u16 = if (gpos) 9 else 7;
    const n_words = words(num_glyphs);
    for (out, 0..) |*acc, li| {
        const l = t.lookup(@intCast(li)) catch {
            acc.* = .{ .lookup = .{ .data = &.{}, .kind = 0, .flag = 0, .subtable_count = 0, .mark_filtering_set = null }, .subtables = &.{}, .digest = &.{} };
            continue;
        };
        const subs = try a.alloc(SubAccel, l.subtable_count);
        var n: usize = 0;
        var union_set: []u64 = try a.alloc(u64, n_words);
        @memset(union_set, 0);
        var known = true;
        for (0..l.subtable_count) |k| {
            const st = l.subtable(@intCast(k), ext) catch continue;
            var set: []const u64 = &.{};
            if (firstCoverageAt(st.kind, st.data, gpos)) |at| {
                const bits = try a.alloc(u64, n_words);
                @memset(bits, 0);
                if (addCoverage(bits, st.data, at)) {
                    set = bits;
                    for (union_set, bits) |*u, b| u.* |= b;
                }
            }
            if (set.len == 0) known = false;
            subs[n] = .{ .kind = st.kind, .data = st.data, .digest = set };
            n += 1;
        }
        if (!known) union_set = &.{};
        acc.* = .{ .lookup = l, .subtables = subs[0..n], .digest = union_set };
    }
    return out;
}

test "digest: bit operations" {
    var set: [2]u64 = @splat(0);
    add(&set, 3);
    add(&set, 70);
    add(&set, 500); // out of range: ignored
    try std.testing.expect(has(&set, 3) and has(&set, 70) and !has(&set, 4) and !has(&set, 500));
    try std.testing.expect(has(&.{}, 9));
    var other: [2]u64 = @splat(0);
    try std.testing.expect(!intersects(&set, &other));
    add(&other, 70);
    try std.testing.expect(intersects(&set, &other));
}
