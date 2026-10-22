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

/// Streaming terminator counter; a CR at a chunk end waits for the next.
const Counter = struct {
    counts: [3]u64 = .{ 0, 0, 0 },
    pending_cr: bool = false,

    fn feed(c: *Counter, chunk: []const u8) void {
        var i: usize = 0;
        if (c.pending_cr and chunk.len > 0) {
            c.pending_cr = false;
            if (chunk[0] == '\n') {
                c.counts[@intFromEnum(Eol.crlf)] += 1;
                i = 1;
            } else c.counts[@intFromEnum(Eol.cr)] += 1;
        }
        while (std.mem.indexOfAnyPos(u8, chunk, i, "\r\n")) |p| {
            if (chunk[p] == '\n') {
                c.counts[@intFromEnum(Eol.lf)] += 1;
                i = p + 1;
            } else if (p + 1 == chunk.len) {
                c.pending_cr = true;
                return;
            } else if (chunk[p + 1] == '\n') {
                c.counts[@intFromEnum(Eol.crlf)] += 1;
                i = p + 2;
            } else {
                c.counts[@intFromEnum(Eol.cr)] += 1;
                i = p + 1;
            }
        }
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
