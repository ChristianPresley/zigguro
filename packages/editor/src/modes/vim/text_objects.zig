//! Vim text objects (motion.txt "Text object selection"): words, WORDs,
//! sentences, paragraphs, bracket blocks, quoted strings and tags. Each
//! returns the start of the object and where the cursor goes, as Vim's
//! `current_*` functions do, so the same result serves an operator
//! (start .. cursor, inclusive or not) and Visual mode (anchor, cursor).

const std = @import("std");
const text_mod = @import("text.zig");
const motions = @import("motions.zig");

const Text = text_mod.Text;

pub const Object = enum {
    word,
    big_word,
    sentence,
    paragraph,
    paren,
    bracket,
    brace,
    angle,
    double_quote,
    single_quote,
    backtick,
    tag,

    /// The object named by the character after `i`/`a`.
    pub fn fromChar(c: u21) ?Object {
        return switch (c) {
            'w' => .word,
            'W' => .big_word,
            's' => .sentence,
            'p' => .paragraph,
            '(', ')', 'b' => .paren,
            '[', ']' => .bracket,
            '{', '}', 'B' => .brace,
            '<', '>' => .angle,
            '"' => .double_quote,
            '\'' => .single_quote,
            '`' => .backtick,
            't' => .tag,
            else => null,
        };
    }
};

pub const Selection = struct {
    start: u64,
    /// Where the cursor goes; included when `inclusive`.
    cursor: u64,
    inclusive: bool = true,
    linewise: bool = false,
};

/// Selects `obj` around `pos`; `around` is `a` (vs `i`). `visual` is the
/// Visual anchor when Visual mode is active (extending the area).
pub fn select(x: Text, pos: u64, obj: Object, around: bool, count: u32, visual: ?u64) ?Selection {
    const n = @max(count, 1);
    return switch (obj) {
        .word, .big_word => currentWord(x, pos, n, around, obj == .big_word, visual),
        .paragraph => currentPar(x, pos, n, around, visual),
        .sentence => currentSent(x, pos, n, around),
        .paren => currentBlock(x, pos, n, around, '(', ')', visual),
        .bracket => currentBlock(x, pos, n, around, '[', ']', visual),
        .brace => currentBlock(x, pos, n, around, '{', '}', visual),
        .angle => currentBlock(x, pos, n, around, '<', '>', visual),
        .double_quote => currentQuote(x, pos, around, '"'),
        .single_quote => currentQuote(x, pos, around, '\''),
        .backtick => currentQuote(x, pos, around, '`'),
        .tag => currentTag(x, pos, n, around),
    };
}

fn oneLeft(x: Text, p: *u64) bool {
    const q = x.before(p.*);
    if (q == p.*) return false;
    p.* = q;
    return true;
}

fn backInLine(x: Text, p: *u64, big: bool) void {
    const sclass = x.class(p.*, big);
    while (true) {
        if (p.* == x.lineStart(x.lineOf(p.*))) break;
        _ = x.dec(p);
        if (x.class(p.*, big) != sclass) {
            _ = x.inc(p);
            break;
        }
    }
}

fn currentWord(x: Text, pos: u64, count_in: u32, include: bool, big: bool, visual: ?u64) ?Selection {
    var cur = pos;
    var start = pos;
    var count = count_in;
    var inclusive = true;
    var include_white = false;
    const fresh = visual == null or visual.? == pos;
    if (fresh) {
        backInLine(x, &cur, big);
        start = cur;
        if ((x.class(cur, big) == 0) == include) {
            if (!motions.endWord(x, &cur, 1, big, true, true)) return null;
        } else {
            _ = motions.fwdWord(x, &cur, 1, big, true);
            if (cur == x.lineStart(x.lineOf(cur))) {
                _ = motions.decl(x, &cur);
            } else {
                _ = oneLeft(x, &cur);
            }
            if (include) include_white = true;
        }
        count -= 1;
    } else start = visual.?;

    while (count > 0) : (count -= 1) {
        inclusive = true;
        if (visual != null and cur < start) {
            if (motions.decl(x, &cur) == -1) return null;
            if (include != (x.class(cur, big) != 0)) {
                if (!motions.bckWord(x, &cur, 1, big, true)) return null;
            } else {
                if (!motions.bckendWord(x, &cur, 1, big, true)) return null;
                _ = motions.incl(x, &cur);
            }
        } else {
            if (motions.incl(x, &cur) == -1) return null;
            if (include != (x.class(cur, big) == 0)) {
                if (!motions.fwdWord(x, &cur, 1, big, true) and count > 1) return null;
                if (!oneLeft(x, &cur)) inclusive = false;
            } else {
                if (!motions.endWord(x, &cur, 1, big, true, true)) return null;
            }
        }
    }

    if (include_white and (x.class(cur, big) != 0 or (cur == x.lineStart(x.lineOf(cur)) and !inclusive))) {
        // No white space after the word: take the white space before it
        // instead, but not the indent.
        var p = start;
        if (oneLeft(x, &p)) {
            backInLine(x, &p, big);
            if (x.class(p, big) == 0 and p != x.lineStart(x.lineOf(p))) start = p;
        }
    }
    return .{ .start = start, .cursor = cur, .inclusive = inclusive };
}

fn lineWhite(x: Text, line: u64) bool {
    return x.firstNonBlank(line) == x.lineEnd(line);
}

fn currentPar(x: Text, pos: u64, count: u32, include: bool, visual: ?u64) ?Selection {
    const last = x.lineCount() - 1;
    var start_l = x.lineOf(pos);
    if (visual) |v| if (x.lineOf(v) != start_l) {
        // Extend the Visual area by paragraphs.
        const back = start_l < x.lineOf(v);
        var i = count;
        while (i > 0) : (i -= 1) {
            if (start_l == (if (back) 0 else last)) return null;
            var prev_white: ?bool = null;
            for (0..2) |_| {
                start_l = if (back) start_l - 1 else start_l + 1;
                const white = lineWhite(x, start_l);
                if (prev_white != null and prev_white.? == white) {
                    start_l = if (back) start_l + 1 else start_l - 1;
                    break;
                }
                while (start_l != (if (back) 0 else last)) {
                    const nl = if (back) start_l - 1 else start_l + 1;
                    if (white != lineWhite(x, nl) or (!white and motions.startPS(x, if (back) start_l else start_l + 1))) break;
                    start_l = nl;
                }
                if (!include) break;
                if (start_l == (if (back) 0 else last)) break;
                prev_white = white;
            }
        }
        return .{ .start = v, .cursor = x.lineStart(start_l), .linewise = true };
    };

    const white_in_front = lineWhite(x, start_l);
    while (start_l > 0) : (start_l -= 1) {
        if (white_in_front) {
            if (!lineWhite(x, start_l - 1)) break;
        } else if (lineWhite(x, start_l - 1) or motions.startPS(x, start_l)) break;
    }
    var end_l = start_l;
    while (end_l <= last and lineWhite(x, end_l)) end_l += 1;
    end_l = if (end_l == 0) 0 else end_l - 1;
    // `end_l` may sit before `start_l` when the paragraph is not white.
    var end_i: i64 = @as(i64, @intCast(end_l));
    if (!lineWhite(x, start_l)) end_i = @as(i64, @intCast(start_l)) - 1;
    var i = count;
    if (!include and white_in_front) i -= 1;
    while (i > 0) {
        i -= 1;
        if (end_i == @as(i64, @intCast(last))) return null;
        var do_white = false;
        if (!include) do_white = lineWhite(x, @intCast(end_i + 1));
        if (include or !do_white) {
            end_i += 1;
            while (end_i < last and !lineWhite(x, @intCast(end_i + 1)) and !motions.startPS(x, @intCast(end_i + 1))) end_i += 1;
        }
        if (i == 0 and white_in_front and include) break;
        if (include or do_white) {
            while (end_i < last and lineWhite(x, @intCast(end_i + 1))) end_i += 1;
        }
    }
    const e: u64 = @intCast(@max(end_i, @as(i64, @intCast(start_l))));
    if (!white_in_front and !lineWhite(x, e) and include) {
        while (start_l > 0 and lineWhite(x, start_l - 1)) start_l -= 1;
    }
    return .{ .start = x.lineStart(start_l), .cursor = x.lineStart(e), .linewise = true };
}

fn currentSent(x: Text, pos: u64, count: u32, include: bool) ?Selection {
    // The sentence (or white space between sentences) around the cursor.
    var after_cursor = pos;
    _ = motions.incl(x, &after_cursor);
    const start = motions.findSent(x, after_cursor, false, 1) orelse 0;
    var end = start;
    var i = count;
    while (i > 0) : (i -= 1) end = motions.findSent(x, end, true, 1) orelse x.len;
    // `end` is the start of the next sentence; back over white space
    // unless it is included.
    var cur = end;
    if (cur > start) _ = motions.decl(x, &cur);
    var trail_white = false;
    while (cur > start and (x.cp(cur) == ' ' or x.cp(cur) == '\t' or x.cp(cur) == 0)) {
        trail_white = true;
        _ = motions.decl(x, &cur);
    }
    var s = start;
    if (include) {
        if (trail_white) {
            cur = end;
            _ = motions.decl(x, &cur);
        } else {
            // No white space after: take the white space before.
            var p = s;
            while (p > 0) {
                var q = p;
                if (motions.decl(x, &q) == -1) break;
                const c = x.cp(q);
                if (c != ' ' and c != '\t') break;
                p = q;
            }
            s = p;
        }
    }
    return .{ .start = s, .cursor = cur };
}

/// Whether only white space precedes `p` in its line, with `extra` more
/// characters of slack.
fn inIndent(x: Text, p: u64, extra: u64) bool {
    const ls = x.lineStart(x.lineOf(p));
    const fnb = x.firstNonBlank(x.lineOf(p));
    return fnb - ls >= p - ls + extra;
}

fn currentBlock(x: Text, pos: u64, count: u32, include: bool, open: u8, close: u8, visual: ?u64) ?Selection {
    var cur = pos;
    var old_start = pos;
    var old_end = pos;
    const fresh = visual == null or visual.? == pos;
    if (fresh) {
        if (open == '{') {
            while (inIndent(x, cur, 1)) if (x.inc(&cur) != 0) break;
        }
        if (x.byte(cur) == open) cur += 1;
    } else if (visual.? < pos) {
        old_start = visual.?;
        cur = visual.?;
    } else old_end = visual.?;

    var start = cur;
    var found = false;
    var i = count;
    while (i > 0) : (i -= 1) {
        const p = motions.findUnclosed(x, cur, open, close, false) orelse break;
        cur = p;
        start = p;
        found = true;
    }
    if (!found) return null;
    var end = motions.findUnclosed(x, start, open, close, true) orelse return null;

    var sol = false;
    while (!include) {
        _ = motions.incl(x, &start);
        sol = end == x.lineStart(x.lineOf(end));
        _ = motions.decl(x, &end);
        while (inIndent(x, end, 1)) {
            sol = true;
            if (motions.decl(x, &end) != 0) break;
        }
        if (visual != null and !fresh and !(start < old_start) and !(old_end < end) and start != end) {
            // Not bigger than before: extend to the next block out.
            var o = old_start;
            _ = motions.decl(x, &o);
            start = motions.findUnclosed(x, o, open, close, false) orelse return null;
            end = motions.findUnclosed(x, start, open, close, true) orelse return null;
        } else break;
    }

    if (visual != null) {
        if (sol and !x.atEol(end)) _ = x.inc(&end);
        return .{ .start = start, .cursor = end };
    }
    if (sol) {
        _ = motions.incl(x, &end);
        return .{ .start = start, .cursor = end, .inclusive = false };
    }
    if (start <= end) return .{ .start = start, .cursor = end };
    // Nothing between the brackets.
    return .{ .start = start, .cursor = start, .inclusive = false };
}

/// Quoted strings on the cursor's line (`\` escapes a quote).
fn currentQuote(x: Text, pos: u64, include: bool, q: u8) ?Selection {
    const line = x.lineOf(pos);
    const ls = x.lineStart(line);
    const le = x.lineEnd(line);
    // Positions of the unescaped quotes on the line.
    var quotes: [256]u64 = undefined;
    var nq: usize = 0;
    var p = ls;
    while (p < le and nq < quotes.len) : (p += 1) {
        const b = x.byte(p);
        if (b == '\\') {
            p += 1;
            continue;
        }
        if (b == q) {
            quotes[nq] = p;
            nq += 1;
        }
    }
    if (nq < 2) return null;
    var open: u64 = 0;
    var close: u64 = 0;
    // The cursor on a quote: count the quotes before it.
    var on: ?usize = null;
    for (quotes[0..nq], 0..) |qp, i| if (qp == pos) {
        on = i;
    };
    if (on) |i| {
        if (i % 2 == 0) {
            if (i + 1 >= nq) return null;
            open = quotes[i];
            close = quotes[i + 1];
        } else {
            open = quotes[i - 1];
            close = quotes[i];
        }
    } else {
        // Between quotes: the nearest before and after; before the first
        // quote, the first pair.
        var before_n: usize = 0;
        for (quotes[0..nq]) |qp| {
            if (qp < pos) before_n += 1;
        }
        if (before_n == 0) {
            open = quotes[0];
            close = quotes[1];
        } else if (before_n >= nq) {
            return null;
        } else {
            open = quotes[before_n - 1];
            close = quotes[before_n];
        }
    }
    if (!include) {
        if (close == open + 1) return .{ .start = close, .cursor = close, .inclusive = false };
        return .{ .start = open + 1, .cursor = x.before(close) };
    }
    // Trailing white space, or leading white space when there is none.
    var s = open;
    var e = close;
    var t = close + 1;
    while (t < le and text_mod.isBlank(x.byte(t))) t += 1;
    if (t > close + 1) {
        e = t - 1;
    } else {
        while (s > ls and text_mod.isBlank(x.byte(s - 1))) s -= 1;
        // Not the indent.
        if (s == ls) s = open;
    }
    return .{ .start = s, .cursor = e };
}

/// `<tag>` ... `</tag>` around the cursor (a plain scan, nesting by name).
fn currentTag(x: Text, pos: u64, count: u32, include: bool) ?Selection {
    var search_from = pos;
    // On an opening tag, start inside it.
    if (x.byte(pos) == '<') search_from = pos + 1;
    var level = count;
    var open_start: u64 = 0;
    var open_end: u64 = 0;
    var name_buf: [64]u8 = undefined;
    var name: []const u8 = "";
    var close_start: u64 = 0;
    var close_end: u64 = 0;
    var from = search_from;
    while (level > 0) : (level -= 1) {
        // Find an unclosed opening tag before `from` whose closing tag
        // comes after `pos`.
        var p = from;
        var found = false;
        while (p > 0) {
            p -= 1;
            if (x.byte(p) != '<' or x.byte(p + 1) == '/' or x.byte(p + 1) == '!') continue;
            var e = p + 1;
            var nl: usize = 0;
            while (e < x.len and nl < name_buf.len) : (e += 1) {
                const b = x.byte(e);
                if (b == '>' or b == ' ' or b == '/' or b == '\n' or b == '\t') break;
                name_buf[nl] = b;
                nl += 1;
            }
            if (nl == 0) continue;
            var gt = e;
            while (gt < x.len and x.byte(gt) != '>') gt += 1;
            if (gt >= x.len or x.byte(gt - 1) == '/') continue;
            const close = findClose(x, gt + 1, name_buf[0..nl]) orelse continue;
            if (close.end <= pos) continue;
            open_start = p;
            open_end = gt + 1;
            name = name_buf[0..nl];
            close_start = close.start;
            close_end = close.end;
            found = true;
            break;
        }
        if (!found) return null;
        from = open_start;
    }
    if (include) return .{ .start = open_start, .cursor = close_end - 1 };
    if (close_start == open_end) return .{ .start = open_end, .cursor = open_end, .inclusive = false };
    return .{ .start = open_end, .cursor = x.before(close_start) };
}

fn findClose(x: Text, from: u64, name: []const u8) ?struct { start: u64, end: u64 } {
    var depth: u32 = 0;
    var p = from;
    while (p + 1 < x.len) : (p += 1) {
        if (x.byte(p) != '<') continue;
        const closing = x.byte(p + 1) == '/';
        const ns = p + (if (closing) @as(u64, 2) else 1);
        if (!nameAt(x, ns, name)) continue;
        var gt = ns + name.len;
        while (gt < x.len and x.byte(gt) != '>') gt += 1;
        if (gt >= x.len) return null;
        if (closing) {
            if (depth == 0) return .{ .start = p, .end = gt + 1 };
            depth -= 1;
        } else if (x.byte(gt - 1) != '/') depth += 1;
        p = gt;
    }
    return null;
}

fn nameAt(x: Text, p: u64, name: []const u8) bool {
    for (name, 0..) |b, i| if (x.byte(p + i) != b) return false;
    const e = x.byte(p + name.len);
    return e == '>' or e == ' ' or e == '/' or e == '\n' or e == '\t';
}
