//! JavaScript, TypeScript, JSX and TSX (ECMAScript §12), one lexer with
//! dialect flags.
//!
//! Regex versus division uses the standard editor heuristic: `/` starts a
//! regex when the previous significant token is an operator, an opening
//! bracket, `,`, `;`, `{`, `}`, a keyword such as `return` or `typeof`, or
//! nothing; after an identifier, a literal, `)` or `]` it divides. The
//! answer is kept in `mode` (`Bits.div_ok`) across lines.
//!
//! Template literals, `${ }` expressions and JSX elements nest on a frame
//! stack in `aux`, one byte per frame (at most 16): template text, a
//! template expression or JSX expression with its open-brace count, and
//! the JSX opening tag, closing tag and children. When the stack is full a
//! new frame is not pushed, so the lexer degrades to plain code instead of
//! failing; resync recovers far viewports.

const std = @import("std");
const language = @import("../language.zig");
const common = @import("common.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Which language the lexer accepts.
pub const Dialect = packed struct { typescript: bool = false, jsx: bool = false };

/// Token kinds.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    pub const keyword: u16 = 3 | atomic;
    pub const ident: u16 = 4 | atomic;
    pub const number: u16 = 5 | atomic;
    pub const string: u16 = 6;
    pub const str_escape: u16 = 7;
    pub const regex: u16 = 8 | atomic;
    pub const operator: u16 = 9 | atomic;
    pub const punctuation: u16 = 10 | atomic;
    pub const bracket: u16 = 11 | atomic;
    /// `$` of `${` in a template.
    pub const interp: u16 = 12 | atomic;
    pub const decorator: u16 = 13 | atomic;
    pub const jsx_punct: u16 = 14 | atomic;
    pub const jsx_tag: u16 = 15 | atomic;
    pub const jsx_attr: u16 = 16 | atomic;
    pub const jsx_text: u16 = 17;
    pub const invalid: u16 = 18;
};

/// `mode` bits.
pub const Bits = struct {
    /// A `/` here divides (the previous token ends an operand).
    pub const div_ok: u16 = 1;
    pub const block_comment: u16 = 2;
    /// A `"` string continued with a trailing backslash.
    pub const dq_cont: u16 = 4;
    /// A `'` string continued with a trailing backslash.
    pub const sq_cont: u16 = 8;
};

/// Frames on the `aux` stack.
pub const Frame = struct {
    pub const template: u8 = 0x01;
    pub const jsx_tag: u8 = 0x02;
    pub const jsx_close: u8 = 0x03;
    pub const jsx_children: u8 = 0x04;
    /// A `${ }` expression; the low six bits count open braces.
    pub const template_expr: u8 = 0x40;
    /// A JSX `{ }` expression; the low six bits count open braces.
    pub const jsx_expr: u8 = 0x80;
    pub const depth_mask: u8 = 0x3f;
};

pub const max_frames = 16;

const js_words = [_]common.Word{
    .{ "if", .keyword_control },         .{ "else", .keyword_control },        .{ "for", .keyword_control },
    .{ "while", .keyword_control },      .{ "do", .keyword_control },          .{ "switch", .keyword_control },
    .{ "case", .keyword_control },       .{ "default", .keyword_control },     .{ "break", .keyword_control },
    .{ "continue", .keyword_control },   .{ "return", .keyword_control },      .{ "throw", .keyword_control },
    .{ "try", .keyword_control },        .{ "catch", .keyword_control },       .{ "finally", .keyword_control },
    .{ "yield", .keyword_control },      .{ "await", .keyword_control },       .{ "with", .keyword_control },
    .{ "debugger", .keyword },           .{ "var", .keyword_storage },         .{ "let", .keyword_storage },
    .{ "const", .keyword_storage },      .{ "function", .keyword_storage },    .{ "class", .keyword_storage },
    .{ "typeof", .keyword_operator },    .{ "instanceof", .keyword_operator }, .{ "in", .keyword_operator },
    .{ "of", .keyword_operator },        .{ "new", .keyword_operator },        .{ "delete", .keyword_operator },
    .{ "void", .keyword_operator },      .{ "import", .keyword },              .{ "export", .keyword },
    .{ "from", .keyword },               .{ "extends", .keyword },             .{ "static", .keyword_storage },
    .{ "get", .keyword },                .{ "set", .keyword },                 .{ "async", .keyword_storage },
    .{ "as", .keyword },                 .{ "this", .variable_builtin },       .{ "super", .variable_builtin },
    .{ "null", .constant_builtin },      .{ "true", .constant_builtin },       .{ "false", .constant_builtin },
    .{ "undefined", .constant_builtin }, .{ "NaN", .constant_builtin },        .{ "Infinity", .constant_builtin },
};

const ts_words = js_words ++ [_]common.Word{
    .{ "type", .keyword_storage },      .{ "interface", .keyword_storage }, .{ "enum", .keyword_storage },
    .{ "namespace", .keyword_storage }, .{ "module", .keyword_storage },    .{ "declare", .keyword_storage },
    .{ "abstract", .keyword_storage },  .{ "implements", .keyword },        .{ "readonly", .keyword_storage },
    .{ "keyof", .keyword_operator },    .{ "infer", .keyword_operator },    .{ "satisfies", .keyword_operator },
    .{ "is", .keyword_operator },       .{ "private", .keyword_storage },   .{ "public", .keyword_storage },
    .{ "protected", .keyword_storage }, .{ "override", .keyword_storage },  .{ "asserts", .keyword_operator },
    .{ "unique", .keyword_operator },   .{ "string", .type_builtin },       .{ "number", .type_builtin },
    .{ "boolean", .type_builtin },      .{ "any", .type_builtin },          .{ "unknown", .type_builtin },
    .{ "never", .type_builtin },        .{ "object", .type_builtin },       .{ "symbol", .type_builtin },
    .{ "bigint", .type_builtin },
};

const JsWords = common.WordTable(&js_words);
const TsWords = common.WordTable(&ts_words);

/// Words that are keywords only when another word (or a bracket, a string
/// or `*`) follows: `const type = 1` is a variable, `type T = U` is not.
const Contextual = common.WordTable(&.{
    .{ "of", .none },        .{ "as", .none },      .{ "from", .none },    .{ "get", .none },
    .{ "set", .none },       .{ "async", .none },   .{ "static", .none },  .{ "type", .none },
    .{ "namespace", .none }, .{ "module", .none },  .{ "declare", .none }, .{ "abstract", .none },
    .{ "readonly", .none },  .{ "keyof", .none },   .{ "infer", .none },   .{ "satisfies", .none },
    .{ "is", .none },        .{ "private", .none }, .{ "public", .none },  .{ "protected", .none },
    .{ "override", .none },  .{ "asserts", .none }, .{ "unique", .none },  .{ "implements", .none },
    .{ "string", .none },    .{ "number", .none },  .{ "boolean", .none }, .{ "any", .none },
    .{ "unknown", .none },   .{ "never", .none },   .{ "object", .none },  .{ "symbol", .none },
    .{ "bigint", .none },
});

/// Words after which a value (so a regex) follows, besides plain keywords.
fn isValueWord(hl: HighlightId) bool {
    return hl == .variable_builtin or hl == .constant_builtin or hl == .type_builtin;
}

const Ops = common.OpTable(&.{
    ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
    "=>",   "==",  "!=",  "<=",  ">=",  "&&",  "||",  "??",  "?.",  "++",  "--",
    "+=",   "-=",  "*=",  "%=",  "&=",  "|=",  "^=",  "**",  "<<",  ">>",  "+",
    "-",    "*",   "%",   "&",   "|",   "^",   "!",   "~",   "?",   ":",   "=",
    "<",    ">",
});

fn isIdentStart(b: u8) bool {
    return common.isIdentStart(b) or b == '$';
}

fn isIdent(b: u8) bool {
    return common.isIdent(b) or b == '$';
}

fn isJsxName(b: u8) bool {
    return isIdent(b) or b == '-' or b == '.' or b == ':';
}

/// An escape sequence from `\` at the cursor: `\xHH`, `\uHHHH`,
/// `\u{…}` or one escaped byte.
fn escape(s: *Scanner) void {
    const line = s.line;
    s.advance();
    if (s.pos >= line.len) return;
    const k = line[s.pos];
    s.advance();
    var want: usize = switch (k) {
        'x' => 2,
        'u' => 4,
        else => 0,
    };
    if (k == 'u' and s.peek() == '{') {
        s.advance();
        while (s.peek()) |c| {
            s.advance();
            if (c == '}' or !std.ascii.isHex(c)) break;
        }
        return;
    }
    while (want > 0 and s.peek() != null and std.ascii.isHex(s.peek().?)) : (want -= 1) s.advance();
}

fn top(st: *const LexState) u8 {
    return if (st.aux_len == 0) 0 else st.aux[st.aux_len - 1];
}

fn push(st: *LexState, f: u8) bool {
    if (st.aux_len >= max_frames) return false;
    st.aux[st.aux_len] = f;
    st.aux_len += 1;
    return true;
}

fn pop(st: *LexState) void {
    if (st.aux_len == 0) return;
    st.aux_len -= 1;
    st.aux[st.aux_len] = 0;
}

fn setTop(st: *LexState, f: u8) void {
    st.aux[st.aux_len - 1] = f;
}

fn isExprFrame(f: u8) bool {
    return f & (Frame.template_expr | Frame.jsx_expr) != 0;
}

fn Lexer(comptime d: Dialect) type {
    return struct {
        const Self = @This();
        const Words = if (d.typescript) TsWords else JsWords;

        st: *LexState,
        s: *Scanner,
        out: *TokenSink,
        /// The previous token was `.` or `?.`: the next word is a property.
        after_dot: bool = false,
        /// The previous token was `function`: the next word names it.
        after_function: bool = false,
        /// A type may follow (after `:`, `<`, `|`, `&`, `as`, `extends`, …):
        /// TypeScript builtin type words are types there.
        type_ctx: bool = false,
        /// `type_ctx` as it was before the current token.
        prev_type_ctx: bool = false,

        fn emit(l: *Self, start: u32, kind: u16, hl: HighlightId) void {
            l.s.emit(l.out, start, kind, hl);
        }

        fn divOk(l: *Self, ok: bool) void {
            if (ok) l.st.mode |= Bits.div_ok else l.st.mode &= ~Bits.div_ok;
        }

        fn regexAllowed(l: *const Self) bool {
            return l.st.mode & Bits.div_ok == 0;
        }

        /// A one-byte token.
        fn single(l: *Self, kind: u16, hl: HighlightId) void {
            const start = l.s.pos;
            l.s.advance();
            l.emit(start, kind, hl);
        }

        /// The body of a `"` or `'` string from the cursor (after the
        /// quote or at a continued line's start).
        fn stringBody(l: *Self, q: u8) void {
            const s = l.s;
            const line = s.line;
            while (s.pos < line.len) {
                const start = s.pos;
                const c = line[start];
                if (c == q) {
                    s.advance();
                    l.emit(start, Kind.string, .string);
                    l.divOk(true);
                    return;
                }
                if (c == '\\') {
                    if (start + 1 >= common.trimCr(line).len) {
                        // A line continuation.
                        s.skipToEnd();
                        l.emit(start, Kind.str_escape, .string_escape);
                        l.st.mode |= if (q == '"') Bits.dq_cont else Bits.sq_cont;
                        return;
                    }
                    escape(s);
                    l.emit(start, Kind.str_escape, .string_escape);
                    continue;
                }
                s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, if (q == '"') "\"\\" else "'\\") orelse line.len);
                l.emit(start, Kind.string, .string);
            }
            // Unterminated: the string ends with the line.
            l.divOk(true);
        }

        /// A block comment body from the cursor.
        fn blockComment(l: *Self, start: u32) void {
            const s = l.s;
            if (std.mem.indexOfPos(u8, s.line, s.pos, "*/")) |e| {
                s.pos = @intCast(e + 2);
                l.st.mode &= ~Bits.block_comment;
            } else {
                s.skipToEnd();
                l.st.mode |= Bits.block_comment;
            }
            l.emit(start, Kind.comment, .comment);
        }

        /// A regex literal from `/` at the cursor.
        fn regex(l: *Self) void {
            const s = l.s;
            const line = s.line;
            const start = s.pos;
            var i: usize = s.pos + 1;
            var class = false;
            while (i < line.len) : (i += 1) {
                const c = line[i];
                if (c == '\\') {
                    i += 1;
                } else if (c == '[') {
                    class = true;
                } else if (c == ']') {
                    class = false;
                } else if (c == '/' and !class) {
                    i += 1;
                    while (i < line.len and isIdent(line[i])) i += 1;
                    break;
                }
            }
            s.pos = @intCast(@min(i, line.len));
            l.emit(start, Kind.regex, .string_special);
            l.divOk(true);
        }

        fn number(l: *Self) void {
            const s = l.s;
            const line = s.line;
            const start = s.pos;
            var i: usize = s.pos;
            if (line[i] == '0' and i + 1 < line.len and std.mem.indexOfScalar(u8, "xXoObB", line[i + 1]) != null) {
                i += 2;
                while (i < line.len and (std.ascii.isHex(line[i]) or line[i] == '_')) i += 1;
            } else {
                while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) i += 1;
                if (i < line.len and line[i] == '.') {
                    i += 1;
                    while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) i += 1;
                }
                if (i < line.len and (line[i] == 'e' or line[i] == 'E')) {
                    i += 1;
                    if (i < line.len and (line[i] == '+' or line[i] == '-')) i += 1;
                    while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '_')) i += 1;
                }
            }
            // BigInt `n` and any glued identifier bytes.
            while (i < line.len and isIdent(line[i])) i += 1;
            s.pos = @intCast(i);
            l.emit(start, Kind.number, .number);
            l.divOk(true);
        }

        /// The next non-blank byte at or after `i`.
        fn nextByte(line: []const u8, i_in: usize) ?u8 {
            var i = i_in;
            while (i < line.len and common.isSpace(line[i])) i += 1;
            return if (i < line.len) line[i] else null;
        }

        fn word(l: *Self) void {
            const s = l.s;
            const line = s.line;
            const start = s.pos;
            _ = s.eatWhile(isIdent);
            const w = line[start..s.pos];
            const next = nextByte(line, s.pos);
            if (l.after_dot) {
                l.after_dot = false;
                l.emit(start, Kind.ident, if (next == '(') .function else .property);
                l.divOk(true);
                return;
            }
            if (Words.get(w)) |hl| {
                const contextual = Contextual.get(w) != null;
                const keyword = !contextual or (next != null and (isIdentStart(next.?) or std.mem.indexOfScalar(u8, "{[*\"'`#@", next.?) != null)) or
                    (next == '(' and std.mem.eql(u8, w, "async"));
                // A TS builtin type is one where a type can stand.
                const type_word = hl == .type_builtin and (l.prev_type_ctx or (next != null and std.mem.indexOfScalar(u8, "=:(.", next.?) == null));
                if (keyword or type_word) {
                    l.emit(start, Kind.keyword, hl);
                    l.divOk(isValueWord(hl));
                    if (std.mem.eql(u8, w, "function")) l.after_function = true;
                    if (hl == .keyword_operator or std.mem.eql(u8, w, "as") or std.mem.eql(u8, w, "extends") or std.mem.eql(u8, w, "implements")) l.type_ctx = true;
                    return;
                }
            }
            if (l.after_function) {
                l.after_function = false;
                l.emit(start, Kind.ident, .function);
                l.divOk(true);
                return;
            }
            l.emit(start, Kind.ident, common.identHl(w, if (s.pos < line.len) line[s.pos] else null));
            l.divOk(true);
        }

        /// Whether `<` at the cursor starts a JSX element.
        fn jsxStarts(l: *const Self) bool {
            if (!d.jsx or !l.regexAllowed()) return false;
            const line = l.s.line;
            const i = l.s.pos + 1;
            if (i >= line.len) return false;
            if (line[i] == '>') return true;
            if (!isIdentStart(line[i])) return false;
            if (d.typescript) {
                // A generic arrow `<T,>(…)` or `<T extends U>(…)`.
                var j = i;
                while (j < line.len and isJsxName(line[j])) j += 1;
                var k = j;
                while (k < line.len and common.isSpace(line[k])) k += 1;
                if (k < line.len and line[k] == ',') return false;
                if (k > j and std.mem.startsWith(u8, line[k..], "extends") and
                    (k + 7 >= line.len or !isIdent(line[k + 7]))) return false;
            }
            return true;
        }

        /// `<` and the tag name of an opening tag (or `<>`); pushes the frame.
        fn openTag(l: *Self) void {
            const s = l.s;
            const start = s.pos;
            if (s.peekAt(1) == '>') {
                if (!push(l.st, Frame.jsx_children)) return l.operator();
                s.advanceBy(2);
                l.emit(start, Kind.jsx_punct, .punctuation);
                return;
            }
            if (!push(l.st, Frame.jsx_tag)) return l.operator();
            s.advance();
            l.emit(start, Kind.jsx_punct, .punctuation);
            const n = s.pos;
            _ = s.eatWhile(isJsxName);
            l.emit(n, Kind.jsx_tag, if (std.ascii.isUpper(s.line[n])) .type else .tag);
        }

        fn operator(l: *Self) void {
            const s = l.s;
            const start = s.pos;
            const n = Ops.len(s.rest()) orelse 1;
            s.advanceBy(n);
            l.emit(start, Kind.operator, .operator);
            const op = s.line[start..s.pos];
            if (!std.mem.eql(u8, op, "++") and !std.mem.eql(u8, op, "--")) l.divOk(false);
            if (op.len == 1 and std.mem.indexOfScalar(u8, ":<|&", op[0]) != null) l.type_ctx = true;
        }

        /// JavaScript code.
        fn code(l: *Self) void {
            const s = l.s;
            const line = s.line;
            const start = s.pos;
            const c = line[start];
            if (!common.isSpace(c)) {
                l.prev_type_ctx = l.type_ctx;
                l.type_ctx = false;
            }
            switch (c) {
                ' ', '\t', '\r', 0x0b, 0x0c => {
                    _ = s.eatWhile(common.isSpace);
                    l.emit(start, Kind.ws, .none);
                    return;
                },
                '/' => {
                    const n = s.peekAt(1);
                    if (n == '/') {
                        s.skipToEnd();
                        l.emit(start, Kind.comment, .comment);
                    } else if (n == '*') {
                        s.advanceBy(2);
                        l.blockComment(start);
                    } else if (l.regexAllowed()) {
                        l.regex();
                    } else l.operator();
                },
                '"', '\'' => {
                    s.advance();
                    l.emit(start, Kind.string, .string);
                    l.stringBody(c);
                },
                '`' => {
                    s.advance();
                    l.emit(start, Kind.string, .string);
                    if (!push(l.st, Frame.template)) l.divOk(true);
                },
                '0'...'9' => l.number(),
                '.' => if (s.peekAt(1) != null and std.ascii.isDigit(s.peekAt(1).?)) {
                    l.number();
                } else if (s.peekAt(1) == '.' and s.peekAt(2) == '.') {
                    l.operator();
                } else {
                    l.single(Kind.punctuation, .punctuation_delimiter);
                    l.after_dot = true;
                    return;
                },
                '#' => {
                    s.advance();
                    if (s.eatWhile(isIdent) > 0) {
                        l.emit(start, Kind.ident, .property);
                        l.divOk(true);
                    } else l.emit(start, Kind.invalid, .invalid);
                },
                '@' => {
                    s.advance();
                    _ = s.eatWhile(struct {
                        fn f(b: u8) bool {
                            return isIdent(b) or b == '.';
                        }
                    }.f);
                    l.emit(start, Kind.decorator, .attribute);
                    l.divOk(false);
                },
                '(', '[' => {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.divOk(false);
                },
                ')', ']' => {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.divOk(true);
                },
                '{' => {
                    l.single(Kind.bracket, .punctuation_bracket);
                    const f = top(l.st);
                    if (isExprFrame(f) and f & Frame.depth_mask < Frame.depth_mask) setTop(l.st, f + 1);
                    l.divOk(false);
                },
                '}' => {
                    l.single(Kind.bracket, .punctuation_bracket);
                    const f = top(l.st);
                    if (isExprFrame(f)) {
                        if (f & Frame.depth_mask == 0) {
                            pop(l.st);
                            // Back in a template or JSX: the expression was a value.
                            l.divOk(true);
                            return;
                        }
                        setTop(l.st, f - 1);
                    }
                    l.divOk(false);
                },
                ';', ',' => {
                    l.single(Kind.punctuation, .punctuation_delimiter);
                    l.divOk(false);
                },
                '<' => if (l.jsxStarts()) l.openTag() else l.operator(),
                '?' => if (s.peekAt(1) == '.' and !(s.peekAt(2) != null and std.ascii.isDigit(s.peekAt(2).?))) {
                    s.advanceBy(2);
                    l.emit(start, Kind.punctuation, .punctuation_delimiter);
                    l.after_dot = true;
                    return;
                } else l.operator(),
                '\\' => {
                    // A `\u` escape in an identifier.
                    s.advance();
                    _ = s.eatWhile(isIdent);
                    l.emit(start, Kind.ident, .variable);
                    l.divOk(true);
                },
                else => if (isIdentStart(c)) {
                    l.word();
                    return;
                } else if (Ops.len(s.rest()) != null) {
                    l.operator();
                } else {
                    l.single(Kind.invalid, .invalid);
                },
            }
            l.after_dot = false;
        }

        /// Template text up to the closing backtick or a `${`.
        fn template(l: *Self) void {
            const s = l.s;
            const line = s.line;
            const start = s.pos;
            switch (line[start]) {
                '`' => {
                    l.single(Kind.string, .string);
                    pop(l.st);
                    l.divOk(true);
                },
                '\\' => {
                    escape(s);
                    l.emit(start, Kind.str_escape, .string_escape);
                },
                '$' => if (s.peekAt(1) == '{' and push(l.st, Frame.template_expr)) {
                    l.single(Kind.interp, .punctuation);
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.divOk(false);
                } else {
                    s.advance();
                    l.emit(start, Kind.string, .string);
                },
                else => {
                    s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, "`\\$") orelse line.len);
                    l.emit(start, Kind.string, .string);
                },
            }
        }

        /// Inside an opening tag: attributes up to `>` or `/>`.
        fn jsxTag(l: *Self) void {
            const s = l.s;
            const line = s.line;
            const start = s.pos;
            const c = line[start];
            switch (c) {
                ' ', '\t', '\r' => {
                    _ = s.eatWhile(common.isSpace);
                    l.emit(start, Kind.ws, .none);
                },
                '/' => if (s.peekAt(1) == '>') {
                    s.advanceBy(2);
                    l.emit(start, Kind.jsx_punct, .punctuation);
                    pop(l.st);
                    l.divOk(true);
                } else l.single(Kind.invalid, .invalid),
                '>' => {
                    l.single(Kind.jsx_punct, .punctuation);
                    setTop(l.st, Frame.jsx_children);
                },
                '{' => if (push(l.st, Frame.jsx_expr)) {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.divOk(false);
                } else l.single(Kind.invalid, .invalid),
                '"', '\'' => {
                    const end = std.mem.indexOfScalarPos(u8, line, start + 1, c);
                    s.pos = if (end) |e| @intCast(e + 1) else @intCast(line.len);
                    l.emit(start, Kind.string, .string);
                },
                '=' => l.single(Kind.operator, .operator),
                '<' => {
                    // Type arguments of a generic component: `<List<T> …>`.
                    var depth: usize = 0;
                    var i: usize = start;
                    while (i < line.len) : (i += 1) {
                        if (line[i] == '<') depth += 1;
                        if (line[i] == '>') {
                            depth -= 1;
                            if (depth == 0) {
                                i += 1;
                                break;
                            }
                        }
                    }
                    s.pos = @intCast(i);
                    l.emit(start, Kind.jsx_attr, .type);
                },
                else => if (isIdentStart(c)) {
                    _ = s.eatWhile(isJsxName);
                    l.emit(start, Kind.jsx_attr, .attribute);
                } else l.single(Kind.invalid, .invalid),
            }
        }

        /// Inside a closing tag, up to `>`.
        fn jsxClose(l: *Self) void {
            const s = l.s;
            const line = s.line;
            const start = s.pos;
            const c = line[start];
            if (common.isSpace(c)) {
                _ = s.eatWhile(common.isSpace);
                l.emit(start, Kind.ws, .none);
            } else if (c == '>') {
                l.single(Kind.jsx_punct, .punctuation);
                pop(l.st);
                l.divOk(true);
            } else if (isIdentStart(c)) {
                _ = s.eatWhile(isJsxName);
                l.emit(start, Kind.jsx_tag, if (std.ascii.isUpper(c)) .type else .tag);
            } else l.single(Kind.invalid, .invalid);
        }

        /// Element children: text, entities, `{ }` and nested tags.
        fn jsxChildren(l: *Self) void {
            const s = l.s;
            const line = s.line;
            const start = s.pos;
            switch (line[start]) {
                '<' => {
                    const n = s.peekAt(1);
                    if (n == '/') {
                        s.advanceBy(2);
                        l.emit(start, Kind.jsx_punct, .punctuation);
                        setTop(l.st, Frame.jsx_close);
                    } else if (n != null and (n.? == '>' or isIdentStart(n.?))) {
                        l.openTag();
                    } else {
                        s.advance();
                        l.emit(start, Kind.jsx_text, .string);
                    }
                },
                '{' => if (push(l.st, Frame.jsx_expr)) {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.divOk(false);
                } else {
                    s.advance();
                    l.emit(start, Kind.jsx_text, .string);
                },
                '&' => {
                    // `&name;`, `&#123;` or `&#x7b;`.
                    var e: usize = start + 1;
                    if (e < line.len and line[e] == '#') e += 1;
                    while (e < line.len and e < start + 32 and std.ascii.isAlphanumeric(line[e])) e += 1;
                    if (e > start + 1 and e < line.len and line[e] == ';') {
                        s.pos = @intCast(e + 1);
                        l.emit(start, Kind.str_escape, .string_escape);
                    } else {
                        s.advance();
                        l.emit(start, Kind.jsx_text, .string);
                    }
                },
                else => {
                    s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, "<{&") orelse line.len);
                    l.emit(start, Kind.jsx_text, .string);
                },
            }
        }

        fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
            var sc = s_in.*;
            defer s_in.* = sc;
            var l: Self = .{ .st = st, .s = &sc, .out = out };
            const line = sc.line;
            if (st.mode & Bits.block_comment != 0) {
                l.blockComment(0);
            } else if (st.mode & (Bits.dq_cont | Bits.sq_cont) != 0) {
                const q: u8 = if (st.mode & Bits.dq_cont != 0) '"' else '\'';
                st.mode &= ~(Bits.dq_cont | Bits.sq_cont);
                l.stringBody(q);
            } else if (st.mode == 0 and st.aux_len == 0 and std.mem.startsWith(u8, line, "#!")) {
                // A hashbang line.
                sc.skipToEnd();
                l.emit(0, Kind.comment, .comment);
            }
            while (sc.pos < line.len) {
                if (st.mode & (Bits.block_comment | Bits.dq_cont | Bits.sq_cont) != 0) break;
                switch (top(st)) {
                    Frame.template => l.template(),
                    Frame.jsx_tag => l.jsxTag(),
                    Frame.jsx_close => l.jsxClose(),
                    Frame.jsx_children => l.jsxChildren(),
                    else => l.code(),
                }
            }
        }
    };
}

/// Lexes one line of `dialect`.
pub fn lexLineWith(comptime dialect: Dialect, st: *LexState, s: *Scanner, out: *TokenSink) void {
    Lexer(dialect).lexLine(st, s, out);
}

fn lexJs(st: *LexState, s: *Scanner, out: *TokenSink) void {
    Lexer(.{}).lexLine(st, s, out);
}

fn lexTs(st: *LexState, s: *Scanner, out: *TokenSink) void {
    Lexer(.{ .typescript = true }).lexLine(st, s, out);
}

fn lexJsx(st: *LexState, s: *Scanner, out: *TokenSink) void {
    Lexer(.{ .jsx = true }).lexLine(st, s, out);
}

fn lexTsx(st: *LexState, s: *Scanner, out: *TokenSink) void {
    Lexer(.{ .typescript = true, .jsx = true }).lexLine(st, s, out);
}

fn resync(line: []const u8) bool {
    // A top-level declaration at column 0.
    const starts = [_][]const u8{ "function ", "class ", "export ", "import ", "const ", "let ", "var ", "async function ", "interface ", "type ", "enum ", "declare " };
    for (starts) |p| if (std.mem.startsWith(u8, line, p)) return true;
    return false;
}

const js_decls = [_]language.DeclKeyword{
    .{ .word = "function", .kind = .function },
    .{ .word = "class", .kind = .class },
    .{ .word = "interface", .kind = .interface },
    .{ .word = "enum", .kind = .@"enum" },
    .{ .word = "namespace", .kind = .namespace },
    .{ .word = "module", .kind = .module },
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
        .{ .open = "`", .close = "`" },
    },
    .insert_spaces = true,
    .indent_after = &.{ "{", "(", "[" },
    .dedent_on = &.{ "}", ")", "]" },
};

const brackets = [_]language.BracketPair{
    .{ .open = "(", .close = ")" },
    .{ .open = "[", .close = "]" },
    .{ .open = "{", .close = "}" },
};

/// JavaScript.
pub const javascript_language: language.Language = .{
    .id = .javascript,
    .name = "javascript",
    .aliases = &.{ "js", "node" },
    .extensions = &.{ ".js", ".mjs", ".cjs" },
    .shebangs = &.{ "node", "deno", "bun" },
    .lexer = .{ .lexLineFn = lexJs },
    .resync = resync,
    .decl_keywords = &js_decls,
    .edit_rules = edit_rules,
    .brackets = &brackets,
    .word_chars = &.{'$'},
};

/// TypeScript.
pub const typescript_language: language.Language = .{
    .id = .typescript,
    .name = "typescript",
    .aliases = &.{"ts"},
    .extensions = &.{ ".ts", ".mts", ".cts" },
    .lexer = .{ .lexLineFn = lexTs },
    .resync = resync,
    .decl_keywords = &js_decls,
    .edit_rules = edit_rules,
    .brackets = &brackets,
    .word_chars = &.{'$'},
};

/// JavaScript with JSX.
pub const jsx_language: language.Language = .{
    .id = .jsx,
    .name = "jsx",
    .aliases = &.{"javascriptreact"},
    .extensions = &.{".jsx"},
    .lexer = .{ .lexLineFn = lexJsx },
    .resync = resync,
    .decl_keywords = &js_decls,
    .edit_rules = edit_rules,
    .brackets = &brackets,
    .word_chars = &.{'$'},
};

/// TypeScript with JSX.
pub const tsx_language: language.Language = .{
    .id = .tsx,
    .name = "tsx",
    .aliases = &.{"typescriptreact"},
    .extensions = &.{".tsx"},
    .lexer = .{ .lexLineFn = lexTsx },
    .resync = resync,
    .decl_keywords = &js_decls,
    .edit_rules = edit_rules,
    .brackets = &brackets,
    .word_chars = &.{'$'},
};
