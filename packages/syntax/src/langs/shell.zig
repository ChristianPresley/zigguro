//! POSIX sh and bash. Quotes, `$( )`, `${ }`, backticks, `$(( ))` and
//! parentheses nest on a context stack, and here-documents (`<<WORD`,
//! `<<-WORD`, `<<'WORD'`, `<<"WORD"`) queue until the line ends; their
//! bodies run on the following lines until a line equal to the delimiter
//! (leading tabs stripped for `<<-`).
//!
//! State: `mode` bits 0-7 hold the stack depth, 8-10 the queued
//! here-document count, bit 11 "in a here-document body" and bit 12 "the
//! previous line ended with a `\` continuation", bit 13 "a `case` pattern
//! comes next". `aux` holds the stack
//! (one context code per byte), then each here-document as a header byte
//! (0x80 strip tabs, 0x40 quoted, low six bits the delimiter length)
//! followed by the delimiter.

const std = @import("std");
const language = @import("../language.zig");
const common = @import("common.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Shell token kinds.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    pub const word: u16 = 3;
    pub const keyword: u16 = 4 | atomic;
    pub const command: u16 = 5 | atomic;
    pub const variable: u16 = 6 | atomic;
    pub const string: u16 = 7;
    pub const str_escape: u16 = 8;
    pub const number: u16 = 9 | atomic;
    pub const operator: u16 = 10 | atomic;
    pub const separator: u16 = 11 | atomic;
    pub const bracket: u16 = 12 | atomic;
    pub const dollar: u16 = 13 | atomic;
    pub const heredoc_op: u16 = 14 | atomic;
    pub const heredoc_delim: u16 = 15 | atomic;
    pub const heredoc_body: u16 = 16;
    pub const heredoc_end: u16 = 17 | atomic;
    pub const param: u16 = 18;
    pub const escape: u16 = 19;
};

/// Context codes on the stack.
pub const Ctx = struct {
    pub const dquote: u8 = 1;
    pub const squote: u8 = 2;
    /// `${ }`.
    pub const param: u8 = 3;
    /// `$( )`.
    pub const cmdsubst: u8 = 4;
    pub const backtick: u8 = 5;
    /// `$(( ))` and `(( ))`.
    pub const arith: u8 = 6;
    /// A subshell or grouping `( )`.
    pub const paren: u8 = 7;
    /// `$' '`.
    pub const ansi: u8 = 8;
    /// An array literal `name=( )`.
    pub const array: u8 = 9;
};

/// `mode` bit layout.
pub const Bits = struct {
    pub const depth_mask: u16 = 0xff;
    pub const heredoc_shift: u4 = 8;
    pub const heredoc_mask: u16 = 0x700;
    pub const in_body: u16 = 0x800;
    pub const continued: u16 = 0x1000;
    pub const case_pattern: u16 = 0x2000;
};

pub const max_stack = 8;
pub const max_heredocs = 4;

const strip_tabs: u8 = 0x80;
const quoted: u8 = 0x40;
const len_mask: u8 = 0x3f;

/// The decoded line state.
const State = struct {
    stack: [max_stack]u8 = @splat(0),
    n: u8 = 0,
    /// Queued here-documents, encoded as in `aux`.
    docs: [LexState.max_aux]u8 = @splat(0),
    docs_len: u8 = 0,
    ndocs: u8 = 0,
    in_body: bool = false,
    continued: bool = false,
    case_pat: bool = false,

    fn decode(st: *const LexState) State {
        var d: State = .{};
        const aux = st.auxBytes();
        d.n = @intCast(@min(st.mode & Bits.depth_mask, max_stack, aux.len));
        @memcpy(d.stack[0..d.n], aux[0..d.n]);
        const rest = aux[d.n..];
        @memcpy(d.docs[0..rest.len], rest);
        d.docs_len = @intCast(rest.len);
        d.ndocs = @intCast((st.mode & Bits.heredoc_mask) >> Bits.heredoc_shift);
        d.in_body = st.mode & Bits.in_body != 0;
        d.continued = st.mode & Bits.continued != 0;
        d.case_pat = st.mode & Bits.case_pattern != 0;
        return d;
    }

    fn encode(d: *const State, st: *LexState) void {
        var buf: [LexState.max_aux]u8 = undefined;
        @memcpy(buf[0..d.n], d.stack[0..d.n]);
        // Keep the here-documents that still fit after the stack.
        var len: usize = d.n;
        var i: usize = 0;
        var kept: u16 = 0;
        while (i < d.docs_len) {
            const l = 1 + @as(usize, d.docs[i] & len_mask);
            if (len + l > buf.len) break;
            @memcpy(buf[len..][0..l], d.docs[i..][0..l]);
            len += l;
            i += l;
            kept += 1;
        }
        st.setAux(buf[0..len]);
        st.mode = @as(u16, d.n) | kept << Bits.heredoc_shift;
        if (d.in_body and kept > 0) st.mode |= Bits.in_body;
        if (d.continued) st.mode |= Bits.continued;
        if (d.case_pat) st.mode |= Bits.case_pattern;
        st.depth = 0;
    }

    fn top(d: *const State) u8 {
        return if (d.n == 0) 0 else d.stack[d.n - 1];
    }

    fn push(d: *State, c: u8) void {
        if (d.n < max_stack) {
            d.stack[d.n] = c;
            d.n += 1;
        }
    }

    fn pop(d: *State) void {
        d.n -|= 1;
    }

    fn addDoc(d: *State, delim: []const u8, flags: u8) void {
        if (d.ndocs == max_heredocs or delim.len > len_mask) return;
        if (d.docs_len + 1 + delim.len > d.docs.len) return;
        d.docs[d.docs_len] = flags | @as(u8, @intCast(delim.len));
        @memcpy(d.docs[d.docs_len + 1 ..][0..delim.len], delim);
        d.docs_len += @intCast(1 + delim.len);
        d.ndocs += 1;
    }

    /// The first queued here-document.
    fn firstDoc(d: *const State) struct { []const u8, u8 } {
        const h = d.docs[0];
        return .{ d.docs[1..][0 .. h & len_mask], h };
    }

    fn dropFirstDoc(d: *State) void {
        const l = 1 + @as(usize, d.docs[0] & len_mask);
        std.mem.copyForwards(u8, d.docs[0 .. d.docs_len - l], d.docs[l..d.docs_len]);
        d.docs_len -= @intCast(l);
        d.ndocs -= 1;
        if (d.ndocs == 0) d.in_body = false;
    }
};

const Keywords = common.WordTable(&.{
    .{ "if", .keyword_control },       .{ "then", .keyword_control },     .{ "else", .keyword_control },
    .{ "elif", .keyword_control },     .{ "fi", .keyword_control },       .{ "for", .keyword_control },
    .{ "while", .keyword_control },    .{ "until", .keyword_control },    .{ "do", .keyword_control },
    .{ "done", .keyword_control },     .{ "case", .keyword_control },     .{ "esac", .keyword_control },
    .{ "select", .keyword_control },   .{ "in", .keyword_control },       .{ "time", .keyword },
    .{ "function", .keyword_storage }, .{ "[[", .keyword },               .{ "]]", .keyword },
    .{ "!", .keyword_operator },       .{ "local", .keyword_storage },    .{ "export", .keyword_storage },
    .{ "declare", .keyword_storage },  .{ "readonly", .keyword_storage }, .{ "typeset", .keyword_storage },
    .{ "return", .keyword_control },   .{ "exit", .keyword_control },     .{ "break", .keyword_control },
    .{ "continue", .keyword_control },
});

const Builtins = common.WordTable(&.{
    .{ "echo", .function_builtin },    .{ "printf", .function_builtin },  .{ "cd", .function_builtin },
    .{ "pwd", .function_builtin },     .{ "set", .function_builtin },     .{ "unset", .function_builtin },
    .{ "shift", .function_builtin },   .{ "source", .function_builtin },  .{ ".", .function_builtin },
    .{ "eval", .function_builtin },    .{ "exec", .function_builtin },    .{ "trap", .function_builtin },
    .{ "test", .function_builtin },    .{ "[", .function_builtin },       .{ "read", .function_builtin },
    .{ "alias", .function_builtin },   .{ "unalias", .function_builtin }, .{ "wait", .function_builtin },
    .{ "kill", .function_builtin },    .{ "true", .function_builtin },    .{ "false", .function_builtin },
    .{ ":", .function_builtin },       .{ "type", .function_builtin },    .{ "command", .function_builtin },
    .{ "builtin", .function_builtin }, .{ "getopts", .function_builtin }, .{ "hash", .function_builtin },
    .{ "ulimit", .function_builtin },  .{ "umask", .function_builtin },   .{ "let", .function_builtin },
    .{ "shopt", .function_builtin },   .{ "mapfile", .function_builtin }, .{ "readarray", .function_builtin },
    .{ "pushd", .function_builtin },   .{ "popd", .function_builtin },    .{ "dirs", .function_builtin },
    .{ "jobs", .function_builtin },    .{ "fg", .function_builtin },      .{ "bg", .function_builtin },
});

fn isSpaceB(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r';
}

/// Bytes that end a word.
fn isMeta(b: u8) bool {
    return switch (b) {
        ' ', '\t', '\r', '|', '&', ';', '<', '>', '(', ')', '$', '`', '"', '\'', '\\' => true,
        else => false,
    };
}

fn isWordByte(b: u8) bool {
    return !isMeta(b);
}

fn isNameByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn isSpecialParam(b: u8) bool {
    return switch (b) {
        '@', '*', '#', '?', '$', '!', '-', '0'...'9' => true,
        else => false,
    };
}

/// Per-line lexing state on top of the decoded line state.
const Lexer = struct {
    s: *Scanner,
    out: *TokenSink,
    d: State,
    /// At command position: the next word is a command or keyword.
    cmd: bool,
    /// The next word follows `for`/`select` (a variable) or `case`.
    after: enum { none, for_var, case_word, function_name } = .none,
    /// `in` is a keyword next (after `for x` / `case x`).
    expect_in: enum { no, for_in, case_in } = .no,
    /// In the arguments of `local`, `export` and friends: names are
    /// variables.
    decl: bool = false,

    /// A quoted or expanded argument where `for`/`case` expect their word.
    fn argSeen(l: *Lexer) void {
        switch (l.after) {
            .for_var => l.expect_in = .for_in,
            .case_word => l.expect_in = .case_in,
            else => {},
        }
        l.after = .none;
    }

    fn emit(l: *Lexer, start: u32, kind: u16, hl: HighlightId) void {
        l.s.emit(l.out, start, kind, hl);
    }

    fn single(l: *Lexer, kind: u16, hl: HighlightId) void {
        const start = l.s.pos;
        l.s.advance();
        l.emit(start, kind, hl);
    }

    /// A `$` expansion at the cursor.
    fn dollar(l: *Lexer, in_code: bool) void {
        const s = l.s;
        const start = s.pos;
        const n1 = s.peekAt(1);
        if (n1 == '(' and s.peekAt(2) == '(') {
            l.single(Kind.dollar, .punctuation);
            l.single(Kind.bracket, .punctuation_bracket);
            l.single(Kind.bracket, .punctuation_bracket);
            l.d.push(Ctx.arith);
        } else if (n1 == '(') {
            l.single(Kind.dollar, .punctuation);
            l.single(Kind.bracket, .punctuation_bracket);
            l.d.push(Ctx.cmdsubst);
            l.cmd = true;
        } else if (n1 == '{') {
            l.single(Kind.dollar, .variable);
            l.single(Kind.bracket, .punctuation_bracket);
            l.d.push(Ctx.param);
        } else if (in_code and n1 == '\'') {
            s.advanceBy(2);
            l.emit(start, Kind.string, .string);
            l.d.push(Ctx.ansi);
        } else if (in_code and n1 == '"') {
            s.advanceBy(2);
            l.emit(start, Kind.string, .string);
            l.d.push(Ctx.dquote);
        } else if (n1 != null and isSpecialParam(n1.?)) {
            s.advanceBy(2);
            l.emit(start, Kind.variable, .variable_builtin);
        } else if (n1 != null and (std.ascii.isAlphabetic(n1.?) or n1.? == '_')) {
            s.advance();
            _ = s.eatWhile(isNameByte);
            l.emit(start, Kind.variable, .variable);
        } else {
            s.advance();
            l.emit(start, Kind.word, .none);
        }
    }

    /// A `\` escape in code: `\` and the next byte; a trailing `\`
    /// continues the line.
    fn backslash(l: *Lexer) void {
        const s = l.s;
        const start = s.pos;
        s.advance();
        if (s.atEnd() or (s.peek() == '\r' and s.pos + 1 == s.line.len)) {
            s.skipToEnd();
            l.emit(start, Kind.escape, .string_escape);
            l.d.continued = true;
            return;
        }
        s.advance();
        l.emit(start, Kind.escape, .string_escape);
    }

    /// A here-document operator `<<` or `<<-` (cursor after it) and its
    /// delimiter word.
    fn heredoc(l: *Lexer, start: u32, strip: bool) void {
        const s = l.s;
        l.emit(start, Kind.heredoc_op, .operator);
        const ws = s.pos;
        if (s.eatWhile(isSpaceB) > 0) l.emit(ws, Kind.ws, .none);
        const w = s.pos;
        var delim: [len_mask]u8 = undefined;
        var n: usize = 0;
        var is_quoted = false;
        while (s.peek()) |c| {
            if (c == '\'' or c == '"') {
                is_quoted = true;
                s.advance();
                while (s.peek()) |k| {
                    s.advance();
                    if (k == c) break;
                    if (n < delim.len) delim[n] = k;
                    n += 1;
                }
                continue;
            }
            if (c == '\\') {
                is_quoted = true;
                s.advance();
                continue;
            }
            if (isMeta(c)) break;
            if (n < delim.len) delim[n] = c;
            n += 1;
            s.advance();
        }
        if (s.pos == w) return;
        l.emit(w, Kind.heredoc_delim, .label);
        if (n <= delim.len) l.d.addDoc(delim[0..n], (if (strip) strip_tabs else 0) | (if (is_quoted) quoted else 0));
    }

    /// A word in code context.
    fn word(l: *Lexer) void {
        const s = l.s;
        const start = s.pos;
        _ = s.eatWhile(isWordByte);
        const w = s.line[start..s.pos];
        // Assignment: `name=` or `name+=` at command position.
        if (l.cmd or l.decl) assign: {
            const eq = std.mem.indexOfScalar(u8, w, '=') orelse break :assign;
            var name_end = eq;
            if (name_end > 0 and w[name_end - 1] == '+') name_end -= 1;
            if (name_end > 0 and (std.ascii.isAlphabetic(w[0]) or w[0] == '_') and allName(w[0..name_end])) {
                s.pos = start;
                s.advanceBy(name_end);
                l.emit(start, Kind.variable, .variable);
                const op = s.pos;
                s.advanceBy(eq + 1 - name_end);
                l.emit(op, Kind.operator, .operator);
                if (s.peek() == '(') {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.d.push(Ctx.array);
                    l.cmd = false;
                    return;
                }
                const v = s.pos;
                _ = s.eatWhile(isWordByte);
                if (s.pos > v) l.emit(v, Kind.word, .none);
                return;
            }
        }
        switch (l.after) {
            .for_var => {
                l.after = .none;
                l.expect_in = .for_in;
                l.emit(start, Kind.variable, .variable);
                return;
            },
            .case_word => {
                l.after = .none;
                l.expect_in = .case_in;
                l.emit(start, Kind.word, .none);
                return;
            },
            .function_name => {
                l.after = .none;
                l.emit(start, Kind.command, .function);
                return;
            },
            .none => {},
        }
        if (l.expect_in != .no and std.mem.eql(u8, w, "in")) {
            if (l.expect_in == .case_in) l.d.case_pat = true;
            l.expect_in = .no;
            l.emit(start, Kind.keyword, .keyword_control);
            return;
        }
        if (l.d.case_pat) {
            // A pattern word, or the end of the `case`.
            if (std.mem.eql(u8, w, "esac")) {
                l.d.case_pat = false;
                l.cmd = false;
                l.emit(start, Kind.keyword, .keyword_control);
            } else l.emit(start, Kind.word, .none);
            return;
        }
        if (l.decl and w.len > 0 and (std.ascii.isAlphabetic(w[0]) or w[0] == '_') and allName(w)) {
            l.emit(start, Kind.variable, .variable);
            return;
        }
        if (l.cmd) {
            if (Keywords.get(w)) |hl| {
                l.emit(start, Kind.keyword, hl);
                if (std.mem.eql(u8, w, "for") or std.mem.eql(u8, w, "select")) {
                    l.after = .for_var;
                    l.cmd = false;
                } else if (std.mem.eql(u8, w, "case")) {
                    l.after = .case_word;
                    l.cmd = false;
                } else if (std.mem.eql(u8, w, "function")) {
                    l.after = .function_name;
                    l.cmd = false;
                } else if (hl == .keyword_storage) {
                    l.decl = true;
                    l.cmd = false;
                } else if (std.mem.eql(u8, w, "[[") or std.mem.eql(u8, w, "return") or std.mem.eql(u8, w, "exit") or
                    std.mem.eql(u8, w, "esac") or std.mem.eql(u8, w, "fi") or std.mem.eql(u8, w, "done") or
                    std.mem.eql(u8, w, "]]") or std.mem.eql(u8, w, "break") or std.mem.eql(u8, w, "continue"))
                {
                    l.cmd = false;
                }
                return;
            }
            if (std.mem.eql(u8, w, "{") or std.mem.eql(u8, w, "}")) {
                l.emit(start, Kind.bracket, .punctuation_bracket);
                return;
            }
            l.emit(start, Kind.command, Builtins.get(w) orelse .function);
            l.cmd = false;
            return;
        }
        if (std.mem.eql(u8, w, "]]")) {
            l.emit(start, Kind.keyword, .keyword);
            return;
        }
        if (allDigits(w)) {
            l.emit(start, Kind.number, .number);
            return;
        }
        l.emit(start, Kind.word, .none);
    }

    /// Code context: the top level, `$( )`, backticks, `( )` and arrays.
    fn code(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        const c = line[start];
        const top = l.d.top();
        if (l.d.case_pat) switch (c) {
            // Pattern syntax: `(a|b)`.
            '(', '|' => return l.single(Kind.operator, .operator),
            ')' => {
                l.single(Kind.operator, .operator);
                l.d.case_pat = false;
                l.cmd = true;
                return;
            },
            else => {},
        };
        switch (c) {
            ' ', '\t', '\r' => {
                _ = s.eatWhile(isSpaceB);
                l.emit(start, Kind.ws, .none);
            },
            '#' => if (start == 0 or isSpaceB(line[start - 1]) or std.mem.indexOfScalar(u8, ";&|(", line[start - 1]) != null) {
                s.skipToEnd();
                l.emit(start, Kind.comment, .comment);
            } else l.word(),
            '"' => {
                l.argSeen();
                l.single(Kind.string, .string);
                l.d.push(Ctx.dquote);
                l.cmd = false;
            },
            '\'' => {
                l.argSeen();
                l.single(Kind.string, .string);
                l.d.push(Ctx.squote);
                l.cmd = false;
            },
            '$' => {
                l.argSeen();
                l.dollar(true);
                if (l.d.top() != Ctx.cmdsubst) l.cmd = false;
            },
            '`' => {
                l.single(Kind.dollar, .punctuation);
                if (top == Ctx.backtick) {
                    l.d.pop();
                    l.cmd = false;
                } else {
                    l.d.push(Ctx.backtick);
                    l.cmd = true;
                }
            },
            '\\' => l.backslash(),
            '(' => {
                if (l.cmd and s.peekAt(1) == '(') {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.d.push(Ctx.arith);
                    l.cmd = false;
                    return;
                }
                l.single(Kind.bracket, .punctuation_bracket);
                l.d.push(if (top == Ctx.array) Ctx.array else Ctx.paren);
                l.cmd = top != Ctx.array;
            },
            ')' => {
                if (top == Ctx.cmdsubst or top == Ctx.paren or top == Ctx.array) {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.d.pop();
                } else {
                    // A `case` pattern end, or unbalanced.
                    l.single(Kind.operator, .operator);
                    l.cmd = true;
                    return;
                }
                l.cmd = false;
            },
            ';' => {
                s.advance();
                _ = s.eatByte(';');
                _ = s.eatByte('&');
                l.emit(start, Kind.separator, .punctuation_delimiter);
                l.cmd = true;
                l.decl = false;
                l.expect_in = .no;
                // `;;`, `;&` and `;;&` end a `case` branch.
                if (s.pos - start >= 2) l.d.case_pat = true;
            },
            '|' => {
                s.advance();
                _ = s.eatByte('|') or s.eatByte('&');
                l.emit(start, Kind.operator, .operator);
                l.cmd = true;
                l.decl = false;
            },
            '&' => {
                s.advance();
                if (s.eatByte('>')) {
                    // `&>` and `&>>` redirect output.
                    _ = s.eatByte('>');
                    l.emit(start, Kind.operator, .operator);
                    return;
                }
                _ = s.eatByte('&');
                l.emit(start, Kind.operator, .operator);
                l.cmd = true;
                l.decl = false;
            },
            '<' => {
                s.advance();
                if (s.eatByte('<')) {
                    if (s.eatByte('<')) {
                        l.emit(start, Kind.operator, .operator);
                        return;
                    }
                    l.heredoc(start, s.eatByte('-'));
                    return;
                }
                _ = s.eatByte('&') or s.eatByte('>') or s.eatByte('(');
                if (s.line[s.pos - 1] == '(') {
                    // Process substitution `<( )`.
                    l.emit(start, Kind.operator, .operator);
                    l.d.push(Ctx.cmdsubst);
                    l.cmd = true;
                    return;
                }
                l.emit(start, Kind.operator, .operator);
            },
            '>' => {
                s.advance();
                _ = s.eatByte('>') or s.eatByte('&') or s.eatByte('|') or s.eatByte('(');
                if (s.line[s.pos - 1] == '(') {
                    l.emit(start, Kind.operator, .operator);
                    l.d.push(Ctx.cmdsubst);
                    l.cmd = true;
                    return;
                }
                l.emit(start, Kind.operator, .operator);
            },
            else => l.word(),
        }
    }

    /// Inside double quotes: text, escapes, expansions and backticks.
    fn dquote(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        switch (line[start]) {
            '"' => {
                l.single(Kind.string, .string);
                l.d.pop();
            },
            '\\' => {
                const n = s.peekAt(1);
                if (n == null or n == '$' or n == '`' or n == '"' or n == '\\') {
                    s.advanceBy(if (n == null) 1 else 2);
                    l.emit(start, Kind.str_escape, .string_escape);
                } else {
                    s.advanceBy(2);
                    l.emit(start, Kind.string, .string);
                }
            },
            '$' => l.dollar(false),
            '`' => {
                l.single(Kind.dollar, .punctuation);
                l.d.push(Ctx.backtick);
                l.cmd = true;
            },
            else => {
                s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, "\"\\$`") orelse line.len);
                l.emit(start, Kind.string, .string);
            },
        }
    }

    /// Inside single quotes (no escapes) or `$' '` (backslash escapes).
    fn squote(l: *Lexer, ansi: bool) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        if (line[start] == '\'') {
            l.single(Kind.string, .string);
            l.d.pop();
            return;
        }
        if (ansi and line[start] == '\\') {
            s.advanceBy(@min(2, line.len - start));
            l.emit(start, Kind.str_escape, .string_escape);
            return;
        }
        s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, if (ansi) "'\\" else "'") orelse line.len);
        l.emit(start, Kind.string, .string);
    }

    /// Inside `${ }`.
    fn param(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        switch (line[start]) {
            '}' => {
                l.single(Kind.bracket, .punctuation_bracket);
                l.d.pop();
            },
            '$' => l.dollar(false),
            '"' => {
                l.single(Kind.string, .string);
                l.d.push(Ctx.dquote);
            },
            '\'' => {
                l.single(Kind.string, .string);
                l.d.push(Ctx.squote);
            },
            '`' => {
                l.single(Kind.dollar, .punctuation);
                l.d.push(Ctx.backtick);
                l.cmd = true;
            },
            '\\' => {
                s.advanceBy(@min(2, line.len - start));
                l.emit(start, Kind.str_escape, .string_escape);
            },
            else => {
                s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, "}$\"'`\\") orelse line.len);
                l.emit(start, Kind.param, .variable);
            },
        }
    }

    /// Inside `$(( ))` / `(( ))`.
    fn arith(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        const c = line[start];
        switch (c) {
            ' ', '\t', '\r' => {
                _ = s.eatWhile(isSpaceB);
                l.emit(start, Kind.ws, .none);
            },
            '$' => l.dollar(false),
            '(' => {
                l.single(Kind.bracket, .punctuation_bracket);
                l.d.push(Ctx.paren);
            },
            ')' => {
                if (l.d.top() == Ctx.arith and s.peekAt(1) == ')') {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.d.pop();
                } else {
                    l.single(Kind.bracket, .punctuation_bracket);
                    l.d.pop();
                }
            },
            '"' => {
                l.single(Kind.string, .string);
                l.d.push(Ctx.dquote);
            },
            '`' => {
                l.single(Kind.dollar, .punctuation);
                l.d.push(Ctx.backtick);
                l.cmd = true;
            },
            '\\' => l.backslash(),
            '0'...'9' => {
                _ = s.eatWhile(isNameByte);
                if (s.peek() == '#') {
                    s.advance();
                    _ = s.eatWhile(isNameByte);
                }
                l.emit(start, Kind.number, .number);
            },
            else => if (std.ascii.isAlphabetic(c) or c == '_') {
                _ = s.eatWhile(isNameByte);
                l.emit(start, Kind.variable, .variable);
            } else {
                s.advance();
                _ = s.eatWhile(struct {
                    fn f(b: u8) bool {
                        return std.mem.indexOfScalar(u8, "+-*/%<>=!&|^~?:,", b) != null;
                    }
                }.f);
                l.emit(start, Kind.operator, .operator);
            },
        }
    }

    /// A here-document body line (the whole line).
    fn body(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const doc = l.d.firstDoc();
        var t = line;
        if (t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
        var lead: usize = 0;
        if (doc[1] & strip_tabs != 0) {
            while (lead < t.len and t[lead] == '\t') lead += 1;
        }
        if (std.mem.eql(u8, t[lead..], doc[0])) {
            if (lead > 0) l.emit(0, Kind.ws, .none);
            if (lead < line.len) l.emit(@intCast(lead), Kind.heredoc_end, .label);
            s.skipToEnd();
            l.d.dropFirstDoc();
            return;
        }
        if (line.len == 0) return;
        if (doc[1] & quoted != 0) {
            l.emit(0, Kind.heredoc_body, .string);
            s.skipToEnd();
            return;
        }
        // Unquoted: parameter and command expansions show as variables.
        while (s.pos < line.len) {
            const start = s.pos;
            const c = line[start];
            if (c == '\\' and start + 1 < line.len) {
                s.advanceBy(2);
                l.emit(start, Kind.str_escape, .string_escape);
            } else if (c == '$' and start + 1 < line.len and (line[start + 1] == '{' or line[start + 1] == '(')) {
                // A one-line `${ }` or `$( )`, balanced.
                const open = line[start + 1];
                const close: u8 = if (open == '{') '}' else ')';
                var depth: usize = 0;
                var i: usize = start + 1;
                while (i < line.len) : (i += 1) {
                    if (line[i] == open) depth += 1;
                    if (line[i] == close) {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    }
                }
                s.pos = @intCast(i);
                l.emit(start, Kind.variable, .variable);
            } else if (c == '$' and start + 1 < line.len and (isNameByte(line[start + 1]) or isSpecialParam(line[start + 1]))) {
                s.advance();
                if (isSpecialParam(s.peek().?) and !std.ascii.isAlphabetic(s.peek().?)) s.advance() else _ = s.eatWhile(isNameByte);
                l.emit(start, Kind.variable, .variable);
            } else {
                s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, "\\$") orelse line.len);
                l.emit(start, Kind.heredoc_body, .string);
            }
        }
    }
};

fn allName(w: []const u8) bool {
    for (w) |b| if (!isNameByte(b)) return false;
    return true;
}

fn allDigits(w: []const u8) bool {
    if (w.len == 0) return false;
    for (w) |b| if (!std.ascii.isDigit(b)) return false;
    return true;
}

fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    var sc = s_in.*;
    defer s_in.* = sc;
    var l: Lexer = .{ .s = &sc, .out = out, .d = .decode(st), .cmd = false };
    defer l.d.encode(st);
    if (l.d.in_body and l.d.ndocs > 0) {
        l.body();
        return;
    }
    l.cmd = !l.d.continued;
    l.d.continued = false;
    const line = sc.line;
    while (sc.pos < line.len) {
        switch (l.d.top()) {
            Ctx.dquote => l.dquote(),
            Ctx.squote => l.squote(false),
            Ctx.ansi => l.squote(true),
            Ctx.param => l.param(),
            Ctx.arith => l.arith(),
            else => l.code(),
        }
    }
    // Queued here-documents start on the next line.
    if (l.d.ndocs > 0) l.d.in_body = true;
}

fn resync(line: []const u8) bool {
    // A function definition at column 0.
    if (line.len == 0 or !(std.ascii.isAlphabetic(line[0]) or line[0] == '_')) return false;
    return std.mem.startsWith(u8, line, "function ") or std.mem.indexOf(u8, line, "() {") != null;
}

/// The shell language definition (sh, bash, zsh, ksh).
pub const shell_language: language.Language = .{
    .id = .shell,
    .name = "shell",
    .aliases = &.{ "sh", "bash", "zsh", "ksh" },
    .extensions = &.{ ".sh", ".bash", ".zsh", ".ksh" },
    .filenames = &.{ "PKGBUILD", ".bashrc", ".bash_profile", ".bash_logout", ".profile", ".zshrc", ".zprofile", ".zshenv", ".kshrc" },
    .shebangs = &.{ "sh", "bash", "zsh", "ksh", "dash" },
    .lexer = .{ .lexLineFn = lexLine },
    .resync = resync,
    .decl_keywords = &.{.{ .word = "function", .kind = .function }},
    .edit_rules = .{
        .line_comment = "#",
        .auto_close = &.{
            .{ .open = "(", .close = ")" },
            .{ .open = "[", .close = "]" },
            .{ .open = "{", .close = "}" },
            .{ .open = "\"", .close = "\"" },
            .{ .open = "'", .close = "'" },
            .{ .open = "`", .close = "`" },
        },
        .insert_spaces = true,
        .indent_after = &.{ "then", "do", "else", "{", "(", "in" },
        .dedent_on = &.{ "fi", "done", "esac", "else", "elif", "}", ")" },
    },
    .brackets = &.{
        .{ .open = "(", .close = ")" },
        .{ .open = "{", .close = "}" },
    },
};
