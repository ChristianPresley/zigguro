//! Fingerprint search: the prefilter for literal sets too large for
//! `memchr2/3`, in place of Aho-Corasick. Aho-Corasick's next state
//! depends on the previous one, so each byte waits for a table load; this
//! filter tests every position independently, so the loads overlap.
//!
//! Each literal is reduced to a fingerprint of its first `k` bytes (`k` is
//! the shortest literal's length, at most 3), and the fingerprints are set
//! in a 64 Ki-bit table: two bytes index it directly, three are hashed to
//! 16 bits. A position whose next `k` bytes hit a set bit is a candidate.
//! Like Teddy (Hyperscan's packed search) the result is a superset of the
//! literal starts that the caller verifies; with at most `max_lits`
//! fingerprints a hash collision passes about one position in a thousand.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Most literals (distinct fingerprints) a `Packed` takes.
pub const max_lits = 64;
/// Most distinct leading pairs for testing the pair table first.
const max_pair_first = 12;

pub const Packed = struct {
    k: u8,
    /// 64 Ki bits, one per fingerprint key.
    bits: *[1024]u64,
    /// With `k == 3`: the first two bytes of each fingerprint, a cheaper
    /// first test (no hash) that most positions fail.
    pairs: *[1024]u64,
    /// Test the pairs first: worth it while few distinct pairs make a
    /// pair hit rare (`regex.teddy_8`); with more, the branch on a pair
    /// hit mispredicts and hashing every position is faster
    /// (`regex.literal_alt_20`).
    pair_first: bool,

    /// The fingerprint search for `lits`, or null when there are more
    /// than `max_lits` of them or one is shorter than 2 bytes.
    pub fn init(gpa: Allocator, lits: []const []const u8) Allocator.Error!?Packed {
        if (lits.len == 0 or lits.len > max_lits) return null;
        var min_len: usize = std.math.maxInt(usize);
        for (lits) |l| min_len = @min(min_len, l.len);
        if (min_len < 2) return null;
        const tables = try gpa.create([2][1024]u64);
        var p: Packed = .{ .k = @intCast(@min(min_len, 3)), .bits = &tables[0], .pairs = &tables[1], .pair_first = false };
        p.bits.* = @splat(0);
        p.pairs.* = @splat(0);
        for (lits) |l| {
            setBit(p.bits, p.keyOf(l[0..p.k]));
            setBit(p.pairs, std.mem.readInt(u16, l[0..2], .little));
        }
        var n_pairs: usize = 0;
        for (p.pairs) |w| n_pairs += @popCount(w);
        p.pair_first = n_pairs <= max_pair_first;
        return p;
    }

    pub fn deinit(p: *Packed, gpa: Allocator) void {
        const tables: *[2][1024]u64 = @ptrCast(p.bits);
        gpa.destroy(tables);
    }

    fn setBit(t: *[1024]u64, key: u16) void {
        t[key >> 6] |= @as(u64, 1) << @intCast(key & 63);
    }

    inline fn hash3(w: u32) u16 {
        return @truncate((w & 0xFF_FFFF) *% 0x9E37_79B1 >> 16);
    }

    fn keyOf(p: *const Packed, fp: []const u8) u16 {
        return if (p.k == 2) std.mem.readInt(u16, fp[0..2], .little) else hash3(@as(u32, fp[0]) | @as(u32, fp[1]) << 8 | @as(u32, fp[2]) << 16);
    }

    inline fn hit(p: *const Packed, key: u16) bool {
        return test_(p.bits, key);
    }

    inline fn test_(t: *const [1024]u64, key: u16) bool {
        return t[key >> 6] >> @intCast(key & 63) & 1 != 0;
    }

    /// The first `i >= from` whose next `k` bytes (all inside `hay`) hit
    /// a fingerprint, or null.
    pub fn find(p: *const Packed, hay: []const u8, from: usize) ?usize {
        var i = from;
        if (p.k == 2) {
            while (i + 2 <= hay.len) : (i += 1) {
                if (p.hit(std.mem.readInt(u16, hay[i..][0..2], .little))) return i;
            }
            return null;
        }
        if (p.pair_first) {
            // Most positions stop at the pair table.
            while (i + 4 <= hay.len) : (i += 1) {
                if (!test_(p.pairs, std.mem.readInt(u16, hay[i..][0..2], .little))) continue;
                if (p.hit(hash3(std.mem.readInt(u32, hay[i..][0..4], .little)))) return i;
            }
        } else {
            // Four positions per step, each from its own 4-byte load.
            while (i + 7 <= hay.len) : (i += 4) {
                const h0 = p.hit(hash3(std.mem.readInt(u32, hay[i..][0..4], .little)));
                const h1 = p.hit(hash3(std.mem.readInt(u32, hay[i + 1 ..][0..4], .little)));
                const h2 = p.hit(hash3(std.mem.readInt(u32, hay[i + 2 ..][0..4], .little)));
                const h3 = p.hit(hash3(std.mem.readInt(u32, hay[i + 3 ..][0..4], .little)));
                if (h0 or h1 or h2 or h3) return if (h0) i else if (h1) i + 1 else if (h2) i + 2 else i + 3;
            }
        }
        while (i + 3 <= hay.len) : (i += 1) {
            if (p.hit(p.keyOf(hay[i..][0..3]))) return i;
        }
        return null;
    }
};

test "packed: finds every fingerprint and nothing earlier than a scalar scan" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(11);
    const rnd = prng.random();
    var store: [max_lits][5]u8 = undefined;
    var lits: [max_lits][]const u8 = undefined;
    var buf: [200]u8 = undefined;
    for (0..400) |_| {
        const n = rnd.intRangeAtMost(usize, 1, 30);
        for (0..n) |j| {
            const len = rnd.intRangeAtMost(usize, 2, 5);
            for (store[j][0..len]) |*b| b.* = "abcdef"[rnd.uintLessThan(usize, 6)];
            lits[j] = store[j][0..len];
        }
        var p = (try Packed.init(gpa, lits[0..n])).?;
        defer p.deinit(gpa);
        const h = rnd.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..h]) |*b| b.* = "abcdefgh"[rnd.uintLessThan(usize, 8)];
        const hay = buf[0..h];
        const from = rnd.intRangeAtMost(usize, 0, h);
        // The first position where some literal's first k bytes occur.
        var want: ?usize = null;
        outer: for (from..h) |i| {
            for (lits[0..n]) |l| {
                if (i + p.k <= h and std.mem.eql(u8, hay[i..][0..p.k], l[0..p.k])) {
                    want = i;
                    break :outer;
                }
            }
        }
        const got = p.find(hay, from);
        if (want) |w| {
            // A hash collision may report an earlier position, never a later one.
            try std.testing.expect(got != null and got.? <= w);
        }
        if (got) |g| try std.testing.expect(g >= from and g + p.k <= h);
        if (p.k == 2) try std.testing.expectEqual(want, got);
    }
}

test "packed: refuses short literals and too many literals" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try Packed.init(gpa, &.{ "ab", "c" }) == null);
    var store: [max_lits + 1][3]u8 = undefined;
    var lits: [max_lits + 1][]const u8 = undefined;
    for (&store, 0..) |*s, j| {
        s.* = .{ 'a', @intCast('0' + j), 'z' };
        lits[j] = s;
    }
    var p = (try Packed.init(gpa, lits[0..max_lits])).?;
    p.deinit(gpa);
    try std.testing.expect(try Packed.init(gpa, &lits) == null);
}
