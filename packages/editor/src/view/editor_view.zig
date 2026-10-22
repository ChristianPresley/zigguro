//! EditorView: the per-view state of an open document (selections, scroll,
//! undo, the highlighter and decorations it shows) and the editing
//! operations the editor widget (`widget.zig`) runs on it.
//!
//! This is the first cut of E05.F05.S02.T02/T04: unwrapped rows (no display
//! map yet), monospace-style layout through the E04 `TextSystem` with tabs
//! expanded to `tab_size` columns, and the core editing commands. Every
//! edit goes through `Document.applyChangeSet` and the undo tree. Edits
//! from elsewhere (agents, reload) map the selections through the change.

const std = @import("std");
const zg_gui = @import("zg_gui");
const document = @import("../model/document.zig");
const pt = @import("../model/buffer/piece_tree.zig");
const cs_mod = @import("../model/edit/change_set.zig");
const sel_mod = @import("../model/edit/selection.zig");
const undo_mod = @import("../model/edit/undo.zig");
const syntax_mod = @import("../model/syntax.zig");
const deco_store = @import("../model/decorations/store.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;
const PieceTree = pt.PieceTree;
const ChangeSet = cs_mod.ChangeSet;
const Range = cs_mod.Range;
const Replace = cs_mod.Replace;
const Selection = sel_mod.Selection;
const UndoTree = undo_mod.UndoTree;
const CoalesceKey = undo_mod.CoalesceKey;
const TextSystem = zg_gui.paint.TextSystem;
const TextStyle = zg_gui.paint.text.TextStyle;
const Vec2 = zg_gui.core.Vec2;
const Size = zg_gui.core.Size;
const Color = zg_gui.core.Color;

/// View settings (the `editor.*` settings E15 will feed in).
pub const Options = struct {
    tab_size: u8 = 4,
    /// Tab inserts spaces.
    insert_spaces: bool = true,
    line_numbers: bool = true,
    font_size: f32 = 13,
    read_only: bool = false,
};

/// Maps a decoration's `StyleRef` to a colour (E15 theme tokens); null
/// uses the view's default for that kind.
pub const StyleResolver = struct {
    ctx: ?*anyopaque = null,
    color: *const fn (ctx: ?*anyopaque, style: deco_store.StyleRef) ?Color,
};

/// Told after the document changed under the view (not by the view's own
/// editing), so the owner can mark the window dirty.
pub const ChangeHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, v: *EditorView) void,
};

/// Horizontal moves.
pub const Unit = enum { char, word };

/// See the module doc.
pub const EditorView = struct {
    gpa: Allocator,
    doc: *Document,
    listener: document.ListenerId,
    /// Sorted by start and non-overlapping.
    sels: std.ArrayList(Selection) = .empty,
    /// Index of the primary selection (the one scrolled into view).
    primary: usize = 0,
    undo: UndoTree,
    /// Highlighting, fed this document's changes by the view (one view
    /// per `DocumentSyntax`). Not owned.
    syntax: ?*syntax_mod.DocumentSyntax = null,
    /// Decorations to draw (fed by its own listener). Not owned.
    decorations: ?*const deco_store.DecorationStore = null,
    styles: ?StyleResolver = null,
    on_change: ?ChangeHook = null,
    opts: Options,
    /// Content scroll offset in pixels.
    scroll: Vec2 = .{},
    /// Bumped on every visible change; part of the widget's paint hash.
    generation: u64 = 0,
    /// The text system and the text area size from the last paint or
    /// event; geometry before the first paint uses a 8x16 fallback.
    text_sys: ?TextSystem = null,
    viewport: Size = .{ .w = 0, .h = 0 },
    /// Width of the line-number gutter at the last paint.
    gutter_w: f32 = 0,
    /// Wall time for undo grouping (ms), set by the widget.
    now_ms: u64 = 0,
    scratch: std.ArrayList(u8) = .empty,
    in_edit: bool = false,

    /// A view on `doc` with a caret at the start.
    pub fn init(gpa: Allocator, doc: *Document, opts: Options) !*EditorView {
        const v = try gpa.create(EditorView);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .doc = doc, .listener = undefined, .undo = .init(gpa, .{}), .opts = opts };
        errdefer v.undo.deinit();
        try v.sels.append(gpa, .caret(0));
        errdefer v.sels.deinit(gpa);
        v.listener = try doc.subscribe(.{ .ctx = v, .onChange = onDocChange });
        return v;
    }

    /// Unsubscribes and frees the view (not the document).
    pub fn deinit(v: *EditorView) void {
        v.doc.unsubscribe(v.listener);
        v.sels.deinit(v.gpa);
        v.undo.deinit();
        v.scratch.deinit(v.gpa);
        v.gpa.destroy(v);
    }

    fn tree(v: *const EditorView) *const PieceTree {
        return &v.doc.tree;
    }

    /// Number of lines (at least 1).
    pub fn lineCount(v: *const EditorView) u64 {
        return v.tree().lineCount();
    }

    /// Byte range of `line` without its terminator.
    pub fn lineRange(v: *const EditorView, line: u64) Range {
        const r = v.tree().lineRange(line);
        return .{ .start = r.start, .end = r.end };
    }

    /// The line holding offset `off`.
    pub fn lineOf(v: *const EditorView, off: u64) u64 {
        return v.tree().lineOf(off);
    }

    /// The text of `range`, valid until the next call.
    pub fn text(v: *EditorView, range: Range) []const u8 {
        v.scratch.clearRetainingCapacity();
        v.scratch.ensureTotalCapacity(v.gpa, @intCast(range.len())) catch return "";
        var it = v.tree().slice(range);
        while (it.next()) |chunk| v.scratch.appendSliceAssumeCapacity(chunk);
        return v.scratch.items;
    }

    /// The whole document (caller frees).
    pub fn allText(v: *const EditorView, gpa: Allocator) ![]u8 {
        return v.tree().copyRange(gpa, .{ .start = 0, .end = v.doc.len() });
    }

    /// The primary selection.
    pub fn primarySel(v: *const EditorView) Selection {
        return v.sels.items[v.primary];
    }

    fn touch(v: *EditorView) void {
        v.generation +%= 1;
    }

    fn onDocChange(ctx: *anyopaque, ev: *const document.ChangeEvent) void {
        const v: *EditorView = @ptrCast(@alignCast(ctx));
        if (v.syntax) |ds| ds.onChange(ev, &v.doc.tree, null) catch {};
        if (v.in_edit) return;
        for (v.sels.items) |*s| s.* = s.map(ev.changes);
        v.normalize();
        v.touch();
        if (v.on_change) |h| h.f(h.ctx, v);
    }

    // -- geometry ----------------------------------------------------------

    /// The editor's text style.
    pub fn textStyle(v: *const EditorView) TextStyle {
        return .{ .font = .mono, .size = v.opts.font_size };
    }

    /// Row height in pixels.
    pub fn lineHeight(v: *const EditorView) f32 {
        const ts = v.text_sys orelse return 16;
        return ts.metrics(v.textStyle()).line_h;
    }

    fn advance(v: *const EditorView, cp: u21) f32 {
        const ts = v.text_sys orelse return 8;
        return ts.advance(v.textStyle(), cp);
    }

    fn spaceW(v: *const EditorView) f32 {
        return v.advance(' ');
    }

    /// The x of byte `col` in line text `s` (tabs to the next stop).
    pub fn xInLine(v: *const EditorView, s: []const u8, col: usize) f32 {
        const sw = v.spaceW();
        const tab_w = sw * @as(f32, @floatFromInt(v.opts.tab_size));
        var x: f32 = 0;
        var i: usize = 0;
        while (i < @min(col, s.len)) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            if (s[i] == '\t') {
                x = (@floor(x / tab_w + 0.001) + 1) * tab_w;
            } else {
                const cp = std.unicode.utf8Decode(s[i..@min(s.len, i + n)]) catch 0xfffd;
                x += v.advance(cp);
            }
            i += n;
        }
        return x;
    }

    /// The byte column in line text `s` nearest to `x`.
    pub fn colAt(v: *const EditorView, s: []const u8, x: f32) usize {
        const sw = v.spaceW();
        const tab_w = sw * @as(f32, @floatFromInt(v.opts.tab_size));
        var cx: f32 = 0;
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const w = if (s[i] == '\t')
                (@floor(cx / tab_w + 0.001) + 1) * tab_w - cx
            else
                v.advance(std.unicode.utf8Decode(s[i..@min(s.len, i + n)]) catch 0xfffd);
            if (x < cx + w / 2) return i;
            cx += w;
            i += n;
        }
        return s.len;
    }

    /// The offset nearest to `p`, in text-area coordinates (scroll applied
    /// by the caller is not: `p` is relative to the text origin).
    pub fn offsetAt(v: *EditorView, p: Vec2) u64 {
        const lh = v.lineHeight();
        const line_f = @floor(p.y / lh);
        if (line_f < 0) return 0;
        const line: u64 = @intFromFloat(line_f);
        if (line >= v.lineCount()) return v.doc.len();
        const r = v.lineRange(line);
        const s = v.text(r);
        return r.start + v.colAt(s, p.x);
    }

    /// The text-origin position of offset `off` (top of its row).
    pub fn posOf(v: *EditorView, off: u64) Vec2 {
        const line = v.lineOf(off);
        const r = v.lineRange(line);
        const s = v.text(r);
        return .{ .x = v.xInLine(s, @intCast(off - r.start)), .y = @as(f32, @floatFromInt(line)) * v.lineHeight() };
    }

    /// Lines `[first, last]` intersecting the viewport.
    pub fn visibleLines(v: *const EditorView) [2]u64 {
        const lh = v.lineHeight();
        const first: u64 = @intFromFloat(@max(0, @floor(v.scroll.y / lh)));
        const rows: u64 = @intFromFloat(@max(1, @ceil(v.viewport.h / lh)));
        const last = @min(v.lineCount() - 1, first + rows);
        return .{ @min(first, last), last };
    }

    /// Clamps the scroll offset to the content.
    pub fn clampScroll(v: *EditorView) void {
        const lh = v.lineHeight();
        // One screen of overscroll past the last line, like most editors.
        const max_y = @max(0, @as(f32, @floatFromInt(v.lineCount() - 1)) * lh);
        v.scroll.y = std.math.clamp(v.scroll.y, 0, max_y);
        v.scroll.x = @max(0, v.scroll.x);
    }

    /// Scrolls by `d` pixels.
    pub fn scrollBy(v: *EditorView, d: Vec2) void {
        v.scroll.x += d.x;
        v.scroll.y += d.y;
        v.clampScroll();
        v.touch();
    }

    /// Scrolls so `line` is the first visible row.
    pub fn scrollToLine(v: *EditorView, line: u64) void {
        v.scroll.y = @as(f32, @floatFromInt(line)) * v.lineHeight();
        v.clampScroll();
        v.touch();
    }

    /// Scrolls the primary caret into view.
    pub fn revealPrimary(v: *EditorView) void {
        if (v.viewport.h <= 0) return;
        const lh = v.lineHeight();
        const p = v.posOf(v.primarySel().head);
        if (p.y < v.scroll.y) v.scroll.y = p.y;
        if (p.y + lh > v.scroll.y + v.viewport.h) v.scroll.y = p.y + lh - v.viewport.h;
        const margin = @min(4 * v.spaceW(), v.viewport.w / 3);
        if (p.x - v.scroll.x < margin) v.scroll.x = @max(0, p.x - margin);
        if (p.x - v.scroll.x > v.viewport.w - margin) v.scroll.x = p.x - v.viewport.w + margin;
        v.clampScroll();
        v.touch();
    }

    // -- selections --------------------------------------------------------

    /// Sorts the selections and merges overlapping ones (touching carets
    /// merge; touching ranges do not).
    pub fn normalize(v: *EditorView) void {
        if (v.sels.items.len == 0) {
            v.sels.append(v.gpa, .caret(0)) catch {};
            v.primary = 0;
            return;
        }
        const len = v.doc.len();
        const prim_head = v.sels.items[@min(v.primary, v.sels.items.len - 1)].head;
        for (v.sels.items) |*s| {
            s.anchor = @min(s.anchor, len);
            s.head = @min(s.head, len);
        }
        std.sort.pdq(Selection, v.sels.items, {}, struct {
            fn lt(_: void, a: Selection, b: Selection) bool {
                return a.start() < b.start() or (a.start() == b.start() and a.end() < b.end());
            }
        }.lt);
        var out: usize = 0;
        for (v.sels.items) |s| {
            if (out > 0) {
                const last = &v.sels.items[out - 1];
                const overlap = s.start() < last.end() or (s.start() == last.end() and (s.isCaret() or last.isCaret()));
                if (overlap) {
                    const fwd = last.head >= last.anchor;
                    const lo = last.start();
                    const hi = @max(last.end(), s.end());
                    last.* = if (fwd) .{ .anchor = lo, .head = hi } else .{ .anchor = hi, .head = lo };
                    continue;
                }
            }
            v.sels.items[out] = s;
            out += 1;
        }
        v.sels.shrinkRetainingCapacity(out);
        v.primary = 0;
        for (v.sels.items, 0..) |s, i| if (s.start() <= prim_head and prim_head <= s.end()) {
            v.primary = i;
            break;
        };
    }

    /// Replaces the selections with one caret or range.
    pub fn setSelection(v: *EditorView, s: Selection) void {
        v.sels.clearRetainingCapacity();
        v.sels.append(v.gpa, s) catch {};
        v.primary = 0;
        v.normalize();
        v.undo.breakGroup();
        v.touch();
    }

    /// Adds a caret (Alt+click).
    pub fn addCaret(v: *EditorView, off: u64) void {
        v.sels.append(v.gpa, .caret(off)) catch return;
        v.primary = v.sels.items.len - 1;
        v.normalize();
        v.undo.breakGroup();
        v.touch();
    }

    /// Selects everything.
    pub fn selectAll(v: *EditorView) void {
        v.setSelection(.{ .anchor = 0, .head = v.doc.len() });
    }

    fn byteAt(v: *const EditorView, off: u64) u8 {
        return v.tree().byteAt(off);
    }

    fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }

    /// The offset one code point before `off`.
    fn prevChar(v: *const EditorView, off: u64) u64 {
        if (off == 0) return 0;
        var p = off - 1;
        while (p > 0 and v.byteAt(p) & 0xc0 == 0x80) p -= 1;
        // A CRLF is one step.
        if (p > 0 and v.byteAt(p) == '\n' and v.byteAt(p - 1) == '\r') p -= 1;
        return p;
    }

    /// The offset one code point after `off`.
    fn nextChar(v: *const EditorView, off: u64) u64 {
        const len = v.doc.len();
        if (off >= len) return len;
        if (v.byteAt(off) == '\r' and off + 1 < len and v.byteAt(off + 1) == '\n') return off + 2;
        var p = off + 1;
        while (p < len and v.byteAt(p) & 0xc0 == 0x80) p += 1;
        return p;
    }

    /// The start of the word at or before `off` (skipping spaces first).
    fn prevWord(v: *const EditorView, off: u64) u64 {
        var p = off;
        while (p > 0 and std.ascii.isWhitespace(v.byteAt(p - 1)) and v.byteAt(p - 1) != '\n') p -= 1;
        if (p == 0) return 0;
        if (p == off and v.byteAt(p - 1) == '\n') return v.prevChar(p);
        const word = isWordByte(v.byteAt(p - 1));
        while (p > 0) {
            const c = v.byteAt(p - 1);
            if (std.ascii.isWhitespace(c) or isWordByte(c) != word) break;
            p -= 1;
        }
        return p;
    }

    /// The end of the word at or after `off` (skipping spaces first).
    fn nextWord(v: *const EditorView, off: u64) u64 {
        const len = v.doc.len();
        var p = off;
        while (p < len and std.ascii.isWhitespace(v.byteAt(p)) and v.byteAt(p) != '\n') p += 1;
        if (p >= len) return len;
        if (p == off and (v.byteAt(p) == '\n' or v.byteAt(p) == '\r')) return v.nextChar(p);
        const word = isWordByte(v.byteAt(p));
        while (p < len) {
            const c = v.byteAt(p);
            if (std.ascii.isWhitespace(c) or isWordByte(c) != word) break;
            p += 1;
        }
        return p;
    }

    /// The word (or run of punctuation, or of spaces) around `off`.
    pub fn wordRange(v: *const EditorView, off: u64) Range {
        const len = v.doc.len();
        if (len == 0) return .{ .start = 0, .end = 0 };
        const at = if (off < len and v.byteAt(off) != '\n') off else if (off > 0) off - 1 else 0;
        const c = v.byteAt(at);
        if (c == '\n') return .{ .start = off, .end = off };
        const Class = enum { word, space, punct };
        const class = struct {
            fn of(b: u8) Class {
                return if (isWordByte(b)) .word else if (b == ' ' or b == '\t') .space else .punct;
            }
        }.of;
        const k = class(c);
        var s = at;
        while (s > 0 and v.byteAt(s - 1) != '\n' and class(v.byteAt(s - 1)) == k) s -= 1;
        var e = at + 1;
        while (e < len and v.byteAt(e) != '\n' and v.byteAt(e) != '\r' and class(v.byteAt(e)) == k) e += 1;
        return .{ .start = s, .end = e };
    }

    /// The line around `off`, with its terminator.
    pub fn lineRangeWithEol(v: *const EditorView, off: u64) Range {
        const line = v.lineOf(off);
        const r = v.tree().lineRange(line);
        return .{ .start = r.start, .end = r.end + r.eol_len };
    }

    /// Moves every selection by one character or word; `extend` keeps the
    /// anchor. Without `extend`, a range collapses to its edge first.
    pub fn moveH(v: *EditorView, forward: bool, unit: Unit, extend: bool) void {
        for (v.sels.items) |*s| {
            if (!extend and !s.isCaret() and unit == .char) {
                s.* = .caret(if (forward) s.end() else s.start());
                continue;
            }
            const to = switch (unit) {
                .char => if (forward) v.nextChar(s.head) else v.prevChar(s.head),
                .word => if (forward) v.nextWord(s.head) else v.prevWord(s.head),
            };
            s.head = to;
            if (!extend) s.anchor = to;
            s.goal_x = null;
        }
        v.afterMove();
    }

    /// Moves every selection `lines` rows (negative is up), keeping the
    /// sticky x.
    pub fn moveV(v: *EditorView, lines: i64, extend: bool) void {
        const n = v.lineCount();
        for (v.sels.items) |*s| {
            const line = v.lineOf(s.head);
            const gx = s.goal_x orelse v.posOf(s.head).x;
            const target_i = @as(i64, @intCast(line)) + lines;
            const to: u64 = if (target_i < 0)
                0
            else if (target_i >= @as(i64, @intCast(n)))
                v.doc.len()
            else blk: {
                const r = v.lineRange(@intCast(target_i));
                break :blk r.start + v.colAt(v.text(r), gx);
            };
            s.head = to;
            if (!extend) s.anchor = to;
            s.goal_x = if (target_i < 0 or target_i >= @as(i64, @intCast(n))) null else gx;
        }
        v.afterMove();
    }

    /// Home: to the first non-blank, or to column 0 when already there.
    pub fn home(v: *EditorView, extend: bool) void {
        for (v.sels.items) |*s| {
            const r = v.lineRange(v.lineOf(s.head));
            var first = r.start;
            while (first < r.end and (v.byteAt(first) == ' ' or v.byteAt(first) == '\t')) first += 1;
            const to = if (s.head == first) r.start else first;
            s.head = to;
            if (!extend) s.anchor = to;
            s.goal_x = null;
        }
        v.afterMove();
    }

    /// End of line.
    pub fn end(v: *EditorView, extend: bool) void {
        for (v.sels.items) |*s| {
            const to = v.lineRange(v.lineOf(s.head)).end;
            s.head = to;
            if (!extend) s.anchor = to;
            s.goal_x = null;
        }
        v.afterMove();
    }

    /// Start or end of the document.
    pub fn docEdge(v: *EditorView, at_end: bool, extend: bool) void {
        const to: u64 = if (at_end) v.doc.len() else 0;
        const anchor = if (extend) v.primarySel().anchor else to;
        v.setSelection(.{ .anchor = anchor, .head = to });
        v.revealPrimary();
    }

    fn afterMove(v: *EditorView) void {
        v.normalize();
        v.undo.breakGroup();
        v.revealPrimary();
        v.touch();
    }

    // -- editing -----------------------------------------------------------

    fn timestamp(v: *const EditorView) std.Io.Timestamp {
        return .{ .nanoseconds = @as(i96, v.now_ms) * std.time.ns_per_ms };
    }

    /// Applies one edit per selection (in selection order) and leaves a
    /// caret after each edit's text.
    fn applyPerSelection(v: *EditorView, edits: []const Replace, key: ?CoalesceKey) !void {
        std.debug.assert(edits.len == v.sels.items.len);
        if (v.opts.read_only) return;
        var nonempty = false;
        for (edits) |e| if (e.range.start != e.range.end or e.text.len > 0) {
            nonempty = true;
        };
        if (!nonempty) return;
        var cs = try ChangeSet.fromEdits(v.gpa, v.doc.len(), edits);
        var cs_owned = true;
        defer if (cs_owned) cs.deinit();
        var inverse = try cs.invert(v.doc.tree, v.gpa);
        var inv_owned = true;
        defer if (inv_owned) inverse.deinit();
        const before = try sel_mod.dupe(v.gpa, v.sels.items);
        defer v.gpa.free(before);

        v.in_edit = true;
        defer v.in_edit = false;
        try v.doc.applyChangeSet(&cs, .{ .user = 0 });
        for (v.sels.items, edits) |*s, e| {
            s.* = .caret(cs.mapPos(e.range.start, .left) + e.text.len);
        }
        v.normalize();
        cs_owned = false;
        inv_owned = false;
        try v.undo.record(cs, inverse, before, v.sels.items, .{ .origin = .{ .user = 0 }, .timestamp = v.timestamp(), .coalesce_key = key });
        v.revealPrimary();
        v.touch();
    }

    /// Types `t` over every selection.
    pub fn insertText(v: *EditorView, t: []const u8) !void {
        const edits = try v.gpa.alloc(Replace, v.sels.items.len);
        defer v.gpa.free(edits);
        for (v.sels.items, edits) |s, *e| e.* = .{ .range = s.range(), .text = t };
        const space = t.len > 0 and std.mem.indexOfNone(u8, t, " \t") == null;
        const key: ?CoalesceKey = if (std.mem.indexOfScalar(u8, t, '\n') != null) null else if (space) .typing_space else .typing_word;
        try v.applyPerSelection(edits, key);
    }

    /// Inserts a line break that keeps the current line's indentation.
    pub fn newline(v: *EditorView) !void {
        var arena: std.heap.ArenaAllocator = .init(v.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const edits = try a.alloc(Replace, v.sels.items.len);
        for (v.sels.items, edits) |s, *e| {
            const r = v.lineRange(v.lineOf(s.start()));
            var i = r.start;
            while (i < s.start() and (v.byteAt(i) == ' ' or v.byteAt(i) == '\t')) i += 1;
            const indent = try a.dupe(u8, v.text(.{ .start = r.start, .end = i }));
            e.* = .{ .range = s.range(), .text = try std.mem.concat(a, u8, &.{ "\n", indent }) };
        }
        v.undo.breakGroup();
        try v.applyPerSelection(edits, null);
    }

    /// Tab: indent to the next tab stop (or insert a tab character).
    pub fn tab(v: *EditorView) !void {
        var arena: std.heap.ArenaAllocator = .init(v.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const edits = try a.alloc(Replace, v.sels.items.len);
        for (v.sels.items, edits) |s, *e| {
            if (!v.opts.insert_spaces) {
                e.* = .{ .range = s.range(), .text = "\t" };
                continue;
            }
            const r = v.lineRange(v.lineOf(s.start()));
            const col_x = v.xInLine(v.text(r), @intCast(s.start() - r.start));
            const cols: usize = @intFromFloat(@round(col_x / v.spaceW()));
            const n = v.opts.tab_size - @as(u8, @intCast(cols % v.opts.tab_size));
            const sp = try a.alloc(u8, n);
            @memset(sp, ' ');
            e.* = .{ .range = s.range(), .text = sp };
        }
        try v.applyPerSelection(edits, .typing_space);
    }

    /// Deletes the selections, or one character or word before each caret.
    pub fn backspace(v: *EditorView, unit: Unit) !void {
        const edits = try v.gpa.alloc(Replace, v.sels.items.len);
        defer v.gpa.free(edits);
        for (v.sels.items, edits) |s, *e| {
            const r: Range = if (!s.isCaret()) s.range() else .{ .start = switch (unit) {
                .char => v.prevChar(s.head),
                .word => v.prevWord(s.head),
            }, .end = s.head };
            e.* = .{ .range = r, .text = "" };
        }
        try v.applyPerSelection(edits, .delete_left);
    }

    /// Deletes the selections, or one character or word after each caret.
    pub fn deleteForward(v: *EditorView, unit: Unit) !void {
        const edits = try v.gpa.alloc(Replace, v.sels.items.len);
        defer v.gpa.free(edits);
        for (v.sels.items, edits) |s, *e| {
            const r: Range = if (!s.isCaret()) s.range() else .{ .start = s.head, .end = switch (unit) {
                .char => v.nextChar(s.head),
                .word => v.nextWord(s.head),
            } };
            e.* = .{ .range = r, .text = "" };
        }
        try v.applyPerSelection(edits, .delete_right);
    }

    /// The text Copy takes (caller frees): the selections joined by
    /// newlines, or the caret lines when nothing is selected.
    pub fn copyText(v: *EditorView, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var all_carets = true;
        for (v.sels.items) |s| if (!s.isCaret()) {
            all_carets = false;
        };
        var last_line: ?u64 = null;
        for (v.sels.items, 0..) |s, i| {
            if (all_carets) {
                const line = v.lineOf(s.head);
                if (last_line == line) continue;
                last_line = line;
                const r = v.lineRangeWithEol(s.head);
                try out.appendSlice(gpa, v.text(r));
                if (r.end == v.doc.len() and (r.start == r.end or v.byteAt(r.end - 1) != '\n')) try out.append(gpa, '\n');
            } else {
                if (i > 0) try out.append(gpa, '\n');
                try out.appendSlice(gpa, v.text(s.range()));
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Cut: copies (see `copyText`) and deletes; caret-only cuts take
    /// whole lines.
    pub fn cut(v: *EditorView, gpa: Allocator) ![]u8 {
        const t = try v.copyText(gpa);
        errdefer gpa.free(t);
        var all_carets = true;
        for (v.sels.items) |s| if (!s.isCaret()) {
            all_carets = false;
        };
        if (all_carets) {
            for (v.sels.items) |*s| {
                const r = v.lineRangeWithEol(s.head);
                s.* = .{ .anchor = r.start, .head = r.end };
            }
            v.normalize();
        }
        v.undo.breakGroup();
        try v.backspace(.char);
        return t;
    }

    /// Paste: one line per selection when the counts match, else the
    /// whole text at every selection.
    pub fn paste(v: *EditorView, t: []const u8) !void {
        if (t.len == 0) return;
        const n = v.sels.items.len;
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(v.gpa);
        if (n > 1) {
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, t, "\n"), '\n');
            while (it.next()) |l| try lines.append(v.gpa, l);
        }
        const edits = try v.gpa.alloc(Replace, n);
        defer v.gpa.free(edits);
        for (v.sels.items, edits, 0..) |s, *e, i| {
            e.* = .{ .range = s.range(), .text = if (lines.items.len == n) lines.items[i] else t };
        }
        v.undo.breakGroup();
        try v.applyPerSelection(edits, null);
        v.undo.breakGroup();
    }

    fn applyStep(v: *EditorView, step: undo_mod.Step, origin: document.EditOrigin) !void {
        v.in_edit = true;
        defer v.in_edit = false;
        try v.doc.applyChangeSet(step.changes, origin);
        v.sels.clearRetainingCapacity();
        try v.sels.appendSlice(v.gpa, step.selections);
        v.primary = v.sels.items.len -| 1;
        v.normalize();
        v.revealPrimary();
        v.touch();
    }

    /// Undoes the last group; false when there is nothing to undo.
    pub fn undoStep(v: *EditorView) !bool {
        const step = v.undo.undo() orelse return false;
        try v.applyStep(step, .undo);
        return true;
    }

    /// Redoes the next group; false when there is nothing to redo.
    pub fn redoStep(v: *EditorView) !bool {
        const step = v.undo.redo() orelse return false;
        try v.applyStep(step, .redo);
        return true;
    }
};
