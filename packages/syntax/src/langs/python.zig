//! Python, following the Language Reference's lexical analysis. Every
//! string is a frame on a small stack kept in the state, so triple-quoted
//! strings span lines and f-strings nest the PEP 701 way: a replacement
//! field is code (it may hold any string, even with the same quote) until
//! its `}`, and the format spec after `:` is string text again.
//!
//! The state: `mode` holds the frame count (low byte) and, for tier 2, the
//! explicit line-join flag; `aux` holds two bytes per frame, then (tier 2)
//! the indentation stack; `depth` is the tier-2 bracket depth.

const std = @import("std");
const language = @import("../language.zig");
const common = @import("common.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Python token kinds. Code tokens are atomic so tier 2 can mark the
/// first one of a line with `indent_flag` / `dedent_shift`.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    /// A string's prefix and opening quote.
    pub const string: u16 = 3 | atomic;
    pub const str_escape: u16 = 4;
    /// String text (also the closing quote and format specs).
    pub const str_cont: u16 = 5;
    pub const number: u16 = 6 | atomic;
    pub const ident: u16 = 7 | atomic;
    pub const keyword: u16 = 8 | atomic;
    pub const operator: u16 = 9 | atomic;
    pub const bracket: u16 = 10 | atomic;
    pub const punctuation: u16 = 11 | atomic;
    pub const decorator: u16 = 12 | atomic;
    /// The `{` and `}` around an f-string replacement field.
    pub const field_brace: u16 = 13 | atomic;
    /// A backslash that joins the line to the next.
    pub const join: u16 = 14;
    pub const invalid: u16 = 15;
    /// Tier 2 only: the logical line ends here (at the line's length).
    pub const newline: u16 = 16 | atomic;
    /// Tier 2 only: or-ed into the first token of a line that indents.
    pub const indent_flag: u16 = 0x2000;
    /// Tier 2 only: the number of DEDENTs before the first token of a
    /// line, shifted into bits 8..12 of its kind.
    pub const dedent_shift: u4 = 8;
    pub const dedent_mask: u16 = 0x1f00;
};

/// Frame flags (`aux[2 * i]`); `aux[2 * i + 1]` is the bracket depth inside
/// the frame's replacement field (0: in the string text).
pub const Frame = struct {
    pub const double: u8 = 1;
    pub const triple: u8 = 2;
    pub const raw: u8 = 4;
    pub const fmt: u8 = 8;
    /// In a format spec (after `:` in a replacement field).
    pub const spec: u8 = 16;
    /// The open replacement field is nested in a format spec.
    pub const nested: u8 = 32;

    flags: u8,
    depth: u8 = 0,

    fn quote(f: Frame) u8 {
        return if (f.flags & double != 0) '"' else '\'';
    }
    fn has(f: Frame, bit: u8) bool {
        return f.flags & bit != 0;
    }
};

/// Most nested strings tracked; deeper ones are lexed as text.
pub const max_frames = 8;
/// Most tier-2 indentation levels kept; deeper ones are dropped (resync).
pub const max_indents = (LexState.max_aux - 2 * max_frames);

/// `mode` bit: the previous line ended in an explicit join (tier 2).
pub const join_bit: u16 = 0x100;

/// Lexer options. Highlighting uses the defaults; the tier-2 parser turns
/// on `virtual_tokens` to get NEWLINE tokens and INDENT/DEDENT marks.
pub const Options = struct {
    virtual_tokens: bool = false,
};

const words = [_]common.Word{
    .{ "if", .keyword_control },              .{ "elif", .keyword_control },         .{ "else", .keyword_control },
    .{ "for", .keyword_control },             .{ "while", .keyword_control },        .{ "break", .keyword_control },
    .{ "continue", .keyword_control },        .{ "return", .keyword_control },       .{ "pass", .keyword_control },
    .{ "raise", .keyword_control },           .{ "try", .keyword_control },          .{ "except", .keyword_control },
    .{ "finally", .keyword_control },         .{ "with", .keyword_control },         .{ "yield", .keyword_control },
    .{ "await", .keyword_control },           .{ "assert", .keyword },               .{ "del", .keyword },
    .{ "import", .keyword },                  .{ "from", .keyword },                 .{ "as", .keyword },
    .{ "def", .keyword_storage },             .{ "class", .keyword_storage },        .{ "lambda", .keyword_storage },
    .{ "global", .keyword_storage },          .{ "nonlocal", .keyword_storage },     .{ "async", .keyword_storage },
    .{ "and", .keyword_operator },            .{ "or", .keyword_operator },          .{ "not", .keyword_operator },
    .{ "in", .keyword_operator },             .{ "is", .keyword_operator },          .{ "True", .constant_builtin },
    .{ "False", .constant_builtin },          .{ "None", .constant_builtin },        .{ "self", .variable_builtin },
    .{ "cls", .variable_builtin },            .{ "__name__", .variable_builtin },    .{ "__file__", .variable_builtin },
    .{ "NotImplemented", .constant_builtin }, .{ "Ellipsis", .constant_builtin },
    // Builtin types and functions; called names highlight as functions.
       .{ "int", .type_builtin },
    .{ "float", .type_builtin },              .{ "complex", .type_builtin },         .{ "str", .type_builtin },
    .{ "bytes", .type_builtin },              .{ "bytearray", .type_builtin },       .{ "bool", .type_builtin },
    .{ "list", .type_builtin },               .{ "dict", .type_builtin },            .{ "set", .type_builtin },
    .{ "frozenset", .type_builtin },          .{ "tuple", .type_builtin },           .{ "object", .type_builtin },
    .{ "memoryview", .type_builtin },         .{ "range", .type_builtin },           .{ "abs", .function_builtin },
    .{ "all", .function_builtin },            .{ "any", .function_builtin },         .{ "bin", .function_builtin },
    .{ "callable", .function_builtin },       .{ "chr", .function_builtin },         .{ "dir", .function_builtin },
    .{ "divmod", .function_builtin },         .{ "enumerate", .function_builtin },   .{ "eval", .function_builtin },
    .{ "exec", .function_builtin },           .{ "filter", .function_builtin },      .{ "format", .function_builtin },
    .{ "getattr", .function_builtin },        .{ "globals", .function_builtin },     .{ "hasattr", .function_builtin },
    .{ "hash", .function_builtin },           .{ "hex", .function_builtin },         .{ "id", .function_builtin },
    .{ "input", .function_builtin },          .{ "isinstance", .function_builtin },  .{ "issubclass", .function_builtin },
    .{ "iter", .function_builtin },           .{ "len", .function_builtin },         .{ "locals", .function_builtin },
    .{ "map", .function_builtin },            .{ "max", .function_builtin },         .{ "min", .function_builtin },
    .{ "next", .function_builtin },           .{ "oct", .function_builtin },         .{ "open", .function_builtin },
    .{ "ord", .function_builtin },            .{ "pow", .function_builtin },         .{ "print", .function_builtin },
    .{ "property", .function_builtin },       .{ "repr", .function_builtin },        .{ "reversed", .function_builtin },
    .{ "round", .function_builtin },          .{ "setattr", .function_builtin },     .{ "sorted", .function_builtin },
    .{ "staticmethod", .function_builtin },   .{ "classmethod", .function_builtin }, .{ "sum", .function_builtin },
    .{ "super", .function_builtin },          .{ "vars", .function_builtin },        .{ "zip", .function_builtin },
    .{ "breakpoint", .function_builtin },     .{ "aiter", .function_builtin },       .{ "anext", .function_builtin },
    .{ "ascii", .function_builtin },          .{ "compile", .function_builtin },     .{ "delattr", .function_builtin },
    .{ "help", .function_builtin },           .{ "slice", .function_builtin },
};

const Words = common.WordTable(&words);

const Ops = common.OpTable(&.{
    "+",  "-",  "*",  "/",  "//",  "%",   "**",  "@",  "<<", ">>", "&",  "|",  "^",   "~",
    ":=", "<",  ">",  "<=", ">=",  "==",  "!=",  "->", "+=", "-=", "*=", "/=", "//=", "%=",
    "@=", "&=", "|=", "^=", ">>=", "<<=", "**=", "=",  "!",
});

fn isSpaceB(b: u8) bool {
    return common.isSpace(b);
}

/// The working state of one line: the frames and (tier 2) indent stack
/// decoded from `LexState`, re-encoded at the line end.
const Line = struct {
    frames: [max_frames]Frame = undefined,
    n: usize = 0,
    indents: [max_indents]u8 = undefined,
    m: usize = 0,

    fn load(st: *const LexState) Line {
        var l: Line = .{};
        const aux = st.auxBytes();
        l.n = @min(st.mode & 0xff, max_frames, aux.len / 2);
        for (0..l.n) |i| l.frames[i] = .{ .flags = aux[2 * i], .depth = aux[2 * i + 1] };
        const rest = aux[2 * l.n ..];
        l.m = @min(rest.len, max_indents);
        @memcpy(l.indents[0..l.m], rest[0..l.m]);
        return l;
    }

    fn store(l: *const Line, st: *LexState, join: bool) void {
        var buf: [LexState.max_aux]u8 = undefined;
        for (l.frames[0..l.n], 0..) |f, i| {
            buf[2 * i] = f.flags;
            buf[2 * i + 1] = f.depth;
        }
        @memcpy(buf[2 * l.n ..][0..l.m], l.indents[0..l.m]);
        st.setAux(buf[0 .. 2 * l.n + l.m]);
        st.mode = @as(u16, @intCast(l.n)) | if (join) join_bit else 0;
    }

    fn top(l: *Line) ?*Frame {
        return if (l.n == 0) null else &l.frames[l.n - 1];
    }
};

/// The string prefix in `w` (letters from `rbfutRBFUT`, at most two, in a
/// valid combination) as frame flags, or null.
fn prefixFlags(w: []const u8) ?u8 {
    if (w.len > 2) return null;
    var flags: u8 = 0;
    var seen: u8 = 0;
    for (w) |c| {
        const bit: u8 = switch (c | 0x20) {
            'r' => 1,
            'b' => 2,
            'f' => 4,
            't' => 8,
            'u' => 16,
            else => return null,
        };
        if (seen & bit != 0) return null;
        seen |= bit;
    }
    if (seen & 16 != 0 and w.len > 1) return null; // `u` stands alone
    if (seen & 2 != 0 and seen & 12 != 0) return null; // no bf / bt
    if (seen & 4 != 0 and seen & 8 != 0) return null;
    if (seen & 1 != 0) flags |= Frame.raw;
    if (seen & 12 != 0) flags |= Frame.fmt;
    return flags;
}

/// Opens a string at the quote under the cursor (the prefix, if any,
/// starts at `start`).
fn openString(s: *Scanner, out: *TokenSink, l: *Line, start: u32, prefix: u8) void {
    const q = s.peek().?;
    var flags = prefix | if (q == '"') Frame.double else 0;
    if (s.peekAt(1) == q and s.peekAt(2) == q) {
        flags |= Frame.triple;
        s.advanceBy(3);
    } else s.advance();
    s.emit(out, start, Kind.string, .string);
    if (l.n < max_frames) {
        l.frames[l.n] = .{ .flags = flags };
        l.n += 1;
    } else {
        // Too deep to track: the body is plain text to its quote.
        stringTextUntracked(s, out, .{ .flags = flags });
    }
}

/// The body of an untracked string up to its closing quote on this line.
fn stringTextUntracked(s: *Scanner, out: *TokenSink, f: Frame) void {
    s.emit(out, s.pos, Kind.str_cont, .string);
    const q = f.quote();
    while (s.peek()) |c| {
        if (c == '\\' and !f.has(Frame.raw)) {
            s.advanceBy(2);
            continue;
        }
        s.advance();
        if (c == q and (!f.has(Frame.triple) or (s.peek() == q and s.peekAt(1) == q))) {
            if (f.has(Frame.triple)) s.advanceBy(2);
            return;
        }
    }
}

/// Whether the closing quote of `f` is at the cursor.
fn atClose(s: *const Scanner, f: Frame) bool {
    const q = f.quote();
    if (s.peek() != q) return false;
    return !f.has(Frame.triple) or (s.peekAt(1) == q and s.peekAt(2) == q);
}

/// String text of the top frame (its body, or its format spec) up to the
/// end of the line, the closing quote, or a replacement field.
fn stringText(s: *Scanner, out: *TokenSink, l: *Line) void {
    const f = l.top().?;
    const fmt = f.has(Frame.fmt);
    const raw = f.has(Frame.raw);
    const q = f.quote();
    const line = s.line;
    var text_start: ?u32 = null;
    while (s.pos < line.len) {
        const c = line[s.pos];
        if (c == q and atClose(s, f.*)) {
            if (text_start == null) s.emit(out, s.pos, Kind.str_cont, .string);
            s.advanceBy(if (f.has(Frame.triple)) 3 else 1);
            l.n -= 1;
            return;
        }
        if (fmt and (c == '{' or c == '}')) {
            if (!f.has(Frame.spec) and s.peekAt(1) == c) {
                // `{{` / `}}`: a literal brace.
                s.emit(out, s.pos, Kind.str_escape, .string_escape);
                s.advanceBy(2);
                text_start = null;
                continue;
            }
            s.emit(out, s.pos, Kind.field_brace, .punctuation_bracket);
            s.advance();
            if (c == '{') {
                f.depth = 1;
                if (f.has(Frame.spec)) f.flags |= Frame.nested;
            } else {
                // `}` ends a format spec's field, or is a stray brace.
                f.flags &= ~Frame.spec;
            }
            return;
        }
        if (c == '\\' and !raw) {
            const start = s.pos;
            s.advance();
            if (s.peek()) |e| {
                s.advance();
                switch (e) {
                    'x' => {
                        var k: u32 = 0;
                        while (k < 2 and s.peek() != null and std.ascii.isHex(s.peek().?)) : (k += 1) s.advance();
                    },
                    'u', 'U' => {
                        const max: u32 = if (e == 'u') 4 else 8;
                        var k: u32 = 0;
                        while (k < max and s.peek() != null and std.ascii.isHex(s.peek().?)) : (k += 1) s.advance();
                    },
                    'N' => if (s.peek() == '{') {
                        if (std.mem.indexOfScalarPos(u8, line, s.pos, '}')) |e2| s.pos = @intCast(e2 + 1);
                    },
                    '0'...'7' => {
                        var k: u32 = 1;
                        while (k < 3 and s.peek() != null and s.peek().? >= '0' and s.peek().? <= '7') : (k += 1) s.advance();
                    },
                    else => {},
                }
            }
            s.emit(out, start, Kind.str_escape, .string_escape);
            text_start = null;
            continue;
        }
        if (text_start == null) {
            text_start = s.pos;
            s.emit(out, s.pos, Kind.str_cont, .string);
        }
        s.advance();
    }
}

fn isDigitU(b: u8) bool {
    return std.ascii.isDigit(b) or b == '_';
}

/// A number: integers in any base, floats with exponents, and imaginary
/// `j` suffixes.
inline fn number(s: *Scanner) void {
    const line = s.line;
    var i: usize = s.pos;
    if (line[i] == '0' and i + 1 < line.len and std.mem.indexOfScalar(u8, "xXoObB", line[i + 1]) != null) {
        i += 2;
        while (i < line.len and (std.ascii.isHex(line[i]) or line[i] == '_')) i += 1;
    } else {
        while (i < line.len and isDigitU(line[i])) i += 1;
        if (i < line.len and line[i] == '.') {
            i += 1;
            while (i < line.len and isDigitU(line[i])) i += 1;
        }
        if (i < line.len and (line[i] == 'e' or line[i] == 'E')) {
            var j = i + 1;
            if (j < line.len and (line[j] == '+' or line[j] == '-')) j += 1;
            if (j < line.len and std.ascii.isDigit(line[j])) {
                i = j;
                while (i < line.len and isDigitU(line[i])) i += 1;
            }
        }
        if (i < line.len and (line[i] == 'j' or line[i] == 'J')) i += 1;
    }
    s.pos = @intCast(i);
}

/// Whether the line, without a trailing comment, ends with `:` (a block
/// header): the test for the soft keywords `match` and `case`.
fn endsWithColon(line: []const u8) bool {
    var end = line.len;
    if (std.mem.indexOfScalar(u8, line, '#')) |h| end = h;
    const t = std.mem.trimEnd(u8, line[0..end], " \t\r");
    return t.len > 0 and t[t.len - 1] == ':';
}

fn lexLine(st: *LexState, s: *Scanner, out: *TokenSink) void {
    lexLineWith(.{}, st, s, out);
}

/// Indentation width of `line` (tabs to the next multiple of 8) and
/// whether it holds anything but blanks and a comment.
fn indentOf(line: []const u8) struct { u32, bool } {
    var w: u32 = 0;
    for (line) |c| switch (c) {
        ' ' => w += 1,
        '\t' => w = (w / 8 + 1) * 8,
        0x0c => w = 0,
        '\r' => {},
        '#' => return .{ w, false },
        else => return .{ w, true },
    };
    return .{ w, false };
}

/// Lexes one line with explicit options (the tier-2 entry point).
pub fn lexLineWith(comptime o: Options, st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    var sc = s_in.*;
    defer s_in.* = sc;
    const s = &sc;
    var l = Line.load(st);
    const joined = st.mode & join_bit != 0;

    // Tier 2: INDENT/DEDENT at the start of a logical line.
    var mark: u16 = 0;
    var mark_pending = false;
    if (o.virtual_tokens and l.n == 0 and st.depth == 0 and !joined) {
        const ind = indentOf(s.line);
        if (ind[1]) {
            const w: u8 = @intCast(@min(ind[0], 255));
            const cur: u8 = if (l.m > 0) l.indents[l.m - 1] else 0;
            if (w > cur) {
                if (l.m < max_indents) {
                    l.indents[l.m] = w;
                    l.m += 1;
                }
                mark = Kind.indent_flag;
            } else {
                var d: u16 = 0;
                while (l.m > 0 and l.indents[l.m - 1] > w) : (l.m -= 1) d += 1;
                mark = @as(u16, @min(d, 31)) << Kind.dedent_shift;
            }
            mark_pending = mark != 0;
        }
    }
    const tok0 = out.toks.items.len;
    var significant = false;
    var join = false;
    var first_code = true;
    // The previous significant token was `def` or `class`.
    var after: enum { none, def, class } = .none;

    while (s.pos < s.line.len) {
        if (l.top()) |f| {
            if (f.depth == 0) {
                stringText(s, out, &l);
                significant = true;
                continue;
            }
        }
        const start = s.pos;
        const c = s.line[start];
        const named = after;
        after = .none;
        switch (c) {
            ' ', '\t', '\r', 0x0b, 0x0c => {
                _ = s.eatWhile(isSpaceB);
                s.emit(out, start, Kind.ws, .none);
                after = named;
                continue;
            },
            '#' => {
                s.skipToEnd();
                s.emit(out, start, Kind.comment, .comment);
                continue;
            },
            '\\' => {
                s.advance();
                const rest = common.trimCr(s.line[s.pos..]);
                if (rest.len == 0) {
                    s.skipToEnd();
                    s.emit(out, start, Kind.join, .none);
                    join = true;
                } else s.emit(out, start, Kind.invalid, .invalid);
                continue;
            },
            '"', '\'' => openString(s, out, &l, start, 0),
            '0'...'9' => {
                number(s);
                s.emit(out, start, Kind.number, .number);
            },
            '.' => if (s.peekAt(1) != null and std.ascii.isDigit(s.peekAt(1).?)) {
                number(s);
                s.emit(out, start, Kind.number, .number);
            } else if (s.eat("...")) {
                s.emit(out, start, Kind.ident, .constant_builtin);
            } else {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            '(', '[', '{' => {
                s.advance();
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
                if (l.top()) |f| {
                    f.depth +|= 1;
                } else if (o.virtual_tokens) st.depth +|= 1;
            },
            ')', ']', '}' => {
                s.advance();
                if (l.top()) |f| {
                    if (c == '}' and f.depth == 1) {
                        // The end of a replacement field.
                        s.emit(out, start, Kind.field_brace, .punctuation_bracket);
                        f.depth = 0;
                        // Back to the format spec it was nested in, or the body.
                        if (f.has(Frame.nested)) f.flags &= ~Frame.nested else f.flags &= ~Frame.spec;
                    } else {
                        s.emit(out, start, Kind.bracket, .punctuation_bracket);
                        if (f.depth > 1) f.depth -= 1;
                    }
                } else {
                    s.emit(out, start, Kind.bracket, .punctuation_bracket);
                    if (o.virtual_tokens and st.depth > 0) st.depth -= 1;
                }
            },
            ',', ';' => {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            ':' => if (s.peekAt(1) == '=') {
                s.advanceBy(2);
                s.emit(out, start, Kind.operator, .operator);
            } else {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
                if (l.top()) |f| {
                    if (f.depth == 1 and f.has(Frame.fmt)) {
                        // The format spec of a replacement field.
                        f.depth = 0;
                        f.flags |= Frame.spec;
                    }
                }
            },
            '@' => if (first_code and l.n == 0 and s.peekAt(1) != null and common.isIdentStart(s.peekAt(1).?)) {
                s.advance();
                while (s.peek()) |d| {
                    if (common.isIdent(d) or (d == '.' and s.peekAt(1) != null and common.isIdentStart(s.peekAt(1).?))) s.advance() else break;
                }
                s.emit(out, start, Kind.decorator, .attribute);
            } else {
                s.advance();
                _ = s.eatByte('=');
                s.emit(out, start, Kind.operator, .operator);
            },
            else => if (common.isIdentStart(c)) {
                _ = s.eatIdent();
                const word = s.line[start..s.pos];
                const next = s.peek();
                if ((next == '"' or next == '\'') and prefixFlags(word) != null) {
                    openString(s, out, &l, start, prefixFlags(word).?);
                } else {
                    identToken(s, out, start, word, next, named, first_code and l.n == 0);
                    if (std.mem.eql(u8, word, "def")) after = .def else if (std.mem.eql(u8, word, "class")) after = .class;
                }
            } else if (Ops.len(s.rest())) |n| {
                s.advanceBy(n);
                s.emit(out, start, Kind.operator, .operator);
            } else {
                s.advance();
                s.emit(out, start, Kind.invalid, .invalid);
            },
        }
        first_code = false;
        significant = true;
    }

    // An unterminated single-quoted string ends at the line end unless a
    // backslash continues it; so does any such string around it.
    while (l.top()) |f| {
        if (f.depth != 0 or f.has(Frame.triple)) break;
        const t = common.trimCr(s.line);
        if (t.len > 0 and t[t.len - 1] == '\\' and !f.has(Frame.raw)) break;
        l.n -= 1;
    }

    if (o.virtual_tokens) {
        if (mark_pending and out.toks.items.len > tok0) {
            for (out.toks.items[tok0..]) |*t| {
                if (t.kind == Kind.ws) continue;
                t.kind |= mark;
                break;
            }
        }
        if (significant and l.n == 0 and st.depth == 0 and !join) {
            out.push(.{ .start = @intCast(s.line.len), .kind = Kind.newline, .hl = .none });
        }
    }
    l.store(st, o.virtual_tokens and join);
    if (!o.virtual_tokens) st.depth = 0;
}

/// An identifier or keyword, with soft keywords at statement start and
/// names after `def`/`class`.
fn identToken(s: *Scanner, out: *TokenSink, start: u32, word: []const u8, next: ?u8, named: anytype, stmt_start: bool) void {
    if (stmt_start and (std.mem.eql(u8, word, "match") or std.mem.eql(u8, word, "case")) and
        next != null and common.isSpace(next.?) and endsWithColon(s.line))
    {
        s.emit(out, start, Kind.keyword, .keyword_control);
        return;
    }
    if (stmt_start and std.mem.eql(u8, word, "type") and next != null and common.isSpace(next.?)) {
        const rest = std.mem.trimStart(u8, s.line[s.pos..], " \t");
        if (rest.len > 0 and common.isIdentStart(rest[0])) {
            s.emit(out, start, Kind.keyword, .keyword_storage);
            return;
        }
    }
    switch (named) {
        .def => return s.emit(out, start, Kind.ident, .function),
        .class => return s.emit(out, start, Kind.ident, .type),
        .none => {},
    }
    if (Words.get(word)) |hl| {
        const h: HighlightId = switch (hl) {
            .function_builtin, .type_builtin => if (next == '(') .function_builtin else if (hl == .type_builtin) .type_builtin else .variable,
            else => hl,
        };
        const kind = switch (hl) {
            .keyword, .keyword_control, .keyword_storage, .keyword_operator => Kind.keyword,
            else => Kind.ident,
        };
        s.emit(out, start, kind, h);
        return;
    }
    s.emit(out, start, Kind.ident, common.identHl(word, next));
}

fn resync(line: []const u8) bool {
    // A top-level statement that is not inside a string: a keyword or
    // name at column 0 (a heuristic).
    return line.len > 0 and (common.isIdentStart(line[0]) or line[0] == '@');
}

/// The Python language definition.
pub const python_language: language.Language = .{
    .id = .python,
    .name = "python",
    .aliases = &.{ "py", "python3" },
    .extensions = &.{ ".py", ".pyi", ".pyw" },
    .shebangs = &.{ "python", "python3", "python2", "pypy", "pypy3" },
    .lexer = .{ .lexLineFn = lexLine },
    .resync = resync,
    .fold_by_indent = true,
    .edit_rules = .{
        .line_comment = "#",
        .auto_close = &.{
            .{ .open = "(", .close = ")" },
            .{ .open = "[", .close = "]" },
            .{ .open = "{", .close = "}" },
            .{ .open = "\"", .close = "\"" },
            .{ .open = "'", .close = "'" },
        },
        .insert_spaces = true,
        .indent_after = &.{":"},
        .dedent_on = &.{ "else", "elif", "except", "finally" },
        .dedent_after = &.{ "return", "pass", "break", "continue", "raise" },
    },
    .brackets = &.{
        .{ .open = "(", .close = ")" },
        .{ .open = "[", .close = "]" },
        .{ .open = "{", .close = "}" },
    },
};
