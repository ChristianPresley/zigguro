//! A one-shot zlib/DEFLATE encoder (RFC 1950, RFC 1951) for whole
//! buffers, as loose objects and pack entries are written. It replaces
//! `std.compress.flate.Compress` there, whose per-stream setup and
//! streaming matcher kept loose encoding under half its budget (#731).
//!
//! Design, after zlib and miniz:
//! - LZ77 over the whole input with hash chains (4-byte hash, a 32 KiB
//!   ring of previous positions) and zlib's matching parameters (`good`,
//!   `nice`, `lazy`, `chain`: `std.compress.flate.Compress.Options`, so
//!   levels mean the same thing); `lazy == 0` matches greedily;
//! - matches extended 8 bytes at a time;
//! - blocks of up to 16 Ki symbols, each written as whichever of stored,
//!   fixed or dynamic Huffman is smallest; dynamic codes are built with
//!   Moffat-Katajainen and limited to 15 (7) bits as miniz does;
//! - bits gathered in a 64-bit buffer and stored four bytes at a time.
//!
//! The output is a valid zlib stream; it need not match zlib's bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Options = std.compress.flate.Compress.Options;
const adler32 = @import("inflate.zig").adler32;

const window_size = 32768;
const window_mask = window_size - 1;
const min_match = 4;
const max_match = 258;
const hash_bits = 15;
const block_symbols = 16384;

/// Compresses `data` as one zlib stream appended to `out`.
pub fn zlibDeflate(gpa: Allocator, out: *std.ArrayList(u8), data: []const u8, o: Options) Allocator.Error!void {
    const flg: u8 = if (o.lazy == 0) 0x01 else if (o.chain >= 256) 0xda else 0x9c;
    try out.appendSlice(gpa, &.{ 0x78, flg });
    try rawDeflate(gpa, out, data, o);
    var trailer: [4]u8 = undefined;
    std.mem.writeInt(u32, &trailer, adler32(data), .big);
    try out.appendSlice(gpa, &trailer);
}

/// Compresses `data` as raw DEFLATE blocks appended to `out`.
pub fn rawDeflate(gpa: Allocator, out: *std.ArrayList(u8), data: []const u8, o: Options) Allocator.Error!void {
    const st = try gpa.create(State);
    defer gpa.destroy(st);
    st.init(gpa, out, o);
    // Positions are u32: inputs past 1 GiB are matched in independent
    // segments.
    const seg_len: usize = 1 << 30;
    var start: usize = 0;
    while (true) {
        const end = @min(data.len, start + seg_len);
        try st.compress(data[start..end], end == data.len);
        if (end == data.len) break;
        start = end;
    }
    try st.bits.finish();
}

const State = struct {
    opts: Options,
    /// Most recent position + 1 for each hash, 0 for none.
    head: [1 << hash_bits]u32,
    /// The previous position + 1 with the same hash, by position mod
    /// the window.
    prev: [window_size]u32,
    /// Symbols of the current block: literal bytes (`dist == 0`) or
    /// matches (`ll` the length).
    ll: [block_symbols]u16,
    dist: [block_symbols]u16,
    n: usize,
    lit_freq: [286]u32,
    dist_freq: [30]u32,
    /// Extra bits of the block's lengths and distances.
    extra_bits: u64,
    bits: BitWriter,

    fn init(st: *State, gpa: Allocator, out: *std.ArrayList(u8), o: Options) void {
        st.opts = o;
        st.bits = .{ .gpa = gpa, .out = out };
        st.resetBlock();
    }

    fn resetBlock(st: *State) void {
        st.n = 0;
        @memset(&st.lit_freq, 0);
        @memset(&st.dist_freq, 0);
        st.extra_bits = 0;
    }

    inline fn literal(st: *State, c: u8) void {
        st.ll[st.n] = c;
        st.dist[st.n] = 0;
        st.n += 1;
        st.lit_freq[c] += 1;
    }

    inline fn match(st: *State, len: usize, d: usize) void {
        st.ll[st.n] = @intCast(len);
        st.dist[st.n] = @intCast(d);
        st.n += 1;
        const ls = len_sym[len];
        st.lit_freq[257 + @as(usize, ls)] += 1;
        const ds = distSym(d);
        st.dist_freq[ds] += 1;
        st.extra_bits += @as(u64, len_extra[ls]) + dist_extra[ds];
    }

    /// Matches and encodes `data`; `block_start` is where the current
    /// block's input begins.
    fn compress(st: *State, data: []const u8, final: bool) Allocator.Error!void {
        clear(&st.head);
        var block_start: usize = 0;
        var pos: usize = 0;
        const n = data.len;
        const o = st.opts;
        // Lazy matching state (zlib's deflate_slow).
        var prev_len: usize = 0;
        var prev_dist: usize = 0;
        var have_prev = false;
        while (pos < n) {
            if (st.n + 2 > block_symbols) {
                // Flush at a symbol boundary: the pending literal (if any)
                // is data[pos - 1] and stays in the next block.
                const cut = if (have_prev) pos - 1 else pos;
                if (have_prev) {
                    st.literal(data[pos - 1]);
                    have_prev = false;
                    try st.flush(data[block_start..pos], false);
                    block_start = pos;
                } else {
                    try st.flush(data[block_start..cut], false);
                    block_start = cut;
                }
                prev_len = 0;
            }
            var len: usize = 0;
            var dist: usize = 0;
            if (pos + min_match <= n) {
                const cand = st.insert(data, pos);
                if (cand != 0 and (o.lazy == 0 or prev_len < o.lazy)) {
                    const best_in = if (o.lazy == 0) min_match - 1 else @max(prev_len, min_match - 1);
                    const m = st.longest(data, pos, cand, best_in);
                    len = m.len;
                    dist = m.dist;
                }
            }
            if (o.lazy == 0) {
                if (len >= min_match) {
                    st.match(len, dist);
                    const end = pos + len;
                    if (len <= o.nice) {
                        var p = pos + 1;
                        while (p < end and p + min_match <= n) : (p += 1) _ = st.insert(data, p);
                    }
                    pos = end;
                } else {
                    st.literal(data[pos]);
                    pos += 1;
                }
                continue;
            }
            if (have_prev and prev_len >= min_match and len <= prev_len) {
                // The match at pos - 1 wins.
                st.match(prev_len, prev_dist);
                const end = pos - 1 + prev_len;
                var p = pos + 1;
                while (p < end and p + min_match <= n) : (p += 1) _ = st.insert(data, p);
                pos = end;
                have_prev = false;
                prev_len = 0;
            } else {
                if (have_prev) st.literal(data[pos - 1]);
                have_prev = true;
                prev_len = len;
                prev_dist = dist;
                pos += 1;
            }
        }
        if (have_prev) st.literal(data[n - 1]);
        try st.flush(data[block_start..n], final);
    }

    /// Hashes the 4 bytes at `pos` into the chains and returns the
    /// previous position + 1 with that hash (0: none).
    inline fn insert(st: *State, data: []const u8, pos: usize) u32 {
        const v = std.mem.readInt(u32, data[pos..][0..4], .little);
        const h = (v *% 0x9E3779B1) >> (32 - hash_bits);
        const cand = st.head[h];
        st.prev[pos & window_mask] = cand;
        st.head[h] = @intCast(pos + 1);
        return cand;
    }

    const Match = struct { len: usize, dist: usize };

    /// The longest match for `pos` longer than `best_in`, walking the
    /// chain from `first` (a position + 1, as the tables hold them).
    fn longest(st: *State, data: []const u8, pos: usize, first: u32, best_in: usize) Match {
        const o = st.opts;
        const max_len = @min(max_match, data.len - pos);
        const nice = @min(o.nice, max_len);
        var best = best_in;
        var best_dist: usize = 0;
        if (best >= max_len) return .{ .len = 0, .dist = 0 };
        var chain: usize = o.chain;
        if (best >= o.good) chain >>= 2;
        // Candidates (+ 1) below `lo` are out of the window, or none (0).
        // Each position's `prev` entry is its own while it is in the
        // window, and older than it.
        const lo: u32 = @intCast(if (pos + 1 > window_size) pos + 1 - window_size else 1);
        const here = std.mem.readInt(u32, data[pos..][0..4], .little);
        var c = first;
        while (c >= lo) {
            const cand = c - 1;
            // The last bytes a longer match needs, then the first ones.
            if (std.mem.readInt(u32, data[cand + best - 3 ..][0..4], .little) == std.mem.readInt(u32, data[pos + best - 3 ..][0..4], .little) and
                std.mem.readInt(u32, data[cand..][0..4], .little) == here)
            {
                const l = matchLen(data, cand, pos, max_len);
                if (l > best) {
                    best = l;
                    best_dist = pos - cand;
                    if (l >= nice) break;
                }
            }
            chain -= 1;
            if (chain == 0) break;
            c = st.prev[cand & window_mask];
        }
        if (best_dist == 0) return .{ .len = 0, .dist = 0 };
        return .{ .len = best, .dist = best_dist };
    }

    /// Encodes the block's symbols (covering input `raw`) in its cheapest
    /// form.
    fn flush(st: *State, raw: []const u8, final: bool) Allocator.Error!void {
        st.lit_freq[256] = 1;
        var lit_len: [286]u8 = undefined;
        var dist_len: [30]u8 = undefined;
        buildLengths(&st.lit_freq, &lit_len, 15);
        buildLengths(&st.dist_freq, &dist_len, 15);
        var hdr: DynHeader = undefined;
        hdr.build(&lit_len, &dist_len);

        var dyn_cost: u64 = hdr.cost + st.extra_bits;
        var fixed_cost: u64 = 3 + st.extra_bits;
        for (st.lit_freq, 0..) |f, s| {
            dyn_cost += @as(u64, f) * lit_len[s];
            fixed_cost += @as(u64, f) * fixed_lit_len[s];
        }
        for (st.dist_freq, 0..) |f, s| {
            dyn_cost += @as(u64, f) * dist_len[s];
            fixed_cost += @as(u64, f) * 5;
        }
        const chunks = @max(1, (raw.len + 65534) / 65535);
        const stored_cost: u64 = (@as(u64, raw.len) + 5 * chunks) * 8 + 7;

        const b = &st.bits;
        try b.reserve(@min(stored_cost, @min(dyn_cost, fixed_cost)) / 8 + 64);
        const fin: u64 = @intFromBool(final);
        if (stored_cost <= dyn_cost and stored_cost <= fixed_cost) {
            var rest = raw;
            while (true) {
                const k = @min(rest.len, 65535);
                const last = k == rest.len;
                b.put(@as(u64, @intFromBool(final and last)), 3);
                b.alignByte();
                const k16: u16 = @intCast(k);
                b.putBytes(&std.mem.toBytes(std.mem.nativeToLittle(u16, k16)));
                b.putBytes(&std.mem.toBytes(std.mem.nativeToLittle(u16, ~k16)));
                b.putBytes(rest[0..k]);
                rest = rest[k..];
                if (last) break;
            }
        } else if (fixed_cost <= dyn_cost) {
            b.put(fin | 1 << 1, 3);
            st.writeSymbols(&fixed_codes.lit, &fixed_lit_len, &fixed_codes.dist, &fixed_dist_len);
        } else {
            b.put(fin | 2 << 1, 3);
            hdr.write(b);
            var lc: [286]u16 = undefined;
            var dc: [30]u16 = undefined;
            canonical(&lit_len, &lc);
            canonical(&dist_len, &dc);
            st.writeSymbols(&lc, &lit_len, &dc, &dist_len);
        }
        st.resetBlock();
    }

    fn writeSymbols(st: *State, lc: []const u16, ll: []const u8, dc: []const u16, dl: []const u8) void {
        const b = &st.bits;
        for (st.ll[0..st.n], st.dist[0..st.n]) |v, d| {
            if (d == 0) {
                b.put(lc[v], ll[v]);
                continue;
            }
            const ls = len_sym[v];
            const s = 257 + @as(usize, ls);
            const le = len_extra[ls];
            b.put(@as(u64, lc[s]) | @as(u64, v - len_base[ls]) << @intCast(ll[s]), ll[s] + le);
            const ds = distSym(d);
            const de = dist_extra[ds];
            b.put(@as(u64, dc[ds]) | @as(u64, d - dist_base[ds]) << @intCast(dl[ds]), dl[ds] + de);
        }
        b.put(lc[256], ll[256]);
    }
};

/// Zeroes `t` with vector stores the optimizer leaves alone (it would turn
/// a plain loop into a call to compiler_rt's bytewise memset).
fn clear(t: *[1 << hash_bits]u32) void {
    const V = @Vector(16, u32);
    const p: [*]align(4) volatile V = @ptrCast(t);
    for (0..t.len / 16) |i| p[i] = @splat(0);
}

/// The length of the common prefix of `data[a..]` and `data[b..]`, up to
/// `max` (a < b).
inline fn matchLen(data: []const u8, a: usize, b: usize, max: usize) usize {
    var l: usize = 0;
    while (l + 8 <= max) {
        const x = std.mem.readInt(u64, data[a + l ..][0..8], .little);
        const y = std.mem.readInt(u64, data[b + l ..][0..8], .little);
        const diff = x ^ y;
        if (diff != 0) return l + @ctz(diff) / 8;
        l += 8;
    }
    while (l < max and data[a + l] == data[b + l]) l += 1;
    return l;
}

// ------------------------------------------------------------- bits out

const BitWriter = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    acc: u64 = 0,
    n: u7 = 0,

    /// Makes room for `bytes` more output bytes.
    fn reserve(b: *BitWriter, bytes: u64) Allocator.Error!void {
        try b.out.ensureUnusedCapacity(b.gpa, @intCast(bytes + 8));
    }

    /// Appends `nbits` (at most 32 with a pending count under 32) of `v`.
    inline fn put(b: *BitWriter, v: u64, nbits: u8) void {
        b.acc |= v << @intCast(b.n);
        b.n += @intCast(nbits);
        if (b.n >= 32) {
            const o = b.out;
            std.mem.writeInt(u32, o.unusedCapacitySlice()[0..4], @truncate(b.acc), .little);
            o.items.len += 4;
            b.acc >>= 32;
            b.n -= 32;
        }
    }

    fn alignByte(b: *BitWriter) void {
        while (b.n > 0) {
            b.out.appendAssumeCapacity(@truncate(b.acc));
            b.acc >>= 8;
            b.n -|= 8;
        }
        b.acc = 0;
    }

    fn putBytes(b: *BitWriter, bytes: []const u8) void {
        std.debug.assert(b.n == 0);
        b.out.appendSliceAssumeCapacity(bytes);
    }

    fn finish(b: *BitWriter) Allocator.Error!void {
        try b.reserve(8);
        b.alignByte();
    }
};

// -------------------------------------------------------------- huffman

/// Code lengths for `freq` (0 for unused symbols), at most `max_bits`.
/// At least two symbols get codes, as some decoders require.
fn buildLengths(freq: []const u32, lens: []u8, max_bits: u5) void {
    @memset(lens, 0);
    var syms: [286]SymFreq = undefined;
    var k: usize = 0;
    for (freq, 0..) |f, s| {
        if (f == 0) continue;
        syms[k] = .{ .freq = f, .sym = @intCast(s) };
        k += 1;
    }
    if (k < 2) {
        // One or no symbol: two one-bit codes.
        const first: usize = if (k == 1) syms[0].sym else 0;
        lens[first] = 1;
        lens[if (first == 0) 1 else 0] = 1;
        return;
    }
    const a = syms[0..k];
    std.mem.sort(SymFreq, a, {}, SymFreq.lessThan);
    var keys: [286]u32 = undefined;
    for (a, 0..) |x, i| keys[i] = x.freq;
    minimumRedundancy(keys[0..k]);
    // Count codes per length, folding lengths past the limit, then fix
    // the Kraft sum (miniz's tdefl_huffman_enforce_max_code_size).
    var num: [33]u32 = @splat(0);
    for (keys[0..k]) |l| num[@min(l, 32)] += 1;
    var i: usize = max_bits + 1;
    while (i <= 32) : (i += 1) {
        num[max_bits] += num[i];
        num[i] = 0;
    }
    var total: u64 = 0;
    i = max_bits;
    while (i > 0) : (i -= 1) total += @as(u64, num[i]) << @intCast(max_bits - i);
    while (total != @as(u64, 1) << max_bits) {
        num[max_bits] -= 1;
        i = max_bits - 1;
        while (i > 0) : (i -= 1) {
            if (num[i] != 0) {
                num[i] -= 1;
                num[i + 1] += 2;
                break;
            }
        }
        total -= 1;
    }
    // The most frequent symbols (at the end) get the shortest codes.
    var j = k;
    i = 1;
    while (i <= max_bits) : (i += 1) {
        var c = num[i];
        while (c > 0) : (c -= 1) {
            j -= 1;
            lens[a[j].sym] = @intCast(i);
        }
    }
}

const SymFreq = struct {
    freq: u32,
    sym: u16,

    fn lessThan(_: void, x: SymFreq, y: SymFreq) bool {
        return x.freq < y.freq or (x.freq == y.freq and x.sym < y.sym);
    }
};

/// In-place Moffat-Katajainen: `a` holds weights in ascending order and
/// gets the optimal code lengths.
fn minimumRedundancy(a: []u32) void {
    const n = a.len;
    if (n == 1) {
        a[0] = 1;
        return;
    }
    a[0] += a[1];
    var root: usize = 0;
    var leaf: usize = 2;
    var next: usize = 1;
    while (next < n - 1) : (next += 1) {
        if (leaf >= n or a[root] < a[leaf]) {
            a[next] = a[root];
            a[root] = @intCast(next);
            root += 1;
        } else {
            a[next] = a[leaf];
            leaf += 1;
        }
        if (leaf >= n or (root < next and a[root] < a[leaf])) {
            a[next] += a[root];
            a[root] = @intCast(next);
            root += 1;
        } else {
            a[next] += a[leaf];
            leaf += 1;
        }
    }
    a[n - 2] = 0;
    var t: isize = @as(isize, @intCast(n)) - 3;
    while (t >= 0) : (t -= 1) {
        const u: usize = @intCast(t);
        a[u] = a[a[u]] + 1;
    }
    var avbl: usize = 1;
    var used: usize = 0;
    var dpth: u32 = 0;
    var r: isize = @as(isize, @intCast(n)) - 2;
    var nx: isize = @as(isize, @intCast(n)) - 1;
    while (avbl > 0) {
        while (r >= 0 and a[@intCast(r)] == dpth) {
            used += 1;
            r -= 1;
        }
        while (avbl > used) {
            a[@intCast(nx)] = dpth;
            nx -= 1;
            avbl -= 1;
        }
        avbl = 2 * used;
        dpth += 1;
        used = 0;
    }
}

/// Canonical codes for `lens`, bit-reversed for LSB-first output.
fn canonical(lens: []const u8, codes: []u16) void {
    var count: [16]u16 = @splat(0);
    for (lens) |l| count[l] += 1;
    count[0] = 0;
    var next: [16]u16 = undefined;
    var code: u16 = 0;
    for (1..16) |l| {
        code = (code + count[l - 1]) << 1;
        next[l] = code;
    }
    for (lens, codes) |l, *c| {
        if (l == 0) {
            c.* = 0;
            continue;
        }
        c.* = @bitReverse(next[l]) >> @intCast(16 - @as(u5, @intCast(l)));
        next[l] += 1;
    }
}

const cl_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// A dynamic block's header: HLIT, HDIST, HCLEN and the run-length coded
/// code lengths.
const DynHeader = struct {
    hlit: usize,
    hdist: usize,
    hclen: usize,
    /// Code-length symbols with their repeat counts in the high byte.
    rle: [286 + 30]u16,
    rle_n: usize,
    cl_len: [19]u8,
    cl_code: [19]u16,
    cost: u64,

    fn build(h: *DynHeader, lit_len: []const u8, dist_len: []const u8) void {
        h.hlit = 286;
        while (h.hlit > 257 and lit_len[h.hlit - 1] == 0) h.hlit -= 1;
        h.hdist = 30;
        while (h.hdist > 1 and dist_len[h.hdist - 1] == 0) h.hdist -= 1;
        var all: [286 + 30]u8 = undefined;
        @memcpy(all[0..h.hlit], lit_len[0..h.hlit]);
        @memcpy(all[h.hlit..][0..h.hdist], dist_len[0..h.hdist]);
        const lens = all[0 .. h.hlit + h.hdist];
        var freq: [19]u32 = @splat(0);
        h.rle_n = 0;
        var extra: u64 = 0;
        var i: usize = 0;
        while (i < lens.len) {
            const l = lens[i];
            var run: usize = 1;
            while (i + run < lens.len and lens[i + run] == l) run += 1;
            i += run;
            if (l == 0) {
                while (run >= 11) {
                    const r = @min(run, 138);
                    h.emit(&freq, 18, r - 11);
                    extra += 7;
                    run -= r;
                }
                if (run >= 3) {
                    h.emit(&freq, 17, run - 3);
                    extra += 3;
                    run = 0;
                }
            } else {
                h.emit(&freq, l, 0);
                run -= 1;
                while (run >= 3) {
                    const r = @min(run, 6);
                    h.emit(&freq, 16, r - 3);
                    extra += 2;
                    run -= r;
                }
            }
            while (run > 0) : (run -= 1) h.emit(&freq, l, 0);
        }
        buildLengths(&freq, &h.cl_len, 7);
        canonical(&h.cl_len, &h.cl_code);
        h.hclen = 19;
        while (h.hclen > 4 and h.cl_len[cl_order[h.hclen - 1]] == 0) h.hclen -= 1;
        h.cost = 5 + 5 + 4 + 3 * @as(u64, h.hclen) + extra;
        for (freq, h.cl_len) |f, l| h.cost += @as(u64, f) * l;
    }

    fn emit(h: *DynHeader, freq: *[19]u32, sym: u8, rep: usize) void {
        h.rle[h.rle_n] = @as(u16, sym) | @as(u16, @intCast(rep)) << 8;
        h.rle_n += 1;
        freq[sym] += 1;
    }

    fn write(h: *const DynHeader, b: *BitWriter) void {
        b.put(h.hlit - 257, 5);
        b.put(h.hdist - 1, 5);
        b.put(h.hclen - 4, 4);
        for (cl_order[0..h.hclen]) |s| b.put(h.cl_len[s], 3);
        for (h.rle[0..h.rle_n]) |e| {
            const s: u8 = @truncate(e);
            const rep: u64 = e >> 8;
            b.put(h.cl_code[s], h.cl_len[s]);
            switch (s) {
                16 => b.put(rep, 2),
                17 => b.put(rep, 3),
                18 => b.put(rep, 7),
                else => {},
            }
        }
    }
};

// --------------------------------------------------------------- tables

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

/// Length 3..258 to its length symbol index (0..28).
const len_sym: [259]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [259]u8 = @splat(0);
    for (0..29) |s| {
        const top = if (s == 28) 259 else len_base[s] + (1 << len_extra[s]);
        for (len_base[s]..top) |l| t[l] = s;
    }
    t[258] = 28;
    break :blk t;
};

/// Distance symbols: distances 1..256 directly, larger ones by
/// (d - 1) >> 7.
const dist_small: [256]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]u8 = undefined;
    for (1..257) |d| t[d - 1] = distSymSlow(d);
    break :blk t;
};
const dist_large: [256]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = distSymSlow(@max(257, (i << 7) + 1));
    break :blk t;
};

fn distSymSlow(d: usize) u8 {
    var s: u8 = 29;
    while (dist_base[s] > d) s -= 1;
    return s;
}

inline fn distSym(d: usize) u8 {
    return if (d <= 256) dist_small[d - 1] else dist_large[(d - 1) >> 7];
}

/// The fixed literal/length code has 288 symbols (286 and 287 unused but
/// counted when assigning codes).
const fixed_lit_len_all: [288]u8 = blk: {
    var t: [288]u8 = undefined;
    for (&t, 0..) |*l, s| l.* = if (s < 144) 8 else if (s < 256) 9 else if (s < 280) 7 else 8;
    break :blk t;
};
const fixed_lit_len: [286]u8 = fixed_lit_len_all[0..286].*;
const fixed_dist_len: [30]u8 = @splat(5);
const fixed_codes: struct { lit: [286]u16, dist: [30]u16 } = blk: {
    @setEvalBranchQuota(100_000);
    var lit: [288]u16 = undefined;
    var dist: [30]u16 = undefined;
    canonical(&fixed_lit_len_all, &lit);
    canonical(&fixed_dist_len, &dist);
    const l = lit[0..286].*;
    const d = dist;
    break :blk .{ .lit = l, .dist = d };
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const inflate = @import("inflate.zig");
const flate = std.compress.flate;

fn roundtrip(data: []const u8, o: Options) !usize {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try zlibDeflate(gpa, &out, data, o);
    // Our decoder.
    const back = try gpa.alloc(u8, data.len);
    defer gpa.free(back);
    const r = try inflate.zlibInflate(out.items, back, .exact);
    try testing.expectEqual(out.items.len, r.consumed);
    try testing.expectEqualSlices(u8, data, back);
    // std's decoder.
    var in: std.Io.Reader = .fixed(out.items);
    var buf: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&in, .zlib, &buf);
    const got = try dec.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, data, got);
    return out.items.len;
}

const levels = [_]Options{ .level_1, .level_2, .level_3, .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };

test "deflate: roundtrips text, random, runs and edge sizes at every level" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..4000) |i| try text.print(gpa, "fn f{d}(x: u32) u32 {{ return x * {d}; }}\n", .{ i, r.int(u16) });
    const noise = try gpa.alloc(u8, 200_000);
    defer gpa.free(noise);
    r.bytes(noise);
    const run = try gpa.alloc(u8, 100_000);
    defer gpa.free(run);
    @memset(run, 'a');
    const cases = [_][]const u8{ "", "a", "abc", "abcd", "abcabcabcabc", text.items, noise, run, noise[0..70_000] };
    for (levels) |o| for (cases) |c| {
        _ = try roundtrip(c, o);
    };
    // Random data is stored (barely larger), runs compress hugely.
    try testing.expect(try roundtrip(noise, .default) < noise.len + noise.len / 100);
    try testing.expect(try roundtrip(run, .default) < 1000);
}

test "deflate: within a few percent of std's size" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const words = [_][]const u8{ "const", "var", "return", "if", "else", "while", "for", "try", "self", "data", "len", "pos", "u32", "usize", "=", "+", "(", ")", "{", "}", ";", ".", "," };
    for (0..20_000) |i| {
        try text.appendSlice(gpa, words[r.uintLessThan(usize, words.len)]);
        try text.append(gpa, if (i % 9 == 8) '\n' else ' ');
    }
    for ([_]Options{ .level_1, .default, .best }) |o| {
        const ours = try roundtrip(text.items, o);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        _ = try aw.writer.writableSliceGreedy(16);
        var window: [flate.max_window_len]u8 = undefined;
        var c: flate.Compress = try .init(&aw.writer, &window, .zlib, o);
        try c.writer.writeAll(text.items);
        try c.finish();
        const theirs = aw.written().len;
        if (ours * 100 > theirs * 105) {
            std.debug.print("ours {d} vs std {d}\n", .{ ours, theirs });
            return error.TestUnexpectedResult;
        }
    }
}

test "deflate: random inputs roundtrip" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(99);
    const r = prng.random();
    const buf = try gpa.alloc(u8, 1 << 17);
    defer gpa.free(buf);
    for (0..60) |_| {
        const n = r.uintLessThan(usize, buf.len);
        // Small alphabets and repeated chunks make long and short matches.
        const alpha = r.intRangeAtMost(u8, 1, 255);
        var i: usize = 0;
        while (i < n) {
            if (i > 16 and r.boolean()) {
                const d = r.intRangeAtMost(usize, 1, @min(i, 40_000));
                const l = @min(n - i, r.intRangeAtMost(usize, 1, 300));
                for (0..l) |k| buf[i + k] = buf[i + k - d];
                i += l;
            } else {
                buf[i] = r.uintLessThan(u8, alpha);
                i += 1;
            }
        }
        _ = try roundtrip(buf[0..n], levels[r.uintLessThan(usize, levels.len)]);
    }
}

test "deflate: code lengths stay within limits" {
    // Fibonacci frequencies force deep trees.
    var freq: [286]u32 = @splat(0);
    var a: u32 = 1;
    var b: u32 = 1;
    for (0..30) |i| {
        freq[i] = a;
        const c = a + b;
        a = b;
        b = c;
    }
    var lens: [286]u8 = undefined;
    buildLengths(&freq, &lens, 15);
    var kraft: f64 = 0;
    for (lens[0..30]) |l| {
        try testing.expect(l >= 1 and l <= 15);
        kraft += std.math.pow(f64, 2, -@as(f64, @floatFromInt(l)));
    }
    try testing.expectApproxEqAbs(@as(f64, 1), kraft, 1e-9);
}
