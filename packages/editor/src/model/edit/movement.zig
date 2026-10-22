//! Cursor movement by unit: grapheme, word (UAX #29 classes with a code
//! tailoring, see word.zig), subword, line boundaries, display rows,
//! paragraphs, pages, brackets and the document. Every move reads a small
//! window of the piece tree into a stack buffer: O(log n + window), no
//! allocation.

const std = @import("std");
const zg_text = @import("zg_text");
const zg_syntax = @import("zg_syntax");
const word_mod = @import("word.zig");
const mc = @import("multi_cursor.zig");
const snapshot_mod = @import("../snapshot.zig");
const pt = @import("../buffer/piece_tree.zig");

const Snapshot = snapshot_mod.Snapshot;
const PieceTree = pt.PieceTree;
const grapheme = zg_text.unicode.grapheme;
const WordClass = word_mod.WordClass;

/// What a move steps over.
pub const Unit = enum {
    grapheme,
    /// VS Code word: forward lands at the end of the next word, backward
    /// at the start of the previous one.
    word,
    /// Vim `e` (forward) and `ge` (backward): ends of words, across lines.
    word_end,
    subword,
    /// Vim WORD (`W`/`B`): runs of non-whitespace.
    whitespace_word,
    /// Line start or end.
    line_boundary,
    /// Home: the first non-whitespace character, then column 0.
    smart_home,
    display_row,
    buffer_line,
    paragraph,
    page,
    bracket,
    document,
};

pub const Dir = enum { backward, forward };

/// What a move may consult. `goal_x` is the sticky x for vertical moves
/// (pixels with a display map, display columns without).
pub const MoveContext = struct {
    display: ?mc.DisplayMapQuery = null,
    goal_x: ?f32 = null,
    page_rows: u32 = 40,
    lang: ?*const zg_syntax.Language = null,
    tab_size: u8 = 4,

    fn wordChars(c: MoveContext) []const u21 {
        return if (c.lang) |l| l.word_chars else &.{};
    }

    fn columns(c: MoveContext) mc.ColumnOptions {
        return .{ .tab_size = c.tab_size };
    }
};

/// The position `unit` away from `pos` in `dir`, clamped to the document.
pub fn move(snap: *const Snapshot, pos_in: u64, unit: Unit, dir: Dir, ctx: MoveContext) u64 {
    var tx: Text = .init(&snap.tree);
    const pos = @min(pos_in, tx.len);
    return switch (unit) {
        .grapheme => graphemeStep(&tx, pos, dir),
        .word => switch (dir) {
            .forward => wordForward(&tx, pos, ctx.wordChars(), false),
            .backward => wordBackward(&tx, pos, ctx.wordChars(), false),
        },
        .subword => switch (dir) {
            .forward => wordForward(&tx, pos, ctx.wordChars(), true),
            .backward => wordBackward(&tx, pos, ctx.wordChars(), true),
        },
        .word_end => switch (dir) {
            .forward => wordEndForward(&tx, pos, ctx.wordChars()),
            .backward => wordEndBackward(&tx, pos, ctx.wordChars()),
        },
        .whitespace_word => switch (dir) {
            .forward => bigWordForward(&tx, pos),
            .backward => bigWordBackward(&tx, pos),
        },
        .line_boundary => switch (dir) {
            .forward => tx.lineEndOf(pos),
            .backward => tx.lineStartOf(pos),
        },
        .smart_home => switch (dir) {
            .forward => tx.lineEndOf(pos),
            .backward => smartHome(&tx, pos),
        },
        .buffer_line => vertical(&tx, pos, dir, 1, ctx, false),
        .display_row => vertical(&tx, pos, dir, 1, ctx, true),
        .page => vertical(&tx, pos, dir, ctx.page_rows, ctx, true),
        .paragraph => paragraph(&tx, pos, dir),
        .bracket => matchingBracket(&tx, pos) orelse pos,
        .document => switch (dir) {
            .forward => tx.len,
            .backward => 0,
        },
    };
}

/// The x a vertical move from `pos` keeps: the display map's x, or the
/// display column.
pub fn goalOf(snap: *const Snapshot, pos: u64, ctx: MoveContext) f32 {
    if (ctx.display) |d| return d.rowOf(pos).x;
    var tx: Text = .init(&snap.tree);
    const line = tx.t.lineOf(pos);
    var buf: [line_window]u8 = undefined;
    const lt = tx.lineText(line, &buf);
    const at: usize = @intCast(@min(pos - tx.t.lineStart(line), lt.len));
    return @floatFromInt(mc.columnOf(lt, at, ctx.columns()));
}

/// Whether `unit` moves vertically (keeps `goal_x`).
pub fn isVertical(unit: Unit) bool {
    return switch (unit) {
        .buffer_line, .display_row, .page => true,
        else => false,
    };
}

// -- reading text -----------------------------------------------------------

const window = 512;
/// Bytes of a line considered for display columns.
const line_window = 4096;

const Cp = struct { cp: u21, len: u3 };

/// A window of the tree, reloaded around a position on demand.
const Text = struct {
    t: *const PieceTree,
    len: u64,
    buf: [window]u8 = undefined,
    base: u64 = 0,
    n: usize = 0,

    fn init(t: *const PieceTree) Text {
        return .{ .t = t, .len = t.len() };
    }

    fn load(x: *Text, center: u64) void {
        const s = center -| window / 2;
        const e = @min(x.len, s + window);
        x.base = s;
        x.n = 0;
        var it = x.t.slice(.{ .start = s, .end = e });
        while (it.next()) |c| {
            @memcpy(x.buf[x.n..][0..c.len], c);
            x.n += c.len;
        }
    }

    /// Makes the window cover `[pos - margin, pos + margin]` (clamped).
    fn ensure(x: *Text, pos: u64, margin: u64) void {
        const lo = pos -| margin;
        const hi = @min(x.len, pos + margin);
        if (lo < x.base or hi > x.base + x.n) x.load(pos);
    }

    /// The code point starting at `pos` (an invalid byte is U+FFFD of
    /// length 1).
    fn after(x: *Text, pos: u64) ?Cp {
        if (pos >= x.len) return null;
        x.ensure(pos, 4);
        const b = x.buf[@intCast(pos - x.base)..x.n];
        return decodeAt(b);
    }

    /// The code point ending at `pos`.
    fn before(x: *Text, pos: u64) ?Cp {
        if (pos == 0) return null;
        x.ensure(pos, 4);
        const i: usize = @intCast(pos - x.base);
        var s = i - 1;
        var k: usize = 0;
        while (k < 3 and s > 0 and x.buf[s] & 0xc0 == 0x80) : (k += 1) s -= 1;
        const c = decodeAt(x.buf[s..i]);
        if (c.len == i - s) return c;
        return .{ .cp = 0xfffd, .len = 1 };
    }

    fn byteAt(x: *Text, pos: u64) u8 {
        x.ensure(pos, 1);
        return x.buf[@intCast(pos - x.base)];
    }

    /// The start of line `line`'s text (without EOL) copied into `buf`
    /// (truncated to its size).
    fn lineText(x: *Text, line: u64, buf: []u8) []const u8 {
        const lr = x.t.lineRange(line);
        return x.copy(lr.start, lr.end, buf);
    }

    /// The start of the line containing `pos`, by scanning back (one
    /// descent plus the line's length).
    fn lineStartOf(x: *Text, pos: u64) u64 {
        var it = x.t.chunksRev(pos);
        var end = pos;
        while (it.next()) |c| {
            if (std.mem.lastIndexOfAny(u8, c, "\n\r")) |i| return end - c.len + i + 1;
            end -= c.len;
        }
        return 0;
    }

    /// The end (before the EOL) of the line containing `pos`.
    fn lineEndOf(x: *Text, pos: u64) u64 {
        var it = x.t.chunks(pos);
        var start = pos;
        while (it.next()) |c| {
            if (std.mem.indexOfAny(u8, c, "\n\r")) |i| return start + i;
            start += c.len;
        }
        return x.len;
    }

    /// Bytes `[start, end)` copied into `buf` (truncated to its size).
    fn copy(x: *Text, start: u64, end_in: u64, buf: []u8) []const u8 {
        const end = @min(end_in, start + buf.len);
        var n: usize = 0;
        var it = x.t.slice(.{ .start = start, .end = end });
        while (it.next()) |c| {
            @memcpy(buf[n..][0..c.len], c);
            n += c.len;
        }
        return buf[0..n];
    }
};

fn decodeAt(b: []const u8) Cp {
    const n = std.unicode.utf8ByteSequenceLength(b[0]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (n > b.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(b[0..n]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = @intCast(n) };
}

// -- graphemes --------------------------------------------------------------

fn graphemeStep(tx: *Text, pos: u64, dir: Dir) u64 {
    switch (dir) {
        .forward => {
            if (pos >= tx.len) return tx.len;
            tx.ensure(pos, window / 2 - 1);
            const i: usize = @intCast(pos - tx.base);
            return tx.base + grapheme.nextBoundary(tx.buf[0..tx.n], i);
        },
        .backward => {
            if (pos == 0) return 0;
            tx.ensure(pos, window / 2 - 1);
            const i: usize = @intCast(pos - tx.base);
            const p = tx.base + grapheme.prevBoundary(tx.buf[0..tx.n], i);
            // A window start that is not the document start is not a
            // boundary: step at least one code point.
            if (p == tx.base and tx.base > 0 and p + window / 2 < pos) return pos - tx.before(pos).?.len;
            return p;
        },
    }
}

// -- words ------------------------------------------------------------------

fn classAfter(tx: *Text, pos: u64, extra: []const u21) ?struct { class: WordClass, len: u3, cp: u21 } {
    const c = tx.after(pos) orelse return null;
    return .{ .class = word_mod.classify(c.cp, extra), .len = c.len, .cp = c.cp };
}

fn classBefore(tx: *Text, pos: u64, extra: []const u21) ?struct { class: WordClass, len: u3, cp: u21 } {
    const c = tx.before(pos) orelse return null;
    return .{ .class = word_mod.classify(c.cp, extra), .len = c.len, .cp = c.cp };
}

/// Past an EOL starting at `pos` (`\r\n` counts as one).
fn eolAfter(tx: *Text, pos: u64) u64 {
    if (tx.byteAt(pos) == '\r' and pos + 1 < tx.len and tx.byteAt(pos + 1) == '\n') return pos + 2;
    return pos + 1;
}

fn eolBefore(tx: *Text, pos: u64) u64 {
    if (tx.byteAt(pos - 1) == '\n' and pos >= 2 and tx.byteAt(pos - 2) == '\r') return pos - 2;
    return pos - 1;
}

fn skipSpaceForward(tx: *Text, pos: u64, extra: []const u21) u64 {
    var p = pos;
    while (classAfter(tx, p, extra)) |c| {
        if (c.class != .space) break;
        p += c.len;
    }
    return p;
}

fn skipSpaceBackward(tx: *Text, pos: u64, extra: []const u21) u64 {
    var p = pos;
    while (classBefore(tx, p, extra)) |c| {
        if (c.class != .space) break;
        p -= c.len;
    }
    return p;
}

/// VS Code word right: an EOL is one stop; otherwise skip whitespace and
/// land at the end of the run that follows (stopping at subword
/// boundaries when `sub`).
fn wordForward(tx: *Text, pos: u64, extra: []const u21, sub: bool) u64 {
    const first = classAfter(tx, pos, extra) orelse return tx.len;
    if (first.class == .newline) return eolAfter(tx, pos);
    var p = pos;
    if (sub) {
        // Separators inside identifiers (`_`, `-`) are skipped like spaces.
        while (classAfter(tx, p, extra)) |c| {
            if (c.class != .space and !(c.class == .ident and word_mod.isSubwordSeparator(c.cp)) and !(c.class == .punct and c.cp == '-')) break;
            p += c.len;
        }
    } else p = skipSpaceForward(tx, p, extra);
    const c0 = classAfter(tx, p, extra) orelse return p;
    if (c0.class == .newline) return p;
    var prev = c0.cp;
    p += c0.len;
    while (classAfter(tx, p, extra)) |c| {
        if (c.class != c0.class) break;
        if (sub and c0.class == .ident) {
            if (word_mod.isSubwordSeparator(c.cp)) break;
            const next = tx.after(p + c.len);
            if (word_mod.subwordBoundary(prev, c.cp, if (next) |n| n.cp else 0)) break;
        }
        prev = c.cp;
        p += c.len;
    }
    return p;
}

/// VS Code word left: an EOL is one stop; otherwise skip whitespace and
/// land at the start of the run before it.
fn wordBackward(tx: *Text, pos: u64, extra: []const u21, sub: bool) u64 {
    const first = classBefore(tx, pos, extra) orelse return 0;
    if (first.class == .newline) return eolBefore(tx, pos);
    var p = pos;
    if (sub) {
        while (classBefore(tx, p, extra)) |c| {
            if (c.class != .space and !(c.class == .ident and word_mod.isSubwordSeparator(c.cp)) and !(c.class == .punct and c.cp == '-')) break;
            p -= c.len;
        }
    } else p = skipSpaceBackward(tx, p, extra);
    const c0 = classBefore(tx, p, extra) orelse return p;
    if (c0.class == .newline) return p;
    var next = c0.cp;
    p -= c0.len;
    while (classBefore(tx, p, extra)) |c| {
        if (c.class != c0.class) break;
        if (sub and c0.class == .ident) {
            if (word_mod.isSubwordSeparator(c.cp)) break;
            // `next` follows `c`; the code point after `next` decides
            // Upper Upper lower.
            const nlen: u64 = std.unicode.utf8CodepointSequenceLength(next) catch 1;
            const after_next = tx.after(p + nlen);
            if (word_mod.subwordBoundary(c.cp, next, if (after_next) |n| n.cp else 0)) break;
        }
        next = c.cp;
        p -= c.len;
    }
    return p;
}

fn isBlankClass(c: WordClass) bool {
    return c == .space or c == .newline;
}

/// Vim `e`: the end of the next word, crossing lines.
fn wordEndForward(tx: *Text, pos: u64, extra: []const u21) u64 {
    var p = pos;
    // Step off the current character so a cursor already at a word end moves on.
    if (classAfter(tx, p, extra)) |c| p += c.len else return tx.len;
    while (classAfter(tx, p, extra)) |c| {
        if (!isBlankClass(c.class)) break;
        p += c.len;
    }
    const c0 = classAfter(tx, p, extra) orelse return tx.len;
    p += c0.len;
    while (classAfter(tx, p, extra)) |c| {
        if (c.class != c0.class) break;
        p += c.len;
    }
    return p;
}

/// Vim `ge`: the end of the previous word, crossing lines.
fn wordEndBackward(tx: *Text, pos: u64, extra: []const u21) u64 {
    var p = pos;
    if (classBefore(tx, p, extra)) |c0| {
        if (!isBlankClass(c0.class)) {
            // Leave the run the cursor is in or just after.
            while (classBefore(tx, p, extra)) |c| {
                if (c.class != c0.class) break;
                p -= c.len;
            }
        }
    } else return 0;
    while (classBefore(tx, p, extra)) |c| {
        if (!isBlankClass(c.class)) break;
        p -= c.len;
    }
    return p;
}

/// Vim `W`: the start of the next whitespace-delimited WORD.
fn bigWordForward(tx: *Text, pos: u64) u64 {
    var p = pos;
    while (classAfter(tx, p, &.{})) |c| {
        if (isBlankClass(c.class)) break;
        p += c.len;
    }
    while (classAfter(tx, p, &.{})) |c| {
        if (!isBlankClass(c.class)) break;
        p += c.len;
    }
    return p;
}

/// Vim `B`: the start of the previous WORD.
fn bigWordBackward(tx: *Text, pos: u64) u64 {
    var p = pos;
    while (classBefore(tx, p, &.{})) |c| {
        if (!isBlankClass(c.class)) break;
        p -= c.len;
    }
    while (classBefore(tx, p, &.{})) |c| {
        if (isBlankClass(c.class)) break;
        p -= c.len;
    }
    return p;
}

// -- lines ------------------------------------------------------------------

/// The first byte from `lr.start` that is not a space or tab (stops at
/// `lr.end`).
fn firstNonBlank(tx: *Text, lr: anytype) u64 {
    var p = lr.start;
    while (p < lr.end) : (p += 1) {
        const b = tx.byteAt(p);
        if (b != ' ' and b != '\t') break;
    }
    return p;
}

fn smartHome(tx: *Text, pos: u64) u64 {
    const start = tx.lineStartOf(pos);
    const f = firstNonBlank(tx, .{ .start = start, .end = tx.len });
    return if (pos == f) start else f;
}

/// Vim `}` / `{`: the next (previous) blank (whitespace-only) line after
/// a non-blank one, or the document's end (start). Streams chunks: one
/// descent plus the bytes passed over.
fn paragraph(tx: *Text, pos: u64, dir: Dir) u64 {
    var seen_text = false;
    var blank = true;
    switch (dir) {
        .forward => {
            const from = tx.lineEndOf(pos);
            if (from >= tx.len) return tx.len;
            var line_start = eolAfter(tx, from);
            var it = tx.t.chunks(line_start);
            var off = line_start;
            while (it.next()) |c| {
                for (c, 0..) |byte, i| {
                    if (byte == '\n') {
                        if (blank and seen_text) return line_start;
                        if (!blank) seen_text = true;
                        blank = true;
                        line_start = off + i + 1;
                    } else if (byte != ' ' and byte != '\t' and byte != '\r') blank = false;
                }
                off += c.len;
            }
            if (blank and seen_text and line_start < tx.len) return line_start;
            return tx.len;
        },
        .backward => {
            const ls = tx.lineStartOf(pos);
            if (ls == 0) return 0;
            // Bytes before the current line's EOL, read backward: each
            // '\n' ends the line read so far (which starts after it).
            var it = tx.t.chunksRev(ls - 1);
            var end = ls - 1;
            while (it.next()) |c| {
                var i = c.len;
                while (i > 0) {
                    i -= 1;
                    const byte = c[i];
                    if (byte == '\n') {
                        const start = end - c.len + i + 1;
                        if (blank and seen_text) return start;
                        if (!blank) seen_text = true;
                        blank = true;
                    } else if (byte != ' ' and byte != '\t' and byte != '\r') blank = false;
                }
                end -= c.len;
            }
            return 0;
        },
    }
}

/// Up or down `n` rows keeping `ctx.goal_x` (or the current x). Through
/// the display map when there is one and `display`; otherwise buffer
/// lines and display columns.
fn vertical(tx: *Text, pos: u64, dir: Dir, n: u32, ctx: MoveContext, display: bool) u64 {
    if (display) if (ctx.display) |d| {
        const here = d.rowOf(pos);
        const rows = d.rowCount();
        const row: u64 = switch (dir) {
            .forward => if (here.row + n >= rows) return tx.len else here.row + n,
            .backward => if (here.row < n) return 0 else here.row - n,
        };
        return d.hitTest(row, ctx.goal_x orelse here.x).offset;
    };
    var buf: [line_window]u8 = undefined;
    const ls = tx.lineStartOf(pos);
    const col: u32 = if (ctx.goal_x) |g| @intFromFloat(@max(0, @round(g))) else blk: {
        const lt = tx.copy(ls, pos, &buf);
        break :blk mc.columnOf(lt, lt.len, ctx.columns());
    };
    // The target line's start: by scanning for one line, else by index.
    const start: u64 = if (n == 1) switch (dir) {
        .forward => blk: {
            const e = tx.lineEndOf(pos);
            if (e >= tx.len) return tx.len;
            break :blk eolAfter(tx, e);
        },
        .backward => blk: {
            if (ls == 0) return 0;
            break :blk tx.lineStartOf(eolBefore(tx, ls));
        },
    } else blk: {
        const line = tx.t.lineOf(pos);
        const lines = tx.t.lineCount();
        const target: u64 = switch (dir) {
            .forward => if (line + n >= lines) return tx.len else line + n,
            .backward => if (line < n) return 0 else line - n,
        };
        break :blk tx.t.lineStart(target);
    };
    // A column needs at most 1 byte per column, plus a cluster's tail;
    // the copy stops at the line's EOL.
    const dst = lineHead(tx.copy(start, start + col + 64, &buf));
    const r = mc.byteAtColumn(dst, col, ctx.columns());
    return start + r.byte;
}

/// `bytes` up to its first EOL.
fn lineHead(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfAny(u8, bytes, "\n\r") orelse bytes.len];
}

// -- brackets ---------------------------------------------------------------

/// Bytes a bracket scan reads before giving up.
const max_bracket_scan = 1 << 20;

fn partner(b: u8) ?struct { other: u8, forward: bool } {
    return switch (b) {
        '(' => .{ .other = ')', .forward = true },
        '[' => .{ .other = ']', .forward = true },
        '{' => .{ .other = '}', .forward = true },
        ')' => .{ .other = '(', .forward = false },
        ']' => .{ .other = '[', .forward = false },
        '}' => .{ .other = '{', .forward = false },
        else => null,
    };
}

/// The position of the bracket matching the one after `pos` (or, failing
/// that, before it): at an opener's partner, or at a closer's partner.
/// A plain scan that skips nothing (no strings or comments).
pub fn matchingBracketPos(snap: *const Snapshot, pos: u64) ?u64 {
    var tx: Text = .init(&snap.tree);
    return matchingBracket(&tx, @min(pos, tx.len));
}

fn matchingBracket(tx: *Text, pos: u64) ?u64 {
    const at: u64 = blk: {
        if (pos < tx.len and partner(tx.byteAt(pos)) != null) break :blk pos;
        if (pos > 0 and partner(tx.byteAt(pos - 1)) != null) break :blk pos - 1;
        return null;
    };
    const open = tx.byteAt(at);
    const pr = partner(open).?;
    var depth: u32 = 0;
    var p = at;
    var scanned: u32 = 0;
    while (scanned < max_bracket_scan) : (scanned += 1) {
        if (pr.forward) {
            p += 1;
            if (p >= tx.len) return null;
        } else {
            if (p == 0) return null;
            p -= 1;
        }
        const b = tx.byteAt(p);
        if (b == open) depth += 1 else if (b == pr.other) {
            if (depth == 0) return p;
            depth -= 1;
        }
    }
    return null;
}
