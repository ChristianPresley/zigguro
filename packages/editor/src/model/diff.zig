//! The headless diff engine: line and token diffs (Myers, minimal,
//! patience, histogram), hunks with context and unified output. Used by
//! review views (E12), SCM (E09), the gutter's dirty diff and the CLI.

const std = @import("std");

/// Edit scripts, change marks and deadlines.
pub const script = @import("diff/script.zig");
/// Line splitting and interning.
pub const line_ids = @import("diff/line_ids.zig");
/// Myers O(ND), linear space.
pub const myers = @import("diff/myers.zig");
/// Patience diff.
pub const patience = @import("diff/patience.zig");
/// Histogram diff.
pub const histogram = @import("diff/histogram.zig");
/// Hunk grouping.
pub const hunks = @import("diff/hunks.zig");
/// Unified diff output.
pub const unified = @import("diff/unified.zig");
/// Intraline word and character highlights.
pub const intraline = @import("diff/intraline.zig");
/// The slider (indent) heuristic.
pub const postprocess = @import("diff/postprocess.zig");
/// Moved-block detection.
pub const moves = @import("diff/moves.zig");

const Allocator = std.mem.Allocator;

pub const Edit = script.Edit;
pub const Deadline = script.Deadline;
pub const LineSource = line_ids.LineSource;
pub const WsMode = line_ids.WsMode;
pub const LineHunk = hunks.LineHunk;
pub const DiffRange = hunks.DiffRange;

/// Which sequence diff to run.
pub const Algorithm = enum { myers, minimal, patience, histogram };

/// Line diff options.
pub const DiffOptions = struct {
    algorithm: Algorithm = .histogram,
    ignore_ws: WsMode = .none,
    context_lines: u32 = 3,
    /// Slide hunk boundaries to follow indentation.
    indent_heuristic: bool = true,
    intraline: enum { none, word, char } = .word,
    detect_moves: bool = false,
    /// Coarse fallback (delete plus insert) once this has elapsed; needs
    /// `io`.
    timeout_ns: u64 = 200 * std.time.ns_per_ms,
    io: ?std.Io = null,
};

/// A line diff: the edit script over lines and its hunks.
pub const DiffResult = struct {
    edits: []Edit,
    hunks: []LineHunk,
    /// Every hunk's highlights, grouped by hunk (`LineHunk.intraline`
    /// slices into this).
    ranges: []DiffRange = &.{},
    moves: []moves.Move = &.{},

    /// Frees everything.
    pub fn deinit(r: *DiffResult, gpa: Allocator) void {
        gpa.free(r.edits);
        gpa.free(r.hunks);
        gpa.free(r.ranges);
        gpa.free(r.moves);
        r.* = undefined;
    }
};

/// The edit script between two id sequences.
pub fn diffTokens(gpa: Allocator, a: []const u32, b: []const u32, alg: Algorithm, deadline: ?Deadline) Allocator.Error![]Edit {
    return switch (alg) {
        .myers => myers.myers(gpa, a, b, .{ .deadline = deadline }),
        .minimal => myers.myers(gpa, a, b, .{ .minimal = true, .deadline = deadline }),
        .patience => patience.patience(gpa, a, b, deadline),
        .histogram => histogram.histogram(gpa, a, b, deadline),
    };
}

/// Diffs the lines of `a` and `b`.
pub fn diffLines(gpa: Allocator, a: *const LineSource, b: *const LineSource, o: DiffOptions) Allocator.Error!DiffResult {
    var ia: std.ArrayList(u32) = .empty;
    defer ia.deinit(gpa);
    var ib: std.ArrayList(u32) = .empty;
    defer ib.deinit(gpa);
    try line_ids.intern(gpa, a, b, o.ignore_ws, &ia, &ib);
    const deadline: ?Deadline = if (o.io) |io| .after(io, o.timeout_ns) else null;
    var edits = try diffTokens(gpa, ia.items, ib.items, o.algorithm, deadline);
    errdefer gpa.free(edits);
    if (o.indent_heuristic) {
        const n = postprocess.slideHunks(edits, ia.items, ib.items, a, b);
        edits = try gpa.realloc(edits, n);
    }
    var r: DiffResult = .{ .edits = edits, .hunks = try hunks.buildHunks(gpa, edits, o.context_lines) };
    errdefer gpa.free(r.hunks);
    if (o.detect_moves) r.moves = try moves.detectMoves(gpa, edits, a, b, .{});
    errdefer gpa.free(r.moves);
    var all: std.ArrayList(DiffRange) = .empty;
    defer all.deinit(gpa);
    if (o.intraline != .none) {
        const ir = try intraline.intralineEdits(gpa, edits, a, b, if (o.intraline == .word) .word else .char);
        defer gpa.free(ir);
        try all.appendSlice(gpa, ir);
    }
    for (r.moves) |mv| {
        try all.append(gpa, .{ .side = .old, .range = linesRange(a, mv.from), .kind = .moved });
        try all.append(gpa, .{ .side = .new, .range = linesRange(b, mv.to), .kind = .moved });
        const from = hunkOf(r.hunks, .old, mv.from.start);
        const to = hunkOf(r.hunks, .new, mv.to.start);
        if (from != null and to != null) r.hunks[to.?].moved_from = @intCast(from.?);
    }
    r.ranges = try groupByHunk(gpa, r.hunks, all.items, a, b);
    return r;
}

fn linesRange(src: *const LineSource, s: hunks.LineSpan) @import("buffer/piece_tree.zig").Range {
    return .{ .start = src.offsetOf(@intCast(s.start)), .end = src.offsetOf(@intCast(s.start + s.count)) };
}

fn hunkOf(hs: []const LineHunk, side: DiffRange.Side, line: u64) ?usize {
    for (hs, 0..) |h, k| {
        const sp = if (side == .old) h.old else h.new;
        if (line >= sp.start and line < sp.start + sp.count) return k;
    }
    return null;
}

/// Orders `all` by hunk (old side, then new) and points each hunk's
/// `intraline` at its part.
fn groupByHunk(gpa: Allocator, hs: []LineHunk, all: []const DiffRange, a: *const LineSource, b: *const LineSource) Allocator.Error![]DiffRange {
    var out: std.ArrayList(DiffRange) = .empty;
    errdefer out.deinit(gpa);
    const bounds = try gpa.alloc([2]usize, hs.len);
    defer gpa.free(bounds);
    for (hs, bounds) |h, *bd| {
        bd[0] = out.items.len;
        inline for (.{ .{ DiffRange.Side.old, a, h.old }, .{ DiffRange.Side.new, b, h.new } }) |side| {
            const r = linesRange(side[1], side[2]);
            for (all) |x| if (x.side == side[0] and x.range.start >= r.start and x.range.start < r.end) {
                try out.append(gpa, x);
            };
        }
        bd[1] = out.items.len;
    }
    const owned = try out.toOwnedSlice(gpa);
    for (hs, bounds) |*h, bd| h.intraline = owned[bd[0]..bd[1]];
    return owned;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("diff/diff_test.zig");
    _ = @import("diff/diff_post_test.zig");
}
