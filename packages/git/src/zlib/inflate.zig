//! A one-shot zlib/DEFLATE decoder (RFC 1950, RFC 1951) for buffers whose
//! inflated size is known up front, as it is for every pack entry and
//! loose object. It replaces `std.compress.flate.Decompress` on the hot
//! paths, whose per-stream setup dominated small reads (#729, #731).
//!
//! Design, after libdeflate:
//! - a 64-bit bit buffer refilled with one unaligned 8-byte load, so each
//!   symbol (at most 15 + 5 + 15 + 13 = 48 bits) needs one refill;
//! - table-driven Huffman decoding: a 9-bit (lengths) or 6-bit
//!   (distances) primary table with second-level tables for longer codes;
//!   the fixed code's tables are built at compile time;
//! - matches copied 8 bytes at a time when the distance allows.
//!
//! Past the end of the input the bit buffer is fed zeros; a stream that
//! needed them is truncated and rejected. Every table entry and copy is
//! bounds-checked, so malformed input fails with `error.CorruptObject`.

const std = @import("std");

pub const Error = error{CorruptObject};

/// What `inflate` stops at.
pub const Mode = enum {
    /// The stream must end, with a valid zlib trailer, after exactly
    /// `out.len` bytes.
    exact,
    /// Stops once `out` is full or the stream ends; nothing past that is
    /// checked.
    prefix,
};

pub const Result = struct {
    /// Bytes written to `out`.
    written: usize,
    /// Input bytes consumed, including the zlib header and trailer
    /// (`exact` only).
    consumed: usize,
};

/// Inflates the zlib stream at the start of `in` into `out`.
pub fn zlibInflate(in: []const u8, out: []u8, mode: Mode) Error!Result {
    if (in.len < 2) return error.CorruptObject;
    const cmf = in[0];
    const flg = in[1];
    if (cmf & 0x0f != 8 or cmf >> 4 > 7) return error.CorruptObject;
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0) return error.CorruptObject;
    if (flg & 0x20 != 0) return error.CorruptObject; // preset dictionary
    var d: Decoder = .{ .br = .{ .in = in, .pos = 2 }, .out = out, .mode = mode };
    try d.run();
    if (mode == .prefix) return .{ .written = d.o, .consumed = 0 };
    if (d.o != out.len) return error.CorruptObject;
    // The trailer starts at the next byte boundary.
    const end = d.bytePos();
    if (end + 4 > in.len) return error.CorruptObject;
    const want = std.mem.readInt(u32, in[end..][0..4], .big);
    if (adler32(out) != want) return error.CorruptObject;
    return .{ .written = d.o, .consumed = end + 4 };
}

/// Inflates raw DEFLATE data (no zlib wrapper) into exactly `out`, and
/// returns the input bytes consumed.
pub fn rawInflate(in: []const u8, out: []u8) Error!usize {
    var d: Decoder = .{ .br = .{ .in = in, .pos = 0 }, .out = out, .mode = .exact };
    try d.run();
    if (d.o != out.len) return error.CorruptObject;
    return d.bytePos();
}

// ---------------------------------------------------------------- tables

/// A decode table entry:
/// bits 0..4: code bits to consume; 5..7: `Kind`; 8..12: extra bits (or
/// a subtable's index bits); 16..31: literal, base value or subtable
/// offset.
const Entry = u32;

const Kind = enum(u3) { literal = 0, base = 1, end = 2, sub = 3, invalid = 4 };

inline fn entry(nbits: u32, kind: Kind, extra: u32, value: u32) Entry {
    return nbits | @as(u32, @intFromEnum(kind)) << 5 | extra << 8 | value << 16;
}
inline fn eBits(e: Entry) u5 {
    return @truncate(e);
}
inline fn eKind(e: Entry) Kind {
    return @enumFromInt(@as(u3, @truncate(e >> 5)));
}
inline fn eExtra(e: Entry) u5 {
    return @truncate(e >> 8);
}
inline fn eValue(e: Entry) u32 {
    return e >> 16;
}

const invalid_entry = entry(0, .invalid, 0, 0);

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const lit_bits = 9;
const dist_bits = 6;
const clen_bits = 7;
// zlib's ENOUGH_LENS and ENOUGH_DISTS (inftrees.h, computed by its
// enough.c) for these root sizes, 286 and 30 symbols and 15-bit codes:
// the most entries a two-level table can need. The builder checks the
// bound anyway.
const lit_table_len = 852;
const dist_table_len = 592;

const Alphabet = enum { litlen, dist, clen };

fn symEntry(comptime alpha: Alphabet, sym: u32, nbits: u32) Entry {
    return switch (alpha) {
        .litlen => if (sym < 256)
            entry(nbits, .literal, 0, sym)
        else if (sym == 256)
            entry(nbits, .end, 0, 0)
        else if (sym < 286)
            entry(nbits, .base, len_extra[sym - 257], len_base[sym - 257])
        else
            invalid_entry,
        .dist => if (sym < 30) entry(nbits, .base, dist_extra[sym], dist_base[sym]) else invalid_entry,
        .clen => entry(nbits, .literal, 0, sym),
    };
}

/// Builds the decode table for code `lens` (canonical Huffman codes).
/// Incomplete codes are accepted (unused entries decode as invalid);
/// over-subscribed ones are not.
///
/// The primary table is built by doubling, as libdeflate does: after the
/// codes of length `l` are stored once in the first 2^l entries, those
/// entries are copied up to make 2^(l+1), which repeats every shorter
/// code at its stride. Each short code is then a single store.
fn buildTable(comptime alpha: Alphabet, comptime primary: u5, lens: []const u8, table: []Entry) Error!void {
    var count: [16]u16 = @splat(0);
    for (lens) |l| count[l] += 1;
    count[0] = 0;
    var left: i32 = 1;
    for (1..16) |l| {
        left = (left << 1) - count[l];
        if (left < 0) return error.CorruptObject;
    }
    // A complete code fills every entry; only an incomplete one leaves
    // gaps that must decode as invalid (and not as a previous block's).
    const complete = left == 0;

    // Symbols sorted by code length, then by value: canonical order.
    var start: [17]u16 = undefined;
    start[1] = 0;
    for (1..16) |l| start[l + 1] = start[l] + count[l];
    var at_len = start;
    var sorted: [288]u16 = undefined;
    for (lens, 0..) |l, sym| {
        if (l == 0) continue;
        sorted[at_len[l]] = @intCast(sym);
        at_len[l] += 1;
    }

    table[0] = invalid_entry;
    table[1] = invalid_entry;
    var code: u32 = 0;
    var i: usize = 0;
    for (1..primary + 1) |l| {
        const half: usize = @as(usize, 1) << @intCast(l - 1);
        if (l > 1) @memcpy(table[half..][0..half], table[0..half]);
        for (0..count[l]) |_| {
            table[reverse(@intCast(code), @intCast(l))] = symEntry(alpha, sorted[i], @intCast(l));
            code += 1;
            i += 1;
        }
        code <<= 1;
    }
    const psize: u32 = 1 << primary;
    if (i == start[16]) return;

    // Long codes are grouped by their primary prefix into subtables sized
    // for the longest code in each. `sub_bits` and `sub_at` are only read
    // at prefixes set here first.
    var sub_bits: [1 << lit_bits]u8 = undefined;
    var sub_at: [1 << lit_bits]u16 = undefined;
    const first_long = i;
    {
        var c = code;
        for (primary + 1..16) |l| {
            for (0..count[l]) |_| {
                const p = reverse(@intCast(c), @intCast(l)) & (psize - 1);
                sub_bits[p] = 0;
                sub_at[p] = 0;
                c += 1;
            }
            c <<= 1;
        }
        c = code;
        for (primary + 1..16) |l| {
            for (0..count[l]) |_| {
                const p = reverse(@intCast(c), @intCast(l)) & (psize - 1);
                sub_bits[p] = @max(sub_bits[p], @as(u8, @intCast(l - primary)));
                c += 1;
            }
            c <<= 1;
        }
    }
    var at: u32 = psize;
    i = first_long;
    for (primary + 1..16) |l| {
        for (0..count[l]) |_| {
            const rev = reverse(@intCast(code), @intCast(l));
            const p = rev & (psize - 1);
            const size: u32 = @as(u32, 1) << @intCast(sub_bits[p]);
            if (sub_at[p] == 0) {
                if (at + size > table.len) return error.CorruptObject;
                table[p] = entry(primary, .sub, sub_bits[p], at);
                if (!complete) fill(table[at..][0..size], invalid_entry);
                sub_at[p] = @intCast(at);
                at += size;
            }
            // Subtable entries hold the full code length: decoding looks
            // the entry up first and drops all its bits at once.
            const off: u32 = sub_at[p];
            const l2: u5 = @intCast(l - primary);
            const e = symEntry(alpha, sorted[i], @intCast(l));
            var k: u32 = rev >> primary;
            while (k < size) : (k += @as(u32, 1) << l2) table[off + k] = e;
            code += 1;
            i += 1;
        }
        code <<= 1;
    }
}

/// Fills without `@memset`, which 0.16 lowers to a byte loop.
fn fill(dst: []Entry, v: Entry) void {
    var i: usize = 0;
    const V = @Vector(8, Entry);
    var vv: V = @splat(v);
    std.mem.doNotOptimizeAway(&vv);
    while (i + 8 <= dst.len) : (i += 8) dst[i..][0..8].* = vv;
    while (i < dst.len) : (i += 1) dst[i] = v;
}

fn reverse(code: u16, len: u32) u16 {
    const r = @as(u16, rev8[code & 0xff]) << 8 | rev8[code >> 8];
    return r >> @intCast(16 - len);
}

const rev8: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*x, i| x.* = @bitReverse(@as(u8, i));
    break :blk t;
};

const FixedTables = struct { lit: [lit_table_len]Entry, dist: [dist_table_len]Entry };

const fixed: FixedTables = blk: {
    @setEvalBranchQuota(200_000);
    var lens: [288]u8 = undefined;
    for (0..144) |i| lens[i] = 8;
    for (144..256) |i| lens[i] = 9;
    for (256..280) |i| lens[i] = 7;
    for (280..288) |i| lens[i] = 8;
    var t: FixedTables = undefined;
    buildTable(.litlen, lit_bits, &lens, &t.lit) catch unreachable;
    const dl = [_]u8{5} ** 32;
    buildTable(.dist, dist_bits, &dl, &t.dist) catch unreachable;
    break :blk t;
};

// ---------------------------------------------------------------- decoder

/// The input and its bit buffer. Hot loops copy it into a local so the
/// fields stay in registers (stores to the output could alias them).
const Bits = struct {
    in: []const u8,
    /// Next input byte to load into `bits`.
    pos: usize,
    bits: u64 = 0,
    nbits: u6 = 0,

    /// Tops the bit buffer up to at least 56 bits. Bits above `nbits` are
    /// the following input bits (or zeros past the end), which a later
    /// refill ORs in again at the same place.
    inline fn refill(b: *Bits) void {
        if (b.pos + 8 <= b.in.len) {
            const w = std.mem.readInt(u64, b.in[b.pos..][0..8], .little);
            b.bits |= w << b.nbits;
            b.pos += (63 - @as(usize, b.nbits)) >> 3;
            b.nbits |= 56;
        } else {
            while (b.nbits < 56) {
                const x: u64 = if (b.pos < b.in.len) b.in[b.pos] else 0;
                b.bits |= x << b.nbits;
                b.pos += 1;
                b.nbits += 8;
            }
        }
    }

    inline fn peek(b: *const Bits, n: u6) u64 {
        return b.bits & ((@as(u64, 1) << n) - 1);
    }

    inline fn drop(b: *Bits, n: u6) void {
        b.bits >>= n;
        b.nbits -= n;
    }

    inline fn take(b: *Bits, n: u6) u32 {
        const v: u32 = @intCast(b.peek(n));
        b.drop(n);
        return v;
    }
};

const Decoder = struct {
    br: Bits,
    out: []u8,
    o: usize = 0,
    mode: Mode,
    lit: [lit_table_len]Entry = undefined,
    dist: [dist_table_len]Entry = undefined,

    inline fn refill(d: *Decoder) void {
        d.br.refill();
    }
    inline fn peek(d: *const Decoder, n: u6) u64 {
        return d.br.peek(n);
    }
    inline fn drop(d: *Decoder, n: u6) void {
        d.br.drop(n);
    }
    inline fn take(d: *Decoder, n: u6) u32 {
        return d.br.take(n);
    }

    /// The input position of the next unread bit's byte, after discarding
    /// a partial byte.
    fn bytePos(d: *const Decoder) usize {
        return d.br.pos - (d.br.nbits >> 3);
    }

    /// Fails when decoding needed bytes past the end of the input.
    fn checkOverrun(d: *const Decoder) Error!void {
        if (d.bytePos() > d.br.in.len) return error.CorruptObject;
    }

    fn run(d: *Decoder) Error!void {
        while (true) {
            d.refill();
            const final = d.take(1);
            const btype = d.take(2);
            const full = switch (btype) {
                0 => try d.stored(),
                1 => try d.codes(&fixed.lit, &fixed.dist),
                2 => blk: {
                    try d.dynamicHeader();
                    break :blk try d.codes(&d.lit, &d.dist);
                },
                else => return error.CorruptObject,
            };
            try d.checkOverrun();
            if (full) return; // prefix mode filled `out`
            if (final == 1) return;
        }
    }

    /// Returns true when prefix mode filled the output.
    fn stored(d: *Decoder) Error!bool {
        d.drop(d.br.nbits & 7);
        var p = d.bytePos();
        d.br.bits = 0;
        d.br.nbits = 0;
        const in = d.br.in;
        if (p + 4 > in.len) return error.CorruptObject;
        const len = std.mem.readInt(u16, in[p..][0..2], .little);
        const nlen = std.mem.readInt(u16, in[p + 2 ..][0..2], .little);
        if (len != ~nlen) return error.CorruptObject;
        p += 4;
        if (p + len > in.len) return error.CorruptObject;
        var n: usize = len;
        var full = false;
        if (d.o + n > d.out.len) {
            if (d.mode == .exact) return error.CorruptObject;
            n = d.out.len - d.o;
            full = true;
        }
        @memcpy(d.out[d.o..][0..n], in[p..][0..n]);
        d.o += n;
        d.br.pos = p + len;
        return full;
    }

    fn dynamicHeader(d: *Decoder) Error!void {
        const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
        var lens: [286 + 30]u8 = undefined;
        var br = d.br;
        defer d.br = br;
        br.refill();
        const hlit = br.take(5) + 257;
        const hdist = br.take(5) + 1;
        const hclen = br.take(4) + 4;
        if (hlit > 286 or hdist > 30) return error.CorruptObject;
        var clens: [19]u8 = @splat(0);
        for (order[0..hclen]) |i| {
            if (br.nbits < 3) br.refill();
            clens[i] = @intCast(br.take(3));
        }
        var ctab: [1 << clen_bits]Entry = undefined;
        try buildTable(.clen, clen_bits, &clens, &ctab);

        const total = hlit + hdist;
        var i: usize = 0;
        while (i < total) {
            // A code-length code and its repeat bits take at most 14.
            if (br.nbits < 14) br.refill();
            const e = ctab[@intCast(br.peek(clen_bits))];
            if (eKind(e) != .literal) return error.CorruptObject;
            br.drop(eBits(e));
            const sym = eValue(e);
            if (sym < 16) {
                lens[i] = @intCast(sym);
                i += 1;
                continue;
            }
            const rep: usize, const val: u8 = switch (sym) {
                16 => blk: {
                    if (i == 0) return error.CorruptObject;
                    break :blk .{ 3 + br.take(2), lens[i - 1] };
                },
                17 => .{ 3 + br.take(3), 0 },
                else => .{ 11 + br.take(7), 0 },
            };
            if (i + rep > total) return error.CorruptObject;
            for (lens[i..][0..rep]) |*x| x.* = val;
            i += rep;
        }
        d.br = br;
        try d.checkOverrun();
        if (lens[256] == 0) return error.CorruptObject;
        try buildTable(.litlen, lit_bits, lens[0..hlit], &d.lit);
        try buildTable(.dist, dist_bits, lens[hlit..total], &d.dist);
    }

    /// Decodes one Huffman-coded block. Returns true when prefix mode
    /// filled the output.
    fn outputFull(d: *const Decoder) Error!bool {
        if (d.mode == .prefix) return true;
        return error.CorruptObject;
    }

    fn codes(d: *Decoder, lit: []const Entry, dist: []const Entry) Error!bool {
        const out = d.out;
        var o = d.o;
        var br = d.br;
        defer {
            d.o = o;
            d.br = br;
        }
        while (true) {
            br.refill();
            var e = lookup(lit, lit_bits, &br);
            if (eKind(e) == .literal) {
                // A literal takes at most 15 of the 56+ bits, so a second
                // one fits without a refill; anything else waits for one.
                br.drop(eBits(e));
                if (o == out.len) return d.outputFull();
                out[o] = @intCast(eValue(e));
                o += 1;
                e = lookup(lit, lit_bits, &br);
                if (eKind(e) != .literal) continue;
                br.drop(eBits(e));
                if (o == out.len) return d.outputFull();
                out[o] = @intCast(eValue(e));
                o += 1;
                continue;
            }
            br.drop(eBits(e));
            switch (eKind(e)) {
                .literal => unreachable,
                .end => return false,
                .base => {
                    var len: usize = eValue(e) + br.take(eExtra(e));
                    const de = lookup(dist, dist_bits, &br);
                    if (eKind(de) != .base) return error.CorruptObject;
                    br.drop(eBits(de));
                    const dd: usize = eValue(de) + br.take(eExtra(de));
                    if (dd > o) return error.CorruptObject;
                    var full = false;
                    if (o + len > out.len) {
                        if (d.mode == .exact) return error.CorruptObject;
                        len = out.len - o;
                        full = true;
                    }
                    copyMatch(out, o, dd, len);
                    o += len;
                    if (full) return true;
                },
                .sub, .invalid => return error.CorruptObject,
            }
        }
    }
};

/// The entry for the code at the bottom of `br`, through its subtable
/// if it has one. Nothing is consumed.
inline fn lookup(table: []const Entry, comptime primary: u6, br: *const Bits) Entry {
    const e = table[@intCast(br.peek(primary))];
    if (eKind(e) != .sub) return e;
    return table[eValue(e) + @as(u32, @intCast((br.bits >> primary) & ((@as(u64, 1) << eExtra(e)) - 1)))];
}

/// Copies `len` bytes from `o - dist` to `o` (the ranges may overlap).
inline fn copyMatch(out: []u8, o: usize, dist: usize, len: usize) void {
    var src = o - dist;
    var dst = o;
    const end = o + len;
    if (dist >= 8 and end + 8 <= out.len) {
        // Whole words; the last one may write up to 7 bytes past `end`,
        // which later output overwrites.
        while (dst < end) {
            const w = std.mem.readInt(u64, out[src..][0..8], .little);
            std.mem.writeInt(u64, out[dst..][0..8], w, .little);
            src += 8;
            dst += 8;
        }
        return;
    }
    if (dist == 1) {
        @memset(out[dst..end], out[src]);
        return;
    }
    while (dst < end) : ({
        src += 1;
        dst += 1;
    }) out[dst] = out[src];
}

/// Adler-32 (RFC 1950) with deferred modulo over 5552-byte runs.
pub fn adler32(data: []const u8) u32 {
    const base = 65521;
    const nmax = 5552;
    var a: u32 = 1;
    var b: u32 = 0;
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, nmax);
        const chunk = rest[0..n];
        var i: usize = 0;
        const V = @Vector(16, u32);
        if (n >= 16) {
            // Per 16 bytes, b gains 16 * (a before them) plus the bytes
            // weighted 16..1. `vs` sums the lane totals seen before each
            // group, so 16 * sum(vs) is the first part over the run.
            var va: V = @splat(0);
            var vb: V = @splat(0);
            var vs: V = @splat(0);
            const weights: V = .{ 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };
            while (i + 16 <= n) : (i += 16) {
                const bytes: @Vector(16, u8) = chunk[i..][0..16].*;
                const w: V = bytes;
                vs += va;
                va += w;
                vb += w * weights;
            }
            const k: u64 = i / 16;
            const bb: u64 = @as(u64, b) + 16 * (@as(u64, @reduce(.Add, vs)) + @as(u64, a) * k) + @reduce(.Add, vb);
            b = @intCast(bb % base);
            a += @reduce(.Add, va);
        }
        while (i < n) : (i += 1) {
            a += chunk[i];
            b += a;
        }
        a %= base;
        b %= base;
        rest = rest[n..];
    }
    return b << 16 | a;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const flate = std.compress.flate;

fn stdCompress(gpa: std.mem.Allocator, data: []const u8, opts: flate.Compress.Options) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    _ = try aw.writer.writableSliceGreedy(16);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    c.* = try .init(&aw.writer, window, .zlib, opts);
    try c.writer.writeAll(data);
    try c.finish();
    return aw.toOwnedSlice();
}

test "inflate: adler32 matches std" {
    var buf: [20000]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(7);
    prng.random().bytes(&buf);
    for ([_]usize{ 0, 1, 15, 16, 17, 5551, 5552, 5553, 11104, 20000 }) |n| {
        try testing.expectEqual(std.hash.Adler32.hash(buf[0..n]), adler32(buf[0..n]));
    }
    @memset(&buf, 0xff);
    try testing.expectEqual(std.hash.Adler32.hash(&buf), adler32(&buf));
}

test "inflate: roundtrips std-compressed data at every level" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const words = [_][]const u8{ "fn ", "const ", "return ", "var ", "x", "y", " = ", ";\n", "(", ")", "{\n", "}\n", "std.mem.", "0x", "  " };
    while (text.items.len < 200_000) try text.appendSlice(gpa, words[r.uintLessThan(usize, words.len)]);
    const random = try gpa.alloc(u8, 70_000);
    defer gpa.free(random);
    r.bytes(random);
    const zeros = try gpa.alloc(u8, 100_000);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    const inputs = [_][]const u8{ "", "a", "hello hello hello hello", text.items, random, zeros, text.items[0..600] };
    const levels = [_]flate.Compress.Options{ .fastest, .level_4, .default, .best };
    for (inputs) |data| for (levels) |lv| {
        const z = try stdCompress(gpa, data, lv);
        defer gpa.free(z);
        const out = try gpa.alloc(u8, data.len);
        defer gpa.free(out);
        const res = try zlibInflate(z, out, .exact);
        try testing.expectEqualSlices(u8, data, out);
        try testing.expectEqual(z.len, res.consumed);
        // Trailing bytes after the stream are left alone.
        const padded = try std.mem.concat(gpa, u8, &.{ z, "TRAILING" });
        defer gpa.free(padded);
        try testing.expectEqual(z.len, (try zlibInflate(padded, out, .exact)).consumed);
    };
}

test "inflate: stored, fixed and hand-built streams" {
    // zlib header, one final stored block "hi", adler32.
    const stored = [_]u8{ 0x78, 0x01, 0x01, 0x02, 0x00, 0xfd, 0xff, 'h', 'i', 0x01, 0x3b, 0x00, 0xd2 };
    var out: [2]u8 = undefined;
    _ = try zlibInflate(&stored, &out, .exact);
    try testing.expectEqualStrings("hi", &out);
    // Fixed Huffman "a" from zlib: 78 9c 4b 04 00 00 62 00 62.
    const fixed_a = [_]u8{ 0x78, 0x9c, 0x4b, 0x04, 0x00, 0x00, 0x62, 0x00, 0x62 };
    var one: [1]u8 = undefined;
    _ = try zlibInflate(&fixed_a, &one, .exact);
    try testing.expectEqualStrings("a", &one);
}

test "inflate: length, trailer and truncation errors" {
    const gpa = testing.allocator;
    const data = "abcabcabc" ** 300;
    const z = try stdCompress(gpa, data, .default);
    defer gpa.free(z);
    var out: [data.len]u8 = undefined;
    var short: [data.len - 1]u8 = undefined;
    var long: [data.len + 1]u8 = undefined;
    try testing.expectError(error.CorruptObject, zlibInflate(z, &short, .exact));
    try testing.expectError(error.CorruptObject, zlibInflate(z, &long, .exact));
    for (0..z.len) |n| try testing.expectError(error.CorruptObject, zlibInflate(z[0..n], &out, .exact));
    const bad = try gpa.dupe(u8, z);
    defer gpa.free(bad);
    bad[bad.len - 2] ^= 0x40;
    try testing.expectError(error.CorruptObject, zlibInflate(bad, &out, .exact));
    bad[bad.len - 2] ^= 0x40;
    bad[0] = 0x79;
    try testing.expectError(error.CorruptObject, zlibInflate(bad, &out, .exact));

    var pre: [64]u8 = undefined;
    const p = try zlibInflate(z, &pre, .prefix);
    try testing.expectEqual(@as(usize, 64), p.written);
    try testing.expectEqualStrings(data[0..64], &pre);
}

test "inflate: random corruption never crashes" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    var src: [4000]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast((i * 7 + i / 13) % 61 + 32);
    const z = try stdCompress(gpa, &src, .default);
    defer gpa.free(z);
    const bad = try gpa.dupe(u8, z);
    defer gpa.free(bad);
    var out: [4000]u8 = undefined;
    for (0..3000) |_| {
        @memcpy(bad, z);
        for (0..1 + r.uintLessThan(usize, 4)) |_| bad[2 + r.uintLessThan(usize, bad.len - 2)] ^= @as(u8, 1) << r.int(u3);
        _ = zlibInflate(bad, &out, .exact) catch {};
        _ = zlibInflate(bad, &out, .prefix) catch {};
    }
    // Pure noise behind a valid header.
    for (0..3000) |_| {
        r.bytes(bad);
        bad[0] = 0x78;
        bad[1] = 0x9c;
        _ = zlibInflate(bad, &out, .exact) catch {};
    }
}
