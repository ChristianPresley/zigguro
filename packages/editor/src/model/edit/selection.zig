//! Selections: carets and ranges in the current version, as byte offsets.
//! A selection with `anchor == head` is a caret. Undo records the selections
//! before and after each step so they restore exactly.

const std = @import("std");
const cs_mod = @import("change_set.zig");

const Allocator = std.mem.Allocator;
const ChangeSet = cs_mod.ChangeSet;

/// One caret or range. `head` is where the cursor is drawn; `anchor` is the
/// fixed end. `goal_x` is the sticky pixel x for vertical movement.
pub const Selection = struct {
    anchor: u64,
    head: u64,
    goal_x: ?f32 = null,
    id: u32 = 0,

    /// A caret at `off`.
    pub fn caret(off: u64) Selection {
        return .{ .anchor = off, .head = off };
    }

    /// Whether this is a caret (empty selection).
    pub fn isCaret(s: Selection) bool {
        return s.anchor == s.head;
    }

    /// The smaller end.
    pub fn start(s: Selection) u64 {
        return @min(s.anchor, s.head);
    }

    /// The larger end.
    pub fn end(s: Selection) u64 {
        return @max(s.anchor, s.head);
    }

    /// The selected range.
    pub fn range(s: Selection) cs_mod.Range {
        return .{ .start = s.start(), .end = s.end() };
    }

    /// Maps through `cs`. A caret follows inserted text at it (`.right`);
    /// a range keeps insertions at its edges outside.
    pub fn map(s: Selection, cs: *const ChangeSet) Selection {
        var out = s;
        if (s.isCaret()) {
            out.anchor = cs.mapPos(s.anchor, .right);
            out.head = out.anchor;
        } else {
            const fwd = s.head > s.anchor;
            out.anchor = cs.mapPos(s.anchor, if (fwd) .right else .left);
            out.head = cs.mapPos(s.head, if (fwd) .left else .right);
            if (fwd and out.head < out.anchor) out.head = out.anchor;
            if (!fwd and out.anchor < out.head) out.anchor = out.head;
        }
        if (out.head != s.head) out.goal_x = null;
        return out;
    }
};

/// Whether two selection lists hold the same carets and ranges (goal
/// columns are ignored).
pub fn eql(a: []const Selection, b: []const Selection) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.anchor != y.anchor or x.head != y.head) return false;
    return true;
}

/// A copy of `sels` allocated with `gpa`.
pub fn dupe(gpa: Allocator, sels: []const Selection) Allocator.Error![]Selection {
    return gpa.dupe(Selection, sels);
}

test "selection: map caret and range" {
    const gpa = std.testing.allocator;
    var cs = try ChangeSet.fromEdits(gpa, 10, &.{.{ .range = .{ .start = 2, .end = 2 }, .text = "abc" }});
    defer cs.deinit();
    try std.testing.expectEqual(@as(u64, 5), Selection.caret(2).map(&cs).head);
    const r = (Selection{ .anchor = 2, .head = 6 }).map(&cs);
    try std.testing.expectEqual(@as(u64, 5), r.anchor);
    try std.testing.expectEqual(@as(u64, 9), r.head);
    try std.testing.expect(eql(&.{Selection.caret(1)}, &.{Selection.caret(1)}));
    try std.testing.expect(!eql(&.{Selection.caret(1)}, &.{Selection.caret(2)}));
}
