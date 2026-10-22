//! Language-aware typing over every selection, each command one change:
//! `typeChar` (surround a selection, type over an auto-inserted closer,
//! auto-close an opener, re-indent a line on an electric closer),
//! `newline` (auto-indent, splitting a bracket pair over three lines),
//! `deleteLeft` (an auto-inserted pair goes as one), and the comment
//! toggles. Rules come from the language's `EditRules` and brackets.

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const sel_mod = @import("selection.zig");
const runner = @import("runner.zig");
const indent = @import("indent.zig");
const pairs = @import("pairs.zig");
const comment = @import("comment.zig");
const movement = @import("movement.zig");
const cmds = @import("commands_move.zig");
const document = @import("../document.zig");
const snapshot_mod = @import("../snapshot.zig");
const pt = @import("../buffer/piece_tree.zig");

const Allocator = std.mem.Allocator;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const Document = document.Document;
const EditOrigin = document.EditOrigin;
const Snapshot = snapshot_mod.Snapshot;
const PieceTree = pt.PieceTree;
const Language = zg_syntax.Language;
const EditRules = zg_syntax.language.EditRules;
const BracketPair = zg_syntax.language.BracketPair;
const IndentUnit = indent.IndentUnit;

pub const TokenQuery = pairs.TokenQuery;
pub const AutoClose = pairs.AutoClose;
pub const AutoPairs = pairs.AutoPairs;

/// Settings and context for smart typing.
pub const EditCtx = struct {
    lang: ?*const Language = null,
    tab_size: u8 = 4,
    /// Indent with spaces (overridden by the language's `insert_spaces`
    /// and by `unit`).
    insert_spaces: bool = true,
    /// The document's guessed unit (`indent.guess`), when known.
    unit: ?IndentUnit = null,
    auto_close: AutoClose = .language_defined,
    tokens: ?TokenQuery = null,
    /// Closers auto-inserted in this typing session.
    auto_pairs: ?*AutoPairs = null,
    /// Re-base pasted lines on the target line's indentation
    /// (`editor.reindentOnPaste`).
    reindent_on_paste: bool = false,
    origin: EditOrigin = .{ .user = 0 },

    fn rules(c: EditCtx) EditRules {
        return if (c.lang) |l| l.edit_rules else .{};
    }

    fn brackets(c: EditCtx) []const BracketPair {
        return if (c.lang) |l| l.brackets else &default_brackets;
    }

    fn closePairs(c: EditCtx) []const BracketPair {
        return if (c.lang) |l| l.edit_rules.auto_close else &default_pairs;
    }

    fn surroundPairs(c: EditCtx) []const BracketPair {
        const l = c.lang orelse return &default_pairs;
        return l.edit_rules.surround orelse l.edit_rules.auto_close;
    }

    /// One indentation level.
    pub fn indentUnit(c: EditCtx) IndentUnit {
        if (c.unit) |u| return u;
        const spaces = if (c.lang) |l| l.edit_rules.insert_spaces orelse c.insert_spaces else c.insert_spaces;
        return .{ .tabs = !spaces, .size = c.tab_size };
    }

    fn kindAt(c: EditCtx, pos: u64) pairs.TokenKind {
        return if (c.tokens) |t| t.kindAt(pos) else .code;
    }
};

const default_brackets = [_]BracketPair{
    .{ .open = "(", .close = ")" },
    .{ .open = "[", .close = "]" },
    .{ .open = "{", .close = "}" },
};

const default_pairs = default_brackets ++ [_]BracketPair{
    .{ .open = "\"", .close = "\"" },
    .{ .open = "'", .close = "'" },
};

const line_window = 4096;

fn byteAt(t: *const PieceTree, pos: u64) ?u8 {
    return if (pos < t.len()) t.byteAt(pos) else null;
}

/// The byte after `pos` unless it ends the line.
fn nextOnLine(t: *const PieceTree, pos: u64) ?u8 {
    const b = byteAt(t, pos) orelse return null;
    return if (b == '\n' or b == '\r') null else b;
}

fn prevByte(t: *const PieceTree, pos: u64) ?u8 {
    return if (pos > 0) t.byteAt(pos - 1) else null;
}

// -- typeChar ---------------------------------------------------------------

const TypeState = struct {
    ctx: EditCtx,
    cp: u21,
    enc: []const u8,
    /// Ids of selections that auto-closed (their closer sits at the caret
    /// afterwards).
    closed: std.ArrayList(u32) = .empty,
    gpa: Allocator,
};

fn typeOne(ptr: *anyopaque, snap: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    const st: *TypeState = @ptrCast(@alignCast(ptr));
    const c = st.ctx;
    const t = &snap.tree;
    const close_pairs = c.closePairs();
    if (!sel.isCaret()) {
        if (c.auto_close != .never) if (pairs.openerOf(c.surroundPairs(), st.cp)) |p| {
            // Surround, keeping the text selected (and the direction).
            const text = try t.copyRange(st.gpa, sel.range());
            defer st.gpa.free(text);
            const wrapped = try std.mem.concat(st.gpa, u8, &.{ p.open, text, p.close });
            defer st.gpa.free(wrapped);
            _ = try out.replace(sel.range(), wrapped);
            const lo: u32 = @intCast(p.open.len);
            const hi: u32 = @intCast(p.open.len + text.len);
            out.select(.{ .range_in_edit = if (sel.head >= sel.anchor) .{ .edit = 0, .anchor = lo, .head = hi } else .{ .edit = 0, .anchor = hi, .head = lo } });
            return;
        };
        _ = try out.replace(sel.range(), st.enc);
        out.select(.{ .in_edit = .{ .edit = 0 } });
        return;
    }
    const pos = sel.head;
    const next = nextOnLine(t, pos);
    // Type over an auto-inserted closer.
    if (c.auto_pairs) |ap| if (pairs.closerOf(close_pairs, st.cp)) |p| {
        if (ap.has(pos) and next != null and std.mem.startsWith(u8, p.close, &.{next.?})) {
            ap.remove(pos);
            out.select(.{ .at = pos + p.close.len });
            return;
        }
    };
    // Auto-close an opener.
    if (pairs.openerOf(close_pairs, st.cp)) |p| {
        if (pairs.shouldAutoClose(p, c.auto_close, next, prevByte(t, pos), c.kindAt(pos))) {
            const both = try std.mem.concat(st.gpa, u8, &.{ p.open, p.close });
            defer st.gpa.free(both);
            _ = try out.insert(pos, both);
            out.select(.{ .in_edit = .{ .edit = 0, .delta = @intCast(p.open.len) } });
            if (c.auto_pairs != null) try st.closed.append(st.gpa, sel.id);
            return;
        }
    }
    // Electric closer: first on its line, re-indent to its opener's line.
    for (c.brackets()) |b| {
        if (!std.mem.eql(u8, b.close, st.enc)) continue;
        const ls = t.lineStart(t.lineOf(pos));
        var buf: [line_window]u8 = undefined;
        const before = copy(t, ls, pos, &buf);
        if (indent.leading(before).len != before.len) break;
        const opener = indent.findOpener(snap, pos, b) orelse break;
        var ib: [256]u8 = undefined;
        const want = indent.indentOfLineAt(t, opener, &ib);
        if (std.mem.eql(u8, want, before)) break;
        const text = try std.mem.concat(st.gpa, u8, &.{ want, st.enc });
        defer st.gpa.free(text);
        _ = try out.replace(.{ .start = ls, .end = pos }, text);
        out.select(.{ .in_edit = .{ .edit = 0 } });
        return;
    }
    // A word char ending a dedent keyword that starts the line
    // (`else:`, `fi;`): re-indent the line.
    if (st.cp < 0x80 and !isWordByte(@intCast(st.cp))) {
        const line = t.lineOf(pos);
        const ls = t.lineStart(line);
        var buf: [line_window]u8 = undefined;
        const before = copy(t, ls, pos, &buf);
        const ws = indent.leading(before);
        if (indent.isDedentKeyword(before[ws.len..], c.rules())) {
            const unit = c.indentUnit();
            const cur = IndentUnit.columns(ws, c.tab_size);
            const want = indent.keywordIndent(t, line, cur, unit, c.tab_size);
            if (want != cur) {
                var ib: [512]u8 = undefined;
                const text = try std.mem.concat(st.gpa, u8, &.{ unit.write(want, &ib), before[ws.len..], st.enc });
                defer st.gpa.free(text);
                _ = try out.replace(.{ .start = ls, .end = pos }, text);
                out.select(.{ .in_edit = .{ .edit = 0 } });
                return;
            }
        }
    }
    _ = try out.insert(pos, st.enc);
    out.select(.{ .in_edit = .{ .edit = 0 } });
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn copy(t: *const PieceTree, start: u64, end_in: u64, buf: []u8) []const u8 {
    const end = @min(end_in, start + buf.len);
    var n: usize = 0;
    var it = t.slice(.{ .start = start, .end = end });
    while (it.next()) |c| {
        @memcpy(buf[n..][0..c.len], c);
        n += c.len;
    }
    return buf[0..n];
}

/// Types `cp` at every selection as one change.
pub fn typeChar(doc: *Document, sels: *SelectionSet, cp: u21, ctx: EditCtx) !runner.RunResult {
    var enc_buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &enc_buf);
    if (ctx.auto_pairs) |ap| ap.sync(doc);
    var st: TypeState = .{ .ctx = ctx, .cp = cp, .enc = enc_buf[0..n], .gpa = sels.gpa };
    defer st.closed.deinit(sels.gpa);
    const res = try runner.runPerSelection(doc, sels, typeOne, &st, ctx.origin);
    if (ctx.auto_pairs) |ap| for (sels.slice()) |s| {
        if (std.mem.indexOfScalar(u32, st.closed.items, s.id) != null) try ap.add(doc, s.head);
    };
    return res;
}

// -- newline ----------------------------------------------------------------

const NewlineState = struct { ctx: EditCtx, gpa: Allocator };

fn newlineOne(ptr: *anyopaque, snap: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    const st: *NewlineState = @ptrCast(@alignCast(ptr));
    const c = st.ctx;
    const t = &snap.tree;
    const rules = c.rules();
    const unit = c.indentUnit();
    const pos = sel.start();
    const ls = t.lineStart(t.lineOf(pos));
    var buf: [line_window]u8 = undefined;
    const before = copy(t, ls, pos, &buf);
    var ws = indent.leading(before);
    var cols = IndentUnit.columns(ws, c.tab_size);
    // A line that is just a dedent keyword (`fi`, `done`) is re-indented
    // before the break.
    var line_ws: ?[]const u8 = null;
    var lb: [512]u8 = undefined;
    if (sel.isCaret() and indent.isDedentKeyword(std.mem.trimEnd(u8, before[ws.len..], " \t"), rules)) {
        const want = indent.keywordIndent(t, t.lineOf(pos), cols, unit, c.tab_size);
        if (want != cols) {
            line_ws = unit.write(want, &lb);
            ws = line_ws.?;
            cols = want;
        }
    }
    switch (indent.changeAfter(before, rules, c.brackets())) {
        .indent => cols += unit.size,
        .dedent => cols -|= unit.size,
        .same => {},
    }
    // The rest of the line after the selection, without leading blanks
    // (they would land at the start of the new line).
    var end = sel.end();
    while (byteAt(t, end)) |b| {
        if (b != ' ' and b != '\t') break;
        end += 1;
    }
    // A whitespace-only line keeps no trailing blanks; a re-indented
    // keyword line is rewritten whole.
    const blank = indent.leading(before).len == before.len;
    const start = if (blank or line_ws != null) ls else pos;
    var keep_buf: [line_window + 512]u8 = undefined;
    const keep: []const u8 = if (line_ws) |lw| blk: {
        const body = before[indent.leading(before).len..];
        @memcpy(keep_buf[0..lw.len], lw);
        @memcpy(keep_buf[lw.len..][0..body.len], body);
        break :blk keep_buf[0 .. lw.len + body.len];
    } else "";
    // Between an opener and its closer: open the pair over three lines.
    const next = nextOnLine(t, end);
    var split_pair = false;
    if (next) |nb| for (c.brackets()) |b| {
        if (b.close.len == 1 and b.close[0] == nb and std.mem.endsWith(u8, std.mem.trimEnd(u8, before, " \t"), b.open)) split_pair = true;
    };
    if (rules.tag_pairs and !split_pair and next == '<' and byteAt(t, end + 1) == '/' and endsInOpenTag(before)) {
        split_pair = true;
        cols += unit.size;
    }
    var ib: [512]u8 = undefined;
    const new_indent = unit.write(cols, &ib);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(st.gpa);
    try text.appendSlice(st.gpa, keep);
    try text.append(st.gpa, '\n');
    try text.appendSlice(st.gpa, new_indent);
    const caret: u32 = @intCast(text.items.len);
    if (split_pair) {
        var ob: [512]u8 = undefined;
        try text.append(st.gpa, '\n');
        try text.appendSlice(st.gpa, unit.write(IndentUnit.columns(ws, c.tab_size), &ob));
    } else if (next) |nb| {
        // A closer right after the caret goes back to the line's indent.
        if (indent.startsDedented(&.{nb}, rules, c.brackets()) and cols >= unit.size) {
            text.shrinkRetainingCapacity(text.items.len - new_indent.len);
            var ob: [512]u8 = undefined;
            try text.appendSlice(st.gpa, unit.write(cols - unit.size, &ob));
        }
    }
    _ = try out.replace(.{ .start = start, .end = end }, text.items);
    out.select(.{ .in_edit = .{ .edit = 0, .delta = @min(caret, @as(u32, @intCast(text.items.len))) } });
}

/// Whether `before` ends with an opening tag (`<p class="x">`, not
/// `</p>`, `<br/>` or `<!-- -->`).
fn endsInOpenTag(before: []const u8) bool {
    const s = std.mem.trimEnd(u8, before, " \t");
    if (s.len < 3 or s[s.len - 1] != '>' or s[s.len - 2] == '/') return false;
    const lt = std.mem.lastIndexOfScalar(u8, s, '<') orelse return false;
    return lt + 1 < s.len and std.ascii.isAlphabetic(s[lt + 1]);
}

/// Enter at every selection: the new line gets the current line's indent,
/// one level more after an opener or `indent_after` token and one less
/// after a `dedent_after` keyword; between a bracket pair the closer moves
/// to its own line.
pub fn newline(doc: *Document, sels: *SelectionSet, ctx: EditCtx) !runner.RunResult {
    var st: NewlineState = .{ .ctx = ctx, .gpa = sels.gpa };
    return runner.runPerSelection(doc, sels, newlineOne, &st, ctx.origin);
}

// -- deleteLeft -------------------------------------------------------------

const DeleteState = struct { ctx: EditCtx, use_tab_stops: bool };

fn deleteLeftOne(ptr: *anyopaque, snap: *const Snapshot, sel: Selection, out: *runner.EditBuilder) anyerror!void {
    const st: *DeleteState = @ptrCast(@alignCast(ptr));
    const t = &snap.tree;
    if (!sel.isCaret()) {
        _ = try out.delete(sel.range());
        out.select(.{ .in_edit = .{ .edit = 0 } });
        return;
    }
    const pos = sel.head;
    if (pos == 0) return;
    if (st.ctx.auto_pairs) |ap| if (ap.has(pos)) {
        for (st.ctx.closePairs()) |p| {
            if (pos < p.open.len or pos + p.close.len > t.len()) continue;
            var b1: [8]u8 = undefined;
            var b2: [8]u8 = undefined;
            if (std.mem.eql(u8, copy(t, pos - p.open.len, pos, &b1), p.open) and std.mem.eql(u8, copy(t, pos, pos + p.close.len, &b2), p.close)) {
                ap.remove(pos);
                _ = try out.delete(.{ .start = pos - p.open.len, .end = pos + p.close.len });
                out.select(.{ .in_edit = .{ .edit = 0 } });
                return;
            }
        }
    };
    var to = movement.move(snap, pos, .grapheme, .backward, .{});
    if (st.use_tab_stops) if (cmds.tabStopBack(snap, pos, st.ctx.tab_size)) |ts| {
        to = ts;
    };
    _ = try out.delete(.{ .start = to, .end = pos });
    out.select(.{ .in_edit = .{ .edit = 0 } });
}

/// Backspace at every selection: an auto-inserted pair around the caret
/// goes as one; leading spaces go back to the previous tab stop.
pub fn deleteLeft(doc: *Document, sels: *SelectionSet, ctx: EditCtx, use_tab_stops: bool) !runner.RunResult {
    if (ctx.auto_pairs) |ap| ap.sync(doc);
    sels.normalize(.for_edit);
    var st: DeleteState = .{ .ctx = ctx, .use_tab_stops = use_tab_stops };
    return runner.runPerSelection(doc, sels, deleteLeftOne, &st, ctx.origin);
}

// -- comments ---------------------------------------------------------------

/// Toggles line comments (see comment.zig).
pub fn toggleLineComment(doc: *Document, sels: *SelectionSet, ctx: EditCtx) !bool {
    return comment.toggleLineComment(doc, sels, ctx.rules(), ctx.origin);
}

/// Toggles a block comment around each selection (see comment.zig).
pub fn toggleBlockComment(doc: *Document, sels: *SelectionSet, ctx: EditCtx) !bool {
    return comment.toggleBlockComment(doc, sels, ctx.rules(), ctx.origin);
}
