//! Selections: carets and ranges in the current version, as byte offsets.
//! A selection with `anchor == head` is a caret. Undo records the selections
//! before and after each step so they restore exactly. `SelectionSet` keeps
//! many of them sorted and merged, with a primary that follows its id.

const std = @import("std");
const cs_mod = @import("change_set.zig");

const Allocator = std.mem.Allocator;
const ChangeSet = cs_mod.ChangeSet;

/// One caret or range. `head` is where the cursor is drawn; `anchor` is the
/// fixed end. `goal_x` is the sticky pixel x for vertical movement.
/// `virtual` counts columns past the end of the head's line (box selection
/// in virtual space): typing pads with that many spaces first.
pub const Selection = struct {
    anchor: u64,
    head: u64,
    goal_x: ?f32 = null,
    id: u32 = 0,
    virtual: u32 = 0,

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
        if (out.head != s.head) {
            out.goal_x = null;
            out.virtual = 0;
        }
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

/// Most selections a set holds; commands that would exceed it refuse.
pub const max_selections: usize = 100_000;

/// How `SelectionSet.normalize` merges. Both merge overlapping ranges and
/// carets at one offset; `.for_edit` (deletions) also merges a caret into
/// a range it touches.
pub const NormalizeMode = enum { for_display, for_edit };

/// Cursor operations kept for `undoCursorOp`.
const max_history = 64;

/// Carets and ranges sorted by start, without overlaps after `normalize`.
/// Never empty. The primary is tracked by id, so it survives sorting and
/// merging; a merged selection takes the primary's id when it absorbs it.
pub const SelectionSet = struct {
    gpa: Allocator,
    items: std.ArrayList(Selection) = .empty,
    primary_id: u32 = 0,
    next_id: u32 = 1,
    history: std.ArrayList([]Selection) = .empty,
    history_primary: std.ArrayList(u32) = .empty,
    /// Occurrence commands match whole words, case-sensitively (set when
    /// one started from a caret; cleared by `set` and text edits).
    word_search: bool = false,

    pub const Error = error{TooManySelections} || Allocator.Error;

    /// A set holding `first` as the primary.
    pub fn init(gpa: Allocator, first: Selection) Allocator.Error!SelectionSet {
        var s: SelectionSet = .{ .gpa = gpa };
        var f = first;
        f.id = 0;
        try s.items.append(gpa, f);
        return s;
    }

    /// Frees the selections and cursor history.
    pub fn deinit(s: *SelectionSet) void {
        s.items.deinit(s.gpa);
        for (s.history.items) |h| s.gpa.free(h);
        s.history.deinit(s.gpa);
        s.history_primary.deinit(s.gpa);
    }

    /// The selections in order.
    pub fn slice(s: *const SelectionSet) []const Selection {
        return s.items.items;
    }

    /// How many selections there are.
    pub fn count(s: *const SelectionSet) usize {
        return s.items.items.len;
    }

    /// The index of the primary selection.
    pub fn primaryIndex(s: *const SelectionSet) u32 {
        for (s.items.items, 0..) |x, i| if (x.id == s.primary_id) return @intCast(i);
        return 0;
    }

    /// The primary selection.
    pub fn primary(s: *const SelectionSet) Selection {
        return s.items.items[s.primaryIndex()];
    }

    /// Makes selection `idx` the primary.
    pub fn setPrimary(s: *SelectionSet, idx: u32) void {
        s.primary_id = s.items.items[idx].id;
    }

    /// Adds `sel` as the new primary (normalize afterwards). Refuses past
    /// `max_selections`.
    pub fn add(s: *SelectionSet, sel: Selection) Error!void {
        if (s.items.items.len >= max_selections) return error.TooManySelections;
        var x = sel;
        x.id = s.next_id;
        s.next_id +%= 1;
        try s.items.append(s.gpa, x);
        s.primary_id = x.id;
    }

    /// Replaces every selection with `sels` (at least one); `primary`
    /// indexes `sels`. Ids are reassigned.
    pub fn set(s: *SelectionSet, sels: []const Selection, primary_idx: usize) Error!void {
        std.debug.assert(sels.len > 0);
        if (sels.len > max_selections) return error.TooManySelections;
        s.items.clearRetainingCapacity();
        try s.items.appendSlice(s.gpa, sels);
        s.word_search = false;
        for (s.items.items) |*x| {
            x.id = s.next_id;
            s.next_id +%= 1;
        }
        s.primary_id = s.items.items[@min(primary_idx, sels.len - 1)].id;
    }

    /// Keeps only the primary selection.
    pub fn collapseToPrimary(s: *SelectionSet) void {
        const p = s.primary();
        s.items.clearRetainingCapacity();
        s.items.appendAssumeCapacity(p);
    }

    /// Maps every selection through `cs` and normalizes for display.
    pub fn mapThrough(s: *SelectionSet, cs: *const ChangeSet) void {
        for (s.items.items) |*x| x.* = x.map(cs);
        s.normalize(.for_display);
    }

    /// Sorts by start and merges per `mode`. A merged selection spans its
    /// parts and keeps the direction of the first; it takes the primary's
    /// id (and so stays primary) when it absorbs the primary.
    pub fn normalize(s: *SelectionSet, mode: NormalizeMode) void {
        const items = s.items.items;
        if (items.len <= 1) return;
        std.sort.pdq(Selection, items, {}, struct {
            fn lt(_: void, a: Selection, b: Selection) bool {
                if (a.start() != b.start()) return a.start() < b.start();
                return a.end() < b.end();
            }
        }.lt);
        var out: usize = 1;
        for (items[1..]) |x| {
            const last = &items[out - 1];
            if (merges(last.*, x, mode)) {
                const lo = @min(last.start(), x.start());
                const hi = @max(last.end(), x.end());
                const back = last.head < last.anchor;
                const id = if (x.id == s.primary_id) x.id else last.id;
                const keep_virtual = if (x.end() >= last.end()) x.virtual else last.virtual;
                if (lo == hi) {
                    last.virtual = @max(last.virtual, x.virtual);
                } else {
                    last.* = if (back) .{ .anchor = hi, .head = lo } else .{ .anchor = lo, .head = hi };
                    last.virtual = if (back) 0 else keep_virtual;
                }
                last.id = id;
                continue;
            }
            items[out] = x;
            out += 1;
        }
        s.items.shrinkRetainingCapacity(out);
    }

    fn merges(a: Selection, b: Selection, mode: NormalizeMode) bool {
        // b.start() >= a.start() after sorting.
        if (b.start() < a.end()) return true;
        if (b.start() > a.end()) return false;
        // Touching: b starts where a ends.
        if (a.isCaret() and b.isCaret()) return true;
        return mode == .for_edit and (a.isCaret() or b.isCaret());
    }

    /// Records the current selections so `undoCursorOp` can restore them;
    /// cursor commands call it before changing the set.
    pub fn pushHistory(s: *SelectionSet) Allocator.Error!void {
        if (s.history.items.len == max_history) {
            s.gpa.free(s.history.orderedRemove(0));
            _ = s.history_primary.orderedRemove(0);
        }
        const copy = try dupe(s.gpa, s.items.items);
        errdefer s.gpa.free(copy);
        try s.history.append(s.gpa, copy);
        errdefer _ = s.history.pop();
        try s.history_primary.append(s.gpa, s.primary_id);
    }

    /// Restores the selections before the last cursor operation; false
    /// when there is none.
    pub fn undoCursorOp(s: *SelectionSet) Allocator.Error!bool {
        const prev = s.history.pop() orelse return false;
        defer s.gpa.free(prev);
        const pid = s.history_primary.pop().?;
        s.items.clearRetainingCapacity();
        try s.items.appendSlice(s.gpa, prev);
        s.primary_id = pid;
        return true;
    }

    /// Forgets the cursor history (after a text edit).
    pub fn clearHistory(s: *SelectionSet) void {
        for (s.history.items) |h| s.gpa.free(h);
        s.history.clearRetainingCapacity();
        s.history_primary.clearRetainingCapacity();
    }

    /// Iterates the selected ranges in order.
    pub fn ranges(s: *const SelectionSet) RangeIterator {
        return .{ .items = s.items.items };
    }
};

/// Yields each selection's range.
pub const RangeIterator = struct {
    items: []const Selection,
    i: usize = 0,

    pub fn next(it: *RangeIterator) ?cs_mod.Range {
        if (it.i >= it.items.len) return null;
        defer it.i += 1;
        return it.items[it.i].range();
    }
};

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
