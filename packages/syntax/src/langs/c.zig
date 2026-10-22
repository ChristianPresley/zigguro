//! C and C++, one lexer with a dialect switch. Follows the translation
//! phases: a backslash at the end of a line splices it to the next, so the
//! line-end state records a string, char, line comment or preprocessor
//! directive continued that way. Block comments do not nest; C++ raw
//! strings keep their delimiter in `aux` while they span lines.

const std = @import("std");
const language = @import("../language.zig");
const common = @import("common.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Which language the lexer follows.
pub const Dialect = enum { c, cpp };

/// C/C++ token kinds. `str_escape` and `str_cont` continue the string or
/// char before them; `raw_cont` continues a raw string from an earlier line.
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
    /// `#` and the directive name, e.g. `# include`.
    pub const directive_name: u16 = 14 | atomic;
    /// The `<path>` or `"path"` of an include.
    pub const header: u16 = 15 | atomic;
    pub const raw_string: u16 = 16 | atomic;
    pub const raw_cont: u16 = 17;
    /// A backslash that splices the line to the next.
    pub const splice: u16 = 18;
    pub const invalid: u16 = 19;
    /// Tier 2 only: a whole preprocessor line (see `Options`).
    pub const directive: u16 = 20 | atomic;
    /// The name after `[[`.
    pub const attribute: u16 = 21 | atomic;
};

/// Line-end modes. The low byte is the construct; `directive` is or-ed in
/// while a preprocessor directive continues.
pub const Mode = struct {
    pub const code: u16 = 0;
    pub const block_comment: u16 = 1;
    pub const doc_block_comment: u16 = 2;
    pub const string: u16 = 3;
    pub const char: u16 = 4;
    pub const line_comment: u16 = 5;
    pub const doc_line_comment: u16 = 6;
    pub const raw_string: u16 = 7;
    pub const kind_mask: u16 = 0xff;
    pub const directive: u16 = 0x100;
};

/// Lexer options. Highlighting uses the defaults; the tier-2 provider
/// turns on `directive_tokens` to get each preprocessor line (with its
/// continuations) as one `Kind.directive` token.
pub const Options = struct {
    dialect: Dialect,
    directive_tokens: bool = false,
};

/// Raw string delimiters are at most 16 bytes.
pub const max_raw_delimiter = 16;

const c_words = [_]common.Word{
    .{ "if", .keyword_control },            .{ "else", .keyword_control },           .{ "switch", .keyword_control },
    .{ "case", .keyword_control },          .{ "default", .keyword_control },        .{ "while", .keyword_control },
    .{ "do", .keyword_control },            .{ "for", .keyword_control },            .{ "break", .keyword_control },
    .{ "continue", .keyword_control },      .{ "return", .keyword_control },         .{ "goto", .keyword_control },
    .{ "auto", .keyword_storage },          .{ "const", .keyword_storage },          .{ "extern", .keyword_storage },
    .{ "inline", .keyword_storage },        .{ "register", .keyword_storage },       .{ "restrict", .keyword_storage },
    .{ "static", .keyword_storage },        .{ "typedef", .keyword_storage },        .{ "volatile", .keyword_storage },
    .{ "struct", .keyword_storage },        .{ "union", .keyword_storage },          .{ "enum", .keyword_storage },
    .{ "_Thread_local", .keyword_storage }, .{ "thread_local", .keyword_storage },   .{ "_Alignas", .keyword_storage },
    .{ "alignas", .keyword_storage },       .{ "constexpr", .keyword_storage },      .{ "_Noreturn", .keyword_storage },
    .{ "_Atomic", .keyword_storage },       .{ "__restrict", .keyword_storage },     .{ "__inline", .keyword_storage },
    .{ "sizeof", .keyword_operator },       .{ "_Alignof", .keyword_operator },      .{ "alignof", .keyword_operator },
    .{ "typeof", .keyword_operator },       .{ "typeof_unqual", .keyword_operator }, .{ "_Generic", .keyword },
    .{ "_Static_assert", .keyword },        .{ "static_assert", .keyword },          .{ "__attribute__", .keyword },
    .{ "asm", .keyword },                   .{ "__asm__", .keyword },                .{ "void", .type_builtin },
    .{ "char", .type_builtin },             .{ "short", .type_builtin },             .{ "int", .type_builtin },
    .{ "long", .type_builtin },             .{ "float", .type_builtin },             .{ "double", .type_builtin },
    .{ "signed", .type_builtin },           .{ "unsigned", .type_builtin },          .{ "_Bool", .type_builtin },
    .{ "bool", .type_builtin },             .{ "_Complex", .type_builtin },          .{ "_Imaginary", .type_builtin },
    .{ "_BitInt", .type_builtin },          .{ "size_t", .type_builtin },            .{ "ssize_t", .type_builtin },
    .{ "ptrdiff_t", .type_builtin },        .{ "intptr_t", .type_builtin },          .{ "uintptr_t", .type_builtin },
    .{ "int8_t", .type_builtin },           .{ "int16_t", .type_builtin },           .{ "int32_t", .type_builtin },
    .{ "int64_t", .type_builtin },          .{ "uint8_t", .type_builtin },           .{ "uint16_t", .type_builtin },
    .{ "uint32_t", .type_builtin },         .{ "uint64_t", .type_builtin },          .{ "wchar_t", .type_builtin },
    .{ "char8_t", .type_builtin },          .{ "char16_t", .type_builtin },          .{ "char32_t", .type_builtin },
    .{ "true", .constant_builtin },         .{ "false", .constant_builtin },         .{ "NULL", .constant_builtin },
    .{ "nullptr", .constant_builtin },      .{ "__func__", .variable_builtin },      .{ "__FILE__", .constant_builtin },
    .{ "__LINE__", .constant_builtin },
};

const cpp_words = c_words ++ [_]common.Word{
    .{ "try", .keyword_control },      .{ "catch", .keyword_control },     .{ "throw", .keyword_control },
    .{ "co_await", .keyword_control }, .{ "co_return", .keyword_control }, .{ "co_yield", .keyword_control },
    .{ "class", .keyword_storage },    .{ "mutable", .keyword_storage },   .{ "virtual", .keyword_storage },
    .{ "explicit", .keyword_storage }, .{ "friend", .keyword_storage },    .{ "export", .keyword_storage },
    .{ "private", .keyword_storage },  .{ "protected", .keyword_storage }, .{ "public", .keyword_storage },
    .{ "template", .keyword_storage }, .{ "typename", .keyword_storage },  .{ "namespace", .keyword_storage },
    .{ "using", .keyword_storage },    .{ "constinit", .keyword_storage }, .{ "consteval", .keyword_storage },
    .{ "override", .keyword_storage }, .{ "final", .keyword_storage },     .{ "concept", .keyword_storage },
    .{ "requires", .keyword_storage }, .{ "module", .keyword_storage },    .{ "import", .keyword_storage },
    .{ "new", .keyword_operator },     .{ "delete", .keyword_operator },   .{ "and", .keyword_operator },
    .{ "and_eq", .keyword_operator },  .{ "bitand", .keyword_operator },   .{ "bitor", .keyword_operator },
    .{ "compl", .keyword_operator },   .{ "not", .keyword_operator },      .{ "not_eq", .keyword_operator },
    .{ "or", .keyword_operator },      .{ "or_eq", .keyword_operator },    .{ "xor", .keyword_operator },
    .{ "xor_eq", .keyword_operator },  .{ "operator", .keyword },          .{ "decltype", .keyword },
    .{ "noexcept", .keyword },         .{ "typeid", .keyword },            .{ "static_cast", .keyword },
    .{ "dynamic_cast", .keyword },     .{ "reinterpret_cast", .keyword },  .{ "const_cast", .keyword },
    .{ "this", .variable_builtin },
};

const CWords = common.WordTable(&c_words);
const CppWords = common.WordTable(&cpp_words);

const c_ops = [_][]const u8{
    "+",  "-",  "*",  "/",  "%",  "=",  "<",  ">",   "!",   "~",  "&",  "|",  "^",  "?",
    "++", "--", "->", "+=", "-=", "*=", "/=", "%=",  "==",  "!=", "<=", ">=", "&&", "||",
    "&=", "|=", "^=", "<<", ">>", "#",  "##", "<<=", ">>=",
};
const COps = common.OpTable(&c_ops);
const CppOps = common.OpTable(&(c_ops ++ [_][]const u8{ "<=>", "->*" }));

fn isSpaceB(b: u8) bool {
    return common.isSpace(b);
}

/// Whether `line` ends in a backslash splice (a trailing CR is ignored).
fn endsWithSplice(line: []const u8) bool {
    const t = common.trimCr(line);
    return t.len > 0 and t[t.len - 1] == '\\';
}

/// Scans a string or char body after its opening quote (or from the start
/// of a continuation line) up to and including the closing quote. Escapes
/// are separate tokens. Returns true when the line ends in a splice inside
/// the literal, which then continues on the next line.
fn quotedBody(s: *Scanner, out: *TokenSink, quote: u8, hl: HighlightId) bool {
    const line = s.line;
    while (s.pos < line.len) {
        const c = line[s.pos];
        if (c == quote) {
            s.pos += 1;
            return false;
        }
        if (c == '\\') {
            const start = s.pos;
            const rest = line.len - s.pos;
            if (rest == 1 or (rest == 2 and line[s.pos + 1] == '\r')) {
                s.skipToEnd();
                s.emit(out, start, Kind.splice, .string_escape);
                return true;
            }
            s.pos += 1;
            const e = line[s.pos];
            s.pos += 1;
            switch (e) {
                'x' => _ = s.eatWhile(std.ascii.isHex),
                '0'...'7' => {
                    var n: u32 = 1;
                    while (n < 3 and s.peek() != null and s.peek().? >= '0' and s.peek().? <= '7') : (n += 1) s.pos += 1;
                },
                'u', 'U' => {
                    if (s.peek() == '{') {
                        _ = s.eatUntilAny("}'\"");
                        _ = s.eatByte('}');
                    } else {
                        const max: u32 = if (e == 'u') 4 else 8;
                        var n: u32 = 0;
                        while (n < max and s.peek() != null and std.ascii.isHex(s.peek().?)) : (n += 1) s.pos += 1;
                    }
                },
                'N', 'o' => if (s.peek() == '{') {
                    _ = s.eatUntilAny("}'\"");
                    _ = s.eatByte('}');
                },
                else => {},
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

/// Finds the end of a block comment from the cursor; returns false (and
/// moves to the end of the line) when it runs on.
fn blockCommentEnd(s: *Scanner) bool {
    if (std.mem.indexOfPos(u8, s.line, s.pos, "*/")) |i| {
        s.pos = @intCast(i + 2);
        return true;
    }
    s.skipToEnd();
    return false;
}

/// Finds the end of a raw string, `)` + `delim` + `"`, from the cursor.
fn rawEnd(s: *Scanner, delim: []const u8) bool {
    var buf: [max_raw_delimiter + 2]u8 = undefined;
    buf[0] = ')';
    @memcpy(buf[1..][0..delim.len], delim);
    buf[delim.len + 1] = '"';
    if (std.mem.indexOfPos(u8, s.line, s.pos, buf[0 .. delim.len + 2])) |i| {
        s.pos = @intCast(i + delim.len + 2);
        return true;
    }
    s.skipToEnd();
    return false;
}

/// The raw-string delimiter after `R"` at the cursor: up to 16 bytes
/// before `(`, none of them space, parentheses, backslash or control.
fn rawDelimiter(s: *const Scanner) ?[]const u8 {
    const line = s.line;
    var i: usize = s.pos;
    while (i < line.len and i - s.pos <= max_raw_delimiter) : (i += 1) {
        const b = line[i];
        if (b == '(') return line[s.pos..i];
        if (b <= ' ' or b == ')' or b == '\\' or b == 0x7f) return null;
    }
    return null;
}

/// A preprocessing number: digits, letters, `_`, `.`, signed exponents
/// and `'` digit separators.
inline fn number(s: *Scanner) void {
    const line = s.line;
    var i: usize = s.pos + 1;
    while (i < line.len) {
        const c = line[i];
        if (c == 'e' or c == 'E' or c == 'p' or c == 'P') {
            i += 1;
            if (i < line.len and (line[i] == '+' or line[i] == '-')) i += 1;
        } else if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
            i += 1;
        } else if (c == '\'' and i + 1 < line.len and (std.ascii.isAlphanumeric(line[i + 1]) or line[i + 1] == '_')) {
            i += 2;
        } else break;
    }
    s.pos = @intCast(i);
}

/// Whether `w` is a string-literal encoding prefix.
fn isEncodingPrefix(w: []const u8) bool {
    return switch (w.len) {
        1 => w[0] == 'u' or w[0] == 'U' or w[0] == 'L',
        2 => w[0] == 'u' and w[1] == '8',
        else => false,
    };
}

/// Whether `w` is a raw-string prefix (`R`, `u8R`, `uR`, `UR`, `LR`).
fn isRawPrefix(w: []const u8) bool {
    if (w.len == 0 or w[w.len - 1] != 'R') return false;
    return w.len == 1 or isEncodingPrefix(w[0 .. w.len - 1]);
}

/// Directive names whose operand is a header name.
fn takesHeader(name: []const u8) bool {
    return std.mem.eql(u8, name, "include") or std.mem.eql(u8, name, "include_next") or
        std.mem.eql(u8, name, "import") or std.mem.eql(u8, name, "embed");
}

fn lexC(st: *LexState, s: *Scanner, out: *TokenSink) void {
    lexLineWith(.{ .dialect = .c }, st, s, out);
}

fn lexCpp(st: *LexState, s: *Scanner, out: *TokenSink) void {
    lexLineWith(.{ .dialect = .cpp }, st, s, out);
}

/// Lexes one line with explicit options (the tier-2 entry point).
pub fn lexLineWith(comptime o: Options, st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    // A local copy that never escapes, so the cursor stays in registers.
    var sc = s_in.*;
    defer s_in.* = sc;
    const s = &sc;
    const n0 = out.toks.items.len;
    const p0 = s.pos;
    const was_directive = st.mode & Mode.directive != 0;
    const started = lexBody(o, st, s, out);
    const in_directive = was_directive or started;
    const splice = endsWithSplice(s.line);
    const kind = st.mode & Mode.kind_mask;
    // Only code needs the splice to keep a directive going: comments,
    // strings and raw strings carry it until they end.
    const keep = in_directive and (kind != Mode.code or splice);
    st.mode = kind | if (keep) Mode.directive else 0;
    if (o.directive_tokens and in_directive) {
        out.toks.items.len = n0;
        out.push(.{ .start = p0, .kind = Kind.directive, .hl = .keyword });
    }
}

/// The line's tokens; returns whether it starts a preprocessor directive.
fn lexBody(comptime o: Options, st: *LexState, s: *Scanner, out: *TokenSink) bool {
    const cpp = o.dialect == .cpp;
    const Words = if (cpp) CppWords else CWords;
    const Ops = if (cpp) CppOps else COps;

    // Finish a construct carried over from the previous line.
    switch (st.mode & Mode.kind_mask) {
        Mode.code => {},
        Mode.block_comment, Mode.doc_block_comment => |m| {
            const start = s.pos;
            const closed = blockCommentEnd(s);
            s.emit(out, start, if (m == Mode.doc_block_comment) Kind.doc_comment else Kind.comment, if (m == Mode.doc_block_comment) .comment_doc else .comment);
            if (!closed) return false;
            st.mode &= ~Mode.kind_mask;
        },
        Mode.line_comment, Mode.doc_line_comment => |m| {
            s.emit(out, s.pos, if (m == Mode.doc_line_comment) Kind.doc_comment else Kind.comment, if (m == Mode.doc_line_comment) .comment_doc else .comment);
            s.skipToEnd();
            if (!endsWithSplice(s.line)) st.mode &= ~Mode.kind_mask;
            return false;
        },
        Mode.string, Mode.char => |m| {
            const hl: HighlightId = if (m == Mode.string) .string else .character;
            s.emit(out, s.pos, Kind.str_cont, hl);
            if (quotedBody(s, out, if (m == Mode.string) '"' else '\'', hl)) return false;
            st.mode &= ~Mode.kind_mask;
        },
        Mode.raw_string => {
            s.emit(out, s.pos, Kind.raw_cont, .string);
            if (!rawEnd(s, st.auxBytes())) return false;
            st.mode &= ~Mode.kind_mask;
            st.clearAux();
        },
        else => st.mode &= ~Mode.kind_mask,
    }

    var first = st.mode & Mode.directive == 0;
    var started = false;
    while (s.peek()) |c| {
        const start = s.pos;
        switch (c) {
            ' ', '\t', '\r', 0x0b, 0x0c => {
                _ = s.eatWhile(isSpaceB);
                s.emit(out, start, Kind.ws, .none);
                continue;
            },
            '/' => if (s.peekAt(1) == '/') {
                const doc = (s.peekAt(2) == '/' and s.peekAt(3) != '/') or s.peekAt(2) == '!';
                s.skipToEnd();
                s.emit(out, start, if (doc) Kind.doc_comment else Kind.comment, if (doc) .comment_doc else .comment);
                if (endsWithSplice(s.line)) st.mode = (st.mode & ~Mode.kind_mask) | (if (doc) Mode.doc_line_comment else Mode.line_comment);
                return started;
            } else if (s.peekAt(1) == '*') {
                const d = s.peekAt(2);
                const doc = (d == '*' and s.peekAt(3) != '*' and s.peekAt(3) != '/') or d == '!';
                s.advanceBy(2);
                const closed = blockCommentEnd(s);
                s.emit(out, start, if (doc) Kind.doc_comment else Kind.comment, if (doc) .comment_doc else .comment);
                if (!closed) {
                    st.mode = (st.mode & ~Mode.kind_mask) | (if (doc) Mode.doc_block_comment else Mode.block_comment);
                    return started;
                }
                continue;
            } else {
                s.advance();
                _ = s.eatByte('=');
                s.emit(out, start, Kind.operator, .operator);
            },
            '"' => {
                s.advance();
                s.emit(out, start, Kind.string, .string);
                if (quotedBody(s, out, '"', .string)) {
                    st.mode = (st.mode & ~Mode.kind_mask) | Mode.string;
                    return started;
                }
            },
            '\'' => {
                s.advance();
                s.emit(out, start, Kind.char, .character);
                if (quotedBody(s, out, '\'', .character)) {
                    st.mode = (st.mode & ~Mode.kind_mask) | Mode.char;
                    return started;
                }
            },
            '0'...'9' => {
                number(s);
                s.emit(out, start, Kind.number, .number);
            },
            '.' => if (s.peekAt(1) != null and std.ascii.isDigit(s.peekAt(1).?)) {
                number(s);
                s.emit(out, start, Kind.number, .number);
            } else if (s.eat("...")) {
                s.emit(out, start, Kind.operator, .operator);
            } else if (cpp and s.eat(".*")) {
                s.emit(out, start, Kind.operator, .operator);
            } else {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            '[' => if (s.peekAt(1) == '[') {
                attributeList(s, out);
            } else {
                s.advance();
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
            },
            '(', ')', ']', '{', '}' => {
                s.advance();
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
            },
            ';', ',' => {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            ':' => {
                s.advance();
                if (cpp) _ = s.eatByte(':');
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            '\\' => {
                const rest = s.line.len - s.pos;
                s.advance();
                if (rest == 1 or (rest == 2 and s.peek() == '\r')) {
                    s.skipToEnd();
                    s.emit(out, start, Kind.splice, .none);
                } else s.emit(out, start, Kind.invalid, .invalid);
            },
            '#' => if (first) {
                directive(s, out);
                started = true;
            } else {
                s.advance();
                _ = s.eatByte('#');
                s.emit(out, start, Kind.operator, .operator);
            },
            else => if (common.isIdentStart(c)) {
                _ = s.eatIdent();
                const word = s.line[start..s.pos];
                const next = s.peek();
                if (next == '"' or next == '\'') {
                    if (cpp and next == '"' and isRawPrefix(word)) {
                        s.advance();
                        if (rawDelimiter(s)) |d| {
                            s.pos += @intCast(d.len + 1);
                            s.emit(out, start, Kind.raw_string, .string);
                            if (!rawEnd(s, d)) {
                                st.mode = (st.mode & ~Mode.kind_mask) | Mode.raw_string;
                                st.setAux(d);
                                return started;
                            }
                            first = false;
                            continue;
                        }
                        // Not a raw string after all: lex the quote normally.
                        s.pos -= 1;
                    } else if (isEncodingPrefix(word)) {
                        s.advance();
                        const is_str = next == '"';
                        const hl: HighlightId = if (is_str) .string else .character;
                        s.emit(out, start, if (is_str) Kind.string else Kind.char, hl);
                        if (quotedBody(s, out, next.?, hl)) {
                            st.mode = (st.mode & ~Mode.kind_mask) | (if (is_str) Mode.string else Mode.char);
                            return started;
                        }
                        first = false;
                        continue;
                    }
                }
                if (Words.get(word)) |hl| {
                    s.emit(out, start, Kind.keyword, hl);
                } else {
                    s.emit(out, start, Kind.ident, identHl(word, next));
                }
            } else if (Ops.len(s.rest())) |n| {
                s.advanceBy(n);
                s.emit(out, start, Kind.operator, .operator);
            } else {
                s.advance();
                s.emit(out, start, Kind.invalid, .invalid);
            },
        }
        first = false;
    }
    return started;
}

/// The highlight of a C/C++ identifier that is not reserved.
fn identHl(word: []const u8, next: ?u8) HighlightId {
    if (next == '(') return .function;
    if (common.isAllCaps(word)) return .constant;
    if (std.ascii.isUpper(word[0])) return .type;
    if (word.len > 2 and std.mem.endsWith(u8, word, "_t")) return .type;
    return .variable;
}

/// `[[` and the first attribute's name (`nodiscard`, `gnu::cold`); the
/// rest of the list lexes as code.
fn attributeList(s: *Scanner, out: *TokenSink) void {
    for (0..2) |_| {
        s.emit(out, s.pos, Kind.bracket, .punctuation_bracket);
        s.advance();
    }
    const ws = s.pos;
    if (s.eatWhile(isSpaceB) > 0) s.emit(out, ws, Kind.ws, .none);
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

/// `#` and the directive name, then the operand of `include` (a header
/// name) or `define` (the macro name).
fn directive(s: *Scanner, out: *TokenSink) void {
    const start = s.pos;
    s.advance();
    _ = s.eatWhile(isSpaceB);
    const name_start = s.pos;
    _ = s.eatWhile(common.isIdent);
    const name = s.line[name_start..s.pos];
    s.emit(out, start, Kind.directive_name, .keyword);
    if (takesHeader(name)) {
        const ws = s.pos;
        if (s.eatWhile(isSpaceB) > 0) s.emit(out, ws, Kind.ws, .none);
        const h = s.pos;
        const close: u8 = switch (s.peek() orelse return) {
            '<' => '>',
            '"' => '"',
            else => return,
        };
        s.advance();
        if (std.mem.indexOfScalarPos(u8, s.line, s.pos, close)) |e| s.pos = @intCast(e + 1) else s.skipToEnd();
        s.emit(out, h, Kind.header, .string_special);
    } else if (std.mem.eql(u8, name, "define") or std.mem.eql(u8, name, "undef")) {
        const ws = s.pos;
        if (s.eatWhile(isSpaceB) > 0) s.emit(out, ws, Kind.ws, .none);
        const m = s.pos;
        if (s.peek() != null and common.isIdentStart(s.peek().?)) {
            _ = s.eatIdent();
            s.emit(out, m, Kind.ident, .function_macro);
        }
    }
}

fn resync(line: []const u8) bool {
    return common.resyncAtColumn0(line);
}

const brackets = [_]language.BracketPair{
    .{ .open = "(", .close = ")" },
    .{ .open = "[", .close = "]" },
    .{ .open = "{", .close = "}" },
};

const edit_rules: language.EditRules = .{
    .line_comment = "//",
    .block_comment = .{ .open = "/*", .close = "*/" },
    .auto_close = &.{
        .{ .open = "(", .close = ")" },
        .{ .open = "[", .close = "]" },
        .{ .open = "{", .close = "}" },
        .{ .open = "\"", .close = "\"" },
        .{ .open = "'", .close = "'" },
    },
    .indent_after = &.{ "{", "(", "[" },
    .dedent_on = &.{ "}", ")", "]" },
};

/// C (C23 with common extensions).
pub const c_language: language.Language = .{
    .id = .c,
    .name = "c",
    .extensions = &.{ ".c", ".h" },
    .lexer = .{ .lexLineFn = lexC },
    .resync = resync,
    .edit_rules = edit_rules,
    .brackets = &brackets,
    .word_chars = &.{'#'},
};

/// C++ (C++23).
pub const cpp_language: language.Language = .{
    .id = .cpp,
    .name = "cpp",
    .aliases = &.{ "c++", "cxx" },
    .extensions = &.{ ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx", ".c++", ".h++", ".ipp", ".tpp" },
    .lexer = .{ .lexLineFn = lexCpp },
    .resync = resync,
    .edit_rules = edit_rules,
    .brackets = &brackets,
    .word_chars = &.{'#'},
};
