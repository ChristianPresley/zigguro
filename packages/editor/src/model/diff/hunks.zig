//! Hunks: contiguous changes of an edit script, optionally widened by
//! context lines and merged when at most `2 * context` equal lines
//! separate them (unified-diff grouping). Line numbers are 0-based.

const std = @import("std");
const script = @import("script.zig");
const pt = @import("../buffer/piece_tree.zig");

const Allocator = std.mem.Allocator;
const Edit = script.Edit;

/// A range of lines.
pub const LineSpan = struct { start: u64, count: u64 };

/// Intraline or moved-block highlight, in byte offsets of one side's text.
pub const DiffRange = struct {
    side: enum { old, new },
    range: pt.Range,
    kind: enum { changed, moved },
};

/// One hunk. With context, `old`/`new` include the context lines.
pub const LineHunk = struct {
    old: LineSpan,
    new: LineSpan,
    /// Word or character highlights (owned by the `DiffResult`).
    intraline: []const DiffRange = &.{},
    /// Index of the hunk this block was moved from (moved-block detection).
    moved_from: ?u32 = null,
};

/// Groups the changes of `edits` into hunks with `context` lines around
/// them.
pub fn buildHunks(gpa: Allocator, edits: []const Edit, context: u32) Allocator.Error![]LineHunk {
    var out: std.ArrayList(LineHunk) = .empty;
    errdefer out.deinit(gpa);
    const a_len: u64 = if (edits.len > 0) edits[edits.len - 1].a_start + (if (edits[edits.len - 1].kind != .insert) edits[edits.len - 1].len else 0) else 0;
    const b_len: u64 = if (edits.len > 0) edits[edits.len - 1].b_start + (if (edits[edits.len - 1].kind != .delete) edits[edits.len - 1].len else 0) else 0;
    var i: usize = 0;
    while (i < edits.len) {
        if (edits[i].kind == .equal) {
            i += 1;
            continue;
        }
        // A change run: consecutive non-equal edits, then extend through
        // short equal gaps.
        const first = i;
        var last = i;
        while (true) {
            while (last + 1 < edits.len and edits[last + 1].kind != .equal) last += 1;
            if (last + 2 < edits.len and edits[last + 1].kind == .equal and edits[last + 1].len <= 2 * context and edits[last + 2].kind != .equal) {
                last += 2;
                continue;
            }
            break;
        }
        const s = edits[first];
        const e = edits[last];
        const a_end = e.a_start + (if (e.kind == .delete) e.len else 0);
        const b_end = e.b_start + (if (e.kind == .insert) e.len else 0);
        const a1 = @min(a_end + context, a_len);
        const b1 = @min(b_end + context, b_len);
        // Context is clamped at the ends; between hunks the equal gap is
        // longer than 2 * context, so it always suffices.
        const pre = @min(context, @min(s.a_start, s.b_start));
        const post = @min(a1 - a_end, b1 - b_end);
        try out.append(gpa, .{
            .old = .{ .start = s.a_start - pre, .count = a_end + post - (s.a_start - pre) },
            .new = .{ .start = s.b_start - pre, .count = b_end + post - (s.b_start - pre) },
        });
        i = last + 1;
    }
    return out.toOwnedSlice(gpa);
}
