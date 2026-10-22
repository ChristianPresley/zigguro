//! Vim motions (motion.txt): where each one goes from a cursor, and the
//! motion's type (exclusive, inclusive or linewise). The word, sentence
//! and paragraph searches follow Vim's own algorithms (`fwd_word`,
//! `end_word`, `bck_word`, `bckend_word`, `findsent`, `findpar`), which
//! step with `Text.inc`/`Text.dec` over Vim's line-end positions.

const std = @import("std");
const text_mod = @import("text.zig");

const Text = text_mod.Text;

pub const Kind = enum { exclusive, inclusive, linewise };

pub const Motion = enum {
    left,
    right,
    /// `<BS>`: left, wrapping to the previous line.
    back_wrap,
    /// `<Space>`: right, wrapping to the next line.
    space_wrap,
    up,
    down,
    word,
    big_word,
    back_word,
    back_big_word,
    end_word,
    end_big_word,
    back_end_word,
    back_end_big_word,
    line_start,
    first_non_blank,
    line_end,
    last_non_blank,
    column,
    goto_first_line,
    goto_line,
    find_forward,
    find_backward,
    till_forward,
    till_backward,
    repeat_find,
    repeat_find_reverse,
    match_pair,
    paragraph_back,
    paragraph_forward,
    sentence_back,
    sentence_forward,
    down_first_non_blank,
    up_first_non_blank,
    current_line_first_non_blank,
    search_word_forward,
    search_word_backward,
    search_next,
    search_prev,

    /// Whether the motion is a jump (sets the previous-context mark).
    pub fn isJump(m: Motion) bool {
        return switch (m) {
            .goto_first_line, .goto_line, .match_pair, .paragraph_back, .paragraph_forward, .sentence_back, .sentence_forward, .search_word_forward, .search_word_backward, .search_next, .search_prev => true,
            else => false,
        };
    }

    /// Whether the motion keeps the remembered column (`curswant`).
    pub fn isVertical(m: Motion) bool {
        return m == .up or m == .down;
    }

    /// Whether the motion takes a character argument.
    pub fn takesChar(m: Motion) bool {
        return switch (m) {
            .find_forward, .find_backward, .till_forward, .till_backward => true,
            else => false,
        };
    }
};

/// The last `f`/`F`/`t`/`T`, for `;` and `,`.
pub const LastFind = struct { motion: Motion, char: u21 };

/// The last `*`/`#` (or `/`) search, for `n` and `N`.
pub const LastSearch = struct {
    buf: [256]u8 = undefined,
    len: u8 = 0,
    whole_word: bool = false,
    backward: bool = false,

    pub fn pattern(s: *const LastSearch) []const u8 {
        return s.buf[0..s.len];
    }
};

pub const Context = struct {
    /// The count typed, or 0 for none.
    count: u32 = 0,
    /// An operator is pending.
    op_pending: bool = false,
    /// `c` is the pending operator (`cw` acts like `ce`).
    op_change: bool = false,
    /// Visual mode is active: the cursor may rest on a line end.
    visual: bool = false,
    /// The remembered column for `j`/`k`, in characters; null: end of line.
    want: ?u32 = 0,
    char: u21 = 0,
    last_find: ?LastFind = null,
    last_search: ?*const LastSearch = null,
    /// Scratch for searches (whole lines).
    scratch: ?*std.ArrayList(u8) = null,
    gpa: ?std.mem.Allocator = null,

    fn n(c: Context) u32 {
        return if (c.count == 0) 1 else c.count;
    }
};

pub const Result = struct {
    pos: u64,
    kind: Kind,
    /// The cursor stays on a line end in normal mode (`$` remembers it).
    want_eol: bool = false,
    /// For `j`/`k`: keep the remembered column.
    keep_want: bool = false,
    /// The motion moved only partly (Vim beeps but an operator still applies).
    failed: bool = false,
    /// The operator end may not be moved back from column 0 (`<BS>` onto a line end).
    no_adjust_end: bool = false,
};

/// Where `m` goes from `pos`; null when it fails (Vim beeps and an
/// operator is cancelled).
pub fn eval(x: Text, pos: u64, m: Motion, c: Context) ?Result {
    const n = c.n();
    const line = x.lineOf(pos);
    switch (m) {
        .left => {
            var p = pos;
            for (0..n) |_| {
                const q = x.before(p);
                if (q == p) break;
                p = q;
            }
            if (p == pos) return null;
            return .{ .pos = p, .kind = .exclusive };
        },
        .right => return right(x, pos, n, c, false),
        .space_wrap => return right(x, pos, n, c, true),
        .back_wrap => {
            var p = pos;
            var r: Result = .{ .pos = pos, .kind = .exclusive };
            for (0..n) |_| {
                const q = x.before(p);
                if (q != p) {
                    p = q;
                    continue;
                }
                const l = x.lineOf(p);
                if (l == 0) break;
                // Onto the previous line's last character; an operator
                // deletes the line break too.
                p = x.lastChar(l - 1);
                if (c.op_pending and !x.lineIsEmpty(l - 1)) {
                    p = x.lineEnd(l - 1);
                    r.no_adjust_end = true;
                }
            }
            if (p == pos) return null;
            r.pos = p;
            return r;
        },
        .down, .up => {
            const target: u64 = if (m == .down) blk: {
                if (x.isLastLine(line)) return null;
                break :blk @min(line + n, x.lineCount() - 1);
            } else blk: {
                if (line == 0) return null;
                break :blk line -| n;
            };
            const p = if (c.want) |w| x.atColumn(target, w, false) else x.lastChar(target);
            return .{ .pos = p, .kind = .linewise, .keep_want = true };
        },
        .down_first_non_blank, .up_first_non_blank, .current_line_first_non_blank => {
            const target: u64 = switch (m) {
                .down_first_non_blank => if (line + n >= x.lineCount()) return null else line + n,
                .up_first_non_blank => if (n > line) return null else line - n,
                else => if (line + n - 1 >= x.lineCount()) return null else line + n - 1,
            };
            return .{ .pos = x.firstNonBlank(target), .kind = .linewise };
        },
        .word, .big_word => {
            const big = m == .big_word;
            if (c.op_change and x.class(pos, big) != 0) {
                // "cw" on a word changes to its end, like "ce".
                var p = pos;
                const ok = endWord(x, &p, n, big, true, false);
                return .{ .pos = p, .kind = .inclusive, .failed = !ok };
            }
            var p = pos;
            const ok = fwdWord(x, &p, n, big, c.op_pending);
            if (!ok and !c.op_pending) {
                if (p == pos) return null;
            }
            return adjustEol(x, pos, p, .exclusive, c, !ok);
        },
        .end_word, .end_big_word => {
            var p = pos;
            const ok = endWord(x, &p, n, m == .end_big_word, false, false);
            if (!ok and !c.op_pending and p == pos) return null;
            return adjustEol(x, pos, p, .inclusive, c, !ok);
        },
        .back_word, .back_big_word => {
            var p = pos;
            if (!bckWord(x, &p, n, m == .back_big_word, false)) return null;
            return .{ .pos = p, .kind = .exclusive };
        },
        .back_end_word, .back_end_big_word => {
            var p = pos;
            if (!bckendWord(x, &p, n, m == .back_end_big_word, false)) return null;
            return .{ .pos = p, .kind = .inclusive };
        },
        .line_start => return .{ .pos = x.lineStart(line), .kind = .exclusive },
        .first_non_blank => return .{ .pos = x.firstNonBlank(line), .kind = .exclusive },
        .line_end => {
            if (line + n - 1 >= x.lineCount()) return null;
            const l = line + n - 1;
            const p = if (c.op_pending or c.visual) x.lineEnd(l) else x.lastChar(l);
            // An operator includes the last character; Visual mode the line break.
            return .{ .pos = if (c.op_pending) x.lastChar(l) else p, .kind = .inclusive, .want_eol = true };
        },
        .last_non_blank => {
            if (line + n - 1 >= x.lineCount()) return null;
            const l = line + n - 1;
            var p = x.lineEnd(l);
            const s = x.lineStart(l);
            while (p > s) {
                const q = x.before(p);
                if (!text_mod.isBlank(x.byte(q))) {
                    p = q;
                    break;
                }
                p = q;
            }
            return .{ .pos = p, .kind = .inclusive };
        },
        .column => return .{ .pos = x.atColumn(line, n - 1, false), .kind = .exclusive },
        .goto_first_line, .goto_line => {
            const last = x.lineCount() - 1;
            const target: u64 = if (c.count > 0) @min(c.count - 1, last) else if (m == .goto_first_line) 0 else last;
            return .{ .pos = x.firstNonBlank(target), .kind = .linewise };
        },
        .find_forward, .find_backward, .till_forward, .till_backward => return find(x, pos, m, c.char, n, false),
        .repeat_find, .repeat_find_reverse => {
            const lf = c.last_find orelse return null;
            const mm = if (m == .repeat_find) lf.motion else reverse(lf.motion);
            return find(x, pos, mm, lf.char, n, true);
        },
        .match_pair => {
            if (c.count > 0) {
                if (c.count > 100) return null;
                const lines = x.lineCount();
                const target = (@as(u64, c.count) * lines + 99) / 100;
                return .{ .pos = x.firstNonBlank(@max(target, 1) - 1), .kind = .linewise };
            }
            return .{ .pos = matchPair(x, pos) orelse return null, .kind = .inclusive };
        },
        .paragraph_forward, .paragraph_back => {
            var inclusive = false;
            const p = findPar(x, pos, m == .paragraph_forward, n, &inclusive) orelse return null;
            return .{ .pos = p, .kind = if (inclusive) .inclusive else .exclusive };
        },
        .sentence_forward, .sentence_back => {
            const p = findSent(x, pos, m == .sentence_forward, n) orelse return null;
            return .{ .pos = p, .kind = .exclusive };
        },
        .search_word_forward, .search_word_backward, .search_next, .search_prev => return search(x, pos, m, n, c),
    }
}

fn right(x: Text, pos: u64, n: u32, c: Context, wrap: bool) ?Result {
    var p = pos;
    var r: Result = .{ .pos = pos, .kind = .exclusive };
    var moved = false;
    for (0..n) |_| {
        const l = x.lineOf(p);
        const at_end = if (c.visual) x.atEol(p) else x.atEol(x.after(p)) or x.atEol(p);
        if (!at_end) {
            p = x.after(p);
            moved = true;
            continue;
        }
        if (wrap and !x.isLastLine(l)) {
            // An operator first takes the last character, then the line break.
            if (c.op_pending and r.kind == .exclusive and !x.lineIsEmpty(l)) {
                r.kind = .inclusive;
            } else {
                p = x.lineStart(l + 1);
                r.kind = .exclusive;
            }
            moved = true;
            continue;
        }
        if (!c.op_pending) {
            if (!moved) return null;
        } else if (!x.lineIsEmpty(l)) {
            r.kind = .inclusive;
            moved = true;
        }
        break;
    }
    if (!moved) return null;
    r.pos = p;
    return r;
}

/// After a forward word motion: a cursor left on a line end steps back
/// onto the last character, and an operator then includes it (Vim's
/// `adjust_cursor`).
fn adjustEol(x: Text, start: u64, p: u64, kind: Kind, c: Context, failed: bool) Result {
    var r: Result = .{ .pos = p, .kind = kind, .failed = failed };
    if (p > start and !c.visual and x.atEol(p) and p > x.lineStart(x.lineOf(p))) {
        r.pos = x.before(p);
        r.kind = .inclusive;
    }
    return r;
}

fn reverse(m: Motion) Motion {
    return switch (m) {
        .find_forward => .find_backward,
        .find_backward => .find_forward,
        .till_forward => .till_backward,
        .till_backward => .till_forward,
        else => m,
    };
}

fn find(x: Text, pos: u64, m: Motion, ch: u21, n: u32, repeat: bool) ?Result {
    const line = x.lineOf(pos);
    const ls = x.lineStart(line);
    const le = x.lineEnd(line);
    var p = pos;
    var left = n;
    switch (m) {
        .find_forward, .till_forward => {
            // ";" after "t" does not stop right before the same character.
            if (repeat and m == .till_forward and x.after(p) < le and x.cp(x.after(p)) == ch) p = x.after(p);
            while (left > 0) {
                p = x.after(p);
                if (p >= le) return null;
                if (x.cp(p) == ch) left -= 1;
            }
            if (m == .till_forward) p = x.before(p);
            return .{ .pos = p, .kind = .inclusive };
        },
        else => {
            if (repeat and m == .till_backward and p > ls and x.cp(x.before(p)) == ch) p = x.before(p);
            while (left > 0) {
                if (p <= ls) return null;
                p = x.before(p);
                if (x.cp(p) == ch) left -= 1;
            }
            if (m == .till_backward) p = x.after(p);
            return .{ .pos = p, .kind = .exclusive };
        },
    }
}

// -- words (Vim's search.c / textobject.c) ------------------------------------

fn skipChars(x: Text, p: *u64, class: u8, big: bool, forward: bool) bool {
    while (x.class(p.*, big) == class) {
        const r = if (forward) x.inc(p) else x.dec(p);
        if (r == -1) return true;
    }
    return false;
}

/// `w`/`W`; `eol`: stop at the end of the line for the last word (an
/// operator is pending). False when it hit the end of the text.
pub fn fwdWord(x: Text, p: *u64, count: u32, big: bool, eol: bool) bool {
    var left = count;
    while (left > 0) {
        left -= 1;
        const sclass = x.class(p.*, big);
        const last_line = x.isLastLine(x.lineOf(p.*));
        var i = x.inc(p);
        if (i == -1 or (i >= 1 and last_line)) return false;
        if (i >= 1 and eol and left == 0) return true;
        if (sclass != 0) {
            while (x.class(p.*, big) == sclass) {
                i = x.inc(p);
                if (i == -1 or (i >= 1 and eol and left == 0)) return true;
            }
        }
        while (x.class(p.*, big) == 0) {
            const l = x.lineOf(p.*);
            if (p.* == x.lineStart(l) and x.lineIsEmpty(l)) break;
            i = x.inc(p);
            if (i == -1 or (i >= 1 and eol and left == 0)) return true;
        }
    }
    return true;
}

/// `e`/`E`; `stop`: stay in the current word if inside one (`cw`);
/// `empty`: stop at empty lines.
pub fn endWord(x: Text, p: *u64, count: u32, big: bool, stop_in: bool, empty: bool) bool {
    var left = count;
    var stop = stop_in;
    while (left > 0) {
        left -= 1;
        const sclass = x.class(p.*, big);
        if (x.inc(p) == -1) return false;
        finished: {
            if (x.class(p.*, big) == sclass and sclass != 0) {
                if (skipChars(x, p, sclass, big, true)) return false;
            } else if (!stop or sclass == 0) {
                while (x.class(p.*, big) == 0) {
                    const l = x.lineOf(p.*);
                    if (p.* == x.lineStart(l) and x.lineIsEmpty(l) and empty) break :finished;
                    if (x.inc(p) == -1) return false;
                }
                if (skipChars(x, p, x.class(p.*, big), big, true)) return false;
            }
            _ = x.dec(p);
        }
        stop = false;
    }
    return true;
}

/// `b`/`B`; `stop`: stay in the current word (text objects).
pub fn bckWord(x: Text, p: *u64, count: u32, big: bool, stop_in: bool) bool {
    var left = count;
    var stop = stop_in;
    while (left > 0) {
        left -= 1;
        const sclass = x.class(p.*, big);
        if (x.dec(p) == -1) return false;
        finished: {
            if (!stop or sclass == x.class(p.*, big) or sclass == 0) {
                while (x.class(p.*, big) == 0) {
                    const l = x.lineOf(p.*);
                    if (p.* == x.lineStart(l) and x.lineIsEmpty(l)) break :finished;
                    if (x.dec(p) == -1) return true;
                }
                if (skipChars(x, p, x.class(p.*, big), big, false)) return true;
            }
            _ = x.inc(p);
        }
        stop = false;
    }
    return true;
}

/// `ge`/`gE`; `eol`: stop at a line break (text objects).
pub fn bckendWord(x: Text, p: *u64, count: u32, big: bool, eol: bool) bool {
    var left = count;
    while (left > 0) {
        left -= 1;
        const sclass = x.class(p.*, big);
        var i = x.dec(p);
        if (i == -1) return false;
        if (eol and i == 1) return true;
        if (sclass != 0) {
            while (x.class(p.*, big) == sclass) {
                i = x.dec(p);
                if (i == -1 or (eol and i == 1)) return true;
            }
        }
        while (x.class(p.*, big) == 0) {
            const l = x.lineOf(p.*);
            if (p.* == x.lineStart(l) and x.lineIsEmpty(l)) break;
            i = x.dec(p);
            if (i == -1 or (eol and i == 1)) return true;
        }
    }
    return true;
}

/// `inc` that skips the line end of non-empty lines (Vim's `incl`).
pub fn incl(x: Text, p: *u64) i8 {
    var r = x.inc(p);
    if (r >= 1 and p.* != x.lineStart(x.lineOf(p.*))) r = x.inc(p);
    return r;
}

/// `dec` that skips the line end of non-empty lines (Vim's `decl`).
pub fn decl(x: Text, p: *u64) i8 {
    var r = x.dec(p);
    if (r == 1 and p.* != x.lineStart(x.lineOf(p.*))) r = x.dec(p);
    return r;
}

// -- paragraphs and sentences -------------------------------------------------

/// Paragraph and section boundaries: empty lines (and form feeds).
pub fn startPS(x: Text, line: u64) bool {
    return x.lineIsEmpty(line) or x.byte(x.lineStart(line)) == 0x0C;
}

fn findPar(x: Text, pos: u64, forward: bool, count: u32, incl_out: *bool) ?u64 {
    var curr: i64 = @intCast(x.lineOf(pos));
    const last: i64 = @intCast(x.lineCount() - 1);
    var left = count;
    while (left > 0) {
        left -= 1;
        var did_skip = false;
        var first = true;
        while (true) : (first = false) {
            if (!x.lineIsEmpty(@intCast(curr))) did_skip = true;
            if (!first and did_skip and startPS(x, @intCast(curr))) break;
            curr += if (forward) 1 else -1;
            if (curr < 0 or curr > last) {
                if (left > 0) return null;
                curr -= if (forward) 1 else -1;
                break;
            }
        }
    }
    const l: u64 = @intCast(curr);
    if (forward and curr == last) {
        if (!x.lineIsEmpty(l)) {
            incl_out.* = true;
            return x.lastChar(l);
        }
    }
    return x.lineStart(l);
}

fn isSentEnd(c: u21) bool {
    return c == '.' or c == '!' or c == '?';
}

fn isCloser(c: u21) bool {
    return c == ')' or c == ']' or c == '"' or c == '\'';
}

fn isWhite(c: u21) bool {
    return c == ' ' or c == '\t';
}

/// Vim's `findsent`.
pub fn findSent(x: Text, start: u64, forward: bool, count: u32) ?u64 {
    var pos = start;
    var left = count;
    while (left > 0) {
        left -= 1;
        var noskip = false;
        found: {
            const l0 = x.lineOf(pos);
            if (x.cp(pos) == 0) {
                while (true) {
                    const r = if (forward) incl(x, &pos) else decl(x, &pos);
                    if (r == -1) break;
                    if (x.cp(pos) != 0) break;
                }
                if (forward) break :found;
            } else if (forward and pos == x.lineStart(l0) and startPS(x, l0)) {
                if (x.isLastLine(l0)) return null;
                pos = x.lineStart(l0 + 1);
                break :found;
            } else if (!forward) {
                _ = decl(x, &pos);
            }

            // Back over white space and punctuation before the start.
            var found_dot = false;
            while (true) {
                const c = x.cp(pos);
                if (!(isWhite(c) or isSentEnd(c) or isCloser(c))) break;
                var t = pos;
                if (decl(x, &t) == -1 or (x.lineIsEmpty(x.lineOf(t)) and forward)) break;
                if (found_dot) break;
                if (isSentEnd(c)) found_dot = true;
                const tc = x.cp(t);
                if (isCloser(c) and !(isSentEnd(tc) or isCloser(tc))) break;
                _ = decl(x, &pos);
            }

            const startlnum = x.lineOf(pos);
            while (true) {
                const c = x.cp(pos);
                if (c == 0 or (pos == x.lineStart(x.lineOf(pos)) and startPS(x, x.lineOf(pos)))) {
                    if (!forward and x.lineOf(pos) != startlnum) pos = x.lineStart(x.lineOf(pos) + 1);
                    break;
                }
                if (isSentEnd(c)) {
                    var t = pos;
                    var r: i8 = 0;
                    while (true) {
                        r = x.inc(&t);
                        if (r == -1) break;
                        if (!isCloser(x.cp(t))) break;
                    }
                    const tc = x.cp(t);
                    if (r == -1 or isWhite(tc) or tc == 0) {
                        pos = t;
                        if (x.cp(pos) == 0) _ = x.inc(&pos);
                        break;
                    }
                }
                const r = if (forward) incl(x, &pos) else decl(x, &pos);
                if (r == -1) {
                    if (left > 0) return null;
                    noskip = true;
                    break;
                }
            }
        }
        while (!noskip and isWhite(x.cp(pos))) {
            if (incl(x, &pos) == -1) break;
        }
    }
    return pos;
}

// -- brackets -------------------------------------------------------------------

const pairs = "()[]{}";

/// `%`: the bracket under or after the cursor on its line, matched.
pub fn matchPair(x: Text, pos: u64) ?u64 {
    const le = x.lineEnd(x.lineOf(pos));
    var p = pos;
    while (p < le) : (p = x.after(p)) {
        const b = x.byte(p);
        if (std.mem.indexOfScalar(u8, pairs, b)) |i| return matchBracket(x, p, pairs[i ^ 1], i % 2 == 0);
    }
    return null;
}

fn matchBracket(x: Text, at: u64, other: u8, forward: bool) ?u64 {
    const self = x.byte(at);
    var depth: u32 = 0;
    var p = at;
    while (true) {
        if (forward) {
            p += 1;
            if (p >= x.len) return null;
        } else {
            if (p == 0) return null;
            p -= 1;
        }
        const b = x.byte(p);
        if (b == self) depth += 1 else if (b == other) {
            if (depth == 0) return p;
            depth -= 1;
        }
    }
}

/// The unclosed `open` before `pos` (or the unclosed `close` after it),
/// not counting the character at `pos`.
pub fn findUnclosed(x: Text, pos: u64, open: u8, close: u8, forward: bool) ?u64 {
    var depth: u32 = 0;
    var p = pos;
    const self = if (forward) open else close;
    const want = if (forward) close else open;
    while (true) {
        if (forward) {
            p += 1;
            if (p >= x.len) return null;
        } else {
            if (p == 0) return null;
            p -= 1;
        }
        const b = x.byte(p);
        if (b == self) depth += 1 else if (b == want) {
            if (depth == 0) return p;
            depth -= 1;
        }
    }
}

// -- word search (* # n N) -----------------------------------------------------

/// The keyword under or after the cursor on its line, for `*` and `#`:
/// its range and whether it is a keyword (searched as a whole word).
pub fn wordUnderCursor(x: Text, pos: u64) ?struct { start: u64, end: u64, keyword: bool } {
    const le = x.lineEnd(x.lineOf(pos));
    var p = pos;
    // A keyword under or after the cursor wins; otherwise any non-blank.
    var q = p;
    while (q < le and x.class(q, false) != 2) q = x.after(q);
    var keyword = true;
    if (q >= le) {
        keyword = false;
        while (p < le and x.class(p, false) == 0) p = x.after(p);
        if (p >= le) return null;
        q = p;
    }
    const class = x.class(q, false);
    var s = q;
    const ls = x.lineStart(x.lineOf(pos));
    while (s > ls and x.class(x.before(s), false) == class) s = x.before(s);
    var e = q;
    while (e < le and x.class(e, false) == class) e = x.after(e);
    return .{ .start = s, .end = e, .keyword = keyword };
}

fn search(x: Text, pos: u64, m: Motion, n: u32, c: Context) ?Result {
    const s = c.last_search orelse return null;
    const pat = s.pattern();
    if (pat.len == 0) return null;
    const backward = switch (m) {
        .search_word_backward => true,
        .search_word_forward => false,
        .search_next => s.backward,
        else => !s.backward,
    };
    var p = pos;
    for (0..n) |_| p = searchOnce(x, p, pat, s.whole_word, backward) orelse return null;
    return .{ .pos = p, .kind = .exclusive };
}

fn matchesAt(x: Text, p: u64, pat: []const u8, whole: bool) bool {
    if (p + pat.len > x.len) return false;
    for (pat, 0..) |b, i| if (x.byte(p + i) != b) return false;
    if (whole) {
        if (p > 0 and text_mod.classOf(x.byte(p - 1)) == 2 and x.byte(p - 1) < 0x80) return false;
        const e = p + pat.len;
        if (e < x.len and text_mod.classOf(x.byte(e)) == 2 and x.byte(e) < 0x80) return false;
    }
    return true;
}

/// The next match of `pat` after (or before) `pos`, wrapping around.
fn searchOnce(x: Text, pos: u64, pat: []const u8, whole: bool, backward: bool) ?u64 {
    if (x.len == 0) return null;
    var p = pos;
    var steps: u64 = 0;
    while (steps <= x.len) : (steps += 1) {
        if (backward) {
            p = if (p == 0) x.len - 1 else p - 1;
        } else {
            p = if (p + 1 >= x.len) 0 else p + 1;
        }
        if (matchesAt(x, p, pat, whole)) return p;
    }
    return null;
}
