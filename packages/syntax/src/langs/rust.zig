//! Rust, following the Rust Reference's token grammar. Strings span
//! lines, block comments nest (the depth is the state's `depth`) and raw
//! strings keep their `#` count in `aux`. A `'` starts a char literal when
//! a closing `'` follows one char or escape, and a lifetime otherwise.

const std = @import("std");
const language = @import("../language.zig");
const common = @import("common.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Rust token kinds. `str_escape` and `str_cont` continue the literal
/// before them; `str_line` continues a string from an earlier line.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    pub const doc_comment: u16 = 3;
    pub const string: u16 = 4 | atomic;
    pub const str_escape: u16 = 5;
    pub const str_cont: u16 = 6;
    pub const char: u16 = 7 | atomic;
    pub const number: u16 = 8 | atomic;
    pub const ident: u16 = 9 | atomic;
    pub const keyword: u16 = 10 | atomic;
    pub const operator: u16 = 11 | atomic;
    pub const bracket: u16 = 12 | atomic;
    pub const punctuation: u16 = 13 | atomic;
    pub const lifetime: u16 = 14 | atomic;
    pub const attribute: u16 = 15 | atomic;
    pub const macro: u16 = 16 | atomic;
    pub const str_line: u16 = 17;
    pub const invalid: u16 = 18;
};

/// Line-end modes.
pub const Mode = struct {
    pub const code: u16 = 0;
    /// `depth` holds the nesting depth.
    pub const block_comment: u16 = 1;
    pub const doc_block_comment: u16 = 2;
    pub const string: u16 = 3;
    /// `aux[0]` holds the number of `#`.
    pub const raw_string: u16 = 4;
};

const words = [_]common.Word{
    .{ "if", .keyword_control },     .{ "else", .keyword_control },     .{ "match", .keyword_control },
    .{ "loop", .keyword_control },   .{ "while", .keyword_control },    .{ "for", .keyword_control },
    .{ "break", .keyword_control },  .{ "continue", .keyword_control }, .{ "return", .keyword_control },
    .{ "await", .keyword_control },  .{ "yield", .keyword_control },    .{ "in", .keyword_control },
    .{ "fn", .keyword_storage },     .{ "let", .keyword_storage },      .{ "mut", .keyword_storage },
    .{ "const", .keyword_storage },  .{ "static", .keyword_storage },   .{ "pub", .keyword_storage },
    .{ "struct", .keyword_storage }, .{ "enum", .keyword_storage },     .{ "trait", .keyword_storage },
    .{ "impl", .keyword_storage },   .{ "type", .keyword_storage },     .{ "mod", .keyword_storage },
    .{ "use", .keyword_storage },    .{ "extern", .keyword_storage },   .{ "unsafe", .keyword_storage },
    .{ "ref", .keyword_storage },    .{ "move", .keyword_storage },     .{ "dyn", .keyword_storage },
    .{ "async", .keyword_storage },  .{ "where", .keyword },            .{ "crate", .keyword },
    .{ "super", .keyword },          .{ "as", .keyword_operator },      .{ "abstract", .keyword },
    .{ "become", .keyword },         .{ "box", .keyword },              .{ "do", .keyword },
    .{ "final", .keyword },          .{ "macro", .keyword },            .{ "override", .keyword },
    .{ "priv", .keyword },           .{ "typeof", .keyword },           .{ "unsized", .keyword },
    .{ "virtual", .keyword },        .{ "try", .keyword },              .{ "gen", .keyword },
    .{ "self", .variable_builtin },  .{ "Self", .type_builtin },        .{ "true", .constant_builtin },
    .{ "false", .constant_builtin }, .{ "i8", .type_builtin },          .{ "i16", .type_builtin },
    .{ "i32", .type_builtin },       .{ "i64", .type_builtin },         .{ "i128", .type_builtin },
    .{ "isize", .type_builtin },     .{ "u8", .type_builtin },          .{ "u16", .type_builtin },
    .{ "u32", .type_builtin },       .{ "u64", .type_builtin },         .{ "u128", .type_builtin },
    .{ "usize", .type_builtin },     .{ "f16", .type_builtin },         .{ "f32", .type_builtin },
    .{ "f64", .type_builtin },       .{ "f128", .type_builtin },        .{ "bool", .type_builtin },
    .{ "char", .type_builtin },      .{ "str", .type_builtin },
};

const Words = common.WordTable(&words);

const Ops = common.OpTable(&.{
    "+",  "-",  "*",  "/",  "%",  "^",  "!",  "&",   "|",   "&&", "||", "<<", ">>", "+=",
    "-=", "*=", "/=", "%=", "^=", "&=", "|=", "<<=", ">>=", "=",  "==", "!=", ">",  "<",
    ">=", "<=", "@",  "->", "=>", "?",  "~",  "$",   "#",
});

fn isSpaceB(b: u8) bool {
    return common.isSpace(b);
}

/// The body of a string or char after its opening quote (or from the
/// start of a continuation line) up to and including the closing quote,
/// with escapes as separate tokens. Returns whether it closed.
fn quotedBody(s: *Scanner, out: *TokenSink, quote: u8, hl: HighlightId) bool {
    const line = s.line;
    while (s.pos < line.len) {
        const c = line[s.pos];
        if (c == quote) {
            s.pos += 1;
            return true;
        }
        if (c == '\\') {
            const start = s.pos;
            s.pos += 1;
            if (s.pos < line.len) {
                const e = line[s.pos];
                s.pos += 1;
                switch (e) {
                    'x' => {
                        var n: u32 = 0;
                        while (n < 2 and s.peek() != null and std.ascii.isHex(s.peek().?)) : (n += 1) s.pos += 1;
                    },
                    'u' => if (s.peek() == '{') {
                        _ = s.eatUntilAny("}\"'");
                        _ = s.eatByte('}');
                    },
                    else => {},
                }
            }
            s.emit(out, start, Kind.str_escape, .string_escape);
            if (s.pos < line.len and line[s.pos] != '\\') s.emit(out, s.pos, Kind.str_cont, hl);
            continue;
        }
        var i: usize = s.pos + 1;
        while (i < line.len) : (i += 1) {
            const b = line[i];
            if (b == quote or b == '\\') break;
        }
        s.pos = @intCast(i);
    }
    return false;
}

/// Scans a nested block comment from the cursor; returns whether it
/// closed (depth reached zero).
fn nestedComment(s: *Scanner, depth: *u16) bool {
    const line = s.line;
    var i: usize = s.pos;
    while (std.mem.indexOfAnyPos(u8, line, i, "/*")) |j| {
        if (j + 1 >= line.len) break;
        if (line[j] == '/' and line[j + 1] == '*') {
            depth.* +|= 1;
            i = j + 2;
        } else if (line[j] == '*' and line[j + 1] == '/') {
            depth.* -= 1;
            i = j + 2;
            if (depth.* == 0) {
                s.pos = @intCast(i);
                return true;
            }
        } else i = j + 1;
    }
    s.skipToEnd();
    return false;
}

/// Finds the end of a raw string, `"` followed by `hashes` `#`.
fn rawEnd(s: *Scanner, hashes: u8) bool {
    const line = s.line;
    var i: usize = s.pos;
    while (std.mem.indexOfScalarPos(u8, line, i, '"')) |q| {
        var n: usize = 0;
        while (n < hashes and q + 1 + n < line.len and line[q + 1 + n] == '#') n += 1;
        if (n == hashes) {
            s.pos = @intCast(q + 1 + n);
            return true;
        }
        i = q + 1;
    }
    s.skipToEnd();
    return false;
}

/// A number literal: an integer with an optional base prefix, or a float,
/// then an optional suffix (`u8`, `f64`).
inline fn number(s: *Scanner) void {
    const line = s.line;
    var i: usize = s.pos;
    if (line[i] == '0' and i + 1 < line.len and (line[i + 1] == 'x' or line[i + 1] == 'o' or line[i + 1] == 'b')) {
        i += 2;
        while (i < line.len and (std.ascii.isHex(line[i]) or line[i] == '_')) i += 1;
    } else {
        while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) i += 1;
        // `1.` is a float, but not in `1..2` or `1.max(2)`.
        if (i < line.len and line[i] == '.' and !(i + 1 < line.len and (line[i + 1] == '.' or common.isIdentStart(line[i + 1])))) {
            i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) i += 1;
        }
        if (i < line.len and (line[i] == 'e' or line[i] == 'E')) {
            var j = i + 1;
            if (j < line.len and (line[j] == '+' or line[j] == '-')) j += 1;
            while (j < line.len and line[j] == '_') j += 1;
            if (j < line.len and std.ascii.isDigit(line[j])) {
                i = j;
                while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) i += 1;
            }
        }
    }
    while (i < line.len and common.isIdent(line[i])) i += 1;
    s.pos = @intCast(i);
}

/// What a `'` starts.
pub const Quote = enum { char, lifetime, invalid };

/// Classifies the `'` at `line[pos]`: a char literal when a closing `'`
/// follows one char or escape, a lifetime (or label) when an identifier
/// follows, and invalid otherwise. Returns the kind and its end.
pub fn classifyQuote(line: []const u8, pos: usize) struct { Quote, usize } {
    var i = pos + 1;
    if (i >= line.len) return .{ .invalid, i };
    const c = line[i];
    if (c == '\\') return .{ .char, escapedCharEnd(line, i) };
    const n: usize = if (c < 0x80) 1 else std.unicode.utf8ByteSequenceLength(c) catch 1;
    if (i + n < line.len and line[i + n] == '\'') return .{ .char, i + n + 1 };
    if (common.isIdentStart(c)) {
        if (c == 'r' and i + 2 < line.len and line[i + 1] == '#' and common.isIdentStart(line[i + 2])) i += 2;
        while (i < line.len and common.isIdent(line[i])) i += 1;
        return .{ .lifetime, i };
    }
    return .{ .invalid, i };
}

/// The end of a char literal whose escape starts at `line[i]`: through
/// the closing `'`, or the end of the line.
fn escapedCharEnd(line: []const u8, i: usize) usize {
    var j = @min(line.len, i + 2);
    while (j < line.len and line[j] != '\'') j += 1;
    return @min(line.len, j + 1);
}

/// A char literal or lifetime at the `'` under the cursor.
fn quoteToken(s: *Scanner, out: *TokenSink) void {
    const start = s.pos;
    const line = s.line;
    if (start + 1 < line.len and line[start + 1] == '\\') {
        s.pos += 1;
        s.emit(out, start, Kind.char, .character);
        _ = quotedBody(s, out, '\'', .character);
        return;
    }
    const q = classifyQuote(line, start);
    s.pos = @intCast(q[1]);
    switch (q[0]) {
        .char => s.emit(out, start, Kind.char, .character),
        .lifetime => s.emit(out, start, Kind.lifetime, .label),
        .invalid => s.emit(out, start, Kind.invalid, .invalid),
    }
}

/// `#[` or `#![`, then the attribute's path.
fn attribute(s: *Scanner, out: *TokenSink) void {
    const start = s.pos;
    s.advance();
    _ = s.eatByte('!');
    s.emit(out, start, Kind.attribute, .attribute);
    const b = s.pos;
    s.advance();
    s.emit(out, b, Kind.bracket, .punctuation_bracket);
    const p = s.pos;
    while (s.peek()) |c| {
        if (common.isIdent(c)) {
            _ = s.eatIdent();
        } else if (c == ':' and s.peekAt(1) == ':') {
            s.advanceBy(2);
        } else break;
    }
    if (s.pos > p) s.emit(out, p, Kind.attribute, .attribute);
}

fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    var sc = s_in.*;
    defer s_in.* = sc;
    const s = &sc;

    switch (st.mode) {
        Mode.code => {},
        Mode.block_comment, Mode.doc_block_comment => |m| {
            const start = s.pos;
            var depth = st.depth;
            const closed = nestedComment(s, &depth);
            const doc = m == Mode.doc_block_comment;
            s.emit(out, start, if (doc) Kind.doc_comment else Kind.comment, if (doc) .comment_doc else .comment);
            if (!closed) {
                st.depth = depth;
                return;
            }
            st.mode = Mode.code;
            st.depth = 0;
        },
        Mode.string => {
            s.emit(out, s.pos, Kind.str_line, .string);
            if (!quotedBody(s, out, '"', .string)) return;
            st.mode = Mode.code;
        },
        Mode.raw_string => {
            s.emit(out, s.pos, Kind.str_line, .string);
            const hashes = if (st.aux_len > 0) st.aux[0] else 0;
            if (!rawEnd(s, hashes)) return;
            st.mode = Mode.code;
            st.clearAux();
        },
        else => {
            st.mode = Mode.code;
            st.depth = 0;
            st.clearAux();
        },
    }

    // A shebang: `#!` at the start of the file that does not open an
    // inner attribute. Lines are lexed alone, so any line starting in code
    // qualifies.
    if (s.pos == 0 and std.mem.startsWith(u8, s.line, "#!")) {
        const rest = std.mem.trimStart(u8, s.line[2..], " \t");
        if (rest.len == 0 or rest[0] != '[') {
            s.skipToEnd();
            s.emit(out, 0, Kind.comment, .comment);
            return;
        }
    }

    // The previous significant token was `fn`: the next identifier is a
    // function name even before generics.
    var after_fn = false;
    while (s.peek()) |c| {
        const start = s.pos;
        const named = after_fn;
        after_fn = false;
        switch (c) {
            ' ', '\t', '\r', 0x0b, 0x0c => {
                _ = s.eatWhile(isSpaceB);
                s.emit(out, start, Kind.ws, .none);
                after_fn = named;
            },
            '/' => if (s.peekAt(1) == '/') {
                const doc = (s.peekAt(2) == '/' and s.peekAt(3) != '/') or s.peekAt(2) == '!';
                s.skipToEnd();
                s.emit(out, start, if (doc) Kind.doc_comment else Kind.comment, if (doc) .comment_doc else .comment);
            } else if (s.peekAt(1) == '*') {
                const d = s.peekAt(2);
                const doc = (d == '*' and s.peekAt(3) != '*' and s.peekAt(3) != '/') or d == '!';
                s.advanceBy(2);
                var depth: u16 = 1;
                const closed = nestedComment(s, &depth);
                s.emit(out, start, if (doc) Kind.doc_comment else Kind.comment, if (doc) .comment_doc else .comment);
                if (!closed) {
                    st.mode = if (doc) Mode.doc_block_comment else Mode.block_comment;
                    st.depth = depth;
                    return;
                }
            } else {
                s.advance();
                _ = s.eatByte('=');
                s.emit(out, start, Kind.operator, .operator);
            },
            '"' => {
                s.advance();
                s.emit(out, start, Kind.string, .string);
                if (!quotedBody(s, out, '"', .string)) {
                    st.mode = Mode.string;
                    return;
                }
            },
            '\'' => quoteToken(s, out),
            '0'...'9' => {
                number(s);
                s.emit(out, start, Kind.number, .number);
            },
            '(', ')', '[', ']', '{', '}' => {
                s.advance();
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
            },
            ';', ',' => {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            ':' => {
                s.advance();
                _ = s.eatByte(':');
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            '.' => {
                s.advance();
                if (s.eatByte('.')) {
                    if (!s.eatByte('.')) _ = s.eatByte('=');
                    s.emit(out, start, Kind.operator, .operator);
                } else s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            '#' => if (s.peekAt(1) == '[' or (s.peekAt(1) == '!' and s.peekAt(2) == '[')) {
                attribute(s, out);
            } else {
                s.advance();
                s.emit(out, start, Kind.operator, .operator);
            },
            else => if (common.isIdentStart(c)) {
                _ = s.eatIdent();
                if (ident(st, s, out, start, named)) return;
                after_fn = std.mem.eql(u8, s.line[start..s.pos], "fn");
            } else if (Ops.len(s.rest())) |n| {
                s.advanceBy(n);
                s.emit(out, start, Kind.operator, .operator);
            } else {
                s.advance();
                s.emit(out, start, Kind.invalid, .invalid);
            },
        }
    }
}

/// An identifier just scanned from `start`, or the prefix of a string,
/// byte char, raw string or raw identifier. Returns true when the line
/// ends inside a string (the state is set).
fn ident(st: *LexState, s: *Scanner, out: *TokenSink, start: u32, fn_name: bool) bool {
    const line = s.line;
    const word = line[start..s.pos];
    const next = s.peek();
    if (next == '"' and word.len == 1 and (word[0] == 'b' or word[0] == 'c')) {
        s.advance();
        s.emit(out, start, Kind.string, .string);
        if (!quotedBody(s, out, '"', .string)) {
            st.mode = Mode.string;
            return true;
        }
        return false;
    }
    if (next == '\'' and word.len == 1 and word[0] == 'b') {
        s.advance();
        s.emit(out, start, Kind.char, .character);
        _ = quotedBody(s, out, '\'', .character);
        return false;
    }
    const raw_prefix = std.mem.eql(u8, word, "r") or std.mem.eql(u8, word, "br") or std.mem.eql(u8, word, "cr");
    if (raw_prefix and (next == '"' or next == '#')) {
        var i: usize = s.pos;
        while (i < line.len and line[i] == '#' and i - s.pos < 255) i += 1;
        const hashes: u8 = @intCast(i - s.pos);
        if (i < line.len and line[i] == '"') {
            s.pos = @intCast(i + 1);
            s.emit(out, start, Kind.string, .string);
            if (!rawEnd(s, hashes)) {
                st.mode = Mode.raw_string;
                st.setAux(&.{hashes});
                return true;
            }
            return false;
        }
        if (word.len == 1 and hashes == 1 and i < line.len and common.isIdentStart(line[i])) {
            // A raw identifier, `r#match`.
            s.pos = @intCast(i);
            _ = s.eatIdent();
            s.emit(out, start, Kind.ident, if (fn_name) .function else identHl(line[i..s.pos], s.peek()));
            return false;
        }
    }
    if (Words.get(word)) |hl| {
        s.emit(out, start, Kind.keyword, hl);
    } else if (next == '!' and s.peekAt(1) != '=') {
        s.advance();
        s.emit(out, start, Kind.macro, .function_macro);
    } else {
        s.emit(out, start, Kind.ident, if (fn_name) .function else identHl(word, next));
    }
    return false;
}

/// The highlight of a Rust identifier by convention: capitalized names
/// are types and constructors (`Some(x)`), even when called.
fn identHl(word: []const u8, next: ?u8) HighlightId {
    if (common.isAllCaps(word)) return .constant;
    if (std.ascii.isUpper(word[0])) return .type;
    return if (next == '(') .function else .variable;
}

fn resync(line: []const u8) bool {
    return common.resyncAtColumn0(line);
}

/// The Rust language definition.
pub const rust_language: language.Language = .{
    .id = .rust,
    .name = "rust",
    .aliases = &.{"rs"},
    .extensions = &.{".rs"},
    .shebangs = &.{ "rust-script", "run-cargo-script" },
    .lexer = .{ .lexLineFn = lexLine },
    .resync = resync,
    .edit_rules = .{
        .line_comment = "//",
        .block_comment = .{ .open = "/*", .close = "*/" },
        .auto_close = &.{
            .{ .open = "(", .close = ")" },
            .{ .open = "[", .close = "]" },
            .{ .open = "{", .close = "}" },
            .{ .open = "\"", .close = "\"" },
        },
        .insert_spaces = true,
        .indent_after = &.{ "{", "(", "[" },
        .dedent_on = &.{ "}", ")", "]" },
    },
    .brackets = &.{
        .{ .open = "(", .close = ")" },
        .{ .open = "[", .close = "]" },
        .{ .open = "{", .close = "}" },
    },
};
