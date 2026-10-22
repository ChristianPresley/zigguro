//! The on-disk format of one commit index segment (`<checksum>.zgx`).
//!
//! A segment holds a contiguous run of index positions `[base, base+count)`
//! and names its parent segment (the one holding the positions below
//! `base`) by checksum, so a chain of segments covers `[0, total)`. Like
//! git's commit-graph, every column is fixed width, so `entry` is a few
//! loads with no parsing:
//!
//! ```
//! header (64 bytes)
//!   "ZGCX" | version u32 | base u32 | count u32 | overflow_len u32 |
//!   pred_len u32 | reserved u64 | parent checksum [32]u8 (zero: none)
//! ids          [count][32]u8
//! change_ids   [count][16]u8
//! time_ms      [count]i64    committer time
//! ctime        [count]u64    corrected commit time (generation v2)
//! level        [count]u32    topological level (generation v1)
//! parent1      [count]u32    none = 0xffffffff
//! parent2      [count]u32    none, a position, or 0x80000000 | index into
//!                            overflow (octopus merges, as git's EDGE chunk)
//! overflow     [overflow_len]u32  parents 2.. ; the last has 0x80000000 set
//! pred_offsets [count+1]u32  ranges into preds
//! preds        [pred_len]u32 predecessor positions
//! flags        [count]u16
//! id_fanout    [256]u32      ids sorted: counts by first byte, cumulative
//! id_prefix    [count]u64    first 8 id bytes, big-endian, sorted
//! id_pos       [count]u32    position of each sorted id
//! cid_fanout   [256]u32      the same for change ids, sorted by (cid, pos)
//! cid_prefix   [count]u64
//! cid_pos      [count]u32
//! checksum     [32]u8        BLAKE3 of everything above
//! ```
//!
//! Integers are little-endian and every column starts 8-byte aligned. The
//! bytes depend only on the entries and their order, so building the same
//! history in the same order gives the same file (and file name).

const std = @import("std");
const id_mod = @import("../store/id.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Blake3 = std.crypto.hash.Blake3;
const Allocator = std.mem.Allocator;

pub const magic = "ZGCX";
pub const format_version: u32 = 1;
pub const header_len = 64;
pub const checksum_len = 32;
/// No parent.
pub const none: u32 = 0xffff_ffff;
/// In `parent2`: the rest of the parents are in `overflow`. In `overflow`:
/// the last parent.
pub const overflow_bit: u32 = 0x8000_0000;
/// Positions must stay below this.
pub const max_positions: u32 = overflow_bit;

/// Per-entry flags.
pub const Flags = packed struct(u16) {
    /// The tree has unresolved merge terms.
    conflict: bool = false,
    /// The tree equals its single parent's (or the empty tree for a root).
    empty: bool = false,
    signed: bool = false,
    /// Carries a provenance manifest (an agent touched it).
    ai_touched: bool = false,
    /// More than one parent.
    merge: bool = false,
    _pad: u11 = 0,
};

/// One entry to write. Positions are global (they may point into parent
/// segments).
pub const NewEntry = struct {
    id: ObjectId,
    change_id: ChangeId,
    time_ms: i64,
    ctime: u64,
    level: u32,
    parents: []const u32,
    preds: []const u32,
    flags: Flags,
};

/// The big-endian value of the first 8 bytes: compares like the bytes.
pub fn prefix64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

fn pad8(n: usize) usize {
    return std.mem.alignForward(usize, n, 8);
}

/// Byte offsets of every column, from the counts.
pub const Layout = struct {
    ids: usize,
    change_ids: usize,
    time_ms: usize,
    ctime: usize,
    level: usize,
    parent1: usize,
    parent2: usize,
    overflow: usize,
    pred_offsets: usize,
    preds: usize,
    flags: usize,
    id_fanout: usize,
    id_prefix: usize,
    id_pos: usize,
    cid_fanout: usize,
    cid_prefix: usize,
    cid_pos: usize,
    checksum: usize,
    total: usize,

    pub fn of(count: usize, overflow_len: usize, pred_len: usize) Layout {
        var l: Layout = undefined;
        var off: usize = header_len;
        inline for (.{
            .{ "ids", 32 * count },
            .{ "change_ids", 16 * count },
            .{ "time_ms", 8 * count },
            .{ "ctime", 8 * count },
            .{ "level", 4 * count },
            .{ "parent1", 4 * count },
            .{ "parent2", 4 * count },
            .{ "overflow", 4 * overflow_len },
            .{ "pred_offsets", 4 * (count + 1) },
            .{ "preds", 4 * pred_len },
            .{ "flags", 2 * count },
            .{ "id_fanout", 4 * 256 },
            .{ "id_prefix", 8 * count },
            .{ "id_pos", 4 * count },
            .{ "cid_fanout", 4 * 256 },
            .{ "cid_prefix", 8 * count },
            .{ "cid_pos", 4 * count },
        }) |c| {
            @field(l, c[0]) = off;
            off = pad8(off + c[1]);
        }
        l.checksum = off;
        l.total = off + checksum_len;
        return l;
    }
};

/// Serializes `entries` as a segment starting at position `base`. The
/// result (allocated with `gpa`) ends with its checksum.
pub fn write(gpa: Allocator, base: u32, parent: ?[checksum_len]u8, entries: []const NewEntry) ![]u8 {
    const n = entries.len;
    if (@as(u64, base) + n > max_positions) return error.TooManyCommits;
    var overflow_len: usize = 0;
    var pred_len: usize = 0;
    for (entries) |e| {
        if (e.parents.len > 2) overflow_len += e.parents.len - 1;
        pred_len += e.preds.len;
    }
    const l = Layout.of(n, overflow_len, pred_len);
    const out = try gpa.alloc(u8, l.total);
    errdefer gpa.free(out);
    @memset(out, 0);

    @memcpy(out[0..4], magic);
    std.mem.writeInt(u32, out[4..8], format_version, .little);
    std.mem.writeInt(u32, out[8..12], base, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(n), .little);
    std.mem.writeInt(u32, out[16..20], @intCast(overflow_len), .little);
    std.mem.writeInt(u32, out[20..24], @intCast(pred_len), .little);
    if (parent) |p| @memcpy(out[32..64], &p);

    var ov: usize = 0;
    var pr: usize = 0;
    for (entries, 0..) |e, i| {
        @memcpy(out[l.ids + 32 * i ..][0..32], &e.id.bytes);
        @memcpy(out[l.change_ids + 16 * i ..][0..16], &e.change_id.bytes);
        std.mem.writeInt(i64, out[l.time_ms + 8 * i ..][0..8], e.time_ms, .little);
        std.mem.writeInt(u64, out[l.ctime + 8 * i ..][0..8], e.ctime, .little);
        std.mem.writeInt(u32, out[l.level + 4 * i ..][0..4], e.level, .little);
        const p1: u32 = if (e.parents.len > 0) e.parents[0] else none;
        const p2: u32 = switch (e.parents.len) {
            0, 1 => none,
            2 => e.parents[1],
            else => overflow_bit | @as(u32, @intCast(ov)),
        };
        std.mem.writeInt(u32, out[l.parent1 + 4 * i ..][0..4], p1, .little);
        std.mem.writeInt(u32, out[l.parent2 + 4 * i ..][0..4], p2, .little);
        if (e.parents.len > 2) {
            for (e.parents[1..], 1..) |p, k| {
                const last = k == e.parents.len - 1;
                std.mem.writeInt(u32, out[l.overflow + 4 * ov ..][0..4], if (last) p | overflow_bit else p, .little);
                ov += 1;
            }
        }
        std.mem.writeInt(u32, out[l.pred_offsets + 4 * i ..][0..4], @intCast(pr), .little);
        for (e.preds) |p| {
            std.mem.writeInt(u32, out[l.preds + 4 * pr ..][0..4], p, .little);
            pr += 1;
        }
        std.mem.writeInt(u16, out[l.flags + 2 * i ..][0..2], @bitCast(e.flags), .little);
    }
    std.mem.writeInt(u32, out[l.pred_offsets + 4 * n ..][0..4], @intCast(pr), .little);

    // Sorted lookup tables.
    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Sort = struct {
        entries: []const NewEntry,
        fn byId(c: @This(), a: u32, b: u32) bool {
            return std.mem.order(u8, &c.entries[a].id.bytes, &c.entries[b].id.bytes) == .lt;
        }
        fn byCid(c: @This(), a: u32, b: u32) bool {
            return switch (std.mem.order(u8, &c.entries[a].change_id.bytes, &c.entries[b].change_id.bytes)) {
                .lt => true,
                .gt => false,
                .eq => a < b,
            };
        }
    };
    std.mem.sort(u32, order, Sort{ .entries = entries }, Sort.byId);
    writeTable(out, l.id_fanout, l.id_prefix, l.id_pos, base, entries, order, .id);
    std.mem.sort(u32, order, Sort{ .entries = entries }, Sort.byCid);
    writeTable(out, l.cid_fanout, l.cid_prefix, l.cid_pos, base, entries, order, .change_id);

    Blake3.hash(out[0..l.checksum], out[l.checksum..][0..checksum_len], .{});
    return out;
}

fn writeTable(out: []u8, fanout: usize, prefixes: usize, positions: usize, base: u32, entries: []const NewEntry, order: []const u32, comptime field: enum { id, change_id }) void {
    var counts: [256]u32 = @splat(0);
    for (order, 0..) |o, k| {
        const bytes: []const u8 = &@field(entries[o], @tagName(field)).bytes;
        counts[bytes[0]] += 1;
        std.mem.writeInt(u64, out[prefixes + 8 * k ..][0..8], prefix64(bytes), .little);
        std.mem.writeInt(u32, out[positions + 4 * k ..][0..4], base + o, .little);
    }
    var sum: u32 = 0;
    for (counts, 0..) |c, b| {
        sum += c;
        std.mem.writeInt(u32, out[fanout + 4 * b ..][0..4], sum, .little);
    }
}

/// A parsed segment over bytes the caller keeps alive. `parse` checks the
/// structure (sizes, fanouts) but not the checksum: see `verify`.
pub const Segment = struct {
    bytes: []const u8,
    base: u32,
    count: u32,
    overflow_len: u32,
    pred_len: u32,
    layout: Layout,

    pub const ParseError = error{CorruptIndex};

    pub fn parse(bytes: []const u8) ParseError!Segment {
        if (bytes.len < header_len + checksum_len) return error.CorruptIndex;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.CorruptIndex;
        if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) return error.CorruptIndex;
        const base = std.mem.readInt(u32, bytes[8..12], .little);
        const count = std.mem.readInt(u32, bytes[12..16], .little);
        const overflow_len = std.mem.readInt(u32, bytes[16..20], .little);
        const pred_len = std.mem.readInt(u32, bytes[20..24], .little);
        if (@as(u64, base) + count > max_positions) return error.CorruptIndex;
        if (count > bytes.len or overflow_len > bytes.len or pred_len > bytes.len) return error.CorruptIndex;
        const l = Layout.of(count, overflow_len, pred_len);
        if (l.total != bytes.len) return error.CorruptIndex;
        const s: Segment = .{ .bytes = bytes, .base = base, .count = count, .overflow_len = overflow_len, .pred_len = pred_len, .layout = l };
        if (s.u32At(l.id_fanout, 255) != count or s.u32At(l.cid_fanout, 255) != count) return error.CorruptIndex;
        if (s.u32At(l.pred_offsets, count) != pred_len) return error.CorruptIndex;
        return s;
    }

    /// The parent segment's checksum, or null for the first segment.
    pub fn parent(s: *const Segment) ?[checksum_len]u8 {
        const p = s.bytes[32..64];
        if (std.mem.allEqual(u8, p, 0)) return null;
        return p.*;
    }

    pub fn checksum(s: *const Segment) [checksum_len]u8 {
        return s.bytes[s.layout.checksum..][0..checksum_len].*;
    }

    /// Re-hashes the file and checks every position it stores is in range
    /// (fsck; too slow for open on big indexes).
    pub fn verify(s: *const Segment) bool {
        var h: [checksum_len]u8 = undefined;
        Blake3.hash(s.bytes[0..s.layout.checksum], &h, .{});
        if (!std.mem.eql(u8, &h, s.bytes[s.layout.checksum..])) return false;
        for (0..s.count) |k| {
            const i: u32 = @intCast(k);
            const pos = s.base + i;
            var it = s.parents(i);
            while (it.next()) |p| if (p >= pos) return false;
            const lo = s.u32At(s.layout.pred_offsets, i);
            const hi = s.u32At(s.layout.pred_offsets, i + 1);
            if (lo > hi or hi > s.pred_len) return false;
            for (lo..hi) |j| if (s.u32At(s.layout.preds, @intCast(j)) >= pos) return false;
            if (s.u32At(s.layout.id_pos, i) -% s.base >= s.count) return false;
            if (s.u32At(s.layout.cid_pos, i) -% s.base >= s.count) return false;
        }
        for (1..s.count) |k| {
            const a = s.idAt(s.u32At(s.layout.id_pos, @intCast(k - 1)) - s.base);
            const b = s.idAt(s.u32At(s.layout.id_pos, @intCast(k)) - s.base);
            if (std.mem.order(u8, &a.bytes, &b.bytes) != .lt) return false;
        }
        return true;
    }

    pub inline fn u32At(s: *const Segment, col: usize, i: u32) u32 {
        return std.mem.readInt(u32, s.bytes[col + 4 * @as(usize, i) ..][0..4], .little);
    }

    pub inline fn u64At(s: *const Segment, col: usize, i: u32) u64 {
        return std.mem.readInt(u64, s.bytes[col + 8 * @as(usize, i) ..][0..8], .little);
    }

    /// `i` is local (position - base).
    pub inline fn idAt(s: *const Segment, i: u32) ObjectId {
        return .{ .bytes = s.bytes[s.layout.ids + 32 * @as(usize, i) ..][0..32].* };
    }

    pub inline fn changeIdAt(s: *const Segment, i: u32) ChangeId {
        return .{ .bytes = s.bytes[s.layout.change_ids + 16 * @as(usize, i) ..][0..16].* };
    }

    pub inline fn timeAt(s: *const Segment, i: u32) i64 {
        return @bitCast(s.u64At(s.layout.time_ms, i));
    }

    pub inline fn ctimeAt(s: *const Segment, i: u32) u64 {
        return s.u64At(s.layout.ctime, i);
    }

    pub inline fn levelAt(s: *const Segment, i: u32) u32 {
        return s.u32At(s.layout.level, i);
    }

    pub inline fn flagsAt(s: *const Segment, i: u32) Flags {
        return @bitCast(std.mem.readInt(u16, s.bytes[s.layout.flags + 2 * @as(usize, i) ..][0..2], .little));
    }

    /// The parents of local entry `i` as global positions.
    pub fn parents(s: *const Segment, i: u32) PosIter {
        const p1 = s.u32At(s.layout.parent1, i);
        const p2 = s.u32At(s.layout.parent2, i);
        if (p1 == none) return .{};
        if (p2 == none) return .{ .first = .{ p1, 0 }, .n_first = 1 };
        if (p2 & overflow_bit == 0) return .{ .first = .{ p1, p2 }, .n_first = 2 };
        const start = p2 & ~overflow_bit;
        if (start >= s.overflow_len) return .{ .first = .{ p1, 0 }, .n_first = 1 };
        return .{ .first = .{ p1, 0 }, .n_first = 1, .rest = s.bytes[s.layout.overflow + 4 * @as(usize, start) .. s.layout.overflow + 4 * @as(usize, s.overflow_len)], .terminated = true };
    }

    /// The predecessors of local entry `i` as global positions.
    pub fn preds(s: *const Segment, i: u32) PosIter {
        const lo = s.u32At(s.layout.pred_offsets, i);
        const hi = @min(s.u32At(s.layout.pred_offsets, i + 1), s.pred_len);
        if (lo >= hi) return .{};
        return .{ .rest = s.bytes[s.layout.preds + 4 * @as(usize, lo) ..][0 .. 4 * @as(usize, hi - lo)] };
    }

    /// The local index of `id`, if this segment has it.
    pub fn find(s: *const Segment, id: ObjectId) ?u32 {
        var k = s.lowerBound(s.layout.id_fanout, s.layout.id_prefix, id.bytes[0], prefix64(&id.bytes));
        while (k < s.count and s.u64At(s.layout.id_prefix, k) == prefix64(&id.bytes)) : (k += 1) {
            const local = s.u32At(s.layout.id_pos, k) -% s.base;
            if (local < s.count and s.idAt(local).eql(id)) return local;
        }
        return null;
    }

    /// The first sorted slot whose prefix is >= `key` (first byte `b`).
    pub fn lowerBound(s: *const Segment, fanout: usize, prefixes: usize, b: u8, key: u64) u32 {
        var lo: u32 = if (b == 0) 0 else s.u32At(fanout, b - 1);
        var hi: u32 = s.u32At(fanout, b);
        if (hi > s.count) hi = s.count;
        if (lo > hi) lo = hi;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (s.u64At(prefixes, mid) < key) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Local indexes of every entry with change ID `cid`, ascending.
    pub fn findChange(s: *const Segment, cid: ChangeId, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
        var k = s.lowerBound(s.layout.cid_fanout, s.layout.cid_prefix, cid.bytes[0], prefix64(&cid.bytes));
        while (k < s.count and s.u64At(s.layout.cid_prefix, k) == prefix64(&cid.bytes)) : (k += 1) {
            const local = s.u32At(s.layout.cid_pos, k) -% s.base;
            if (local < s.count and s.changeIdAt(local).eql(cid)) try out.append(gpa, local);
        }
    }
};

/// A short list of positions: up to two inline, the rest little-endian in
/// the mapped file.
pub const PosIter = struct {
    first: [2]u32 = .{ 0, 0 },
    n_first: u2 = 0,
    rest: []const u8 = &.{},
    /// `rest` ends at the entry with `overflow_bit` set.
    terminated: bool = false,
    i: u32 = 0,

    pub fn next(it: *PosIter) ?u32 {
        if (it.i < it.n_first) {
            it.i += 1;
            return it.first[it.i - 1];
        }
        const k = 4 * @as(usize, it.i - it.n_first);
        if (k + 4 > it.rest.len) return null;
        const v = std.mem.readInt(u32, it.rest[k..][0..4], .little);
        it.i += 1;
        if (it.terminated and v & overflow_bit != 0) {
            it.rest = it.rest[0 .. k + 4];
            return v & ~overflow_bit;
        }
        return v;
    }

    /// The number of positions (walks octopus overflow lists).
    pub fn len(it: PosIter) u32 {
        var c = it;
        c.i = 0;
        var n: u32 = 0;
        while (c.next()) |_| n += 1;
        return n;
    }
};

test "index segment: write, parse, lookups" {
    const t = std.testing;
    const gpa = t.allocator;
    var entries: [5]NewEntry = undefined;
    for (&entries, 0..) |*e, i| {
        e.* = .{
            .id = id_mod.hashObject(.blob, &.{@intCast(i)}),
            .change_id = .{ .bytes = @splat(@intCast(i % 3)) },
            .time_ms = @intCast(1000 * i),
            .ctime = 1000 * i,
            .level = @intCast(i + 1),
            .parents = &.{},
            .preds = &.{},
            .flags = .{ .empty = i == 0 },
        };
    }
    entries[1].parents = &.{10};
    entries[2].parents = &.{ 10, 11 };
    entries[3].parents = &.{ 10, 11, 12, 6 };
    entries[4].preds = &.{ 11, 13 };
    const bytes = try write(gpa, 10, null, &entries);
    defer gpa.free(bytes);
    const s = try Segment.parse(bytes);
    try t.expect(s.verify());
    try t.expectEqual(@as(?[32]u8, null), s.parent());
    for (entries, 0..) |e, i| {
        try t.expectEqual(@as(?u32, @intCast(i)), s.find(e.id));
        var it = s.parents(@intCast(i));
        for (e.parents) |p| try t.expectEqual(@as(?u32, p), it.next());
        try t.expectEqual(@as(?u32, null), it.next());
        var pi = s.preds(@intCast(i));
        for (e.preds) |p| try t.expectEqual(@as(?u32, p), pi.next());
        try t.expectEqual(@as(?u32, null), pi.next());
        try t.expectEqual(e.level, s.levelAt(@intCast(i)));
        try t.expectEqual(e.flags, s.flagsAt(@intCast(i)));
    }
    try t.expectEqual(@as(u32, 4), s.parents(3).len());
    try t.expectEqual(@as(?u32, null), s.find(id_mod.hashObject(.blob, "x")));
    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(gpa);
    try s.findChange(.{ .bytes = @splat(1) }, &hits, gpa);
    try t.expectEqualSlices(u32, &.{ 1, 4 }, hits.items);

    // Deterministic, and any flipped byte is caught by verify.
    const again = try write(gpa, 10, null, &entries);
    defer gpa.free(again);
    try t.expectEqualSlices(u8, bytes, again);
    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    bad[header_len + 3] ^= 1;
    try t.expect(!(try Segment.parse(bad)).verify());
    try t.expectError(error.CorruptIndex, Segment.parse(bytes[0 .. bytes.len - 1]));
}
