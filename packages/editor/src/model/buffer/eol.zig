//! Line-ending detection. A file keeps the terminators it was read with:
//! saving never converts them unless asked (`SaveOptions.eol_override`),
//! and Enter inserts the dominant one.

const std = @import("std");
const pt = @import("piece_tree.zig");

const PieceTree = pt.PieceTree;

/// A line-ending style. `mixed` describes a file using more than one.
pub const Eol = enum {
    lf,
    crlf,
    cr,
    mixed,

    /// The terminator bytes (`mixed` has none of its own: "\n").
    pub fn bytes(e: Eol) []const u8 {
        return switch (e) {
            .lf, .mixed => "\n",
            .crlf => "\r\n",
            .cr => "\r",
        };
    }

    /// The platform's default for new files.
    pub fn native() Eol {
        return if (@import("builtin").os.tag == .windows) .crlf else .lf;
    }
};

/// How many of each terminator a text uses.
pub const EolStats = struct {
    /// The most frequent terminator (ties prefer LF, then CRLF); `lf` for a
    /// text without any.
    dominant: Eol,
    /// `dominant`, or `mixed` when more than one kind occurs.
    style: Eol,
    /// Counts of LF, CRLF and CR, indexed by `Eol` (`lf`, `crlf`, `cr`).
    counts: [3]u64,
    /// Whether only a prefix was scanned.
    sampled: bool = false,

    fn finish(counts: [3]u64, sampled: bool) EolStats {
        var best: usize = 0;
        for (1..3) |k| if (counts[k] > counts[best]) {
            best = k;
        };
        var kinds: u2 = 0;
        for (counts) |c| kinds += @intFromBool(c > 0);
        const dominant: Eol = @enumFromInt(best);
        return .{ .dominant = dominant, .style = if (kinds > 1) .mixed else dominant, .counts = counts, .sampled = sampled };
    }
};

/// Longest prefix `detectEol` scans.
pub const sample_limit: u64 = 1 << 20;

/// Counts terminators in the first MiB of `t`.
pub fn detectEol(t: PieceTree) EolStats {
    var c: Counter = .{};
    const end = @min(t.len(), sample_limit);
    var it = t.slice(.{ .start = 0, .end = end });
    while (it.next()) |chunk| c.feed(chunk);
    // A CR ending the sample may be the first half of a CRLF.
    if (c.pending_cr) {
        if (end < t.len() and t.byteAt(end) == '\n') c.counts[@intFromEnum(Eol.crlf)] += 1 else c.counts[@intFromEnum(Eol.cr)] += 1;
    }
    return .finish(c.counts, end < t.len());
}

/// Counts every terminator in `text`.
pub fn detectEolBytes(text: []const u8) EolStats {
    var c: Counter = .{};
    c.feed(text);
    if (c.pending_cr) c.counts[@intFromEnum(Eol.cr)] += 1;
    return .finish(c.counts, false);
}

/// Counts terminators in the first `sample_limit` bytes of `text`
/// (`sampled` when it is longer): a large file's style without reading
/// all of it.
pub fn detectEolSample(text: []const u8) EolStats {
    if (text.len <= sample_limit) return detectEolBytes(text);
    var c: Counter = .{};
    const end: usize = @intCast(sample_limit);
    c.feed(text[0..end]);
    // A CR ending the sample may be the first half of a CRLF.
    if (c.pending_cr) {
        if (text[end] == '\n') c.counts[@intFromEnum(Eol.crlf)] += 1 else c.counts[@intFromEnum(Eol.cr)] += 1;
    }
    return .finish(c.counts, true);
}

/// Streaming terminator counter; a CR at a chunk end waits for the next.
/// Counts 32 bytes at a time: every LF and CR, and the CRs followed by an
/// LF (CRLF); LF-only and CR-only counts follow from those.
const Counter = struct {
    counts: [3]u64 = .{ 0, 0, 0 },
    pending_cr: bool = false,

    const lanes = 32;
    const V = @Vector(lanes, u8);
    const Mask = std.meta.Int(.unsigned, lanes);

    fn mask(v: V, b: u8) Mask {
        return @bitCast(v == @as(V, @splat(b)));
    }

    fn feed(c: *Counter, chunk: []const u8) void {
        var i: usize = 0;
        if (c.pending_cr) {
            if (chunk.len == 0) return;
            c.pending_cr = false;
            if (chunk[0] == '\n') {
                c.counts[@intFromEnum(Eol.crlf)] += 1;
                i = 1;
            } else c.counts[@intFromEnum(Eol.cr)] += 1;
        }
        var lf: u64 = 0;
        var cr: u64 = 0;
        var pairs: u64 = 0;
        // Each block also reads the byte after it, to pair a CR on its
        // last byte with an LF.
        while (i + lanes + 1 <= chunk.len) : (i += lanes) {
            const v: V = chunk[i..][0..lanes].*;
            const r = mask(v, '\r');
            lf += @popCount(mask(v, '\n'));
            if (r == 0) continue;
            const next: V = chunk[i + 1 ..][0..lanes].*;
            cr += @popCount(r);
            pairs += @popCount(r & mask(next, '\n'));
        }
        while (i < chunk.len) : (i += 1) switch (chunk[i]) {
            '\n' => lf += 1,
            '\r' => if (i + 1 == chunk.len) {
                c.pending_cr = true;
            } else {
                cr += 1;
                if (chunk[i + 1] == '\n') pairs += 1;
            },
            else => {},
        };
        // A pair's LF was counted as an LF and its CR as a CR.
        c.counts[@intFromEnum(Eol.crlf)] += pairs;
        c.counts[@intFromEnum(Eol.lf)] += lf - pairs;
        c.counts[@intFromEnum(Eol.cr)] += cr - pairs;
    }
};

test "eol: detect styles" {
    const s = detectEolBytes("a\r\nb\r\nc\n");
    try std.testing.expectEqual(Eol.crlf, s.dominant);
    try std.testing.expectEqual(Eol.mixed, s.style);
    try std.testing.expectEqual([3]u64{ 1, 2, 0 }, s.counts);
    try std.testing.expectEqual(Eol.cr, detectEolBytes("a\rb\r").style);
    try std.testing.expectEqual(Eol.lf, detectEolBytes("no terminator").style);
    var c: Counter = .{};
    c.feed("a\r");
    c.feed("\nb\r");
    c.feed("c");
    try std.testing.expectEqual([3]u64{ 0, 1, 1 }, c.counts);
}

test "eol: block counting matches a byte-by-byte count over random chunks" {
    var prng: std.Random.DefaultPrng = .init(11);
    const r = prng.random();
    var buf: [700]u8 = undefined;
    for (0..300) |_| {
        const n = r.uintLessThan(usize, buf.len);
        for (buf[0..n]) |*b| b.* = "ab\r\n"[r.uintLessThan(usize, 4)];
        const text = buf[0..n];
        var want = [3]u64{ 0, 0, 0 };
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (text[i] == '\n') want[@intFromEnum(Eol.lf)] += 1 else if (text[i] == '\r') {
                if (i + 1 < n and text[i + 1] == '\n') {
                    want[@intFromEnum(Eol.crlf)] += 1;
                    i += 1;
                } else want[@intFromEnum(Eol.cr)] += 1;
            }
        }
        try std.testing.expectEqual(want, detectEolBytes(text).counts);
        // The same text fed in random pieces.
        var c: Counter = .{};
        var at: usize = 0;
        while (at < n) {
            const k = @min(n - at, r.uintLessThan(usize, 80));
            c.feed(text[at..][0..k]);
            at += k;
        }
        if (c.pending_cr) c.counts[@intFromEnum(Eol.cr)] += 1;
        try std.testing.expectEqual(want, c.counts);
    }
}

test "eol: a sample counts its prefix and pairs a CR at its end" {
    const gpa = std.testing.allocator;
    const n: usize = @intCast(sample_limit + 10);
    const text = try gpa.alloc(u8, n);
    defer gpa.free(text);
    @memset(text, 'x');
    text[10] = '\n';
    text[sample_limit - 1] = '\r';
    text[sample_limit] = '\n';
    text[n - 2] = '\r';
    const s = detectEolSample(text);
    try std.testing.expect(s.sampled);
    try std.testing.expectEqual([3]u64{ 1, 1, 0 }, s.counts);
    try std.testing.expect(!detectEolSample("a\r\nb").sampled);
}
