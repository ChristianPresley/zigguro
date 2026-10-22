//! Multi-cursor commands over a `SelectionSet`: add a cursor above or
//! below, add/skip the next occurrence, select all occurrences, column
//! (box) selection with optional virtual space, split into lines and
//! collapse. Each command records the set first so `undoCursorOp` can
//! take it back.
//!
//! Box selection works in display space through a `DisplayMapQuery` (the
//! F05 display map once it lands); `ColumnMap` is the headless fallback
//! where a row is a buffer line and x is a display column (tabs to the
//! next stop, wide characters two cells).

const std = @import("std");
const zg_regex = @import("zg_regex");
const zg_text = @import("zg_text");
const sel_mod = @import("selection.zig");
const cs_mod = @import("change_set.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");
const find = @import("../search/find.zig");

const Allocator = std.mem.Allocator;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const Range = cs_mod.Range;
const Document = document.Document;
const Snapshot = snapshot_mod.Snapshot;
const word = zg_text.unicode.word;
const grapheme = zg_text.unicode.grapheme;
const width = zg_text.unicode.width;

// -- display space ----------------------------------------------------------

/// A position in display space: a visual row and an x (pixels, or display
/// columns for `ColumnMap`).
pub const DisplayPos = struct { row: u64, col_px: f32 };

/// The buffer position nearest an x on a row, and how many columns past
/// the row's end the x lies (virtual space).
pub const Hit = struct { offset: u64, virtual: u32 = 0 };

/// What box selection needs from a display map.
pub const DisplayMapQuery = struct {
    ptr: *anyopaque,
    rowCountFn: *const fn (ptr: *anyopaque) u64,
    hitTestFn: *const fn (ptr: *anyopaque, row: u64, col_px: f32) Hit,

    pub fn rowCount(q: DisplayMapQuery) u64 {
        return q.rowCountFn(q.ptr);
    }

    pub fn hitTest(q: DisplayMapQuery, row: u64, col_px: f32) Hit {
        return q.hitTestFn(q.ptr, row, col_px);
    }
};

/// Display-column options for the headless fallback.
pub const ColumnOptions = struct {
    tab_size: u32 = 4,
    width: width.WidthOptions = .{},
};

/// The display width of the grapheme `g` starting at column `col`.
fn clusterWidth(g: []const u8, col: u32, o: ColumnOptions) u32 {
    if (g.len == 1 and g[0] == '\t') return o.tab_size - col % o.tab_size;
    return width.graphemeWidth(g, o.width);
}

/// The display column of byte `at` of `line`.
pub fn columnOf(line: []const u8, at: usize, o: ColumnOptions) u32 {
    var col: u32 = 0;
    var it = grapheme.Iterator.init(line);
    while (it.next()) |sp| {
        if (sp.start >= at) break;
        col += clusterWidth(line[sp.start..][0..sp.len], col, o);
    }
    return col;
}

/// The byte of `line` nearest display column `col` (a column inside a
/// tab or wide character rounds to the nearer edge, halfway to the
/// right), and the columns past the end.
pub fn byteAtColumn(line: []const u8, col: u32, o: ColumnOptions) struct { byte: usize, virtual: u32 } {
    var c: u32 = 0;
    var it = grapheme.Iterator.init(line);
    while (it.next()) |sp| {
        if (col <= c) return .{ .byte = sp.start, .virtual = 0 };
        const w = clusterWidth(line[sp.start..][0..sp.len], c, o);
        if (col < c + w) return .{ .byte = if ((col - c) * 2 < w) sp.start else sp.start + sp.len, .virtual = 0 };
        c += w;
    }
    return .{ .byte = line.len, .virtual = col - c };
}

/// Headless display map: row = line, x = display column.
pub const ColumnMap = struct {
    gpa: Allocator,
    snap: *const Snapshot,
    o: ColumnOptions = .{},
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(m: *ColumnMap) void {
        m.buf.deinit(m.gpa);
    }

    pub fn query(m: *ColumnMap) DisplayMapQuery {
        return .{ .ptr = m, .rowCountFn = rowCount, .hitTestFn = hitTest };
    }

    fn rowCount(ptr: *anyopaque) u64 {
        const m: *ColumnMap = @ptrCast(@alignCast(ptr));
        return m.snap.tree.lineCount();
    }

    fn hitTest(ptr: *anyopaque, row: u64, col_px: f32) Hit {
        const m: *ColumnMap = @ptrCast(@alignCast(ptr));
        const lr = m.snap.tree.lineRange(row);
        const line = lineText(m.gpa, &m.buf, m.snap, row) catch return .{ .offset = lr.start };
        const col: u32 = @intFromFloat(@max(0, @round(col_px)));
        const r = byteAtColumn(line, col, m.o);
        return .{ .offset = lr.start + r.byte, .virtual = r.virtual };
    }
};

/// The text of line `line` without its EOL, read into `buf`.
fn lineText(gpa: Allocator, buf: *std.ArrayList(u8), snap: *const Snapshot, line: u64) Allocator.Error![]const u8 {
    const lr = snap.tree.lineRange(line);
    buf.clearRetainingCapacity();
    try buf.ensureTotalCapacity(gpa, lr.end - lr.start);
    var it = snap.tree.slice(.{ .start = lr.start, .end = lr.end });
    while (it.next()) |c| buf.appendSliceAssumeCapacity(c);
    return buf.items;
}

// -- box selection ----------------------------------------------------------

/// A column selection between two display positions.
pub const BoxSelection = struct { anchor: DisplayPos, head: DisplayPos, virtual_space: bool = false };

/// One selection per display row of the box, from the anchor's x to the
/// head's x; the head's row becomes primary. Without virtual space, a
/// row shorter than the box gets a caret at its end.
pub fn boxToSelections(b: BoxSelection, dm: DisplayMapQuery, out: *SelectionSet) SelectionSet.Error!void {
    const rows = dm.rowCount();
    if (rows == 0) return;
    const r0 = @min(b.anchor.row, rows - 1);
    const r1 = @min(b.head.row, rows - 1);
    const lo = @min(r0, r1);
    const hi = @max(r0, r1);
    if (hi - lo + 1 > sel_mod.max_selections) return error.TooManySelections;
    var list = try std.ArrayList(Selection).initCapacity(out.gpa, hi - lo + 1);
    defer list.deinit(out.gpa);
    var row = lo;
    while (row <= hi) : (row += 1) {
        const a = dm.hitTest(row, b.anchor.col_px);
        const h = dm.hitTest(row, b.head.col_px);
        list.appendAssumeCapacity(.{ .anchor = a.offset, .head = h.offset, .virtual = if (b.virtual_space) h.virtual else 0 });
    }
    try out.pushHistory();
    try out.set(list.items, if (r1 >= r0) list.items.len - 1 else 0);
}

// -- vertical cursors -------------------------------------------------------

pub const Direction = enum { up, down };

/// Adds a caret on the line above the topmost (or below the bottommost)
/// selection's head, at the same display column. False at the edge of
/// the document.
pub fn addCursorVertical(snap: *const Snapshot, sels: *SelectionSet, dir: Direction, o: ColumnOptions) SelectionSet.Error!bool {
    const edge = switch (dir) {
        .up => sels.slice()[0],
        .down => sels.slice()[sels.count() - 1],
    };
    const t = &snap.tree;
    const line = t.lineOf(edge.head);
    const target = switch (dir) {
        .up => if (line == 0) return false else line - 1,
        .down => if (line + 1 >= t.lineCount()) return false else line + 1,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(sels.gpa);
    const src = try lineText(sels.gpa, &buf, snap, line);
    const col = columnOf(src, edge.head - t.lineStart(line), o) + edge.virtual;
    const dst = try lineText(sels.gpa, &buf, snap, target);
    const at = byteAtColumn(dst, col, o);
    try sels.pushHistory();
    try sels.add(.caret(t.lineStart(target) + at.byte));
    sels.normalize(.for_display);
    return true;
}

// -- splitting --------------------------------------------------------------

/// Splits every range spanning lines into one range per line (EOLs left
/// out; a last line the range only touches at column 0 is skipped).
/// Carets and single-line ranges stay.
pub fn splitIntoLines(snap: *const Snapshot, sels: *SelectionSet) SelectionSet.Error!void {
    const t = &snap.tree;
    var out: std.ArrayList(Selection) = .empty;
    defer out.deinit(sels.gpa);
    for (sels.slice()) |s| {
        const l0 = t.lineOf(s.start());
        const l1 = t.lineOf(s.end());
        if (s.isCaret() or l0 == l1) {
            try out.append(sels.gpa, s);
            continue;
        }
        var l = l0;
        while (l <= l1) : (l += 1) {
            const lr = t.lineRange(l);
            const a = @max(lr.start, s.start());
            const b = @min(lr.end, s.end());
            if (l == l1 and l != l0 and b == lr.start) break;
            if (out.items.len >= sel_mod.max_selections) return error.TooManySelections;
            try out.append(sels.gpa, .{ .anchor = a, .head = b });
        }
    }
    try sels.pushHistory();
    try sels.set(out.items, out.items.len - 1);
    sels.normalize(.for_display);
}

// -- occurrences ------------------------------------------------------------

/// Matching for occurrence commands. Null fields follow VS Code: started
/// from a caret, matching is whole-word and case-sensitive; started from a
/// selection, neither (the find widget's settings, passed explicitly).
pub const OccurrenceOptions = struct { case_sensitive: ?bool = null, whole_word: ?bool = null, wrap: bool = true };

/// Selects the word at each caret; true when any caret was expanded.
fn expandCarets(snap: *const Snapshot, sels: *SelectionSet) Allocator.Error!bool {
    var any = false;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(sels.gpa);
    for (sels.items.items) |*s| {
        if (!s.isCaret()) continue;
        const line = snap.tree.lineOf(s.head);
        const ls = snap.tree.lineStart(line);
        const text = try lineText(sels.gpa, &buf, snap, line);
        const at: usize = @intCast(s.head - ls);
        var w = word.wordAt(text, at);
        if (!wordish(w.kind) and at > 0) w = word.wordAt(text, at - 1);
        if (!wordish(w.kind) or w.len == 0) continue;
        const id = s.id;
        s.* = .{ .anchor = ls + w.start, .head = ls + w.start + w.len, .id = id };
        any = true;
    }
    return any;
}

fn wordish(k: word.WordSpan.Kind) bool {
    return k == .word or k == .number;
}

fn literalOptions(sels: *const SelectionSet, o: OccurrenceOptions) find.LiteralOptions {
    return .{ .case_sensitive = o.case_sensitive orelse sels.word_search, .whole_word = o.whole_word orelse sels.word_search };
}

/// The primary selection's text.
fn needleOf(gpa: Allocator, snap: *const Snapshot, sels: *const SelectionSet) Allocator.Error![]u8 {
    return snap.tree.copyRange(gpa, sels.primary().range());
}

/// Ctrl+D. With a caret, first selects the word under every caret (and
/// returns true). Otherwise adds the next occurrence of the primary's
/// text after it, wrapping when `o.wrap`; false when every occurrence is
/// already selected or there is none.
pub fn addNextOccurrence(doc: *Document, sels: *SelectionSet, o: OccurrenceOptions) !bool {
    var snap = doc.snapshot();
    defer snap.release();
    if (sels.primary().isCaret()) {
        try sels.pushHistory();
        const any = try expandCarets(&snap, sels);
        if (!any) {
            _ = try sels.undoCursorOp();
            return false;
        }
        sels.word_search = true;
        sels.normalize(.for_display);
        return true;
    }
    const r = try nextOccurrence(&snap, sels, o) orelse return false;
    try sels.pushHistory();
    try sels.add(.{ .anchor = r.start, .head = r.end });
    sels.normalize(.for_display);
    return true;
}

/// Replaces the primary with the next occurrence after it (Ctrl+K Ctrl+D).
pub fn skipOccurrence(doc: *Document, sels: *SelectionSet, o: OccurrenceOptions) !bool {
    var snap = doc.snapshot();
    defer snap.release();
    if (sels.primary().isCaret()) return false;
    const r = try nextOccurrence(&snap, sels, o) orelse return false;
    try sels.pushHistory();
    if (sels.count() > 1) _ = sels.items.orderedRemove(sels.primaryIndex());
    try sels.add(.{ .anchor = r.start, .head = r.end });
    sels.normalize(.for_display);
    return true;
}

fn nextOccurrence(snap: *const Snapshot, sels: *const SelectionSet, o: OccurrenceOptions) !?Range {
    const gpa = sels.gpa;
    const needle = try needleOf(gpa, snap, sels);
    defer gpa.free(needle);
    const from = sels.primary().end();
    const lo = literalOptions(sels, o);
    var at = from;
    // Skip matches already selected, at most one lap.
    var steps: usize = 0;
    while (steps <= sels.count()) : (steps += 1) {
        const r = (try find.literalSearch(gpa, snap, needle, at, lo)) orelse return null;
        if (!o.wrap and r.start < from) return null;
        if (!isSelected(sels, r)) return r;
        at = r.end;
        if (at >= snap.len()) at = 0;
    }
    return null;
}

fn isSelected(sels: *const SelectionSet, r: Range) bool {
    const items = sels.slice();
    // Selections are sorted by start.
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (items[mid].start() < r.start) lo = mid + 1 else hi = mid;
    }
    return lo < items.len and items[lo].start() == r.start and items[lo].end() == r.end;
}

/// Ctrl+Shift+L: selects every occurrence of the primary's text (after
/// expanding a caret to its word). Refuses with `TooManySelections` past
/// `max_selections`. Returns the count.
pub fn selectAllOccurrences(doc: *Document, sels: *SelectionSet, o: OccurrenceOptions) !usize {
    const gpa = sels.gpa;
    var snap = doc.snapshot();
    defer snap.release();
    try sels.pushHistory();
    errdefer _ = sels.undoCursorOp() catch {};
    if (sels.primary().isCaret()) {
        if (!try expandCarets(&snap, sels)) {
            _ = try sels.undoCursorOp();
            return 0;
        }
        sels.word_search = true;
        sels.normalize(.for_display);
    }
    const needle = try needleOf(gpa, &snap, sels);
    defer gpa.free(needle);
    const lo = literalOptions(sels, o);
    var re = try zg_regex.Regex.compile(gpa, needle, .{ .literal = true, .case_insensitive = !lo.case_sensitive, .whole_word = lo.whole_word });
    defer re.deinit(gpa);
    var cache = try re.newCache(gpa);
    defer cache.deinit();
    const prim = sels.primary();
    var list: std.ArrayList(Selection) = .empty;
    defer list.deinit(gpa);
    var primary_idx: usize = 0;
    var it = re.findIter(&cache, find.treeInput(&snap.tree));
    while (it.next()) |m| {
        if (m.start == m.end) continue;
        if (list.items.len >= sel_mod.max_selections) return error.TooManySelections;
        if (m.start <= prim.start() and prim.start() < m.end) primary_idx = list.items.len;
        try list.append(gpa, .{ .anchor = m.start, .head = m.end });
    }
    if (list.items.len == 0) {
        _ = try sels.undoCursorOp();
        return 0;
    }
    const word_search = sels.word_search;
    try sels.set(list.items, primary_idx);
    sels.word_search = word_search;
    return list.items.len;
}

/// Keeps only the primary selection (Escape).
pub fn collapse(sels: *SelectionSet) Allocator.Error!void {
    if (sels.count() == 1) return;
    try sels.pushHistory();
    sels.collapseToPrimary();
}
