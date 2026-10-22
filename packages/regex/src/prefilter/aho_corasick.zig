//! Aho-Corasick multi-literal search, used as the prefilter for large
//! literal sets (workspace multi-pattern search) and alternations.
//!
//! The automaton is a full DFA over byte classes (bytes that occur in no
//! literal share class 0), so each byte costs one table load. As a
//! prefilter it reports the leftmost *start* of any occurrence: after the
//! first hit it keeps scanning for `max_len - 1` more bytes, because an
//! occurrence starting earlier can end at most that much later.
//! It is a streaming matcher, so chunked haystacks are fed chunk by chunk.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A built automaton.
pub const AhoCorasick = struct {
    /// `stride` entries per state.
    delta: []u32,
    /// Length of the longest literal that is a suffix of each state, or 0.
    out_len: []u32,
    classes: [256]u8,
    stride: usize,
    max_len: usize,
    min_len: usize,
    count: usize,

    /// Builds the automaton for `lits` (non-empty, each non-empty).
    pub fn init(gpa: Allocator, lits: []const []const u8) Allocator.Error!AhoCorasick {
        std.debug.assert(lits.len > 0);
        var classes: [256]u8 = @splat(0);
        var used: [256]bool = @splat(false);
        var max_len: usize = 0;
        var min_len: usize = std.math.maxInt(usize);
        for (lits) |l| {
            std.debug.assert(l.len > 0);
            for (l) |b| used[b] = true;
            max_len = @max(max_len, l.len);
            min_len = @min(min_len, l.len);
        }
        var k: u8 = 1;
        for (0..256) |b| if (used[b]) {
            classes[b] = k;
            k += 1;
        };
        const stride: usize = k;

        // Trie.
        var trie: std.ArrayList(u32) = .empty; // stride entries per state, 0 = none (root never a child)
        defer trie.deinit(gpa);
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(gpa);
        try trie.appendNTimes(gpa, 0, stride);
        try out.append(gpa, 0);
        for (lits) |l| {
            var s: usize = 0;
            for (l) |b| {
                const c = classes[b];
                const nxt = trie.items[s * stride + c];
                if (nxt != 0) {
                    s = nxt;
                } else {
                    const id: u32 = @intCast(out.items.len);
                    try trie.appendNTimes(gpa, 0, stride);
                    try out.append(gpa, 0);
                    trie.items[s * stride + c] = id;
                    s = id;
                }
            }
            out.items[s] = @max(out.items[s], @as(u32, @intCast(l.len)));
        }
        const n = out.items.len;
        const delta = try gpa.alloc(u32, n * stride);
        errdefer gpa.free(delta);
        const fail = try gpa.alloc(u32, n);
        defer gpa.free(fail);
        const out_len = try gpa.alloc(u32, n);
        errdefer gpa.free(out_len);
        @memcpy(out_len, out.items);

        // BFS: delta(s, c) = child or delta(fail(s), c).
        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(gpa);
        fail[0] = 0;
        for (0..stride) |c| {
            const child = trie.items[c];
            delta[c] = child;
            if (child != 0) {
                fail[child] = 0;
                try queue.append(gpa, child);
            }
        }
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const s = queue.items[qi];
            out_len[s] = @max(out_len[s], out_len[fail[s]]);
            for (0..stride) |c| {
                const child = trie.items[s * stride + c];
                if (child != 0) {
                    fail[child] = delta[fail[s] * stride + c];
                    delta[s * stride + c] = child;
                    try queue.append(gpa, child);
                } else {
                    delta[s * stride + c] = delta[fail[s] * stride + c];
                }
            }
        }
        return .{ .delta = delta, .out_len = out_len, .classes = classes, .stride = stride, .max_len = max_len, .min_len = min_len, .count = lits.len };
    }

    /// Frees the automaton.
    pub fn deinit(ac: *AhoCorasick, gpa: Allocator) void {
        gpa.free(ac.delta);
        gpa.free(ac.out_len);
    }

    /// A streaming search for the leftmost occurrence start at `>= from`.
    pub const Stream = struct {
        ac: *const AhoCorasick,
        state: u32 = 0,
        best: ?u64 = null,

        /// Feeds `bytes` (absolute offset `base`); returns true once the
        /// result is final.
        pub fn feed(st: *Stream, bytes: []const u8, base: u64) bool {
            const ac = st.ac;
            var s = st.state;
            for (bytes, 0..) |b, i| {
                const pos = base + i;
                if (st.best) |best| if (pos + 1 > best + ac.max_len - 1) {
                    st.state = s;
                    return true;
                };
                s = ac.delta[s * ac.stride + ac.classes[b]];
                const l = ac.out_len[s];
                if (l != 0) {
                    const start = pos + 1 - l;
                    if (st.best == null or start < st.best.?) st.best = start;
                }
            }
            st.state = s;
            return false;
        }
    };

    /// The leftmost start of any occurrence in `hay[from..]`.
    pub fn find(ac: *const AhoCorasick, hay: []const u8, from: usize) ?usize {
        var st: Stream = .{ .ac = ac };
        _ = st.feed(hay[from..], from);
        return if (st.best) |b| @intCast(b) else null;
    }
};

test "aho_corasick: leftmost start against brute force" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(3);
    const rnd = prng.random();
    for (0..300) |_| {
        var lit_bufs: [6][5]u8 = undefined;
        var lits: [6][]const u8 = undefined;
        const nl = rnd.intRangeAtMost(usize, 1, 6);
        for (0..nl) |i| {
            const len = rnd.intRangeAtMost(usize, 1, 5);
            for (lit_bufs[i][0..len]) |*b| b.* = rnd.intRangeAtMost(u8, 'a', 'c');
            lits[i] = lit_bufs[i][0..len];
        }
        var ac = try AhoCorasick.init(gpa, lits[0..nl]);
        defer ac.deinit(gpa);
        var hay_buf: [60]u8 = undefined;
        const hn = rnd.intRangeAtMost(usize, 0, hay_buf.len);
        for (hay_buf[0..hn]) |*b| b.* = rnd.intRangeAtMost(u8, 'a', 'd');
        const hay = hay_buf[0..hn];
        const from = rnd.intRangeAtMost(usize, 0, hn);
        var want: ?usize = null;
        for (from..hn + 1) |s| {
            for (lits[0..nl]) |l| if (std.mem.startsWith(u8, hay[s..], l)) {
                want = s;
                break;
            };
            if (want != null) break;
        }
        try std.testing.expectEqual(want, ac.find(hay, from));
    }
}
