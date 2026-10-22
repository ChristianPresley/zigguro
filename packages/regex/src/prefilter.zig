//! Prefilters: given the prefix literals every match starts with, find the
//! next position where a match can start. The meta engine skips to it while
//! the DFA is in a start state.
//!
//! Selection: one byte -> `memchr`; one literal -> `memmem`; up to three
//! distinct first bytes -> `memchr2/3` on first bytes; otherwise
//! Aho-Corasick. Searches over chunked inputs handle literals that straddle
//! a chunk boundary by stitching a small window across it.

const std = @import("std");
const input_mod = @import("input.zig");
pub const memchr = @import("prefilter/memchr.zig");
pub const memmem = @import("prefilter/memmem.zig");
pub const aho_corasick = @import("prefilter/aho_corasick.zig");

const Allocator = std.mem.Allocator;
const Input = input_mod.Input;

/// Literals longer than this are not used as prefilters (the stitched
/// window across chunk boundaries is a fixed stack buffer).
pub const max_literal = 256;

/// A prefilter over a set of non-empty prefix literals.
pub const Prefilter = struct {
    kind: union(enum) {
        byte1: u8,
        bytes2: [2]u8,
        bytes3: [3]u8,
        substring: memmem.Finder,
        ac: aho_corasick.AhoCorasick,
    },
    /// Owned copies of the literals.
    lits: []const []const u8,
    max_len: usize,

    /// Builds a prefilter, or null when the literal set is unsuitable
    /// (empty, or containing the empty string).
    pub fn init(gpa: Allocator, lits_in: []const []const u8) Allocator.Error!?Prefilter {
        if (lits_in.len == 0) return null;
        for (lits_in) |l| if (l.len == 0 or l.len > max_literal) return null;
        const lits = try gpa.alloc([]const u8, lits_in.len);
        var done: usize = 0;
        errdefer {
            for (lits[0..done]) |l| gpa.free(l);
            gpa.free(lits);
        }
        var max_len: usize = 0;
        for (lits_in, 0..) |l, i| {
            lits[i] = try gpa.dupe(u8, l);
            done += 1;
            max_len = @max(max_len, l.len);
        }
        var pf: Prefilter = .{ .kind = undefined, .lits = lits, .max_len = max_len };
        if (lits.len == 1) {
            pf.kind = if (lits[0].len == 1) .{ .byte1 = lits[0][0] } else .{ .substring = .init(lits[0]) };
            return pf;
        }
        // Distinct first bytes.
        var firsts: [3]u8 = undefined;
        var nf: usize = 0;
        for (lits) |l| {
            if (std.mem.indexOfScalar(u8, firsts[0..nf], l[0]) != null) continue;
            if (nf == 3) {
                nf = 4;
                break;
            }
            firsts[nf] = l[0];
            nf += 1;
        }
        pf.kind = switch (nf) {
            1 => .{ .byte1 = firsts[0] },
            2 => .{ .bytes2 = .{ firsts[0], firsts[1] } },
            3 => .{ .bytes3 = firsts },
            else => .{ .ac = try aho_corasick.AhoCorasick.init(gpa, lits) },
        };
        return pf;
    }

    /// Frees the prefilter.
    pub fn deinit(pf: *Prefilter, gpa: Allocator) void {
        switch (pf.kind) {
            .ac => |*ac| ac.deinit(gpa),
            else => {},
        }
        for (pf.lits) |l| gpa.free(l);
        gpa.free(pf.lits);
    }

    /// Next candidate start in a contiguous slice at `>= from`.
    pub fn findSlice(pf: *const Prefilter, hay: []const u8, from: usize) ?usize {
        return switch (pf.kind) {
            .byte1 => |b| memchr.memchr(b, hay, from),
            .bytes2 => |bs| memchr.memchr2(bs[0], bs[1], hay, from),
            .bytes3 => |bs| memchr.memchr3(bs[0], bs[1], bs[2], hay, from),
            .substring => |*f| f.find(hay, from),
            .ac => |*ac| ac.find(hay, from),
        };
    }

    /// Next candidate start in `in` at `>= from` and `< in.span.end`
    /// (candidates may extend past the span end; callers verify).
    pub fn find(pf: *const Prefilter, in: *const Input, from: u64) ?u64 {
        const end = in.span.end;
        if (from >= end) return null;
        if (in.asSlice()) |s| {
            const r = pf.findSlice(s[0..@intCast(end)], @intCast(from)) orelse return null;
            return r;
        }
        switch (pf.kind) {
            .ac => |*ac| {
                var st: aho_corasick.AhoCorasick.Stream = .{ .ac = ac };
                var pos = from;
                while (pos < end) {
                    const ch = in.chunkAt(pos);
                    const off: usize = @intCast(pos - ch.base);
                    const stop: usize = @intCast(@min(ch.end(), end) - ch.base);
                    if (st.feed(ch.bytes[off..stop], pos)) break;
                    pos = ch.base + stop;
                }
                return st.best;
            },
            else => {},
        }
        // Per-chunk search plus a stitched window across each boundary.
        var pos = from;
        var window: [2 * max_literal]u8 = undefined;
        while (pos < end) {
            const ch = in.chunkAt(pos);
            const off: usize = @intCast(pos - ch.base);
            const stop: usize = @intCast(@min(ch.end(), end) - ch.base);
            if (pf.findSlice(ch.bytes[0..stop], off)) |i| {
                // A candidate fully inside the chunk, or a first-byte
                // candidate (which only needs its first byte).
                if (ch.base + i + pf.needLen() <= ch.base + stop or pf.needLen() == 1) return ch.base + i;
                // Partial at the chunk end: verify through the window below.
            }
            const next = ch.base + stop;
            if (next >= end or pf.needLen() <= 1) {
                pos = next;
                continue;
            }
            // Window: up to needLen-1 bytes before the boundary, and as many after.
            const k: u64 = pf.needLen() - 1;
            const wstart = @max(pos, next -| k);
            const wend = @min(end, next + k);
            const wlen: usize = @intCast(wend - wstart);
            in.copyRange(.{ .start = wstart, .end = wend }, window[0..wlen]);
            var from_w: usize = 0;
            while (pf.findSlice(window[0..wlen], from_w)) |i| {
                if (wstart + i >= next) break; // starts in the next chunk: found by its own scan
                if (i + pf.needLen() <= wlen) return wstart + i;
                from_w = i + 1;
            }
            pos = next;
        }
        return null;
    }

    /// Bytes a `findSlice` hit needs inside the haystack to be complete.
    fn needLen(pf: *const Prefilter) usize {
        return switch (pf.kind) {
            .byte1, .bytes2, .bytes3 => 1,
            .substring => |f| f.needle.len,
            .ac => 1,
        };
    }
};

test "prefilter: chunked search matches the slice search" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(5);
    const rnd = prng.random();
    const sets = [_][]const []const u8{
        &.{"b"},
        &.{"abc"},
        &.{ "ab", "cd" },
        &.{ "ab", "ba", "ca" },
        &.{ "abc", "bcd", "cda", "dab" },
    };
    for (sets) |lits| {
        var pf = (try Prefilter.init(gpa, lits)).?;
        defer pf.deinit(gpa);
        for (0..200) |_| {
            var buf: [40]u8 = undefined;
            const n = rnd.intRangeAtMost(usize, 0, buf.len);
            for (buf[0..n]) |*b| b.* = rnd.intRangeAtMost(u8, 'a', 'd');
            const hay = buf[0..n];
            // Split into up to 4 chunks.
            var parts: [4][]const u8 = undefined;
            var cut = [_]usize{ rnd.intRangeAtMost(usize, 0, n), rnd.intRangeAtMost(usize, 0, n), rnd.intRangeAtMost(usize, 0, n) };
            std.mem.sort(usize, &cut, {}, std.sort.asc(usize));
            parts[0] = hay[0..cut[0]];
            parts[1] = hay[cut[0]..cut[1]];
            parts[2] = hay[cut[1]..cut[2]];
            parts[3] = hay[cut[2]..];
            var starts: [4]u64 = undefined;
            const sc = input_mod.SliceChunks.init(&parts, &starts);
            const chunked = Input.fromChunks(sc.source(), n);
            const flat = Input.fromSlice(hay);
            const from = rnd.intRangeAtMost(usize, 0, n);
            try std.testing.expectEqual(flat.chunkAt(0).bytes.len, n);
            try std.testing.expectEqual(pf.find(&flat, from), pf.find(&chunked, from));
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
