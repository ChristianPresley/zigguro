//! Record-start scanning for the row index (E13.F06.S01.T01).
//!
//! A record starts after a line end (LF, or a CR not followed by LF) that
//! is outside quotes, unless the next byte is another line end (blank
//! lines are skipped, as the reader does). Whether a byte is inside quotes
//! is the parity of the quotes before it: a doubled quote flips it twice,
//! so it cancels. The SIMD path takes 64-byte blocks as `@Vector(64, u8)`,
//! turns quotes, CRs and LFs into u64 bit masks and gets the in-quote
//! mask with a log-step prefix XOR.
//!
//! A chunk of the file can be scanned before its starting quote state is
//! known: a start is unquoted under one state exactly when it's quoted
//! under the other, so one pass sorts every candidate into `out0` (valid
//! if the chunk starts outside quotes) or `out1` (valid if inside), and
//! the parity of the chunk's quotes says how the state changes across it.
//!
//! Assumes balanced quoting: a stray quote inside an unquoted field (which
//! the reader keeps as a literal) shifts the parity; the index falls back
//! to the reader when a file ends inside quotes.

const std = @import("std");

/// Receives record start offsets in increasing order.
pub fn Sink(comptime Ctx: type) type {
    return struct {
        ctx: Ctx,
        add: *const fn (ctx: Ctx, offset: u64) error{OutOfMemory}!void,
    };
}

fn isLe(c: u8) bool {
    return c == '\n' or c == '\r';
}

/// Scans `bytes[from..to]` (peeking at `bytes[to]` for CRLF). Returns
/// whether the chunk holds an odd number of quotes.
pub fn scanScalar(comptime Ctx: type, bytes: []const u8, from: usize, to: usize, quote: ?u8, out0: ?Sink(Ctx), out1: ?Sink(Ctx)) !bool {
    var inq = false;
    const q: u16 = if (quote) |x| x else 0x100;
    var i = from;
    while (i < to) : (i += 1) {
        const c = bytes[i];
        if (c == q) {
            inq = !inq;
            continue;
        }
        const end = c == '\n' or (c == '\r' and !(i + 1 < bytes.len and bytes[i + 1] == '\n'));
        if (!end or i + 1 >= bytes.len or isLe(bytes[i + 1])) continue;
        if (if (inq) out1 else out0) |s| try s.add(s.ctx, i + 1);
    }
    return inq;
}

const V = @Vector(64, u8);

fn mask(v: V, c: u8) u64 {
    return @bitCast(v == @as(V, @splat(c)));
}

/// Inclusive prefix XOR of the bits of `x` (bit i = XOR of bits 0..i).
pub fn prefixXor(x: u64) u64 {
    var m = x;
    m ^= m << 1;
    m ^= m << 2;
    m ^= m << 4;
    m ^= m << 8;
    m ^= m << 16;
    m ^= m << 32;
    return m;
}

/// `scanScalar`, 64 bytes at a time.
pub fn scanSimd(comptime Ctx: type, bytes: []const u8, from: usize, to: usize, quote: ?u8, out0: ?Sink(Ctx), out1: ?Sink(Ctx)) !bool {
    var carry: u64 = 0; // all ones when inside quotes (state-0 view)
    var p = from;
    while (p + 64 <= to) : (p += 64) {
        const v: V = bytes[p..][0..64].*;
        const q = if (quote) |x| mask(v, x) else 0;
        const cr = mask(v, '\r');
        const lf = mask(v, '\n');
        const next: u8 = if (p + 64 < bytes.len) bytes[p + 64] else 0;
        const next_lf: u64 = @intFromBool(next == '\n');
        const next_le: u64 = @intFromBool(isLe(next));
        const term = lf | (cr & ~((lf >> 1) | (next_lf << 63)));
        var valid = term & ~(((cr | lf) >> 1) | (next_le << 63));
        // The last byte of the file starts nothing.
        if (p + 64 >= bytes.len) valid &= ~(@as(u64, 1) << 63);
        const inq = prefixXor(q) ^ carry;
        if (valid != 0) {
            if (out0) |s| try emit(Ctx, s, p, valid & ~inq);
            if (out1) |s| try emit(Ctx, s, p, valid & inq);
        }
        if (@popCount(q) & 1 == 1) carry = ~carry;
    }
    const tail = try scanScalar(Ctx, bytes, p, to, quote, if (carry == 0) out0 else out1, if (carry == 0) out1 else out0);
    return (carry != 0) != tail;
}

fn emit(comptime Ctx: type, s: Sink(Ctx), base: usize, bits: u64) !void {
    var m = bits;
    while (m != 0) {
        const i = @ctz(m);
        try s.add(s.ctx, base + i + 1);
        m &= m - 1;
    }
}
