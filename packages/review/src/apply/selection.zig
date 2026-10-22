//! Hunk decisions as edits (E12.F02.S03.T01). Splits a text change into
//! the edit to land now and the edit that stays pending:
//! - `selected` (against the change's base): the replaces of the taken
//!   hunks, accepted or edited;
//! - `remainder` (against `base ∘ selected`): the replaces of the hunks
//!   still undecided.
//! Rejected hunks' replaces are in neither. Pure: no I/O.
//!
//! Example: base `"a\n.\nb\n.\nc\n"`, three one-line hunks (a→A, b→B,
//! c→C). Accepting hunk 0, editing hunk 1 to `"x\n"` and leaving hunk 2
//! gives `selected` = {0..1 → "A", 4..6 → "x\n"}, so the disk gets
//! `"A\n.\nx\n.\nc\n"`, and `remainder` = {8..9 → "C"} against that
//! text.
//!
//! Line-level selection inside a hunk (the `add -p` split) is not done
//! yet.

const std = @import("std");
const zg_core = @import("zg_core");
const model = @import("../model/root.zig");

const Allocator = std.mem.Allocator;
const ChangeSet = model.changeset.ChangeSet;
const Replace = model.changeset.Replace;
const Range = @import("zg_editor").model.edit.change_set.Range;
const Hunk = model.Hunk;
const Decision = model.Decision;
const FileChange = model.FileChange;

/// One hunk the reviewer rewrote before accepting.
pub const EditedHunk = struct {
    hunk: u32,
    /// The whole replacement for the hunk's `base_lines`.
    text: []const u8,
};

/// Decisions made now; a hunk named in none of them keeps its stored
/// decision.
pub const SelectionInput = struct {
    accept: []const u32 = &.{},
    reject: []const u32 = &.{},
    edited: []const EditedHunk = &.{},
};

pub const Decided = struct { hunk: u32, decision: Decision };

pub const SelectionResult = struct {
    selected: ChangeSet,
    remainder: ChangeSet,
    /// The decision of every hunk that is no longer undecided, by hunk id.
    decided: []Decided,

    /// Whether anything is taken.
    pub fn takes(r: *const SelectionResult) bool {
        for (r.decided) |d| if (d.decision != .rejected) return true;
        return false;
    }

    pub fn deinit(r: *SelectionResult, gpa: Allocator) void {
        r.selected.deinit();
        r.remainder.deinit();
        gpa.free(r.decided);
    }
};

pub const Error = Allocator.Error || error{UnknownHunk};

/// Splits `fc`'s text edits by the decisions in `in` (and the hunks' own).
/// `base` is the change's base text and `lines` its line index; they are
/// read only for edited hunks.
///
/// Example: with the base and hunks of the file comment,
/// `select(gpa, base, &lines, &fc, .{ .accept = &.{0}, .reject = &.{2} })`
/// selects {0..1 → "A"} and leaves {4..5 → "B"} pending.
pub fn select(gpa: Allocator, base: []const u8, lines: *const zg_core.LineIndex, fc: *const FileChange, in: SelectionInput) Error!SelectionResult {
    const edits = &fc.content.text.edits;
    for (in.accept) |h| if (h >= fc.hunks.len) return error.UnknownHunk;
    for (in.reject) |h| if (h >= fc.hunks.len) return error.UnknownHunk;
    for (in.edited) |e| if (e.hunk >= fc.hunks.len) return error.UnknownHunk;

    var take: std.ArrayList(Replace) = .empty;
    defer take.deinit(gpa);
    var rest: std.ArrayList(Replace) = .empty;
    defer rest.deinit(gpa);
    var decided: std.ArrayList(Decided) = .empty;
    errdefer decided.deinit(gpa);
    for (fc.hunks, 0..) |h, i| {
        const id: u32 = @intCast(i);
        const reps = edits.replaces[h.replace_span[0]..h.replace_span[1]];
        if (editedText(in, id)) |text| {
            try take.append(gpa, .{ .range = hunkRange(base, lines, h, reps), .text = text });
            try decided.append(gpa, .{ .hunk = id, .decision = .edited });
            continue;
        }
        const d = decisionOf(in, id) orelse h.decision;
        switch (d) {
            .accepted, .edited => try take.appendSlice(gpa, reps),
            .undecided => try rest.appendSlice(gpa, reps),
            .rejected => {},
        }
        if (d != .undecided) try decided.append(gpa, .{ .hunk = id, .decision = d });
    }
    var sel = try fromSorted(gpa, edits.base_len, take.items);
    errdefer sel.deinit();
    var r0 = try fromSorted(gpa, edits.base_len, rest.items);
    defer r0.deinit();
    return .{ .selected = sel, .remainder = try r0.transform(&sel, false, gpa), .decided = try decided.toOwnedSlice(gpa) };
}

fn editedText(in: SelectionInput, hunk: u32) ?[]const u8 {
    for (in.edited) |e| if (e.hunk == hunk) return e.text;
    return null;
}

fn decisionOf(in: SelectionInput, hunk: u32) ?Decision {
    for (in.reject) |h| if (h == hunk) return .rejected;
    for (in.accept) |h| if (h == hunk) return .accepted;
    return null;
}

/// The bytes of `h`'s base lines, widened to cover its replaces.
fn hunkRange(base: []const u8, lines: *const zg_core.LineIndex, h: Hunk, reps: []const Replace) Range {
    const n = lines.lineCount();
    var lo: u64 = if (h.base_lines.start < n) lines.lineStart(h.base_lines.start) else base.len;
    var hi: u64 = if (h.base_lines.end() < n) lines.lineStart(h.base_lines.end()) else base.len;
    if (reps.len > 0) {
        lo = @min(lo, reps[0].range.start);
        hi = @max(hi, reps[reps.len - 1].range.end);
    }
    return .{ .start = lo, .end = @max(lo, hi) };
}

fn fromSorted(gpa: Allocator, base_len: u64, reps: []const Replace) Allocator.Error!ChangeSet {
    return ChangeSet.fromEdits(gpa, base_len, reps) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // Subsets of a valid ChangeSet, or whole hunks in their place.
        error.Overlap, error.OutOfBounds => unreachable,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Fixture = struct {
    base: []const u8,
    lines: zg_core.LineIndex,
    fc: FileChange,
    hunks: []Hunk,

    fn init(base: []const u8, reps: []const Replace) !Fixture {
        const gpa = testing.allocator;
        var lines: zg_core.LineIndex = try .build(gpa, base);
        errdefer lines.deinit(gpa);
        var edits = try ChangeSet.fromEdits(gpa, base.len, reps);
        errdefer edits.deinit();
        const hs = try model.deriveHunks(gpa, base, &lines, &edits, .{ .merge_gap_lines = 0 });
        return .{
            .base = base,
            .lines = lines,
            .hunks = hs,
            .fc = .{ .path = "f", .op = .modify, .content = .{ .text = .{ .base = .of(base), .edits = edits } }, .hunks = hs },
        };
    }

    fn deinit(f: *Fixture) void {
        f.fc.deinitContent();
        testing.allocator.free(f.hunks);
        f.lines.deinit(testing.allocator);
    }

    fn run(f: *Fixture, in: SelectionInput) !struct { mid: []u8, end: []u8, r: SelectionResult } {
        const gpa = testing.allocator;
        var r = try select(gpa, f.base, &f.lines, &f.fc, in);
        errdefer r.deinit(gpa);
        const mid = try r.selected.applyToSlice(gpa, f.base);
        errdefer gpa.free(mid);
        return .{ .mid = mid, .end = try r.remainder.applyToSlice(gpa, mid), .r = r };
    }
};

test "selection: accept 2 of 5 hunks, remainder equals undecided shifted" {
    const base = "a\n.\nb\n.\nc\n.\nd\n.\ne\n";
    var f = try Fixture.init(base, &.{
        .{ .range = .{ .start = 0, .end = 1 }, .text = "AA" },
        .{ .range = .{ .start = 4, .end = 5 }, .text = "B" },
        .{ .range = .{ .start = 8, .end = 9 }, .text = "C" },
        .{ .range = .{ .start = 12, .end = 13 }, .text = "D" },
        .{ .range = .{ .start = 16, .end = 17 }, .text = "" },
    });
    defer f.deinit();
    try testing.expectEqual(@as(usize, 5), f.hunks.len);
    var o = try f.run(.{ .accept = &.{ 0, 3 }, .reject = &.{1} });
    defer {
        testing.allocator.free(o.mid);
        testing.allocator.free(o.end);
        o.r.deinit(testing.allocator);
    }
    try testing.expectEqualStrings("AA\n.\nb\n.\nc\n.\nD\n.\ne\n", o.mid);
    try testing.expectEqualStrings("AA\n.\nb\n.\nC\n.\nD\n.\n\n", o.end);
    try testing.expectEqual(@as(usize, 3), o.r.decided.len);
    try testing.expect(o.r.takes());
}

test "selection: edited hunk replaces base range, decision edited" {
    const base = "a\n.\nb\n.\nc\n";
    var f = try Fixture.init(base, &.{
        .{ .range = .{ .start = 0, .end = 1 }, .text = "A" },
        .{ .range = .{ .start = 4, .end = 5 }, .text = "B" },
        .{ .range = .{ .start = 8, .end = 9 }, .text = "C" },
    });
    defer f.deinit();
    var o = try f.run(.{ .accept = &.{0}, .edited = &.{.{ .hunk = 1, .text = "x\ny\n" }} });
    defer {
        testing.allocator.free(o.mid);
        testing.allocator.free(o.end);
        o.r.deinit(testing.allocator);
    }
    try testing.expectEqualStrings("A\n.\nx\ny\n.\nc\n", o.mid);
    try testing.expectEqualStrings("A\n.\nx\ny\n.\nC\n", o.end);
    try testing.expectEqual(Decision.edited, o.r.decided[1].decision);
}

test "selection: reject all gives empty selected and empty remainder" {
    const base = "a\n.\nb\n";
    var f = try Fixture.init(base, &.{
        .{ .range = .{ .start = 0, .end = 1 }, .text = "A" },
        .{ .range = .{ .start = 4, .end = 5 }, .text = "B" },
    });
    defer f.deinit();
    var o = try f.run(.{ .reject = &.{ 0, 1 } });
    defer {
        testing.allocator.free(o.mid);
        testing.allocator.free(o.end);
        o.r.deinit(testing.allocator);
    }
    try testing.expect(o.r.selected.isIdentity());
    try testing.expect(o.r.remainder.isIdentity());
    try testing.expect(!o.r.takes());
}

test "selection: stored decisions count, unknown hunks are refused" {
    const base = "a\n.\nb\n";
    var f = try Fixture.init(base, &.{
        .{ .range = .{ .start = 0, .end = 1 }, .text = "A" },
        .{ .range = .{ .start = 4, .end = 5 }, .text = "B" },
    });
    defer f.deinit();
    f.hunks[1].decision = .accepted;
    var o = try f.run(.{});
    defer {
        testing.allocator.free(o.mid);
        testing.allocator.free(o.end);
        o.r.deinit(testing.allocator);
    }
    try testing.expectEqualStrings("a\n.\nB\n", o.mid);
    try testing.expectEqualStrings("A\n.\nB\n", o.end);
    try testing.expectError(error.UnknownHunk, select(testing.allocator, base, &f.lines, &f.fc, .{ .accept = &.{2} }));
}

fn fuzzSelection(_: void, sm: *std.testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var buf: [256]u8 = undefined;
    const raw = buf[0..sm.slice(&buf)];
    if (raw.len < 4) return;
    // A base of short lines, then edits and decisions from the rest.
    var base_buf: [128]u8 = undefined;
    const nb = @min(raw.len / 2, base_buf.len);
    for (raw[0..nb], base_buf[0..nb]) |c, *o| o.* = switch (c % 5) {
        0 => '\n',
        1 => '\r',
        else => 'a' + c % 3,
    };
    const base = base_buf[0..nb];
    var reps: std.ArrayList(Replace) = .empty;
    defer reps.deinit(gpa);
    var pos: u64 = 0;
    var i: usize = nb;
    while (i + 2 < raw.len) : (i += 3) {
        const start = pos + raw[i] % 8;
        if (start > base.len) break;
        const end = @min(base.len, start + raw[i + 1] % 4);
        try reps.append(gpa, .{ .range = .{ .start = start, .end = end }, .text = ([_][]const u8{ "", "x", "\n", "y\r\n" })[raw[i + 2] % 4] });
        pos = end + 1;
    }
    var f = try Fixture.init(base, reps.items);
    defer f.deinit();
    var all: std.ArrayList(Replace) = .empty;
    defer all.deinit(gpa);
    for (f.hunks, 0..) |*h, k| {
        h.decision = @enumFromInt(raw[k % raw.len] % 3);
        if (h.decision != .rejected) try all.appendSlice(gpa, f.fc.content.text.edits.replaces[h.replace_span[0]..h.replace_span[1]]);
    }
    var want_cs = try ChangeSet.fromEdits(gpa, base.len, all.items);
    defer want_cs.deinit();
    const want = try want_cs.applyToSlice(gpa, base);
    defer gpa.free(want);
    var o = try f.run(.{});
    defer {
        gpa.free(o.mid);
        gpa.free(o.end);
        o.r.deinit(gpa);
    }
    try testing.expectEqualStrings(want, o.end);
}

test "selection: fuzz selected then remainder equals every non-rejected edit" {
    try testing.fuzz({}, fuzzSelection, .{});
}
