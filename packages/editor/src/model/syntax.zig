//! Syntax for a document: drives a zg_syntax `Highlighter` from document
//! changes and parses tier-2 structure from snapshots.
//!
//! zg_syntax knows lines, not documents (it sits a layer below), so this
//! adapter supplies a `LineSource` over a piece tree and turns each
//! `ChangeEvent` into the line edits the highlighter wants.

const std = @import("std");
const syntax = @import("zg_syntax");
const pt = @import("buffer/piece_tree.zig");
const document = @import("document.zig");
const Snapshot = @import("snapshot.zig").Snapshot;

const Allocator = std.mem.Allocator;
const PieceTree = pt.PieceTree;
const Highlighter = syntax.Highlighter;
const LineSource = syntax.LineSource;
const LineEdit = syntax.LineEdit;
const Deadline = syntax.Deadline;
const Language = syntax.Language;
const Registry = syntax.Registry;
const Structure = syntax.Structure;
const ChangeEvent = document.ChangeEvent;

/// A `LineSource` over `tree.*` (which must outlive the source). Lines that
/// fit in one piece are returned in place; others are copied to scratch.
pub fn lineSource(tree: *const PieceTree) LineSource {
    return .{ .ctx = @ptrCast(tree), .lines = tree.lineCount(), .getFn = treeLine };
}

fn treeLine(ctx: *const anyopaque, line: u64, scratch: *std.ArrayList(u8), gpa: Allocator) Allocator.Error![]const u8 {
    const t: *const PieceTree = @ptrCast(@alignCast(ctx));
    const r = t.lineRange(line);
    if (r.start == r.end) return "";
    const p = t.pieceAt(r.start);
    if (r.end <= p.base + p.bytes.len) return p.bytes[@intCast(r.start - p.base)..@intCast(r.end - p.base)];
    scratch.clearRetainingCapacity();
    try scratch.ensureTotalCapacity(gpa, @intCast(r.end - r.start));
    var it = t.slice(.{ .start = r.start, .end = r.end });
    while (it.next()) |chunk| scratch.appendSliceAssumeCapacity(chunk);
    return scratch.items;
}

/// The line edits for `ev`, in old-text line coordinates, sorted and
/// merged so no two share a line; `after` is the new tree. Null when the
/// line counts do not add up (the caller resets instead).
pub fn lineEdits(gpa: Allocator, ev: *const ChangeEvent, after: PieceTree, out: *std.ArrayList(LineEdit)) Allocator.Error!?[]const LineEdit {
    out.clearRetainingCapacity();
    const before = ev.before;
    const cs = ev.changes;
    // The edit being built: old lines [first, old_last], new lines
    // [new_first, new_last].
    const Pending = struct { first: u64, old_last: u64, new_first: u64, new_last: u64 };
    var cur: ?Pending = null;
    // Lines added minus lines removed by the edits already in `out`.
    var delta: i128 = 0;
    for (cs.replaces, cs.new_starts) |r, ns| {
        const first = before.lineOf(r.range.start);
        const old_last = before.lineOf(r.range.end);
        const new_end = after.lineOf(ns + r.text.len);
        if (cur) |*c| {
            if (first <= c.old_last) {
                // Shares a line with the previous edit: extend it.
                c.old_last = @max(c.old_last, old_last);
                c.new_last = @max(c.new_last, new_end);
                continue;
            }
            delta += try flush(gpa, out, c.*);
        }
        const new_first: u64 = @intCast(@as(i128, first) + delta);
        cur = .{ .first = first, .old_last = old_last, .new_first = new_first, .new_last = @max(new_first, new_end) };
    }
    if (cur) |c| delta += try flush(gpa, out, c);
    if (@as(i128, before.lineCount()) + delta != after.lineCount()) return null;
    return out.items;
}

fn flush(gpa: Allocator, out: *std.ArrayList(LineEdit), c: anytype) Allocator.Error!i128 {
    const e: LineEdit = .{ .first = c.first, .removed = c.old_last + 1 - c.first, .inserted = c.new_last + 1 - c.new_first };
    try out.append(gpa, e);
    return @as(i128, e.inserted) - @as(i128, e.removed);
}

/// Highlighting for one document, updated from its change events.
pub const DocumentSyntax = struct {
    gpa: Allocator,
    lang: *const Language,
    hl: Highlighter,
    edits: std.ArrayList(LineEdit) = .empty,
    /// Version the highlighter reflects.
    version: u64,

    /// Highlighting of `tree` (at `version`) in `lang`; nothing is lexed
    /// until `ensure`, `idle` or an edit.
    pub fn init(gpa: Allocator, lang: *const Language, reg: *const Registry, tree: *const PieceTree, version: u64) Allocator.Error!DocumentSyntax {
        var hl: Highlighter = try .init(gpa, lang, reg);
        errdefer hl.deinit();
        try hl.reset(lineSource(tree));
        return .{ .gpa = gpa, .lang = lang, .hl = hl, .version = version };
    }

    /// Frees everything.
    pub fn deinit(ds: *DocumentSyntax) void {
        ds.hl.deinit();
        ds.edits.deinit(ds.gpa);
    }

    /// Applies a change (from a document listener; `after` is the
    /// document's new tree) and relexes until convergence or `deadline`.
    pub fn onChange(ds: *DocumentSyntax, ev: *const ChangeEvent, after: *const PieceTree, deadline: ?Deadline) Allocator.Error!void {
        std.debug.assert(ev.old_version == ds.version);
        ds.version = ev.new_version;
        const src = lineSource(after);
        if (try lineEdits(ds.gpa, ev, after.*, &ds.edits)) |edits| {
            if (edits.len > 0) try ds.hl.onEdits(edits, src, deadline);
        } else try ds.hl.reset(src);
    }

    /// Makes lines `[first, last]` of `tree` exact (or approximate, see
    /// `Highlighter.ensure`).
    pub fn ensure(ds: *DocumentSyntax, tree: *const PieceTree, first: u64, last: u64) Allocator.Error!void {
        return ds.hl.ensure(lineSource(tree), first, last);
    }

    /// Background relexing; true when everything is exact.
    pub fn idle(ds: *DocumentSyntax, tree: *const PieceTree, deadline: ?Deadline) Allocator.Error!bool {
        return ds.hl.idle(lineSource(tree), deadline);
    }
};

/// Parses the tier-2 structure of `snap` in `lang` (any thread), or null
/// when the language has none.
pub fn parseStructure(gpa: Allocator, lang: *const Language, snap: *const Snapshot) syntax.structure.structure.ParseError!?Structure {
    const parse = lang.structure orelse return null;
    const text = try snap.tree.copyRange(gpa, .{ .start = 0, .end = snap.tree.len() });
    defer gpa.free(text);
    return try parse(gpa, text, snap.version);
}

const testing = std.testing;
const ChangeSet = @import("edit/change_set.zig").ChangeSet;
const Document = document.Document;

/// Keeps a `DocumentSyntax` in step with a document, as the UI will.
const Follower = struct {
    doc: *Document,
    ds: *DocumentSyntax,

    fn onChange(ctx: *anyopaque, ev: *const ChangeEvent) void {
        const f: *Follower = @ptrCast(@alignCast(ctx));
        f.ds.onChange(ev, &f.doc.tree, null) catch @panic("oom");
    }
};

fn expectMatchesFresh(gpa: Allocator, ds: *DocumentSyntax, reg: *const Registry, tree: *const PieceTree) !void {
    while (!try ds.idle(tree, null)) {}
    var fresh = try DocumentSyntax.init(gpa, ds.lang, reg, tree, 0);
    defer fresh.deinit();
    while (!try fresh.idle(tree, null)) {}
    try testing.expectEqual(fresh.hl.lineCount(), ds.hl.lineCount());
    for (0..@intCast(fresh.hl.lineCount())) |line| {
        try testing.expectEqualSlices(syntax.Token, fresh.hl.tokens(line), ds.hl.tokens(line));
        try testing.expect(fresh.hl.endState(line).eql(ds.hl.endState(line)));
    }
}

test "lineEdits: inside a line, across lines, CRLF and merging" {
    const gpa = testing.allocator;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "ab\ncd\r\nef\ngh");
    defer doc.deinit();
    var out: std.ArrayList(LineEdit) = .empty;
    defer out.deinit(gpa);
    const Probe = struct {
        out: *std.ArrayList(LineEdit),
        doc: *Document,
        got: ?[]const LineEdit = null,
        fn onChange(ctx: *anyopaque, ev: *const ChangeEvent) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.got = (lineEdits(testing.allocator, ev, p.doc.tree, p.out) catch @panic("oom"));
        }
    };
    var probe: Probe = .{ .out = &out, .doc = doc };
    _ = try doc.subscribe(.{ .ctx = &probe, .onChange = Probe.onChange });
    const steps = [_]struct { edits: []const pt.Edit, want: []const LineEdit }{
        // Typing inside line 1.
        .{ .edits = &.{.{ .range = .{ .start = 4, .end = 4 }, .text = "x" }}, .want = &.{.{ .first = 1, .removed = 1, .inserted = 1 }} },
        // Splitting line 0.
        .{ .edits = &.{.{ .range = .{ .start = 1, .end = 1 }, .text = "\n" }}, .want = &.{.{ .first = 0, .removed = 1, .inserted = 2 }} },
        // Joining lines 0-1 ("a\nb\ncxd\r\nef\ngh").
        .{ .edits = &.{.{ .range = .{ .start = 1, .end = 2 }, .text = "" }}, .want = &.{.{ .first = 0, .removed = 2, .inserted = 1 }} },
        // Two edits on line 1 ("ab\ncxd\r\n...") merge; one on line 3.
        .{ .edits = &.{
            .{ .range = .{ .start = 3, .end = 3 }, .text = "1\n" },
            .{ .range = .{ .start = 5, .end = 5 }, .text = "2" },
            .{ .range = .{ .start = 11, .end = 11 }, .text = "3" },
        }, .want = &.{ .{ .first = 1, .removed = 1, .inserted = 2 }, .{ .first = 3, .removed = 1, .inserted = 1 } } },
        // Deleting the LF of a CRLF joins nothing ("\r" still ends a line).
        .{ .edits = &.{.{ .range = .{ .start = 10, .end = 11 }, .text = "" }}, .want = &.{.{ .first = 2, .removed = 2, .inserted = 2 }} },
    };
    for (steps) |step| {
        var cs = try ChangeSet.fromEdits(gpa, doc.len(), step.edits);
        defer cs.deinit();
        probe.got = null;
        try doc.applyChangeSet(&cs, .{ .user = 0 });
        try testing.expectEqualSlices(LineEdit, step.want, probe.got.?);
    }
}

test "DocumentSyntax follows random edits" {
    const gpa = testing.allocator;
    var reg = try syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    const lang = reg.get(.zig).?;
    const initial =
        \\const std = @import("std");
        \\/// Doc.
        \\pub fn main() void {
        \\    const s = "a\"b";
        \\    const m =
        \\        \\multi
        \\        \\line
        \\    ;
        \\    _ = 'x' + 0x1f;
        \\}
        \\
    ;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), initial);
    defer doc.deinit();
    var ds = try DocumentSyntax.init(gpa, lang, &reg, &doc.tree, doc.version);
    defer ds.deinit();
    var follower: Follower = .{ .doc = doc, .ds = &ds };
    _ = try doc.subscribe(.{ .ctx = &follower, .onChange = Follower.onChange });

    const pieces = [_][]const u8{ "\n", "\r\n", "\"", "\\\\", "//", "'", "fn ", "x", "}", "{", "\r", "@" };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    for (0..300) |round| {
        const n = doc.len();
        var edits: [3]pt.Edit = undefined;
        const k = rand.intRangeAtMost(usize, 1, 3);
        var pos: u64 = 0;
        var count: usize = 0;
        for (0..k) |_| {
            if (pos > n) break;
            const start = rand.intRangeAtMost(u64, pos, n);
            const end = @min(n, start + rand.uintLessThan(u64, 4));
            edits[count] = .{ .range = .{ .start = start, .end = end }, .text = pieces[rand.uintLessThan(usize, pieces.len)] };
            count += 1;
            pos = end + 1;
        }
        var cs = try ChangeSet.fromEdits(gpa, n, edits[0..count]);
        defer cs.deinit();
        try doc.applyChangeSet(&cs, .{ .user = 0 });
        if (round % 10 == 0) try expectMatchesFresh(gpa, &ds, &reg, &doc.tree);
    }
    try expectMatchesFresh(gpa, &ds, &reg, &doc.tree);
}

test "parseStructure from a snapshot" {
    const gpa = testing.allocator;
    var reg = try syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "const A = struct {\n    x: u32,\n};\nfn f() void {}\n");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.release();
    var s = (try parseStructure(gpa, reg.get(.zig).?, &snap)).?;
    defer s.deinit();
    try testing.expectEqual(snap.version, s.version);
    try testing.expect(s.symbols.len >= 3);
    try testing.expectEqualStrings("A", s.symbols[0].name);
    try testing.expect(try parseStructure(gpa, reg.get(.plain).?, &snap) == null);
}
