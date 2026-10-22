//! Substring search with a SIMD "packed pair" filter: pick the two rarest
//! bytes of the needle (by a static frequency rank), compare 32 haystack
//! positions at once on both, and verify only the lanes where both match.
//! On text the filter rarely fires, so throughput approaches `memchr`.

const std = @import("std");
const memchr = @import("memchr.zig");

const V = 32;
const Vec = @Vector(V, u8);
const Mask = std.meta.Int(.unsigned, V);

/// Approximate frequency rank of each byte in text and code (higher = more
/// common). Only the order matters. Later groups override earlier ones.
const ranks: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*r, b| r.* = if (b >= 0x80) 60 else 20;
    const groups = .{
        .{ "!#$%&+?@\\^`|~\r", 100 },
        .{ "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 130 },
        .{ "xjqz{}[]/*:'<>", 140 },
        .{ "0123456789", 160 },
        .{ "TSAICERNOMPLD", 170 },
        .{ "vk()_=;\"\t-", 190 },
        .{ "fpgwyb,.\n", 210 },
        .{ "hldcum", 225 },
        .{ "taoinsr", 240 },
        .{ "e", 250 },
        .{ " ", 255 },
    };
    for (groups) |g| for (g[0]) |c| {
        t[c] = g[1];
    };
    break :blk t;
};

fn rank(b: u8) u8 {
    return ranks[b];
}

/// A prepared needle.
pub const Finder = struct {
    needle: []const u8,
    off1: usize,
    off2: usize,

    /// Prepares `needle` (borrowed; must outlive the finder).
    pub fn init(needle: []const u8) Finder {
        var off1: usize = 0;
        var off2: usize = 0;
        if (needle.len >= 2) {
            // Rarest position, then the rarest other position.
            for (needle, 0..) |b, i| if (rank(b) < rank(needle[off1])) {
                off1 = i;
            };
            off2 = if (off1 == 0) 1 else 0;
            for (needle, 0..) |b, i| if (i != off1 and rank(b) < rank(needle[off2])) {
                off2 = i;
            };
            if (off2 < off1) std.mem.swap(usize, &off1, &off2);
        }
        return .{ .needle = needle, .off1 = off1, .off2 = off2 };
    }

    /// The first occurrence starting at `>= from`, or null.
    pub fn find(f: *const Finder, hay: []const u8, from: usize) ?usize {
        const n = f.needle;
        if (n.len == 0) return if (from <= hay.len) from else null;
        if (n.len > hay.len) return null;
        if (n.len == 1) return memchr.memchr(n[0], hay, from);
        const last_start = hay.len - n.len;
        var p = from;
        const v1: Vec = @splat(n[f.off1]);
        const v2: Vec = @splat(n[f.off2]);
        // Vector loop: lanes are candidate starts p..p+V-1.
        while (p + V - 1 <= last_start) : (p += V) {
            const a: Vec = hay[p + f.off1 ..][0..V].*;
            const b: Vec = hay[p + f.off2 ..][0..V].*;
            var m: Mask = @as(Mask, @bitCast(a == v1)) & @as(Mask, @bitCast(b == v2));
            while (m != 0) {
                const k = @ctz(m);
                const s = p + k;
                if (std.mem.eql(u8, hay[s..][0..n.len], n)) return s;
                m &= m - 1;
            }
        }
        while (p <= last_start) : (p += 1) {
            if (hay[p + f.off1] == n[f.off1] and hay[p + f.off2] == n[f.off2] and std.mem.eql(u8, hay[p..][0..n.len], n)) return p;
        }
        return null;
    }
};

test "memmem: agrees with std.mem.indexOfPos" {
    var prng: std.Random.DefaultPrng = .init(11);
    const rnd = prng.random();
    var hay_buf: [400]u8 = undefined;
    var needle_buf: [12]u8 = undefined;
    for (0..2000) |_| {
        const hn = rnd.intRangeAtMost(usize, 0, hay_buf.len);
        for (hay_buf[0..hn]) |*b| b.* = rnd.intRangeAtMost(u8, 'a', 'd');
        const nn = rnd.intRangeAtMost(usize, 0, needle_buf.len);
        for (needle_buf[0..nn]) |*b| b.* = rnd.intRangeAtMost(u8, 'a', 'd');
        const hay = hay_buf[0..hn];
        const needle = needle_buf[0..nn];
        const from = rnd.intRangeAtMost(usize, 0, hn);
        const f = Finder.init(needle);
        try std.testing.expectEqual(std.mem.indexOfPos(u8, hay, from, needle), f.find(hay, from));
    }
}
