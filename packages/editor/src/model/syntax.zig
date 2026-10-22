//! Syntax for a document: drives a zg_syntax `Highlighter` and the
//! bracket-pair tree from document changes, and parses structure (tier 2
//! from snapshots, or the fallback from brackets and lines).
//!
//! zg_syntax knows lines, not documents (it sits a layer below), so this
//! adapter supplies a `LineSource` over a piece tree and turns each
//! `ChangeEvent` into the line edits the highlighter wants.

const std = @import("std");
const syntax = @import("zg_syntax");
const pt = @import("buffer/piece_tree.zig");
const document = @import("document.zig");
const Snapshot = @import("snapshot.zig").Snapshot;
const pairs = @import("edit/pairs.zig");

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
const BracketTree = syntax.BracketTree;
const bracket_tree = syntax.brackets.bracket_tree;
const HighlightBrackets = syntax.brackets.highlight_source.HighlightBrackets;

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

/// Highlighting and bracket pairs for one document, updated from its
/// change events. The bracket tree follows the tokens: it is exact where
/// the highlighting is.
pub const DocumentSyntax = struct {
    gpa: Allocator,
    lang: *const Language,
    hl: Highlighter,
    brackets: BracketTree,
    edits: std.ArrayList(LineEdit) = .empty,
    text_edits: std.ArrayList(bracket_tree.TextEdit) = .empty,
    retokenized: std.ArrayList(bracket_tree.Range) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    /// Version the highlighter reflects.
    version: u64,

    /// Highlighting of `tree` (at `version`) in `lang`; nothing is lexed
    /// until `ensure`, `idle` or an edit.
    pub fn init(gpa: Allocator, lang: *const Language, reg: *const Registry, tree: *const PieceTree, version: u64) Allocator.Error!DocumentSyntax {
        var hl: Highlighter = try .init(gpa, lang, reg);
        errdefer hl.deinit();
        try hl.reset(lineSource(tree));
        var ds: DocumentSyntax = .{ .gpa = gpa, .lang = lang, .hl = hl, .brackets = .init(gpa), .version = version };
        errdefer ds.brackets.deinit();
        try ds.rebuildBrackets(tree);
        return ds;
    }

    /// Frees everything.
    pub fn deinit(ds: *DocumentSyntax) void {
        ds.hl.deinit();
        ds.brackets.deinit();
        ds.edits.deinit(ds.gpa);
        ds.text_edits.deinit(ds.gpa);
        ds.retokenized.deinit(ds.gpa);
        ds.scratch.deinit(ds.gpa);
    }

    /// Applies a change (from a document listener; `after` is the
    /// document's new tree) and relexes until convergence or `deadline`.
    pub fn onChange(ds: *DocumentSyntax, ev: *const ChangeEvent, after: *const PieceTree, deadline: ?Deadline) Allocator.Error!void {
        std.debug.assert(ev.old_version == ds.version);
        ds.version = ev.new_version;
        const src = lineSource(after);
        if (try lineEdits(ds.gpa, ev, after.*, &ds.edits)) |edits| {
            if (edits.len > 0) try ds.hl.onEdits(edits, src, deadline);
            ds.text_edits.clearRetainingCapacity();
            for (ev.changes.replaces) |r| try ds.text_edits.append(ds.gpa, .{ .start = r.range.start, .end = r.range.end, .new_len = r.text.len });
            try ds.syncBrackets(after, ds.text_edits.items, edits);
        } else {
            try ds.hl.reset(src);
            try ds.rebuildBrackets(after);
        }
    }

    /// Makes lines `[first, last]` of `tree` exact (or approximate, see
    /// `Highlighter.ensure`).
    pub fn ensure(ds: *DocumentSyntax, tree: *const PieceTree, first: u64, last: u64) Allocator.Error!void {
        try ds.hl.ensure(lineSource(tree), first, last);
        try ds.syncBrackets(tree, &.{}, &.{});
    }

    /// Background relexing; true when everything is exact.
    pub fn idle(ds: *DocumentSyntax, tree: *const PieceTree, deadline: ?Deadline) Allocator.Error!bool {
        const done = try ds.hl.idle(lineSource(tree), deadline);
        try ds.syncBrackets(tree, &.{}, &.{});
        return done;
    }

    /// Fallback structure (bracket and indentation folds, comment runs,
    /// regions, declaration scopes) of `tree`, at the version the syntax
    /// reflects. Exact once `idle` has finished.
    pub fn fallbackStructure(ds: *DocumentSyntax, gpa: Allocator, tree: *const PieceTree) syntax.structure.structure.ParseError!Structure {
        const text = try tree.copyRange(gpa, .{ .start = 0, .end = tree.len() });
        defer gpa.free(text);
        var hints: CommentHints = .{ .hl = &ds.hl, .src = lineSource(tree), .gpa = gpa };
        defer hints.scratch.deinit(gpa);
        const bt: ?*const BracketTree = if (ds.lang.brackets.len > 0) &ds.brackets else null;
        return syntax.fallbackStructure(gpa, text, ds.version, bt, ds.lang, .{ .hints = .{ .ctx = &hints, .commentFn = CommentHints.isComment } });
    }

    fn bracketSource(ds: *DocumentSyntax, tree: *const PieceTree) HighlightBrackets {
        var hb: HighlightBrackets = .init(ds.gpa, &ds.hl, lineSource(tree), lineIndex(tree));
        hb.scratch = ds.scratch;
        ds.scratch = .empty;
        return hb;
    }

    fn rebuildBrackets(ds: *DocumentSyntax, tree: *const PieceTree) Allocator.Error!void {
        _ = ds.hl.takeRelexed();
        var hb = ds.bracketSource(tree);
        defer ds.scratch = hb.scratch;
        try ds.brackets.rebuild(hb.source());
    }

    /// Brings the bracket tree up to date: `text_edits` (old offsets) and
    /// `line_edits` (old lines) are the change just applied, if any; lines
    /// the highlighter relexed since are retokenized.
    fn syncBrackets(ds: *DocumentSyntax, tree: *const PieceTree, text_edits: []const bracket_tree.TextEdit, line_edits: []const LineEdit) Allocator.Error!void {
        ds.retokenized.clearRetainingCapacity();
        // Lines the edits touched lost their tokens, whether or not they
        // were relexed yet.
        var delta: i128 = 0;
        for (line_edits) |e| {
            const first: u64 = @intCast(@as(i128, e.first) + delta);
            try ds.retokenized.append(ds.gpa, lineBytes(tree, first, first + e.inserted));
            delta += @as(i128, e.inserted) - @as(i128, e.removed);
        }
        if (ds.hl.takeRelexed()) |r| try ds.retokenized.append(ds.gpa, lineBytes(tree, r.start, r.end));
        if (text_edits.len == 0 and ds.retokenized.items.len == 0) return;
        var hb = ds.bracketSource(tree);
        defer ds.scratch = hb.scratch;
        try ds.brackets.applyEdits(text_edits, ds.retokenized.items, hb.source());
    }
};

/// Token kinds of a document from its `DocumentSyntax`, for smart typing
/// (pairs stay out of strings and comments). `tree` is the version the
/// syntax reflects. At the end of a line only a comment counts: a string
/// token there is closed or continues on the next line either way.
pub const SyntaxTokens = struct {
    ds: *DocumentSyntax,
    tree: *const PieceTree,

    pub fn query(s: *SyntaxTokens) pairs.TokenQuery {
        return .{ .ptr = s, .kindAtFn = kindAt };
    }

    fn kindAt(ptr: *anyopaque, pos: u64) pairs.TokenKind {
        const s: *SyntaxTokens = @ptrCast(@alignCast(ptr));
        const lr = s.tree.lineRange(s.tree.lineOf(pos));
        const line = s.tree.lineOf(pos);
        s.ds.ensure(s.tree, line, line) catch return .code;
        const toks = s.ds.hl.tokens(line);
        const col = pos - lr.start;
        var hl: syntax.HighlightId = .none;
        for (toks) |t| {
            if (t.start > col) break;
            hl = t.hl;
        }
        const k = pairs.kindOf(hl);
        if (pos >= lr.end and k != .comment) return .code;
        return k;
    }
};

/// Bytes of lines `[a, b)` of `t`.
fn lineBytes(t: *const PieceTree, a: u64, b: u64) bracket_tree.Range {
    const n = t.lineCount();
    const s = if (a < n) t.lineStart(a) else t.len();
    const e = if (b < n) t.lineStart(b) else t.len();
    return .{ .start = s, .end = @max(s, e) };
}

/// Line offsets of `tree.*`.
pub fn lineIndex(tree: *const PieceTree) syntax.brackets.highlight_source.LineIndex {
    return .{ .ctx = @ptrCast(tree), .len = tree.len(), .startFn = treeLineStart, .lineOfFn = treeLineOf };
}

fn treeLineStart(ctx: *const anyopaque, line: u64) u64 {
    const t: *const PieceTree = @ptrCast(@alignCast(ctx));
    return t.lineStart(line);
}

fn treeLineOf(ctx: *const anyopaque, pos: u64) u64 {
    const t: *const PieceTree = @ptrCast(@alignCast(ctx));
    return t.lineOf(pos);
}

const CommentHints = struct {
    hl: *const Highlighter,
    src: LineSource,
    gpa: Allocator,
    scratch: std.ArrayList(u8) = .empty,

    fn isComment(ctx: *const anyopaque, line: u64) bool {
        const c: *CommentHints = @ptrCast(@alignCast(@constCast(ctx)));
        const text = c.src.get(line, &c.scratch, c.gpa) catch return false;
        return c.hl.isCommentLine(line, text);
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
    // The incrementally kept bracket tree equals one built from scratch.
    try ds.brackets.check();
    var pa: std.ArrayList(bracket_tree.BracketPairInfo) = .empty;
    defer pa.deinit(gpa);
    var pb: std.ArrayList(bracket_tree.BracketPairInfo) = .empty;
    defer pb.deinit(gpa);
    try ds.brackets.pairsInRange(gpa, .{ .start = 0, .end = tree.len() + 1 }, &pa);
    try fresh.brackets.pairsInRange(gpa, .{ .start = 0, .end = tree.len() + 1 }, &pb);
    try testing.expectEqualSlices(bracket_tree.BracketPairInfo, pb.items, pa.items);
    var ua: std.ArrayList(u64) = .empty;
    defer ua.deinit(gpa);
    var ub: std.ArrayList(u64) = .empty;
    defer ub.deinit(gpa);
    try ds.brackets.unmatched(gpa, .{ .start = 0, .end = tree.len() + 1 }, &ua);
    try fresh.brackets.unmatched(gpa, .{ .start = 0, .end = tree.len() + 1 }, &ub);
    try testing.expectEqualSlices(u64, ub.items, ua.items);
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

    const pieces = [_][]const u8{ "\n", "\r\n", "\"", "\\\\", "//", "'", "fn ", "x", "}", "{", "\r", "@", "(", ")", "[" };
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

test "DocumentSyntax: brackets in strings ignored, fallback structure" {
    const gpa = testing.allocator;
    var reg = try syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    const text =
        \\// One
        \\// two
        \\// three
        \\fn f(s: []const u8) void {
        \\    const x = "})]";
        \\    // ({[
        \\    g(s, '}');
        \\}
        \\
    ;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), text);
    defer doc.deinit();
    var ds = try DocumentSyntax.init(gpa, reg.get(.zig).?, &reg, &doc.tree, doc.version);
    defer ds.deinit();
    while (!try ds.idle(&doc.tree, null)) {}
    var un: std.ArrayList(u64) = .empty;
    defer un.deinit(gpa);
    try ds.brackets.unmatched(gpa, .{ .start = 0, .end = doc.len() }, &un);
    try testing.expectEqual(@as(usize, 0), un.items.len);
    const brace = std.mem.indexOf(u8, text, "{").?;
    const m = ds.brackets.matching(brace).?;
    try testing.expectEqual(@as(?u64, std.mem.lastIndexOf(u8, text, "}").?), m.close);
    var s = try ds.fallbackStructure(gpa, &doc.tree);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.folds.len);
    try testing.expectEqual(syntax.structure.structure.FoldKind.comment, s.folds[0].kind);
    try testing.expectEqual(@as(u32, 3), s.folds[1].start_line);
    try testing.expectEqual(@as(u32, 6), s.folds[1].end_line);
    try testing.expectEqual(@as(usize, 1), s.symbols.len);
    try testing.expectEqualStrings("f", s.symbols[0].name);
}

test "DocumentSyntax: C brackets inside multi-line comments and strings are ignored" {
    const gpa = testing.allocator;
    var reg = try syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    const text =
        \\int f(void) {
        \\    /* a comment over lines ( [
        \\       still ) } */
        \\    const char *s = "{ \
        \\    ] spliced";
        \\    return g('(');
        \\}
        \\
    ;
    const doc = try Document.initBytes(gpa, @enumFromInt(1), text);
    defer doc.deinit();
    var ds = try DocumentSyntax.init(gpa, reg.get(.c).?, &reg, &doc.tree, doc.version);
    defer ds.deinit();
    while (!try ds.idle(&doc.tree, null)) {}
    var un: std.ArrayList(u64) = .empty;
    defer un.deinit(gpa);
    try ds.brackets.unmatched(gpa, .{ .start = 0, .end = doc.len() }, &un);
    try testing.expectEqual(@as(usize, 0), un.items.len);
    const brace = std.mem.indexOf(u8, text, "{").?;
    try testing.expectEqual(@as(?u64, std.mem.lastIndexOf(u8, text, "}").?), ds.brackets.matching(brace).?.close);
}
