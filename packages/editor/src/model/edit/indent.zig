//! Indentation for smart typing: a line's indentation and its width, the
//! indentation unit guessed from a file (VS Code's histogram of indent
//! deltas over the first 1,000 indented lines), the indent a new line gets
//! after Enter (the line's indent, one level more after an opener or an
//! `indent_after` token, one less after a `dedent_after` keyword), and the
//! opener a closing bracket matches for electric dedent.

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const snapshot_mod = @import("../snapshot.zig");
const pt = @import("../buffer/piece_tree.zig");

const Snapshot = snapshot_mod.Snapshot;
const PieceTree = pt.PieceTree;
const EditRules = zg_syntax.language.EditRules;
const BracketPair = zg_syntax.language.BracketPair;

/// How one indentation level is written.
pub const IndentUnit = struct {
    tabs: bool = false,
    /// Columns per level (the tab width when `tabs`).
    size: u8 = 4,

    /// Columns of `ws` (spaces and tabs), with tab stops every
    /// `tab_size` columns.
    pub fn columns(ws: []const u8, tab_size: u8) u32 {
        var c: u32 = 0;
        for (ws) |b| c = if (b == '\t') (c / tab_size + 1) * tab_size else c + 1;
        return c;
    }

    /// Writes `cols` columns of indentation into `out` (tabs first when
    /// `tabs`, then spaces for the remainder).
    pub fn write(u: IndentUnit, cols: u32, out: []u8) []const u8 {
        var n: usize = 0;
        var c = cols;
        if (u.tabs) {
            while (c >= u.size and n < out.len) : (c -= u.size) {
                out[n] = '\t';
                n += 1;
            }
        }
        while (c > 0 and n < out.len) : (c -= 1) {
            out[n] = ' ';
            n += 1;
        }
        return out[0..n];
    }
};

/// Lines read by `guess`.
pub const guess_lines = 1000;

/// The indentation unit of `snap`'s text, from the first `guess_lines`
/// indented lines: tabs when most indented lines start with a tab,
/// otherwise the most common positive change in leading spaces between
/// consecutive non-blank lines (2, 4 or 8 preferred on ties). Null when
/// nothing is indented.
pub fn guess(snap: *const Snapshot) ?IndentUnit {
    var tab_lines: u32 = 0;
    var space_lines: u32 = 0;
    var deltas = [_]u32{0} ** 9;
    var prev_spaces: u32 = 0;
    var indented: u32 = 0;
    var it = snap.tree.chunks(0);
    var at_line_start = true;
    var spaces: u32 = 0;
    var first: u8 = 0;
    var blank = true;
    var counting = true;
    outer: while (it.next()) |c| {
        for (c) |b| {
            if (b == '\n') {
                if (!blank) {
                    if (first == '\t') tab_lines += 1 else if (first == ' ') space_lines += 1;
                    if (first != '\t') {
                        if (spaces > prev_spaces and spaces - prev_spaces <= 8) deltas[spaces - prev_spaces] += 1;
                        prev_spaces = spaces;
                    }
                    if (first == '\t' or first == ' ') {
                        indented += 1;
                        if (indented >= guess_lines) break :outer;
                    }
                }
                at_line_start = true;
                spaces = 0;
                first = 0;
                blank = true;
                counting = true;
                continue;
            }
            if (at_line_start) {
                first = b;
                at_line_start = false;
            }
            if (counting and b == ' ') {
                spaces += 1;
            } else if (b != '\t' and b != ' ' and b != '\r') {
                counting = false;
                blank = false;
            } else if (b == '\t') counting = false;
        }
    }
    if (tab_lines == 0 and space_lines == 0) return null;
    if (tab_lines > space_lines) return .{ .tabs = true };
    var best: u8 = 4;
    var best_n: u32 = 0;
    for ([_]u8{ 2, 4, 8, 3, 6, 5, 7, 1 }) |d| if (deltas[d] > best_n) {
        best = d;
        best_n = deltas[d];
    };
    return .{ .size = best };
}

/// Bytes of a line considered by indentation rules.
const line_window = 4096;

/// A line's text (without EOL) copied into `buf`, truncated to it.
pub fn lineText(t: *const PieceTree, line: u64, buf: []u8) []const u8 {
    const lr = t.lineRange(line);
    const end = @min(lr.end, lr.start + buf.len);
    var n: usize = 0;
    var it = t.slice(.{ .start = lr.start, .end = end });
    while (it.next()) |c| {
        @memcpy(buf[n..][0..c.len], c);
        n += c.len;
    }
    return buf[0..n];
}

/// The leading spaces and tabs of `line`.
pub fn leading(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[0..i];
}

/// What the text before a new line asks of the new line's indent.
pub const Change = enum { same, indent, dedent };

/// Classifies `before` (a line's text up to the caret): `indent` when it
/// ends (ignoring trailing blanks and a line comment) with an unclosed
/// opener of `brackets` or with an `indent_after` token, `dedent` when its
/// first word is a `dedent_after` keyword.
pub fn changeAfter(before: []const u8, rules: EditRules, brackets: []const BracketPair) Change {
    var text = before;
    if (rules.line_comment) |lc| if (std.mem.indexOf(u8, text, lc)) |i| {
        text = text[0..i];
    };
    text = std.mem.trimEnd(u8, text, " \t\r");
    const body = std.mem.trimStart(u8, text, " \t");
    if (body.len == 0) return .same;
    for (rules.dedent_after) |kw| {
        if (std.mem.startsWith(u8, body, kw) and (body.len == kw.len or !isIdent(body[kw.len]))) return .dedent;
    }
    for (rules.indent_after) |tok| if (std.mem.endsWith(u8, text, tok)) return .indent;
    // An opener left unclosed on this line.
    var depth: i32 = 0;
    var i = body.len;
    while (i > 0) {
        i -= 1;
        for (brackets) |b| {
            if (endsAt(body, i, b.close)) depth += 1;
            if (endsAt(body, i, b.open)) {
                if (depth == 0) return .indent;
                depth -= 1;
            }
        }
    }
    return .same;
}

fn endsAt(s: []const u8, i: usize, tok: []const u8) bool {
    return tok.len > 0 and i + 1 >= tok.len and std.mem.eql(u8, s[i + 1 - tok.len .. i + 1], tok);
}

fn isIdent(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Whether `rest` (a line's text after its indentation) starts with a
/// token that dedents the line: a `dedent_on` token or a closer of
/// `brackets`.
pub fn startsDedented(rest: []const u8, rules: EditRules, brackets: []const BracketPair) bool {
    for (rules.dedent_on) |tok| {
        if (!std.mem.startsWith(u8, rest, tok)) continue;
        // A keyword must end there ("fi", not "find").
        if (isIdent(tok[tok.len - 1]) and rest.len > tok.len and isIdent(rest[tok.len])) continue;
        return true;
    }
    for (brackets) |b| if (b.close.len > 0 and std.mem.startsWith(u8, rest, b.close)) return true;
    return false;
}

/// Whether `word` is one of the language's `dedent_on` keywords (not a
/// bracket token, which the electric closer handles).
pub fn isDedentKeyword(word: []const u8, rules: EditRules) bool {
    if (word.len == 0 or !isIdent(word[0])) return false;
    for (rules.dedent_on) |tok| if (std.mem.eql(u8, tok, word)) return true;
    return false;
}

/// Columns for line `line` once it starts with a dedent keyword (`else`,
/// `fi`): the previous non-blank line's indent when this line is deeper
/// than it (the keyword closes that line's block), else one level less.
pub fn keywordIndent(t: *const PieceTree, line: u64, cur: u32, unit: IndentUnit, tab_size: u8) u32 {
    var buf: [line_window]u8 = undefined;
    var l = line;
    var seen: u32 = 0;
    while (l > 0 and seen < 1000) : (seen += 1) {
        l -= 1;
        const text = lineText(t, l, &buf);
        const ws = leading(text);
        if (ws.len == text.len) continue;
        const prev = IndentUnit.columns(ws, tab_size);
        return if (cur > prev) prev else cur -| unit.size;
    }
    return cur -| unit.size;
}

/// Bytes the opener search reads before giving up.
const max_scan = 1 << 20;

/// The opener of `pair` that a closer typed at `pos` would close: a plain
/// backward scan counting nested pairs (single-byte brackets).
pub fn findOpener(snap: *const Snapshot, pos: u64, pair: BracketPair) ?u64 {
    if (pair.open.len != 1 or pair.close.len != 1) return null;
    const open = pair.open[0];
    const close = pair.close[0];
    var depth: u32 = 0;
    var it = snap.tree.chunksRev(pos);
    var end = pos;
    var scanned: usize = 0;
    while (it.next()) |c| {
        var i = c.len;
        while (i > 0) {
            i -= 1;
            if (c[i] == close) depth += 1 else if (c[i] == open) {
                if (depth == 0) return end - c.len + i;
                depth -= 1;
            }
        }
        end -= c.len;
        scanned += c.len;
        if (scanned > max_scan) return null;
    }
    return null;
}

/// The indentation (as text) of the line holding `pos`, copied to `buf`.
pub fn indentOfLineAt(t: *const PieceTree, pos: u64, buf: []u8) []const u8 {
    var tmp: [line_window]u8 = undefined;
    const line = lineText(t, t.lineOf(pos), &tmp);
    const ws = leading(line);
    const n = @min(ws.len, buf.len);
    @memcpy(buf[0..n], ws[0..n]);
    return buf[0..n];
}
