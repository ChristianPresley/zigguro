//! Go, following the Go specification's lexical elements. Only raw
//! (backquoted) strings and general comments span lines. For the tier-2
//! parser the lexer can also emit the spec's automatic semicolons.

const std = @import("std");
const language = @import("../language.zig");
const common = @import("common.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Go token kinds. `str_escape` and `str_cont` continue the literal
/// before them; `raw_cont` continues a raw string from an earlier line.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    pub const string: u16 = 4 | atomic;
    pub const str_escape: u16 = 5;
    pub const str_cont: u16 = 6;
    pub const rune: u16 = 7 | atomic;
    pub const number: u16 = 8 | atomic;
    pub const ident: u16 = 9 | atomic;
    pub const keyword: u16 = 10 | atomic;
    pub const operator: u16 = 11 | atomic;
    pub const bracket: u16 = 12 | atomic;
    pub const punctuation: u16 = 13 | atomic;
    pub const raw_string: u16 = 14 | atomic;
    pub const raw_cont: u16 = 15;
    pub const invalid: u16 = 16;
    /// Tier 2 only: an automatic semicolon, at the end of the line (see
    /// `Options`). It starts at the line's length and covers nothing.
    pub const virtual_semicolon: u16 = 17 | atomic;
};

/// Line-end modes.
pub const Mode = struct {
    pub const code: u16 = 0;
    pub const block_comment: u16 = 1;
    pub const raw_string: u16 = 2;
};

/// Lexer options. Highlighting uses the defaults; the tier-2 provider
/// turns on `virtual_semicolons`.
pub const Options = struct {
    virtual_semicolons: bool = false,
};

const words = [_]common.Word{
    .{ "break", .keyword_control },       .{ "case", .keyword_control },      .{ "continue", .keyword_control },
    .{ "default", .keyword_control },     .{ "defer", .keyword_control },     .{ "else", .keyword_control },
    .{ "fallthrough", .keyword_control }, .{ "for", .keyword_control },       .{ "go", .keyword_control },
    .{ "goto", .keyword_control },        .{ "if", .keyword_control },        .{ "range", .keyword_control },
    .{ "return", .keyword_control },      .{ "select", .keyword_control },    .{ "switch", .keyword_control },
    .{ "chan", .keyword_storage },        .{ "const", .keyword_storage },     .{ "func", .keyword_storage },
    .{ "import", .keyword_storage },      .{ "interface", .keyword_storage }, .{ "map", .keyword_storage },
    .{ "package", .keyword_storage },     .{ "struct", .keyword_storage },    .{ "type", .keyword_storage },
    .{ "var", .keyword_storage },         .{ "any", .type_builtin },          .{ "bool", .type_builtin },
    .{ "byte", .type_builtin },           .{ "comparable", .type_builtin },   .{ "complex64", .type_builtin },
    .{ "complex128", .type_builtin },     .{ "error", .type_builtin },        .{ "float32", .type_builtin },
    .{ "float64", .type_builtin },        .{ "int", .type_builtin },          .{ "int8", .type_builtin },
    .{ "int16", .type_builtin },          .{ "int32", .type_builtin },        .{ "int64", .type_builtin },
    .{ "rune", .type_builtin },           .{ "string", .type_builtin },       .{ "uint", .type_builtin },
    .{ "uint8", .type_builtin },          .{ "uint16", .type_builtin },       .{ "uint32", .type_builtin },
    .{ "uint64", .type_builtin },         .{ "uintptr", .type_builtin },      .{ "true", .constant_builtin },
    .{ "false", .constant_builtin },      .{ "iota", .constant_builtin },     .{ "nil", .constant_builtin },
    .{ "append", .function_builtin },     .{ "cap", .function_builtin },      .{ "clear", .function_builtin },
    .{ "close", .function_builtin },      .{ "complex", .function_builtin },  .{ "copy", .function_builtin },
    .{ "delete", .function_builtin },     .{ "imag", .function_builtin },     .{ "len", .function_builtin },
    .{ "make", .function_builtin },       .{ "max", .function_builtin },      .{ "min", .function_builtin },
    .{ "new", .function_builtin },        .{ "panic", .function_builtin },    .{ "print", .function_builtin },
    .{ "println", .function_builtin },    .{ "real", .function_builtin },     .{ "recover", .function_builtin },
};

const Words = common.WordTable(&words);

const Ops = common.OpTable(&.{
    "+",  "-",  "*",  "/",  "%",  "&",   "|",   "^",   "<<", ">>", "&^", "+=", "-=", "*=",
    "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "&^=", "&&", "||", "<-", "++", "--", "==",
    "<",  ">",  "=",  "!",  "~",  "!=",  "<=",  ">=",  ":=",
});

fn isSpaceB(b: u8) bool {
    return common.isSpace(b);
}

/// The body of an interpreted string or rune after its opening quote, up
/// to and including the closing quote, with escapes as separate tokens.
/// Neither spans lines.
fn quotedBody(s: *Scanner, out: *TokenSink, quote: u8, hl: HighlightId) void {
    const line = s.line;
    while (s.pos < line.len) {
        const c = line[s.pos];
        if (c == quote) {
            s.pos += 1;
            return;
        }
        if (c == '\\') {
            const start = s.pos;
            s.pos += 1;
            if (s.pos < line.len) {
                const e = line[s.pos];
                s.pos += 1;
                const hex: u32 = switch (e) {
                    'x' => 2,
                    'u' => 4,
                    'U' => 8,
                    else => 0,
                };
                var n: u32 = 0;
                while (n < hex and s.peek() != null and std.ascii.isHex(s.peek().?)) : (n += 1) s.pos += 1;
                if (e >= '0' and e <= '7') {
                    while (n < 2 and s.peek() != null and s.peek().? >= '0' and s.peek().? <= '7') : (n += 1) s.pos += 1;
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
}

fn isDigitU(b: u8) bool {
    return std.ascii.isDigit(b) or b == '_';
}

fn isHexU(b: u8) bool {
    return std.ascii.isHex(b) or b == '_';
}

/// A number literal: decimal, binary, octal or hex, integer or float
/// (hex floats need a `p` exponent), with an optional imaginary `i`.
inline fn number(s: *Scanner) void {
    const line = s.line;
    var i: usize = s.pos;
    var hex = false;
    if (line[i] == '0' and i + 1 < line.len and std.mem.indexOfScalar(u8, "xXoObB", line[i + 1]) != null) {
        hex = line[i + 1] == 'x' or line[i + 1] == 'X';
        i += 2;
        while (i < line.len and isHexU(line[i])) i += 1;
    } else {
        while (i < line.len and isDigitU(line[i])) i += 1;
    }
    if (i < line.len and line[i] == '.' and !(i + 1 < line.len and line[i + 1] == '.')) {
        i += 1;
        while (i < line.len and (if (hex) isHexU(line[i]) else isDigitU(line[i]))) i += 1;
    }
    if (i < line.len) {
        const e = line[i];
        if ((!hex and (e == 'e' or e == 'E')) or (hex and (e == 'p' or e == 'P'))) {
            var j = i + 1;
            if (j < line.len and (line[j] == '+' or line[j] == '-')) j += 1;
            if (j < line.len and std.ascii.isDigit(line[j])) {
                i = j;
                while (i < line.len and isDigitU(line[i])) i += 1;
            }
        }
    }
    if (i < line.len and line[i] == 'i') i += 1;
    s.pos = @intCast(i);
}

/// Words after which a newline inserts a semicolon.
fn endsStatement(word: []const u8) bool {
    return std.mem.eql(u8, word, "break") or std.mem.eql(u8, word, "continue") or
        std.mem.eql(u8, word, "fallthrough") or std.mem.eql(u8, word, "return");
}

fn lexLine(st: *LexState, s: *Scanner, out: *TokenSink) void {
    lexLineWith(.{}, st, s, out);
}

/// Lexes one line with explicit options (the tier-2 entry point).
pub fn lexLineWith(comptime o: Options, st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    var sc = s_in.*;
    defer s_in.* = sc;
    const s = &sc;
    // Whether the last token so far would end a statement at a newline.
    var semi = false;
    defer if (o.virtual_semicolons and semi) out.push(.{ .start = @intCast(s.line.len), .kind = Kind.virtual_semicolon, .hl = .none });

    switch (st.mode) {
        Mode.code => {},
        Mode.block_comment => {
            const start = s.pos;
            const end = std.mem.indexOfPos(u8, s.line, s.pos, "*/");
            s.pos = if (end) |e| @intCast(e + 2) else @intCast(s.line.len);
            s.emit(out, start, Kind.comment, .comment);
            if (end == null) return;
            st.mode = Mode.code;
        },
        Mode.raw_string => {
            const start = s.pos;
            const end = std.mem.indexOfScalarPos(u8, s.line, s.pos, '`');
            s.pos = if (end) |e| @intCast(e + 1) else @intCast(s.line.len);
            s.emit(out, start, Kind.raw_cont, .string);
            if (end == null) return;
            st.mode = Mode.code;
            semi = true;
        },
        else => st.mode = Mode.code,
    }

    // The previous significant token was `func` or `type`: it names the
    // next identifier.
    var after: enum { none, func, type } = .none;
    while (s.peek()) |c| {
        const start = s.pos;
        const named = after;
        after = .none;
        switch (c) {
            ' ', '\t', '\r', 0x0b, 0x0c => {
                _ = s.eatWhile(isSpaceB);
                s.emit(out, start, Kind.ws, .none);
                after = named;
                continue;
            },
            '/' => if (s.peekAt(1) == '/') {
                s.skipToEnd();
                s.emit(out, start, Kind.comment, .comment);
                continue;
            } else if (s.peekAt(1) == '*') {
                const end = std.mem.indexOfPos(u8, s.line, s.pos + 2, "*/");
                s.pos = if (end) |e| @intCast(e + 2) else @intCast(s.line.len);
                s.emit(out, start, Kind.comment, .comment);
                // A comment that spans lines acts like a newline: the
                // semicolon (if any) goes at this line's end.
                if (end == null) st.mode = Mode.block_comment;
                continue;
            } else {
                s.advance();
                _ = s.eatByte('=');
                s.emit(out, start, Kind.operator, .operator);
                semi = false;
            },
            '"', '\'' => {
                s.advance();
                const str = c == '"';
                const hl: HighlightId = if (str) .string else .character;
                s.emit(out, start, if (str) Kind.string else Kind.rune, hl);
                quotedBody(s, out, c, hl);
                semi = true;
            },
            '`' => {
                s.advance();
                s.emit(out, start, Kind.raw_string, .string);
                if (std.mem.indexOfScalarPos(u8, s.line, s.pos, '`')) |e| {
                    s.pos = @intCast(e + 1);
                    semi = true;
                } else {
                    s.skipToEnd();
                    st.mode = Mode.raw_string;
                    semi = false;
                    return;
                }
            },
            '0'...'9' => {
                number(s);
                s.emit(out, start, Kind.number, .number);
                semi = true;
            },
            '.' => if (s.peekAt(1) != null and std.ascii.isDigit(s.peekAt(1).?)) {
                number(s);
                s.emit(out, start, Kind.number, .number);
                semi = true;
            } else if (s.eat("...")) {
                s.emit(out, start, Kind.operator, .operator);
                semi = false;
            } else {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
                semi = false;
            },
            '(', ')', '[', ']', '{', '}' => {
                s.advance();
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
                semi = c == ')' or c == ']' or c == '}';
            },
            ';', ',' => {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
                semi = false;
            },
            ':' => if (s.peekAt(1) == '=') {
                s.advanceBy(2);
                s.emit(out, start, Kind.operator, .operator);
                semi = false;
            } else {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
                semi = false;
            },
            else => if (common.isIdentStart(c)) {
                _ = s.eatIdent();
                const word = s.line[start..s.pos];
                const next = s.peek();
                if (Words.get(word)) |hl| {
                    // Predeclared functions are ordinary names unless called.
                    const h: HighlightId = if (hl == .function_builtin and next != '(') .variable else hl;
                    const k = switch (hl) {
                        .keyword_control, .keyword_storage => Kind.keyword,
                        else => Kind.ident,
                    };
                    s.emit(out, start, k, h);
                    semi = k == Kind.ident or endsStatement(word);
                    if (std.mem.eql(u8, word, "func")) after = .func else if (std.mem.eql(u8, word, "type")) after = .type;
                } else {
                    const h: HighlightId = switch (named) {
                        .func => .function,
                        .type => .type,
                        .none => if (next == '(') .function else .variable,
                    };
                    s.emit(out, start, Kind.ident, h);
                    semi = true;
                }
            } else if (Ops.len(s.rest())) |n| {
                s.advanceBy(n);
                s.emit(out, start, Kind.operator, .operator);
                const op = s.line[start..s.pos];
                semi = std.mem.eql(u8, op, "++") or std.mem.eql(u8, op, "--");
            } else {
                s.advance();
                s.emit(out, start, Kind.invalid, .invalid);
                semi = false;
            },
        }
    }
}

fn resync(line: []const u8) bool {
    return common.resyncAtColumn0(line);
}

/// The Go language definition.
pub const go_language: language.Language = .{
    .id = .go,
    .name = "go",
    .aliases = &.{"golang"},
    .extensions = &.{".go"},
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
            .{ .open = "'", .close = "'" },
            .{ .open = "`", .close = "`" },
        },
        .insert_spaces = false,
        .indent_after = &.{ "{", "(", "[" },
        .dedent_on = &.{ "}", ")", "]" },
    },
    .brackets = &.{
        .{ .open = "(", .close = ")" },
        .{ .open = "[", .close = "]" },
        .{ .open = "{", .close = "}" },
    },
};
