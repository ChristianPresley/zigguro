//! `cmap`: character to glyph mapping. Formats 0, 4, 6, 12 and 13 map code
//! points; format 14 maps variation sequences. The best Unicode subtable is
//! chosen once at init and ASCII/Latin-1 (page 0) is prebuilt so the hot
//! lookup is a single array load.

const std = @import("std");
const reader = @import("reader.zig");
const GlyphId = reader.GlyphId;
const readAt = reader.readAt;

/// Result of a variation-sequence lookup (format 14).
pub const VariantResult = union(enum) {
    /// The sequence is not in the font.
    not_found,
    /// The sequence is valid and uses the default glyph of the base character.
    use_default,
    /// The sequence maps to this glyph.
    glyph: GlyphId,
};

/// Sorted, merged, inclusive ranges of mapped code points.
pub const CoverageSet = struct {
    ranges: []const [2]u21,

    /// True if `cp` is mapped.
    pub fn contains(s: CoverageSet, cp: u21) bool {
        var lo: usize = 0;
        var hi: usize = s.ranges.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (s.ranges[mid][1] < cp) lo = mid + 1 else hi = mid;
        }
        return lo < s.ranges.len and s.ranges[lo][0] <= cp;
    }

    /// Frees ranges returned by `Cmap.coverage`.
    pub fn deinit(s: CoverageSet, gpa: std.mem.Allocator) void {
        gpa.free(s.ranges);
    }
};

/// The parsed `cmap` table: the chosen subtable plus the format 14 table.
pub const Cmap = struct {
    /// The chosen subtable, clamped to its declared length.
    sub: []const u8,
    format: u16,
    /// Windows symbol (3,0) subtable: U+F000+cp is tried for cp < 0x100.
    symbol: bool,
    /// The format 14 subtable, if any.
    uvs: ?[]const u8,
    /// Glyph ids at or above this map to 0.
    num_glyphs: u16,
    /// Prebuilt glyph ids for U+0000..U+00FF.
    page0: [256]GlyphId,

    /// Parses `table`, accepting any glyph id below 0xFFFF.
    pub fn init(table: []const u8) error{ Malformed, NoUnicodeSubtable }!Cmap {
        return initGlyphs(table, 0xFFFF);
    }

    /// Parses `table`; glyph ids `>= num_glyphs` are treated as unmapped.
    pub fn initGlyphs(table: []const u8, num_glyphs: u16) error{ Malformed, NoUnicodeSubtable }!Cmap {
        if (try readAt(u16, table, 0) != 0) return error.Malformed;
        const n = try readAt(u16, table, 2);
        var best: ?[]const u8 = null;
        var best_fmt: u16 = 0;
        var best_rank: u8 = 0;
        var symbol = false;
        var uvs: ?[]const u8 = null;
        for (0..n) |i| {
            const rec = 4 + i * 8;
            const pid = try readAt(u16, table, rec);
            const eid = try readAt(u16, table, rec + 2);
            const off = try readAt(u32, table, rec + 4);
            const st = subtable(table, off) orelse continue;
            if (pid == 0 and eid == 5 and st.format == 14) {
                uvs = st.bytes;
                continue;
            }
            const rank = rankOf(pid, eid, st.format);
            if (rank > best_rank) {
                best = st.bytes;
                best_fmt = st.format;
                best_rank = rank;
                symbol = pid == 3 and eid == 0;
            }
        }
        const sub = best orelse return error.NoUnicodeSubtable;
        var c: Cmap = .{ .sub = sub, .format = best_fmt, .symbol = symbol, .uvs = uvs, .num_glyphs = num_glyphs, .page0 = undefined };
        for (&c.page0, 0..) |*g, cp| g.* = c.lookupSlow(@intCast(cp));
        return c;
    }

    fn rankOf(pid: u16, eid: u16, format: u16) u8 {
        return switch (pid) {
            3 => switch (eid) {
                10 => if (format == 12) 9 else 0,
                1 => switch (format) {
                    4 => 6,
                    12 => 5,
                    6 => 4,
                    else => 0,
                },
                0 => if (format == 4) 1 else 0,
                else => 0,
            },
            0 => switch (format) {
                13 => if (eid == 6) 8 else 0,
                12 => if (eid == 4) 7 else 5,
                4 => if (eid == 3) 5 else 4,
                6 => 4,
                else => 0,
            },
            1 => if (eid == 0 and format == 0) 2 else 0,
            else => 0,
        };
    }

    const Sub = struct { format: u16, bytes: []const u8 };

    fn subtable(table: []const u8, off: u32) ?Sub {
        const format = readAt(u16, table, off) catch return null;
        const len: usize = switch (format) {
            0, 2, 4, 6 => readAt(u16, table, @as(usize, off) + 2) catch return null,
            8, 10, 12, 13 => readAt(u32, table, @as(usize, off) + 4) catch return null,
            14 => readAt(u32, table, @as(usize, off) + 2) catch return null,
            else => return null,
        };
        const avail = table.len - off;
        return .{ .format = format, .bytes = table[off..][0..@min(len, avail)] };
    }

    /// The glyph for `cp`, or 0 when unmapped.
    pub inline fn lookup(c: *const Cmap, cp: u21) GlyphId {
        if (cp < 256) return c.page0[cp];
        return c.lookupSlow(cp);
    }

    /// The uncached lookup (binary search in the subtable).
    pub fn lookupSlow(c: *const Cmap, cp: u21) GlyphId {
        var g = c.raw(cp);
        if (g == 0 and c.symbol and cp < 0x100) g = c.raw(0xF000 + cp);
        return if (g < c.num_glyphs) g else 0;
    }

    fn raw(c: *const Cmap, cp: u21) GlyphId {
        const s = c.sub;
        return switch (c.format) {
            0 => if (cp < 256) readAt(u8, s, 6 + @as(usize, cp)) catch 0 else 0,
            4 => format4(s, cp),
            6 => blk: {
                const first = readAt(u16, s, 6) catch break :blk 0;
                const count = readAt(u16, s, 8) catch break :blk 0;
                if (cp < first or cp - first >= count) break :blk 0;
                break :blk readAt(u16, s, 10 + @as(usize, cp - first) * 2) catch 0;
            },
            12, 13 => format12(s, cp, c.format == 13),
            else => 0,
        };
    }

    fn format4(s: []const u8, cp: u21) GlyphId {
        if (cp > 0xFFFF) return 0;
        const seg_x2 = readAt(u16, s, 6) catch return 0;
        const seg: usize = seg_x2 / 2;
        const ends = 14;
        const starts = 16 + @as(usize, seg_x2);
        const deltas = starts + seg_x2;
        const ranges = deltas + seg_x2;
        var lo: usize = 0;
        var hi: usize = seg;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const end = readAt(u16, s, ends + mid * 2) catch return 0;
            if (end < cp) lo = mid + 1 else hi = mid;
        }
        if (lo >= seg) return 0;
        const start = readAt(u16, s, starts + lo * 2) catch return 0;
        if (cp < start) return 0;
        const delta = readAt(u16, s, deltas + lo * 2) catch return 0;
        const ro = readAt(u16, s, ranges + lo * 2) catch return 0;
        if (ro == 0) return @truncate(cp +% delta);
        const addr = ranges + lo * 2 + ro + (cp - start) * 2;
        const g = readAt(u16, s, addr) catch return 0;
        if (g == 0) return 0;
        return g +% delta;
    }

    fn format12(s: []const u8, cp: u21, constant: bool) GlyphId {
        const n = readAt(u32, s, 12) catch return 0;
        const groups: usize = @min(n, (s.len -| 16) / 12);
        var lo: usize = 0;
        var hi: usize = groups;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const end = readAt(u32, s, 16 + mid * 12 + 4) catch return 0;
            if (end < cp) lo = mid + 1 else hi = mid;
        }
        if (lo >= groups) return 0;
        const g = 16 + lo * 12;
        const start = readAt(u32, s, g) catch return 0;
        const end = readAt(u32, s, g + 4) catch return 0;
        if (start > end or cp < start) return 0;
        const glyph = readAt(u32, s, g + 8) catch return 0;
        const id: u64 = if (constant) glyph else @as(u64, glyph) + (cp - start);
        return if (id > 0xFFFF) 0 else @intCast(id);
    }

    /// Looks up the variation sequence `cp` + `vs` in the format 14 table.
    pub fn lookupVariant(c: *const Cmap, cp: u21, vs: u21) VariantResult {
        const s = c.uvs orelse return .not_found;
        const n = readAt(u32, s, 6) catch return .not_found;
        const count: usize = @min(n, (s.len -| 10) / 11);
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const sel = readAt(u24, s, 10 + mid * 11) catch return .not_found;
            if (sel < vs) lo = mid + 1 else hi = mid;
        }
        if (lo >= count) return .not_found;
        const rec = 10 + lo * 11;
        if ((readAt(u24, s, rec) catch return .not_found) != vs) return .not_found;
        const def_off = readAt(u32, s, rec + 3) catch return .not_found;
        const nondef_off = readAt(u32, s, rec + 7) catch return .not_found;
        if (def_off != 0) if (inDefault(s, def_off, cp)) return .use_default;
        if (nondef_off != 0) if (nonDefault(s, nondef_off, cp)) |g| {
            return if (g < c.num_glyphs) .{ .glyph = g } else .not_found;
        };
        return .not_found;
    }

    fn inDefault(s: []const u8, off: u32, cp: u21) bool {
        const n = readAt(u32, s, off) catch return false;
        const count: usize = @min(n, (s.len -| (@as(usize, off) + 4)) / 4);
        var lo: usize = 0;
        var hi: usize = count;
        const base = @as(usize, off) + 4;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const start = readAt(u24, s, base + mid * 4) catch return false;
            const add = readAt(u8, s, base + mid * 4 + 3) catch return false;
            if (@as(u32, start) + add < cp) lo = mid + 1 else hi = mid;
        }
        if (lo >= count) return false;
        const start = readAt(u24, s, base + lo * 4) catch return false;
        return start <= cp;
    }

    fn nonDefault(s: []const u8, off: u32, cp: u21) ?GlyphId {
        const n = readAt(u32, s, off) catch return null;
        const count: usize = @min(n, (s.len -| (@as(usize, off) + 4)) / 5);
        const base = @as(usize, off) + 4;
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const u = readAt(u24, s, base + mid * 5) catch return null;
            if (u < cp) lo = mid + 1 else hi = mid;
        }
        if (lo >= count) return null;
        if ((readAt(u24, s, base + lo * 5) catch return null) != cp) return null;
        return readAt(u16, s, base + lo * 5 + 3) catch null;
    }

    /// Calls `cb(ctx, cp, gid)` for every mapped code point in ascending
    /// order. Out-of-order segments/groups are skipped, which bounds the walk
    /// to one pass over the code space even for hostile tables.
    pub fn forEachMapping(c: *const Cmap, ctx: anytype, comptime cb: fn (@TypeOf(ctx), u21, GlyphId) void) void {
        const s = c.sub;
        switch (c.format) {
            0, 6 => {
                var cp: u21 = 0;
                while (cp < 0x10000) : (cp += 1) {
                    const g = c.lookupSlow(cp);
                    if (g != 0) cb(ctx, cp, g);
                }
            },
            4 => {
                const seg_x2 = readAt(u16, s, 6) catch return;
                var next: u32 = 0;
                if (c.symbol) {
                    // Symbol fonts also answer for U+0000..U+00FF through U+F0xx.
                    var cp: u21 = 0;
                    while (cp < 0x100) : (cp += 1) {
                        const g = c.lookupSlow(cp);
                        if (g != 0) cb(ctx, cp, g);
                    }
                    next = 0x100;
                }
                for (0..seg_x2 / 2) |i| {
                    const end = readAt(u16, s, 14 + i * 2) catch return;
                    const start = readAt(u16, s, 16 + @as(usize, seg_x2) + i * 2) catch return;
                    if (start > end or start < next) continue;
                    var cp: u32 = start;
                    while (cp <= end and cp != 0xFFFF) : (cp += 1) {
                        const g = c.lookupSlow(@intCast(cp));
                        if (g != 0) cb(ctx, @intCast(cp), g);
                    }
                    next = @as(u32, end) + 1;
                }
            },
            12, 13 => {
                const n = readAt(u32, s, 12) catch return;
                const groups: usize = @min(n, (s.len -| 16) / 12);
                var next: u32 = 0;
                for (0..groups) |i| {
                    const start = readAt(u32, s, 16 + i * 12) catch return;
                    const end = @min(readAt(u32, s, 16 + i * 12 + 4) catch return, 0x10FFFF);
                    if (start > end or start < next) continue;
                    var cp = start;
                    while (cp <= end) : (cp += 1) {
                        const g = c.lookupSlow(@intCast(cp));
                        if (g != 0) cb(ctx, @intCast(cp), g);
                    }
                    next = end + 1;
                }
            },
            else => {},
        }
    }

    /// Mapped code points as merged ranges; free with `CoverageSet.deinit`.
    /// Well-ordered format 4, 12 and 13 subtables are read segment by
    /// segment; anything else goes through `coverageSlow`.
    pub fn coverage(c: *const Cmap, gpa: std.mem.Allocator) std.mem.Allocator.Error!CoverageSet {
        var acc: RangeAcc = .{ .gpa = gpa };
        errdefer acc.list.deinit(gpa);
        const fast = !c.symbol and switch (c.format) {
            4 => c.coverage4(&acc),
            12, 13 => c.coverage12(&acc),
            else => false,
        };
        if (!fast) {
            acc.list.deinit(gpa);
            return c.coverageSlow(gpa);
        }
        if (acc.failed) return error.OutOfMemory;
        return .{ .ranges = try acc.list.toOwnedSlice(gpa) };
    }

    /// `coverage` by looking up every code point of every segment (the
    /// reference the fast path is tested against).
    pub fn coverageSlow(c: *const Cmap, gpa: std.mem.Allocator) std.mem.Allocator.Error!CoverageSet {
        var acc: RangeAcc = .{ .gpa = gpa };
        errdefer acc.list.deinit(gpa);
        c.forEachMapping(&acc, RangeAcc.addOne);
        if (acc.failed) return error.OutOfMemory;
        return .{ .ranges = try acc.list.toOwnedSlice(gpa) };
    }

    /// Format 4 by segment; false (nothing added) when the segments are
    /// not ascending and disjoint, or the table is short.
    fn coverage4(c: *const Cmap, acc: *RangeAcc) bool {
        const s = c.sub;
        const seg_x2 = readAt(u16, s, 6) catch return false;
        const seg: usize = seg_x2 / 2;
        const ends = 14;
        const starts = 16 + @as(usize, seg_x2);
        const deltas = starts + seg_x2;
        const ranges = deltas + seg_x2;
        if (s.len < ranges + seg_x2) return false;
        var next: u32 = 0;
        for (0..seg) |i| {
            const end = readAt(u16, s, ends + i * 2) catch return false;
            const start = readAt(u16, s, starts + i * 2) catch return false;
            if (start > end or start < next) return false;
            next = @as(u32, end) + 1;
        }
        for (0..seg) |i| {
            const end: u32 = readAt(u16, s, ends + i * 2) catch unreachable;
            const start: u32 = readAt(u16, s, starts + i * 2) catch unreachable;
            const delta = readAt(u16, s, deltas + i * 2) catch unreachable;
            const ro = readAt(u16, s, ranges + i * 2) catch unreachable;
            var cp = start;
            while (cp <= end and cp != 0xFFFF) : (cp += 1) {
                const g: u16 = if (ro == 0) @truncate(cp +% delta) else blk: {
                    const raw_g = readAt(u16, s, ranges + i * 2 + ro + (cp - start) * 2) catch 0;
                    break :blk if (raw_g == 0) 0 else raw_g +% delta;
                };
                if (g != 0 and g < c.num_glyphs) acc.add(@intCast(cp), @intCast(cp));
            }
        }
        return true;
    }

    /// Formats 12 and 13 by group, in closed form; false when the groups
    /// are not ascending and disjoint.
    fn coverage12(c: *const Cmap, acc: *RangeAcc) bool {
        const s = c.sub;
        const n = readAt(u32, s, 12) catch return false;
        const groups: usize = @min(n, (s.len -| 16) / 12);
        var next: u64 = 0;
        for (0..groups) |i| {
            const start = readAt(u32, s, 16 + i * 12) catch return false;
            const end = readAt(u32, s, 16 + i * 12 + 4) catch return false;
            if (start > end or start < next) return false;
            next = @as(u64, end) + 1;
        }
        const ng: u64 = c.num_glyphs;
        for (0..groups) |i| {
            const start: u64 = readAt(u32, s, 16 + i * 12) catch unreachable;
            if (start > 0x10FFFF) break;
            const end: u64 = @min(readAt(u32, s, 16 + i * 12 + 4) catch unreachable, 0x10FFFF);
            const glyph: u64 = readAt(u32, s, 16 + i * 12 + 8) catch unreachable;
            if (c.format == 13) {
                if (glyph != 0 and glyph < ng) acc.add(@intCast(start), @intCast(end));
                continue;
            }
            // Glyph ids glyph + (cp - start), valid in [1, ng).
            if (glyph >= ng) continue;
            const lo = start + (if (glyph == 0) @as(u64, 1) else 0);
            const hi = @min(end, start + (ng - 1 - glyph));
            if (lo <= hi) acc.add(@intCast(lo), @intCast(hi));
        }
        return true;
    }
};

/// Accumulates ascending code point ranges, merging adjacent ones.
const RangeAcc = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList([2]u21) = .empty,
    failed: bool = false,

    fn add(self: *RangeAcc, lo: u21, hi: u21) void {
        if (self.failed) return;
        if (self.list.items.len > 0) {
            const last = &self.list.items[self.list.items.len - 1];
            if (@as(u32, last[1]) + 1 >= lo) {
                last[1] = @max(last[1], hi);
                return;
            }
        }
        self.list.append(self.gpa, .{ lo, hi }) catch {
            self.failed = true;
        };
    }

    fn addOne(self: *RangeAcc, cp: u21, _: GlyphId) void {
        if (self.list.items.len > 0 and self.list.items[self.list.items.len - 1][1] >= cp) return;
        self.add(cp, cp);
    }
};

/// Lazily built glyph ids for BMP pages (256 code points each). Pages are
/// published with a release store, so concurrent readers need no lock; a
/// page built twice by racing threads is freed by the loser.
pub const BmpPageCache = struct {
    pages: [256]?*const [256]GlyphId = @splat(null),
    gpa: std.mem.Allocator,

    /// An empty cache allocating pages from `gpa`.
    pub fn init(gpa: std.mem.Allocator) BmpPageCache {
        return .{ .gpa = gpa };
    }

    /// Frees every built page.
    pub fn deinit(pc: *BmpPageCache) void {
        for (&pc.pages) |*p| if (p.*) |page| {
            pc.gpa.destroy(page);
            p.* = null;
        };
    }

    /// The glyph for `cp`, building its page on first use.
    pub inline fn lookup(pc: *BmpPageCache, c: *const Cmap, cp: u21) GlyphId {
        if (cp >= 0x10000) return c.lookupSlow(cp);
        if (cp < 256) return c.page0[cp];
        const hi = cp >> 8;
        if (@atomicLoad(?*const [256]GlyphId, &pc.pages[hi], .acquire)) |page| return page[cp & 0xFF];
        return pc.build(c, cp);
    }

    fn build(pc: *BmpPageCache, c: *const Cmap, cp: u21) GlyphId {
        const page = pc.gpa.create([256]GlyphId) catch return c.lookupSlow(cp);
        const base = cp & 0xFF00;
        for (page, 0..) |*g, i| g.* = c.lookupSlow(@intCast(base + i));
        if (@cmpxchgStrong(?*const [256]GlyphId, &pc.pages[cp >> 8], null, page, .release, .acquire)) |winner| {
            pc.gpa.destroy(page);
            return winner.?[cp & 0xFF];
        }
        return page[cp & 0xFF];
    }
};

test {
    _ = @import("cmap_test.zig");
}
