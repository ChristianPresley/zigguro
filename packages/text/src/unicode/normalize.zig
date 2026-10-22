//! Unicode normalization forms (UAX #15): NFD, NFC, NFKD and NFKC with a
//! quick-check fast path, canonical ordering, canonical composition and
//! algorithmic Hangul; plus an allocation-free streaming `Decomposer`
//! that keeps source byte offsets (used by canonical caseless matching).

const std = @import("std");
const Allocator = std.mem.Allocator;
const p = @import("props.zig");
const decode = @import("decode.zig");
const appendCp = @import("casefold.zig").appendCp;

/// A normalization form.
pub const Form = enum { nfd, nfc, nfkd, nfkc };

/// Quick-check answer (UAX #15 §9).
pub const QuickCheckResult = enum { yes, no, maybe };

// Hangul syllable constants (Unicode ch. 3.12).
const s_base: u21 = 0xAC00;
const l_base: u21 = 0x1100;
const v_base: u21 = 0x1161;
const t_base: u21 = 0x11A7;
const l_count = 19;
const v_count = 21;
const t_count = 28;
const n_count = v_count * t_count;
const s_count = l_count * n_count;

inline fn ccc(cp: u21) u8 {
    return p.props(cp).ccc;
}

inline fn composes(form: Form) bool {
    return form == .nfc or form == .nfkc;
}

inline fn compat(form: Form) bool {
    return form == .nfkd or form == .nfkc;
}

const V = @Vector(16, u8);

/// UAX #15 quick check: `yes` means `bytes` is already in `form`, `no`
/// that it is not, `maybe` that only the full algorithm can tell.
pub fn isNormalizedQuick(bytes: []const u8, form: Form) QuickCheckResult {
    var result: QuickCheckResult = .yes;
    var last_ccc: u8 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 16 <= bytes.len) {
            const v: V = bytes[i..][0..16].*;
            if (@reduce(.And, v < @as(V, @splat(0x80)))) {
                i += 16;
                last_ccc = 0;
                continue;
            }
        }
        const c0 = bytes[i];
        if (c0 < 0x80) {
            i += 1;
            last_ccc = 0;
            continue;
        }
        // NFC: skip whole 64-code-point blocks known to be starters with
        // NFC_QC=Y, from the lead and first continuation byte.
        if (form == .nfc and i + 1 < bytes.len and bytes[i + 1] & 0xC0 == 0x80) {
            if (c0 >= 0xC2 and c0 < 0xE0 and p.nfcSafeBlock(c0 & 0x1F)) {
                i += 2;
                last_ccc = 0;
                continue;
            }
            if (c0 >= 0xE1 and c0 < 0xF0 and c0 != 0xED and i + 2 < bytes.len and bytes[i + 2] & 0xC0 == 0x80 and
                p.nfcSafeBlock(@as(u32, c0 & 0x0F) << 6 | (bytes[i + 1] & 0x3F)))
            {
                i += 3;
                last_ccc = 0;
                continue;
            }
        }
        const u = decode.at(bytes, i);
        i += u.len;
        if (!u.valid) {
            last_ccc = 0;
            continue;
        }
        const x = p.props(u.cp);
        const c = x.ccc;
        if (c != 0 and last_ccc > c) return .no;
        const qc: p.QuickCheck = switch (form) {
            .nfc => x.nfc_qc,
            .nfd => p.aux(u.cp).nfd_qc,
            .nfkd => p.aux(u.cp).nfkd_qc,
            .nfkc => p.aux(u.cp).nfkc_qc,
        };
        switch (qc) {
            .N => return .no,
            .M => result = .maybe,
            .Y => {},
        }
        last_ccc = c;
    }
    return result;
}

/// Returns `bytes` in `form` as a new allocation (a copy even when it is
/// already normalized). Ill-formed bytes become U+FFFD.
pub fn normalize(gpa: Allocator, bytes: []const u8, form: Form) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try normalizeAppend(&out, gpa, bytes, form);
    return out.toOwnedSlice(gpa);
}

/// Appends `bytes` in `form` to `out`.
pub fn normalizeAppend(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8, form: Form) !void {
    if (isNormalizedQuick(bytes, form) == .yes and std.unicode.utf8ValidateSlice(bytes)) {
        try out.appendSlice(gpa, bytes);
        return;
    }
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(gpa);
    try cps.ensureTotalCapacity(gpa, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const u = decode.at(bytes, i);
        i += u.len;
        try decomposeInto(&cps, gpa, if (u.valid) u.cp else 0xFFFD, compat(form));
    }
    canonicalOrder(cps.items);
    const result = if (composes(form)) compose(cps.items) else cps.items;
    try out.ensureUnusedCapacity(gpa, result.len);
    for (result) |cp| try appendCp(out, gpa, cp);
}

/// Appends the full decomposition of `cp` (canonical, or compatibility
/// when `k`), Hangul syllables algorithmically.
fn decomposeInto(list: *std.ArrayList(u21), gpa: Allocator, cp: u21, k: bool) !void {
    var buf: [max_decomposition]u21 = undefined;
    try list.appendSlice(gpa, decomposeCp(cp, k, &buf));
}

/// Longest full decomposition (U+FDFA has 18 code points).
const max_decomposition = 32;

fn decomposeCp(cp: u21, k: bool, buf: *[max_decomposition]u21) []const u21 {
    if (cp >= s_base and cp < s_base + s_count) {
        const s = cp - s_base;
        buf[0] = l_base + s / n_count;
        buf[1] = v_base + (s % n_count) / t_count;
        const t = s % t_count;
        if (t == 0) return buf[0..2];
        buf[2] = t_base + t;
        return buf[0..3];
    }
    const d = if (k) p.decomposeCompat(cp) orelse p.decomposeCanonical(cp) else p.decomposeCanonical(cp);
    if (d) |cps| return cps;
    buf[0] = cp;
    return buf[0..1];
}

/// Canonical ordering: stable sort of every non-starter run by ccc.
fn canonicalOrder(cps: []u21) void {
    var i: usize = 0;
    while (i < cps.len) {
        if (ccc(cps[i]) == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < cps.len and ccc(cps[j]) != 0) j += 1;
        // Insertion sort: runs are short and it is stable.
        var a = i + 1;
        while (a < j) : (a += 1) {
            const x = cps[a];
            const cx = ccc(x);
            var b = a;
            while (b > i and ccc(cps[b - 1]) > cx) : (b -= 1) cps[b] = cps[b - 1];
            cps[b] = x;
        }
        i = j;
    }
}

/// The primary composite of `a` + `b`, including Hangul LV and LVT.
fn composePair(a: u21, b: u21) ?u21 {
    if (a >= l_base and a < l_base + l_count and b >= v_base and b < v_base + v_count)
        return s_base + ((a - l_base) * v_count + (b - v_base)) * t_count;
    if (a >= s_base and a < s_base + s_count and (a - s_base) % t_count == 0 and b > t_base and b < t_base + t_count)
        return a + (b - t_base);
    return p.compose(a, b);
}

/// Canonical composition in place over decomposed, ordered code points;
/// returns the composed prefix.
fn compose(cps: []u21) []u21 {
    var n: usize = 0; // composed length
    var starter: ?usize = null;
    for (cps) |c| {
        const cc = ccc(c);
        if (starter) |si| {
            // C is blocked from S if some character between them has
            // ccc 0 or ccc >= ccc(C); after ordering, the last one has the
            // highest ccc.
            const blocked = n > si + 1 and blk: {
                const last = ccc(cps[n - 1]);
                break :blk last == 0 or last >= cc;
            };
            if (!blocked) {
                if (composePair(cps[si], c)) |comp| {
                    cps[si] = comp;
                    continue;
                }
            }
        }
        if (cc == 0) starter = n;
        cps[n] = c;
        n += 1;
    }
    return cps[0..n];
}

/// One decomposed code point and the source bytes it came from.
pub const Item = struct { cp: u21, src_start: usize, src_end: usize };

const Entry = struct { cp: u21, ccc: u8, src_start: usize, src_end: usize };

/// Reorder buffer size; longer non-starter runs are flushed in ccc order
/// of what is buffered (pathological input only).
pub const reorder_capacity = 64;

/// Canonical reordering over a stream of `Source.pull() ?Entry`.
fn Reorderer(comptime Source: type) type {
    return struct {
        const Self = @This();
        src: Source,
        buf: [reorder_capacity]Entry = undefined,
        len: usize = 0,
        idx: usize = 0,
        carry: ?Entry = null,

        fn pullOne(r: *Self) ?Entry {
            if (r.carry) |c| {
                r.carry = null;
                return c;
            }
            return r.src.pull();
        }

        fn next(r: *Self) ?Entry {
            if (r.idx < r.len) {
                r.idx += 1;
                return r.buf[r.idx - 1];
            }
            r.len = 0;
            r.idx = 0;
            const first = r.pullOne() orelse return null;
            r.buf[0] = first;
            r.len = 1;
            while (r.len < reorder_capacity) {
                const e = r.pullOne() orelse break;
                if (e.ccc == 0) {
                    r.carry = e;
                    break;
                }
                r.buf[r.len] = e;
                r.len += 1;
            }
            // Stable insertion sort of the non-starters.
            const from: usize = if (first.ccc == 0) 1 else 0;
            var a = from + 1;
            while (a < r.len) : (a += 1) {
                const x = r.buf[a];
                var b = a;
                while (b > from and r.buf[b - 1].ccc > x.ccc) : (b -= 1) r.buf[b] = r.buf[b - 1];
                r.buf[b] = x;
            }
            r.idx = 1;
            return r.buf[0];
        }
    };
}

/// Decomposes source code points one at a time (no ordering).
const DecompSource = struct {
    bytes: []const u8,
    i: usize = 0,
    k: bool,
    dec: [max_decomposition]u21 = undefined,
    dec_len: usize = 0,
    dec_idx: usize = 0,
    start: usize = 0,

    fn pull(s: *DecompSource) ?Entry {
        if (s.dec_idx >= s.dec_len) {
            if (s.i >= s.bytes.len) return null;
            s.start = s.i;
            const u = decode.at(s.bytes, s.i);
            s.i += u.len;
            const d = decomposeCp(if (u.valid) u.cp else 0xFFFD, s.k, &s.dec);
            if (@intFromPtr(d.ptr) != @intFromPtr(&s.dec)) @memcpy(s.dec[0..d.len], d);
            s.dec_len = d.len;
            s.dec_idx = 0;
        }
        const cp = s.dec[s.dec_idx];
        s.dec_idx += 1;
        return .{ .cp = cp, .ccc = ccc(cp), .src_start = s.start, .src_end = s.i };
    }
};

/// Streaming NFD (or NFKD when `compat`) with source offsets: every
/// output code point carries the byte range of the source code point it
/// came from; canonical reordering keeps those ranges. No allocation.
pub const Decomposer = struct {
    r: Reorderer(DecompSource),

    /// Decomposes `bytes`.
    pub fn init(bytes: []const u8, compat_mode: bool) Decomposer {
        return .{ .r = .{ .src = .{ .bytes = bytes, .k = compat_mode } } };
    }

    /// The next decomposed code point, or null at the end.
    pub fn next(d: *Decomposer) ?Item {
        const e = d.r.next() orelse return null;
        return .{ .cp = e.cp, .src_start = e.src_start, .src_end = e.src_end };
    }
};

/// NFD(toCasefold(NFD(x))) as a stream (Unicode D145), for
/// `casefold.Folder` canonical mode.
pub const CanonicalFolder = struct {
    r: Reorderer(FoldSource),

    /// Folds `bytes`.
    pub fn init(bytes: []const u8) CanonicalFolder {
        return .{ .r = .{ .src = .{ .inner = Decomposer.init(bytes, false) } } };
    }

    /// The next folded code point, or null at the end.
    pub fn next(f: *CanonicalFolder) ?Item {
        const e = f.r.next() orelse return null;
        return .{ .cp = e.cp, .src_start = e.src_start, .src_end = e.src_end };
    }
};

/// Folds each canonically decomposed code point and decomposes the result.
const FoldSource = struct {
    inner: Decomposer,
    dec: [max_decomposition * 3]u21 = undefined,
    dec_len: usize = 0,
    dec_idx: usize = 0,
    start: usize = 0,
    end: usize = 0,

    fn pull(s: *FoldSource) ?Entry {
        if (s.dec_idx >= s.dec_len) {
            const it = s.inner.next() orelse return null;
            s.start = it.src_start;
            s.end = it.src_end;
            s.dec_len = 0;
            s.dec_idx = 0;
            const folded = p.caseFoldFull(it.cp);
            for (folded.slice()) |f| {
                var buf: [max_decomposition]u21 = undefined;
                const d = decomposeCp(f, false, &buf);
                @memcpy(s.dec[s.dec_len..][0..d.len], d);
                s.dec_len += d.len;
            }
        }
        const cp = s.dec[s.dec_idx];
        s.dec_idx += 1;
        return .{ .cp = cp, .ccc = ccc(cp), .src_start = s.start, .src_end = s.end };
    }
};

test {
    _ = @import("normalize_test.zig");
}
