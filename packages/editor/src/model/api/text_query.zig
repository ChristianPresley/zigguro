//! Text reads for agents: version-stamped line ranges, optionally numbered
//! the way `cat -n` prints them, truncated at a line boundary.

const std = @import("std");
const pt = @import("../buffer/piece_tree.zig");

const Allocator = std.mem.Allocator;
const PieceTree = pt.PieceTree;

/// Lines `[start, end)`, 0-based.
pub const LineRange = struct { start: u64, end: u64 };

pub const ReadOptions = struct {
    /// Prefix each line with its 1-based number right-aligned to six
    /// columns and a tab.
    line_numbers: bool = false,
    max_bytes: usize = 256 << 10,
};

pub const ReadResult = struct {
    version: u64,
    /// First line returned (0-based).
    start_line: u64,
    /// Number of lines returned.
    lines: u64,
    text: []u8,
    total_lines: u64,
    /// The range was cut at `max_bytes`.
    truncated: bool,

    pub fn deinit(r: *ReadResult, gpa: Allocator) void {
        gpa.free(r.text);
        r.* = undefined;
    }
};

/// Lines in the sense agents count them: a final line terminator does not
/// start another line.
pub fn lineCount(t: PieceTree) u64 {
    const n = t.lineCount();
    if (n > 1 and t.lineStart(n - 1) == t.len()) return n - 1;
    return n;
}

/// Reads `range` (all lines when null, clamped to the text) of `t`, which
/// is at `version`. Lines keep their terminators.
pub fn readLines(gpa: Allocator, t: PieceTree, version: u64, range: ?LineRange, o: ReadOptions) Allocator.Error!ReadResult {
    const total = lineCount(t);
    const r = range orelse LineRange{ .start = 0, .end = total };
    const start = @min(r.start, total);
    const end = @min(@max(r.end, start), total);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var truncated = false;
    var line = start;
    while (line < end) : (line += 1) {
        const a = t.lineStart(line);
        const b = if (line + 1 < t.lineCount()) t.lineStart(line + 1) else t.len();
        var prefix: [24]u8 = undefined;
        const p = if (o.line_numbers) std.fmt.bufPrint(&prefix, "{d:>6}\t", .{line + 1}) catch unreachable else "";
        if (out.items.len + p.len + (b - a) > o.max_bytes) {
            truncated = true;
            break;
        }
        try out.appendSlice(gpa, p);
        var it = t.slice(.{ .start = a, .end = b });
        while (it.next()) |chunk| try out.appendSlice(gpa, chunk);
    }
    return .{
        .version = version,
        .start_line = start,
        .lines = line - start,
        .text = try out.toOwnedSlice(gpa),
        .total_lines = total,
        .truncated = truncated,
    };
}

/// The byte range of lines `[start, end)` of `t` (terminators included;
/// lines past the end clamp to `len()`).
pub fn lineBytes(t: PieceTree, start: u64, end: u64) pt.Range {
    const n = t.lineCount();
    const a = if (start < n) t.lineStart(start) else t.len();
    const b = if (end < n) t.lineStart(end) else t.len();
    return .{ .start = a, .end = @max(a, b) };
}
