//! Markdown (CommonMark 0.31.2 blocks, GFM tables and autolinks) as an
//! injection host. Fenced code blocks inject the language their info
//! string names (looked up in the registry by name or alias through
//! `LexState.pushByName`); HTML blocks inject HTML; `---` front matter on
//! the first line injects YAML. `injection_end` finds the closing fence,
//! the blank line ending an HTML block, or the end of the front matter
//! before the guest sees the line. An unknown info string (or a missing
//! guest) leaves the block to the host, which emits each line as one raw
//! token.
//!
//! Inline spans are matched within the line with simple delimiter rules:
//! code spans by equal backtick runs, `**`/`__` strong and `*`/`_`
//! emphasis to the next matching closer on the line (`_` only at word
//! boundaries), links and images, autolinks and bare URLs, inline HTML,
//! escapes and character references. Deviations from CommonMark: no
//! nested emphasis inside a span, no spans across lines, HTML blocks of
//! every type end at a blank line, closing fences may sit at any
//! indentation (so fences inside list items close), and setext underlines
//! highlight only the underline (the paragraph line is already lexed).
//!
//! State (`mode`): bits 0-2 the block (normal, fenced code, front matter,
//! HTML block), bit 3 "the previous line was paragraph text", bit 4 "a
//! line was lexed" (front matter is only allowed before it), bit 5 "the
//! fence is `~`", bits 6-15 the fence length.

const std = @import("std");
const language = @import("../language.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Token kinds.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const text: u16 = 2;
    /// An ATX heading or setext underline; the level is `kind - heading + 1`.
    pub const heading: u16 = 3 | atomic;
    pub const marker: u16 = 10 | atomic;
    pub const fence: u16 = 11 | atomic;
    pub const info: u16 = 12 | atomic;
    pub const raw: u16 = 13;
    pub const code_span: u16 = 14 | atomic;
    pub const strong: u16 = 15 | atomic;
    pub const emphasis: u16 = 16 | atomic;
    pub const link_text: u16 = 17 | atomic;
    pub const link_dest: u16 = 18 | atomic;
    pub const autolink: u16 = 19 | atomic;
    pub const html: u16 = 20 | atomic;
    pub const escape: u16 = 21 | atomic;
    pub const rule: u16 = 22 | atomic;
    pub const pipe: u16 = 23 | atomic;
    pub const comment: u16 = 24;
};

/// Blocks (`mode` bits 0-2).
pub const Block = struct {
    pub const normal: u16 = 0;
    pub const fence: u16 = 1;
    pub const front_matter: u16 = 2;
    pub const html: u16 = 3;
    pub const mask: u16 = 7;
};

pub const Bits = struct {
    pub const paragraph: u16 = 0x8;
    pub const started: u16 = 0x10;
    pub const tilde: u16 = 0x20;
    pub const len_shift: u4 = 6;
    pub const max_len: u16 = 0x3ff;
};

const heading_hls = [_]HighlightId{ .markup_heading_1, .markup_heading_2, .markup_heading_3, .markup_heading_4, .markup_heading_5, .markup_heading_6 };

fn isSpaceB(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r';
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!isSpaceB(c)) return false;
    return true;
}

fn trimCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// The run of `c` at `i`.
fn runAt(line: []const u8, i: usize, c: u8) usize {
    var n: usize = 0;
    while (i + n < line.len and line[i + n] == c) n += 1;
    return n;
}

/// Whether `line` closes a fence of `len` `c`s: optional indentation, at
/// least `len` fence characters, then only blanks.
fn closesFence(line: []const u8, c: u8, len: usize) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '>')) i += 1;
    const n = runAt(line, i, c);
    return n >= len and isBlank(line[i + n ..]);
}

fn fenceOf(mode: u16) struct { u8, usize } {
    return .{ if (mode & Bits.tilde != 0) '~' else '`', mode >> Bits.len_shift };
}

fn isFrontMatterEnd(line: []const u8) bool {
    const t = std.mem.trimEnd(u8, line, " \t\r");
    return std.mem.eql(u8, t, "---") or std.mem.eql(u8, t, "...");
}

/// CommonMark HTML block start conditions 1-6 (by tag name) and 2-5.
fn htmlBlockStarts(rest: []const u8, paragraph: bool) bool {
    if (rest.len < 2 or rest[0] != '<') return false;
    if (std.mem.startsWith(u8, rest, "<!--") or std.mem.startsWith(u8, rest, "<?") or
        std.mem.startsWith(u8, rest, "<![CDATA[")) return true;
    if (rest[1] == '!' and rest.len > 2 and std.ascii.isAlphabetic(rest[2])) return true;
    var i: usize = 1;
    if (rest[i] == '/') i += 1;
    const name_start = i;
    while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '-')) i += 1;
    if (i == name_start or !std.ascii.isAlphabetic(rest[name_start])) return false;
    const name = rest[name_start..i];
    const after_ok = i == rest.len or isSpaceB(rest[i]) or rest[i] == '>' or (rest[i] == '/' and i + 1 < rest.len and rest[i + 1] == '>');
    if (!after_ok) return false;
    const block_tags = [_][]const u8{
        "address",  "article",    "aside",    "base",    "basefont", "blockquote", "body",     "caption",  "center",
        "col",      "colgroup",   "dd",       "details", "dialog",   "dir",        "div",      "dl",       "dt",
        "fieldset", "figcaption", "figure",   "footer",  "form",     "frame",      "frameset", "h1",       "h2",
        "h3",       "h4",         "h5",       "h6",      "head",     "header",     "hr",       "html",     "iframe",
        "legend",   "li",         "link",     "main",    "menu",     "menuitem",   "nav",      "noframes", "ol",
        "optgroup", "option",     "p",        "param",   "search",   "section",    "summary",  "table",    "tbody",
        "td",       "tfoot",      "th",       "thead",   "title",    "tr",         "track",    "ul",       "pre",
        "script",   "style",      "textarea",
    };
    for (block_tags) |t| if (std.ascii.eqlIgnoreCase(name, t)) return true;
    // Condition 7: any other tag alone on its line, not inside a paragraph.
    return !paragraph and std.mem.endsWith(u8, std.mem.trimEnd(u8, rest, " \t\r"), ">");
}

/// Whether `rest` is a GFM table delimiter row (`| --- | :-: |`).
fn isDelimiterRow(rest: []const u8) bool {
    const t = std.mem.trim(u8, rest, " \t\r");
    if (t.len == 0) return false;
    var dashes = false;
    var pipes = false;
    for (t) |c| switch (c) {
        '-' => dashes = true,
        '|' => pipes = true,
        ':', ' ', '\t' => {},
        else => return false,
    };
    return dashes and (pipes or t[0] == ':');
}

/// A thematic break: three or more of one of `*-_`, with blanks between.
fn isThematicBreak(rest: []const u8) bool {
    const t = std.mem.trimEnd(u8, rest, " \t\r");
    if (t.len < 3) return false;
    const c = t[0];
    if (c != '*' and c != '-' and c != '_') return false;
    var n: usize = 0;
    for (t) |b| {
        if (b == c) {
            n += 1;
        } else if (b != ' ' and b != '\t') return false;
    }
    return n >= 3;
}

fn isAsciiPunct(b: u8) bool {
    return switch (b) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// The matching `close` for the `open` at `i` (simple nesting).
fn matching(line: []const u8, i: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var k = i;
    while (k < line.len) : (k += 1) {
        const c = line[k];
        if (c == '\\') {
            k += 1;
        } else if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return k;
        }
    }
    return null;
}

const Lexer = struct {
    st: *LexState,
    s: *Scanner,
    out: *TokenSink,
    table: bool = false,

    fn emit(l: *Lexer, start: u32, kind: u16, hl: HighlightId) void {
        l.s.emit(l.out, start, kind, hl);
    }

    fn rest(l: *Lexer, kind: u16, hl: HighlightId) void {
        const start = l.s.pos;
        l.s.skipToEnd();
        if (l.s.pos > start) l.emit(start, kind, hl);
    }

    fn setBlock(l: *Lexer, b: u16) void {
        l.st.mode = (l.st.mode & ~Block.mask) | b;
    }

    fn paragraph(l: *Lexer, on: bool) void {
        if (on) l.st.mode |= Bits.paragraph else l.st.mode &= ~Bits.paragraph;
    }

    fn ws(l: *Lexer) void {
        const start = l.s.pos;
        if (l.s.eatWhile(isSpaceB) > 0) l.emit(start, Kind.ws, .none);
    }

    /// The block structure of a normal line from the cursor.
    fn block(l: *Lexer, first: bool) void {
        const s = l.s;
        const line = s.line;
        const paragraph_before = l.st.mode & Bits.paragraph != 0;
        if (isBlank(line)) {
            l.paragraph(false);
            l.rest(Kind.ws, .none);
            return;
        }
        // Front matter on the first line.
        if (first and std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), "---")) {
            l.rest(Kind.rule, .punctuation_delimiter);
            l.setBlock(Block.front_matter);
            _ = l.st.pushByName("yaml");
            return;
        }
        // Indented code (not a paragraph continuation).
        var indent: usize = 0;
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) indent += if (line[i] == '\t') 4 - indent % 4 else 1;
        if (indent >= 4 and !paragraph_before) {
            l.rest(Kind.raw, .markup_code);
            return;
        }
        // Container prefixes: block quotes and list markers.
        while (true) {
            l.ws();
            const c = s.peek() orelse return;
            const start = s.pos;
            if (c == '>') {
                s.advance();
                l.emit(start, Kind.marker, .punctuation);
                continue;
            }
            if ((c == '-' or c == '*' or c == '+') and (s.peekAt(1) == null or s.peekAt(1) == ' ' or s.peekAt(1) == '\t') and !isThematicBreak(s.rest())) {
                s.advance();
                l.emit(start, Kind.marker, .punctuation);
                l.taskBox();
                l.paragraph(false);
                continue;
            }
            if (std.ascii.isDigit(c)) {
                const n = s.rest();
                var k: usize = 0;
                while (k < n.len and k < 9 and std.ascii.isDigit(n[k])) k += 1;
                if (k < n.len and (n[k] == '.' or n[k] == ')') and (k + 1 == n.len or n[k + 1] == ' ' or n[k + 1] == '\t')) {
                    s.advanceBy(k + 1);
                    l.emit(start, Kind.marker, .punctuation);
                    l.taskBox();
                    l.paragraph(false);
                    continue;
                }
            }
            break;
        }
        const r = s.rest();
        const start = s.pos;
        // Fenced code.
        if (r.len >= 3 and (r[0] == '`' or r[0] == '~')) {
            const fc = r[0];
            const n = runAt(r, 0, fc);
            const info = std.mem.trim(u8, r[n..], " \t\r");
            if (n >= 3 and !(fc == '`' and std.mem.indexOfScalar(u8, info, '`') != null)) {
                s.advanceBy(n);
                l.emit(start, Kind.fence, .punctuation_delimiter);
                l.ws();
                l.rest(Kind.info, .label);
                l.st.mode = (l.st.mode & (Bits.started)) | Block.fence | (if (fc == '~') Bits.tilde else 0) |
                    @as(u16, @intCast(@min(n, Bits.max_len))) << Bits.len_shift;
                const name = infoName(info);
                if (name.len > 0) _ = l.st.pushByName(name);
                return;
            }
        }
        // ATX headings.
        if (r[0] == '#') {
            const n = runAt(r, 0, '#');
            if (n <= 6 and (n == r.len or r[n] == ' ' or r[n] == '\t' or r[n] == '\r')) {
                l.rest(Kind.heading + @as(u16, @intCast(n - 1)), heading_hls[n - 1]);
                l.paragraph(false);
                return;
            }
        }
        // Setext underlines, thematic breaks.
        if (paragraph_before and (r[0] == '=' or r[0] == '-')) {
            const n = runAt(r, 0, r[0]);
            if (isBlank(r[n..])) {
                l.rest(Kind.heading + @as(u16, if (r[0] == '=') 0 else 1), if (r[0] == '=') .markup_heading_1 else .markup_heading_2);
                l.paragraph(false);
                return;
            }
        }
        if (isThematicBreak(r)) {
            l.rest(Kind.rule, .punctuation_delimiter);
            l.paragraph(false);
            return;
        }
        // HTML blocks.
        if (htmlBlockStarts(r, paragraph_before)) {
            l.setBlock(Block.html);
            l.paragraph(false);
            if (l.st.pushByName("html")) return;
            l.rest(Kind.raw, .tag);
            return;
        }
        // Tables.
        if (isDelimiterRow(r) and (paragraph_before or std.mem.indexOfScalar(u8, r, '|') != null)) {
            l.rest(Kind.pipe, .punctuation_delimiter);
            l.paragraph(true);
            return;
        }
        l.table = r[0] == '|';
        l.inline_();
        l.paragraph(true);
    }

    /// A GFM task list box after a list marker.
    fn taskBox(l: *Lexer) void {
        const s = l.s;
        l.ws();
        const r = s.rest();
        if (r.len >= 3 and r[0] == '[' and (r[1] == ' ' or r[1] == 'x' or r[1] == 'X') and r[2] == ']' and (r.len == 3 or r[3] == ' ')) {
            const start = s.pos;
            s.advanceBy(3);
            l.emit(start, Kind.marker, .punctuation);
        }
    }

    /// Inline spans to the line end.
    fn inline_(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        while (s.pos < line.len) {
            const start = s.pos;
            const c = line[start];
            switch (c) {
                '\\' => if (start + 1 < line.len and isAsciiPunct(line[start + 1])) {
                    s.advanceBy(2);
                    l.emit(start, Kind.escape, .string_escape);
                } else l.text(start + 1),
                '`' => {
                    const n = runAt(line, start, '`');
                    var k = start + n;
                    const close: ?usize = while (std.mem.indexOfScalarPos(u8, line, k, '`')) |p| {
                        const m = runAt(line, p, '`');
                        if (m == n) break p;
                        k = p + m;
                    } else null;
                    if (close) |p| {
                        s.pos = @intCast(p + n);
                        l.emit(start, Kind.code_span, .markup_code);
                    } else l.text(start + n);
                },
                '*', '_' => l.emphasis(c),
                '!' => if (start + 1 < line.len and line[start + 1] == '[') {
                    if (!l.link(start, start + 1)) l.text(start + 1);
                } else l.text(start + 1),
                '[' => if (!l.link(start, start)) l.text(start + 1),
                '<' => l.angle(),
                '&' => {
                    var e: usize = start + 1;
                    if (e < line.len and line[e] == '#') e += 1;
                    while (e < line.len and e < start + 32 and std.ascii.isAlphanumeric(line[e])) e += 1;
                    if (e > start + 1 and e < line.len and line[e] == ';') {
                        s.pos = @intCast(e + 1);
                        l.emit(start, Kind.escape, .string_escape);
                    } else l.text(start + 1);
                },
                '|' => if (l.table) {
                    s.advance();
                    l.emit(start, Kind.pipe, .punctuation_delimiter);
                } else l.text(start + 1),
                'h', 'w' => if ((start == 0 or !isWordByte(line[start - 1])) and bareUrlLen(line[start..]) > 0) {
                    s.advanceBy(bareUrlLen(line[start..]));
                    l.emit(start, Kind.autolink, .markup_link);
                } else l.text(start + 1),
                else => l.text(start + 1),
            }
        }
    }

    /// Plain text from the cursor through at least `min_end`, up to the
    /// next byte that may start a span.
    fn text(l: *Lexer, min_end: usize) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        var i = min_end;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (std.mem.indexOfScalar(u8, "\\`*_![<&|", c) != null) break;
            if ((c == 'h' or c == 'w') and !isWordByte(line[i - 1])) break;
        }
        s.pos = @intCast(i);
        l.emit(start, Kind.text, .none);
    }

    /// `*`/`_` emphasis or strong emphasis, matched on this line.
    fn emphasis(l: *Lexer, c: u8) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        const n = runAt(line, start, c);
        const after = start + n;
        const left_ok = after < line.len and !isSpaceB(line[after]) and
            (c == '*' or start == 0 or !isWordByte(line[start - 1]));
        if (!left_ok or n > 3) return l.text(after);
        const want: usize = if (n >= 2) 2 else 1;
        // The closer: a run of at least `want` preceded by a non-blank.
        var k = after;
        while (std.mem.indexOfScalarPos(u8, line, k, c)) |p| {
            const m = runAt(line, p, c);
            const right_ok = !isSpaceB(line[p - 1]) and (c == '*' or p + m >= line.len or !isWordByte(line[p + m]));
            if (m >= want and right_ok and p > after) {
                s.pos = @intCast(p + @min(m, n));
                l.emit(start, if (want == 2) Kind.strong else Kind.emphasis, if (want == 2) .markup_bold else .markup_italic);
                return;
            }
            k = p + m;
        }
        l.text(after);
    }

    /// A link or image whose `[` is at `open` (`start` includes a `!`).
    fn link(l: *Lexer, start: usize, open: usize) bool {
        const s = l.s;
        const line = s.line;
        const close = matching(line, open, '[', ']') orelse return false;
        const after = close + 1;
        if (after < line.len and line[after] == '(') {
            const end = matching(line, after, '(', ')') orelse return false;
            s.pos = @intCast(after);
            l.emit(@intCast(start), Kind.link_text, .markup_link);
            s.pos = @intCast(end + 1);
            l.emit(@intCast(after), Kind.link_dest, .string_special);
            return true;
        }
        if (after < line.len and line[after] == '[') {
            const end = matching(line, after, '[', ']') orelse return false;
            s.pos = @intCast(end + 1);
            l.emit(@intCast(start), Kind.link_text, .markup_link);
            return true;
        }
        if (after < line.len and line[after] == ':' and start == firstNonBlank(line)) {
            // A link reference definition.
            s.pos = @intCast(after);
            l.emit(@intCast(start), Kind.link_text, .markup_link);
            s.advance();
            l.emit(@intCast(after), Kind.text, .none);
            l.ws();
            l.rest(Kind.link_dest, .string_special);
            return true;
        }
        // A shortcut reference: `[text]` alone.
        if (close > open + 1) {
            s.pos = @intCast(after);
            l.emit(@intCast(start), Kind.link_text, .markup_link);
            return true;
        }
        return false;
    }

    /// `<…>`: an autolink, inline HTML or an HTML comment.
    fn angle(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        const r = line[start..];
        if (std.mem.startsWith(u8, r, "<!--")) {
            const e = std.mem.indexOfPos(u8, line, start + 4, "-->");
            s.pos = if (e) |p| @intCast(p + 3) else @intCast(line.len);
            l.emit(start, Kind.comment, .comment);
            return;
        }
        const close = std.mem.indexOfScalarPos(u8, line, start + 1, '>') orelse return l.text(start + 1);
        const inner = line[start + 1 .. close];
        if (inner.len == 0) return l.text(start + 1);
        if (std.mem.indexOf(u8, inner, "://") != null or (std.mem.indexOfScalar(u8, inner, '@') != null and std.mem.indexOfScalar(u8, inner, ' ') == null)) {
            s.pos = @intCast(close + 1);
            l.emit(start, Kind.autolink, .markup_link);
            return;
        }
        if (std.ascii.isAlphabetic(inner[0]) or (inner[0] == '/' and inner.len > 1 and std.ascii.isAlphabetic(inner[1]))) {
            s.pos = @intCast(close + 1);
            l.emit(start, Kind.html, .tag);
            return;
        }
        l.text(start + 1);
    }

    fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
        var sc = s_in.*;
        defer s_in.* = sc;
        var l: Lexer = .{ .st = st, .s = &sc, .out = out };
        const first = st.mode & Bits.started == 0;
        st.mode |= Bits.started;
        const line = sc.line;
        switch (st.mode & Block.mask) {
            Block.fence => {
                const fence = fenceOf(st.mode);
                if (closesFence(trimCr(line[sc.pos..]), fence[0], fence[1])) {
                    l.ws();
                    while (sc.peek() == '>') {
                        l.emit(sc.pos, Kind.marker, .punctuation);
                        sc.advance();
                        l.ws();
                    }
                    const start = sc.pos;
                    _ = sc.eatWhile(struct {
                        fn f(b: u8) bool {
                            return b == '`' or b == '~';
                        }
                    }.f);
                    if (sc.pos > start) l.emit(start, Kind.fence, .punctuation_delimiter);
                    l.rest(Kind.ws, .none);
                    st.mode = Bits.started;
                } else l.rest(Kind.raw, .markup_code);
            },
            Block.front_matter => if (isFrontMatterEnd(line)) {
                l.rest(Kind.rule, .punctuation_delimiter);
                st.mode = Bits.started;
            } else l.rest(Kind.raw, .markup_code),
            Block.html => if (isBlank(line)) {
                l.rest(Kind.ws, .none);
                st.mode = Bits.started;
            } else l.rest(Kind.raw, .tag),
            else => l.block(first),
        }
    }
};

/// The language name in a fence's info string: its first word, without a
/// `{.lang}` wrapper.
pub fn infoName(info: []const u8) []const u8 {
    var t = info;
    if (t.len > 0 and t[0] == '{') t = t[1..];
    if (t.len > 0 and t[0] == '.') t = t[1..];
    var e: usize = 0;
    while (e < t.len and !isSpaceB(t[e]) and t[e] != '}' and t[e] != ',' and t[e] != '{') e += 1;
    return t[0..e];
}

fn firstNonBlank(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (isSpaceB(line[i]) or line[i] == '>')) i += 1;
    return i;
}

/// The length of a bare `http://`, `https://` or `www.` URL at the start
/// of `r` (trailing punctuation excluded), or 0.
fn bareUrlLen(r: []const u8) usize {
    if (!(std.mem.startsWith(u8, r, "https://") or std.mem.startsWith(u8, r, "http://") or std.mem.startsWith(u8, r, "www."))) return 0;
    var e: usize = 0;
    while (e < r.len and !isSpaceB(r[e]) and r[e] != '<') e += 1;
    while (e > 0 and std.mem.indexOfScalar(u8, ".,:;!?*_~'\")", r[e - 1]) != null) e -= 1;
    return if (e > 4) e else 0;
}

fn lexLine(st: *LexState, s: *Scanner, out: *TokenSink) void {
    Lexer.lexLine(st, s, out);
}

/// Where a fenced block's, front matter's or HTML block's guest ends.
fn injectionEnd(host_mode: u16, line: []const u8, from: u32) ?u32 {
    if (from != 0) return null;
    switch (host_mode & Block.mask) {
        Block.fence => {
            const f = fenceOf(host_mode);
            return if (closesFence(trimCr(line), f[0], f[1])) 0 else null;
        },
        Block.front_matter => return if (isFrontMatterEnd(line)) 0 else null,
        Block.html => return if (isBlank(line)) 0 else null,
        else => return null,
    }
}

fn resync(line: []const u8) bool {
    // An ATX heading at column 0.
    return line.len > 1 and line[0] == '#' and (line[1] == ' ' or line[1] == '#');
}

/// Markdown.
pub const markdown_language: language.Language = .{
    .id = .markdown,
    .name = "markdown",
    .aliases = &.{ "md", "mdx", "gfm" },
    .extensions = &.{ ".md", ".markdown", ".mdx", ".mkd" },
    .filenames = &.{ "README", "CHANGELOG" },
    .lexer = .{ .lexLineFn = lexLine },
    .injection_end = injectionEnd,
    .resync = resync,
    .decl_keywords = &.{},
    .edit_rules = .{
        .block_comment = .{ .open = "<!--", .close = "-->" },
        .auto_close = &.{
            .{ .open = "(", .close = ")" },
            .{ .open = "[", .close = "]" },
            .{ .open = "`", .close = "`" },
        },
        .surround = &.{
            .{ .open = "(", .close = ")" },
            .{ .open = "[", .close = "]" },
            .{ .open = "`", .close = "`" },
            .{ .open = "*", .close = "*" },
            .{ .open = "_", .close = "_" },
            .{ .open = "\"", .close = "\"" },
            .{ .open = "'", .close = "'" },
        },
        .insert_spaces = true,
    },
    .brackets = &.{},
};
