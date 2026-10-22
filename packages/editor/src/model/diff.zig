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
    /// Coarse fallback (delete plus insert) once this has elapsed; needs
    /// `io`.
    timeout_ns: u64 = 200 * std.time.ns_per_ms,
    io: ?std.Io = null,
};

/// A line diff: the edit script over lines and its hunks.
pub const DiffResult = struct {
    edits: []Edit,
    hunks: []LineHunk,

    /// Frees the script and hunks.
    pub fn deinit(r: *DiffResult, gpa: Allocator) void {
        gpa.free(r.edits);
        gpa.free(r.hunks);
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
    const edits = try diffTokens(gpa, ia.items, ib.items, o.algorithm, deadline);
    errdefer gpa.free(edits);
    return .{ .edits = edits, .hunks = try hunks.buildHunks(gpa, edits, o.context_lines) };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("diff/diff_test.zig");
}
