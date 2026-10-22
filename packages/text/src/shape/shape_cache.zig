//! Word-level shape cache. When no enabled lookup can see the space glyph
//! (`ShapePlan.space_participates == false`), a run shapes the same as the
//! concatenation of its words, so each word (with its trailing spaces) is
//! shaped once and reused. Otherwise the whole run is the cache key.
//!
//! Entries are evicted by CLOCK under a byte budget; the hash index is
//! sized up front so a warm cache does not allocate on lookups.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const Tag = ot.Tag;
const GlyphId = ot.GlyphId;
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const Script = @import("../unicode/root.zig").Script;
const buffer = @import("buffer.zig");
const Direction = buffer.Direction;
const Feature = buffer.Feature;
const shaper_mod = @import("shaper.zig");
const Shaper = shaper_mod.Shaper;
const GlyphRun = shaper_mod.GlyphRun;

/// Identifies one shaped string.
pub const ShapeKey = struct {
    inst: u18,
    script: Script,
    dir: Direction,
    /// Caller-assigned id of the feature list.
    feature_set: u16,
    text_hash: u64,
    len: u32,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: ShapeKey) u64 {
        return k.text_hash ^ (@as(u64, k.inst) << 40 | @as(u64, k.feature_set) << 20 | @as(u64, @intFromEnum(k.script)) << 2 | @intFromEnum(k.dir)) *% 0x9E3779B97F4A7C15;
    }
    pub fn eql(_: KeyContext, a: ShapeKey, b: ShapeKey) bool {
        return a.text_hash == b.text_hash and a.len == b.len and a.inst == b.inst and a.feature_set == b.feature_set and a.script == b.script and a.dir == b.dir;
    }
};

const Entry = struct {
    key: ShapeKey,
    run: GlyphRun = .{},
    used: bool = false,
    referenced: bool = false,
};

/// Bytes one cached glyph costs.
const glyph_bytes = @sizeOf(GlyphId) + 4 * @sizeOf(i32) + @sizeOf(bool);

/// The cache. Owned by one thread (the render thread).
pub const ShapeCache = struct {
    gpa: Allocator,
    entries: []Entry,
    index: std.HashMapUnmanaged(ShapeKey, u32, KeyContext, 80) = .empty,
    hand: usize = 0,
    bytes: usize = 0,
    budget: usize,
    hits: u64 = 0,
    misses: u64 = 0,

    pub const Options = struct {
        max_entries: u32 = 8192,
        budget_bytes: usize = 4 << 20,
    };

    /// An empty cache with room for `opts.max_entries` runs.
    pub fn init(gpa: Allocator, opts: Options) Allocator.Error!ShapeCache {
        const entries = try gpa.alloc(Entry, @max(1, opts.max_entries));
        errdefer gpa.free(entries);
        for (entries) |*e| e.* = .{ .key = undefined };
        var c: ShapeCache = .{ .gpa = gpa, .entries = entries, .budget = opts.budget_bytes };
        try c.index.ensureTotalCapacity(gpa, @intCast(entries.len));
        return c;
    }

    /// Frees every entry.
    pub fn deinit(c: *ShapeCache) void {
        c.clear();
        c.index.deinit(c.gpa);
        c.gpa.free(c.entries);
        c.* = undefined;
    }

    /// Drops every entry.
    pub fn clear(c: *ShapeCache) void {
        for (c.entries) |*e| if (e.used) c.release(e);
        c.index.clearRetainingCapacity();
        c.bytes = 0;
    }

    /// Number of cached runs.
    pub fn count(c: *const ShapeCache) usize {
        return c.index.count();
    }

    /// The cached run for `key`.
    pub fn get(c: *ShapeCache, key: ShapeKey) ?*const GlyphRun {
        const slot = c.index.get(key) orelse {
            c.misses += 1;
            return null;
        };
        c.hits += 1;
        const e = &c.entries[slot];
        e.referenced = true;
        return &e.run;
    }

    /// Stores a copy of `run` under `key`, evicting as needed. A run larger
    /// than the whole budget is not cached.
    pub fn put(c: *ShapeCache, key: ShapeKey, run: GlyphRun) Allocator.Error!void {
        const size = run.len() * glyph_bytes;
        if (size > c.budget) return;
        if (c.index.contains(key)) return;
        const slot = c.makeRoom(size);
        const e = &c.entries[slot];
        var copy = try GlyphRun.alloc(c.gpa, run.len());
        @memcpy(copy.gids, run.gids);
        @memcpy(copy.clusters, run.clusters);
        @memcpy(copy.x_adv, run.x_adv);
        @memcpy(copy.x_off, run.x_off);
        @memcpy(copy.y_off, run.y_off);
        @memcpy(copy.unsafe_to_break, run.unsafe_to_break);
        _ = &copy;
        e.* = .{ .key = key, .run = copy, .used = true, .referenced = false };
        c.bytes += size;
        c.index.putAssumeCapacity(key, @intCast(slot));
    }

    /// Returns a free slot after evicting until `size` more bytes fit.
    fn makeRoom(c: *ShapeCache, size: usize) usize {
        var free: ?usize = null;
        while (true) {
            if (free == null) {
                if (c.index.count() < c.entries.len) {
                    // A free slot exists somewhere; the hand finds it.
                    for (0..c.entries.len) |_| {
                        if (!c.entries[c.hand].used) {
                            free = c.hand;
                            break;
                        }
                        c.hand = (c.hand + 1) % c.entries.len;
                    }
                }
            }
            if (free != null and c.bytes + size <= c.budget) return free.?;
            // CLOCK: skip (and clear) referenced entries, evict the first
            // unreferenced one.
            const e = &c.entries[c.hand];
            if (e.used) {
                if (e.referenced) {
                    e.referenced = false;
                } else {
                    _ = c.index.remove(e.key);
                    c.bytes -= e.run.len() * glyph_bytes;
                    c.release(e);
                    if (free == null) free = c.hand;
                }
            }
            c.hand = (c.hand + 1) % c.entries.len;
        }
    }

    fn release(c: *ShapeCache, e: *Entry) void {
        const r = e.run;
        c.gpa.free(r.gids);
        c.gpa.free(r.clusters);
        c.gpa.free(r.x_adv);
        c.gpa.free(r.x_off);
        c.gpa.free(r.y_off);
        c.gpa.free(r.unsafe_to_break);
        e.* = .{ .key = undefined };
    }
};

/// The end of the word starting at `start`: past its trailing spaces, at a
/// point where the next byte starts an ASCII non-space character (so no
/// mark or joiner continues across it).
pub fn wordEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and text[i] != ' ') i += 1;
    while (i < text.len) {
        while (i < text.len and text[i] == ' ') i += 1;
        if (i >= text.len) return i;
        if (text[i] < 0x80) return i;
        // A non-ASCII character after the spaces may be a mark: keep going.
        while (i < text.len and text[i] != ' ') i += 1;
    }
    return i;
}

/// A `GlyphRun` grown in an arena.
const RunBuilder = struct {
    arena: Allocator,
    run: GlyphRun,
    len: usize = 0,

    fn init(arena: Allocator, cap: usize) Allocator.Error!RunBuilder {
        return .{ .arena = arena, .run = try GlyphRun.alloc(arena, cap) };
    }

    fn append(b: *RunBuilder, src: GlyphRun, offset: u32) Allocator.Error!void {
        const n = src.len();
        if (b.len + n > b.run.len()) {
            var bigger = try GlyphRun.alloc(b.arena, @max(b.len + n, b.run.len() * 2));
            copyInto(&bigger, 0, b.run, b.len, 0);
            b.run = bigger;
        }
        copyInto(&b.run, b.len, src, n, offset);
        b.len += n;
    }

    fn copyInto(dst: *GlyphRun, at: usize, src: GlyphRun, n: usize, offset: u32) void {
        @memcpy(dst.gids[at..][0..n], src.gids[0..n]);
        for (dst.clusters[at..][0..n], src.clusters[0..n]) |*d, cl| d.* = cl + offset;
        @memcpy(dst.x_adv[at..][0..n], src.x_adv[0..n]);
        @memcpy(dst.x_off[at..][0..n], src.x_off[0..n]);
        @memcpy(dst.y_off[at..][0..n], src.y_off[0..n]);
        @memcpy(dst.unsafe_to_break[at..][0..n], src.unsafe_to_break[0..n]);
    }

    fn finish(b: *RunBuilder) GlyphRun {
        return .{
            .gids = b.run.gids[0..b.len],
            .clusters = b.run.clusters[0..b.len],
            .x_adv = b.run.x_adv[0..b.len],
            .x_off = b.run.x_off[0..b.len],
            .y_off = b.run.y_off[0..b.len],
            .unsafe_to_break = b.run.unsafe_to_break[0..b.len],
        };
    }
};

fn reverseSoa(r: GlyphRun, start: usize, end: usize) void {
    std.mem.reverse(GlyphId, r.gids[start..end]);
    std.mem.reverse(u32, r.clusters[start..end]);
    std.mem.reverse(i32, r.x_adv[start..end]);
    std.mem.reverse(i32, r.x_off[start..end]);
    std.mem.reverse(i32, r.y_off[start..end]);
    std.mem.reverse(bool, r.unsafe_to_break[start..end]);
}

/// Shapes `text` like `Shaper.shape`, serving words (or the whole run when
/// the space glyph participates in lookups) from `cache`. `inst_id` and
/// `feature_set` identify the instance and feature list in cache keys.
pub fn shapeCached(s: *Shaper, cache: *ShapeCache, inst: *const FaceInstance, inst_id: u18, feature_set: u16, text: []const u8, script: Script, dir: Direction, lang: Tag, features: []const Feature, out: *GlyphRun, arena: Allocator) Allocator.Error!void {
    const p = try s.plan(inst, script, lang, dir, features);
    // Ranged features address bytes of the whole run, and fraction masks
    // reach across spaces; both shape the run as one piece.
    const whole = p.space_participates or p.ranged.len != 0 or
        (p.has_frac and std.mem.indexOf(u8, text, "\u{2044}") != null);
    var b = try RunBuilder.init(arena, text.len + 8);
    // Glyph start of each word, for RTL reordering.
    var starts_buf: [128]usize = undefined;
    var starts: std.ArrayList(usize) = .initBuffer(&starts_buf);
    var start: usize = 0;
    while (start < text.len) {
        const end = if (whole) text.len else wordEnd(text, start);
        const seg = text[start..end];
        const key: ShapeKey = .{ .inst = inst_id, .script = script, .dir = dir, .feature_set = feature_set, .text_hash = std.hash.XxHash3.hash(0, seg), .len = @intCast(seg.len) };
        if (dir == .rtl) {
            if (starts.items.len == starts.capacity) {
                var bigger: std.ArrayList(usize) = try .initCapacity(arena, starts.capacity * 2);
                bigger.appendSliceAssumeCapacity(starts.items);
                starts = bigger;
            }
            starts.appendAssumeCapacity(b.len);
        }
        if (cache.get(key)) |r| {
            try b.append(r.*, @intCast(start));
        } else {
            try s.shapeWithPlan(p, seg);
            const run = try s.collect(arena);
            try cache.put(key, run);
            try b.append(run, @intCast(start));
        }
        start = end;
    }
    const r = b.finish();
    if (dir == .rtl and starts.items.len > 1) {
        // Words were appended in logical order; RTL output is visual, so
        // reverse the word order and keep each word's glyph order.
        var k = starts.items.len;
        var end = r.len();
        while (k > 0) {
            k -= 1;
            reverseSoa(r, starts.items[k], end);
            end = starts.items[k];
        }
        reverseSoa(r, 0, r.len());
    }
    out.* = r;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "shape cache: word ends" {
    const t = "ab  cd e\u{301} \u{301}x  ";
    try testing.expectEqual(@as(usize, 4), wordEnd(t, 0));
    try testing.expectEqual(@as(usize, 7), wordEnd(t, 4));
    // The space before a combining mark does not end the word.
    try testing.expectEqual(t.len, wordEnd(t, 7));
}

fn testRun(gpa: Allocator, n: usize, seed: u16) !GlyphRun {
    var r = try GlyphRun.alloc(gpa, n);
    for (0..n) |i| {
        r.gids[i] = seed + @as(u16, @intCast(i));
        r.clusters[i] = @intCast(i);
        r.x_adv[i] = 500;
        r.x_off[i] = 0;
        r.y_off[i] = 0;
        r.unsafe_to_break[i] = false;
    }
    return r;
}

test "shape cache: eviction under budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = try ShapeCache.init(testing.allocator, .{ .max_entries = 16, .budget_bytes = 10 * 4 * glyph_bytes });
    defer c.deinit();
    for (0..30) |i| {
        const key: ShapeKey = .{ .inst = 1, .script = .Latn, .dir = .ltr, .feature_set = 0, .text_hash = i, .len = 4 };
        try c.put(key, try testRun(arena.allocator(), 4, @intCast(i)));
        try testing.expect(c.bytes <= c.budget);
        try testing.expect(c.count() <= 10);
        // The newest entry is always present.
        try testing.expectEqual(@as(u16, @intCast(i)), c.get(key).?.gids[0]);
    }
    // A run bigger than the budget is skipped.
    try c.put(.{ .inst = 1, .script = .Latn, .dir = .ltr, .feature_set = 0, .text_hash = 999, .len = 1 }, try testRun(arena.allocator(), 100, 0));
    try testing.expect(c.get(.{ .inst = 1, .script = .Latn, .dir = .ltr, .feature_set = 0, .text_hash = 999, .len = 1 }) == null);
    // Referenced entries survive a sweep that evicts others.
    const keep: ShapeKey = .{ .inst = 1, .script = .Latn, .dir = .ltr, .feature_set = 0, .text_hash = 29, .len = 4 };
    for (30..36) |i| {
        _ = c.get(keep);
        try c.put(.{ .inst = 1, .script = .Latn, .dir = .ltr, .feature_set = 0, .text_hash = i, .len = 4 }, try testRun(arena.allocator(), 4, 0));
    }
    try testing.expect(c.get(keep) != null);
}
