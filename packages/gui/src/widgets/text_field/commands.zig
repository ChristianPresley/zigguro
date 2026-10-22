//! Text field editing commands (E04.F05.S02.T01): caret moves by grapheme
//! cluster, UAX #29 word and logical line; inserts that sanitise UTF-8 and
//! newlines; grapheme- and word-wise deletes; undo/redo. Visual-line and
//! vertical moves need layout and live in `view.zig`.

const std = @import("std");
const zg_text = @import("zg_text");
const model = @import("model.zig");
const undo_mod = @import("undo.zig");

const grapheme = zg_text.unicode.grapheme;
const word = zg_text.unicode.word;
const TextBuffer = model.TextBuffer;
const Selection = model.Selection;
const UndoStack = undo_mod.UndoStack;
const Kind = undo_mod.Kind;

/// Field-level editing rules.
pub const Options = struct {
    multiline: bool = false,
    read_only: bool = false,
    max_len: ?u32 = null,
};

/// Logical caret moves.
pub const Move = enum {
    char_left,
    char_right,
    word_left,
    word_right,
    line_start,
    line_end,
    doc_start,
    doc_end,
};

/// The edit surface over one buffer, selection and undo stack.
pub const Editor = struct {
    buf: *TextBuffer,
    sel: *Selection,
    undo: *UndoStack,
    opts: Options = .{},
    /// Milliseconds on any monotonic clock; drives undo coalescing.
    now_ms: u64 = 0,

    /// The current text (valid until the next edit).
    pub fn text(e: Editor) []const u8 {
        return e.buf.slice();
    }

    /// The selected bytes.
    pub fn selected(e: Editor) []const u8 {
        const r = e.sel.range();
        return e.text()[r[0]..r[1]];
    }

    /// The offset `m` leads to from `from`.
    pub fn target(e: Editor, m: Move, from: u32) u32 {
        const t = e.text();
        const n: u32 = @intCast(t.len);
        return switch (m) {
            .char_left => if (from == 0) 0 else @intCast(grapheme.prevBoundary(t, from)),
            .char_right => if (from >= n) n else @intCast(grapheme.nextBoundary(t, from)),
            .word_left => @intCast(word.prevWordStart(t, from)),
            .word_right => wordRight(t, from),
            .line_start => if (std.mem.lastIndexOfScalar(u8, t[0..from], '\n')) |i| @intCast(i + 1) else 0,
            .line_end => if (std.mem.indexOfScalarPos(u8, t, from, '\n')) |i| @intCast(i) else n,
            .doc_start => 0,
            .doc_end => n,
        };
    }

    /// Ctrl+Right stops at the end of the current word, then at the end of
    /// the next one (Windows and GTK put it at the next start; ending at
    /// word ends keeps Ctrl+Shift+Right from selecting trailing spaces).
    fn wordRight(t: []const u8, from: u32) u32 {
        var i: usize = from;
        while (i < t.len) {
            const span = word.wordAt(t, i);
            const end = span.start + span.len;
            if (end <= i) break;
            if (span.kind == .word or span.kind == .number) return @intCast(end);
            i = end;
        }
        return @intCast(t.len);
    }

    /// Moves the caret; `extend` keeps the anchor (Shift). Without
    /// `extend`, a char move over a selection collapses it to that side.
    pub fn move(e: Editor, m: Move, extend: bool) void {
        e.sel.goal_x = null;
        e.undo.breakGroup();
        if (!extend and !e.sel.isEmpty()) {
            switch (m) {
                .char_left => return e.collapse(e.sel.start()),
                .char_right => return e.collapse(e.sel.end()),
                else => {},
            }
        }
        e.moveTo(e.target(m, e.sel.head), extend);
    }

    /// Puts the caret at `at` (clamped and snapped to a grapheme boundary).
    pub fn moveTo(e: Editor, at: u32, extend: bool) void {
        const t = e.text();
        const a = snap(t, @min(at, @as(u32, @intCast(t.len))));
        e.sel.head = a;
        if (!extend) e.sel.anchor = a;
    }

    fn collapse(e: Editor, at: u32) void {
        e.sel.* = .caret(at);
    }

    /// Selects everything.
    pub fn selectAll(e: Editor) void {
        e.sel.* = .{ .anchor = 0, .head = e.buf.len() };
        e.undo.breakGroup();
    }

    /// The word segment around `at` (double-click).
    pub fn wordRange(e: Editor, at: u32) [2]u32 {
        const span = word.wordAt(e.text(), at);
        return .{ @intCast(span.start), @intCast(span.start + span.len) };
    }

    /// The logical line around `at`, without its newline (triple-click).
    pub fn lineRange(e: Editor, at: u32) [2]u32 {
        return .{ e.target(.line_start, at), e.target(.line_end, at) };
    }

    /// Selects `r`, with the caret at its end.
    pub fn selectRange(e: Editor, r: [2]u32) void {
        e.sel.* = .{ .anchor = r[0], .head = r[1] };
        e.undo.breakGroup();
    }

    // -- edits ---------------------------------------------------------------

    /// Replaces `range` with `s` as one undoable edit, leaving the caret
    /// after the insertion. Returns false when nothing changed.
    fn replaceRange(e: Editor, range: [2]u32, s: []const u8, kind: Kind) !bool {
        if (e.opts.read_only) return false;
        if (range[0] == range[1] and s.len == 0) return false;
        const gpa = e.buf.gpa;
        const removed = try gpa.dupe(u8, e.text()[range[0]..range[1]]);
        defer gpa.free(removed);
        const before = e.sel.*;
        try e.buf.replace(range, s);
        e.sel.* = .caret(range[0] + @as(u32, @intCast(s.len)));
        try e.undo.record(gpa, .{ .at = range[0], .removed = removed, .inserted = s, .sel_before = before, .sel_after = e.sel.*, .kind = kind }, e.now_ms);
        return true;
    }

    /// Types `s` over the selection (coalescing with adjacent typing).
    pub fn insert(e: Editor, s: []const u8) !bool {
        return e.insertKind(s, .typing);
    }

    /// Inserts `s` as one undo step (paste, IME commit).
    pub fn commitText(e: Editor, s: []const u8) !bool {
        return e.insertKind(s, .other);
    }

    fn insertKind(e: Editor, s: []const u8, kind: Kind) !bool {
        if (e.opts.read_only) return false;
        const gpa = e.buf.gpa;
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(gpa);
        try sanitize(gpa, &clean, s, e.opts.multiline);
        const r = e.sel.range();
        if (e.opts.max_len) |max| {
            const room = max -| (e.buf.len() - (r[1] - r[0]));
            if (clean.items.len > room) clean.shrinkRetainingCapacity(truncateAt(clean.items, room));
        }
        // A selection replaced by typing is not a pure insert.
        const k: Kind = if (kind == .typing and r[0] != r[1]) .other else kind;
        return e.replaceRange(r, clean.items, k);
    }

    /// Deletes the selection, or the grapheme (word with `whole_word`)
    /// before the caret.
    pub fn backspace(e: Editor, whole_word: bool) !bool {
        if (!e.sel.isEmpty()) return e.deleteSelection();
        const h = e.sel.head;
        if (h == 0) return false;
        const from = e.target(if (whole_word) .word_left else .char_left, h);
        return e.replaceRange(.{ from, h }, "", if (whole_word) .other else .delete_back);
    }

    /// Deletes the selection, or the grapheme (word with `whole_word`)
    /// after the caret.
    pub fn deleteForward(e: Editor, whole_word: bool) !bool {
        if (!e.sel.isEmpty()) return e.deleteSelection();
        const h = e.sel.head;
        const to = e.target(if (whole_word) .word_right else .char_right, h);
        if (to == h) return false;
        return e.replaceRange(.{ h, to }, "", if (whole_word) .other else .delete_forward);
    }

    /// Deletes `before` bytes before the selection and `after` bytes after
    /// it (an IME's delete-surrounding), widened to whole graphemes and
    /// clamped to the text. The selection stays on the same text.
    pub fn deleteAround(e: Editor, before: u32, after: u32) !bool {
        if (e.opts.read_only or (before == 0 and after == 0)) return false;
        const t = e.text();
        const r = e.sel.range();
        const keep = e.sel.*;
        var to: u32 = @intCast(@min(t.len, @as(usize, r[1]) + after));
        const s = snap(t, to);
        if (s < to) to = @intCast(grapheme.nextBoundary(t, s));
        const from = snap(t, r[0] -| before);
        var changed = false;
        if (to > r[1]) changed = try e.replaceRange(.{ r[1], to }, "", .other);
        e.sel.* = keep;
        if (from < r[0]) {
            changed = try e.replaceRange(.{ from, r[0] }, "", .other) or changed;
            const n = r[0] - from;
            e.sel.* = .{ .anchor = keep.anchor - n, .head = keep.head - n };
        } else e.sel.* = keep;
        return changed;
    }

    /// Deletes the selected bytes.
    pub fn deleteSelection(e: Editor) !bool {
        if (e.sel.isEmpty()) return false;
        return e.replaceRange(e.sel.range(), "", .other);
    }

    /// Reverts the newest step. Returns false when there is none.
    pub fn undoStep(e: Editor) !bool {
        if (e.opts.read_only) return false;
        const ed = e.undo.undo() orelse return false;
        try e.buf.replace(.{ ed.at, ed.at + @as(u32, @intCast(ed.inserted.len)) }, ed.removed);
        e.sel.* = ed.sel_before;
        e.sel.clamp(e.buf.len());
        return true;
    }

    /// Re-applies the newest undone step. Returns false when there is none.
    pub fn redoStep(e: Editor) !bool {
        if (e.opts.read_only) return false;
        const ed = e.undo.redo() orelse return false;
        try e.buf.replace(.{ ed.at, ed.at + @as(u32, @intCast(ed.removed.len)) }, ed.inserted);
        e.sel.* = ed.sel_after;
        e.sel.clamp(e.buf.len());
        return true;
    }
};

/// The nearest grapheme boundary at or before `at`.
pub fn snap(t: []const u8, at: u32) u32 {
    if (at == 0 or at >= t.len) return at;
    const prev = grapheme.prevBoundary(t, at);
    return if (grapheme.nextBoundary(t, prev) == at) at else @intCast(prev);
}

/// Copies `s` into `out` as valid UTF-8 (invalid bytes become U+FFFD).
/// Multi-line fields normalise CRLF and CR to LF; single-line fields turn
/// newlines into spaces. Other C0 controls except tab are dropped.
pub fn sanitize(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, multiline: bool) !void {
    try out.ensureUnusedCapacity(gpa, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            i += 1;
            switch (c) {
                '\r' => {
                    if (i < s.len and s[i] == '\n') i += 1;
                    try out.append(gpa, if (multiline) '\n' else ' ');
                },
                '\n' => try out.append(gpa, if (multiline) '\n' else ' '),
                '\t' => try out.append(gpa, c),
                0...8, 11...12, 14...31, 127 => {},
                else => try out.append(gpa, c),
            }
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (n == 0 or i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
            continue;
        }
        try out.appendSlice(gpa, s[i .. i + n]);
        i += n;
    }
}

/// The longest prefix of `s` no longer than `max` bytes that ends on a
/// grapheme boundary.
fn truncateAt(s: []const u8, max: u32) usize {
    if (max >= s.len) return s.len;
    var end: usize = 0;
    while (end < s.len) {
        const next = grapheme.nextBoundary(s, end);
        if (next > max) break;
        end = next;
    }
    return end;
}

test {
    std.testing.refAllDecls(@This());
}
