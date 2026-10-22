//! CSS (CSS Syntax Level 3 §4 tokens). The brace depth (`depth`) decides
//! selectors versus declarations; inside a block a line whose `{` comes
//! before any `;` or `}` is a nested selector. `mode` keeps a block
//! comment, a value that continues on the next line and an at-rule
//! prelude.

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
    pub const comment: u16 = 2;
    pub const at_rule: u16 = 3 | atomic;
    pub const selector: u16 = 4 | atomic;
    pub const property: u16 = 5 | atomic;
    pub const value: u16 = 6 | atomic;
    pub const number: u16 = 7 | atomic;
    pub const string: u16 = 8;
    pub const str_escape: u16 = 9;
    pub const function: u16 = 10 | atomic;
    pub const url: u16 = 11 | atomic;
    pub const hash: u16 = 12 | atomic;
    pub const important: u16 = 13 | atomic;
    pub const bracket: u16 = 14 | atomic;
    pub const punctuation: u16 = 15 | atomic;
    pub const operator: u16 = 16 | atomic;
    pub const invalid: u16 = 17;
};

/// `mode` bits.
pub const Bits = struct {
    pub const block_comment: u16 = 1;
    /// After a declaration's `:`, until `;` or `}`.
    pub const value: u16 = 2;
    /// After an at-rule name, until `{` or `;`.
    pub const prelude: u16 = 4;
};

fn isSpaceB(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == 0x0c;
}

fn isNameStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_' or b >= 0x80 or b == '\\';
}

fn isName(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b >= 0x80 or b == '\\';
}

/// Whether an identifier starts at `i`: a name start, or `-` followed by
/// a name start or another `-`.
fn identAt(line: []const u8, i: usize) bool {
    if (i >= line.len) return false;
    if (isNameStart(line[i])) return true;
    return line[i] == '-' and i + 1 < line.len and (isNameStart(line[i + 1]) or line[i + 1] == '-');
}

/// The end of the identifier at `i` (escapes take the next byte along).
fn identEnd(line: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < line.len and isName(line[i])) {
        if (line[i] == '\\') i += 1;
        i += 1;
    }
    return @min(i, line.len);
}

/// Whether a number starts at `i`.
fn numberAt(line: []const u8, i: usize) bool {
    if (i >= line.len) return false;
    const c = line[i];
    if (std.ascii.isDigit(c)) return true;
    if (c == '.') return i + 1 < line.len and std.ascii.isDigit(line[i + 1]);
    if (c == '+' or c == '-') return i + 1 < line.len and (std.ascii.isDigit(line[i + 1]) or (line[i + 1] == '.' and i + 2 < line.len and std.ascii.isDigit(line[i + 2])));
    return false;
}

const Lexer = struct {
    st: *LexState,
    s: *Scanner,
    out: *TokenSink,
    /// Inside `[ ]` of a selector.
    in_attr: bool = false,

    fn emit(l: *Lexer, start: u32, kind: u16, hl: HighlightId) void {
        l.s.emit(l.out, start, kind, hl);
    }

    fn single(l: *Lexer, kind: u16, hl: HighlightId) void {
        const start = l.s.pos;
        l.s.advance();
        l.emit(start, kind, hl);
    }

    fn blockComment(l: *Lexer, start: u32) void {
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

    fn string(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const q = line[s.pos];
        l.single(Kind.string, .string);
        while (s.pos < line.len) {
            const start = s.pos;
            const c = line[start];
            if (c == q) {
                l.single(Kind.string, .string);
                return;
            }
            if (c == '\\') {
                s.advanceBy(@min(2, line.len - start));
                l.emit(start, Kind.str_escape, .string_escape);
                continue;
            }
            s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, if (q == '"') "\"\\" else "'\\") orelse line.len);
            l.emit(start, Kind.string, .string);
        }
    }

    fn number(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        var i: usize = start;
        if (line[i] == '+' or line[i] == '-') i += 1;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i + 1 < line.len and line[i] == '.' and std.ascii.isDigit(line[i + 1])) {
            i += 1;
            while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        }
        if (i + 1 < line.len and (line[i] == 'e' or line[i] == 'E') and (std.ascii.isDigit(line[i + 1]) or
            ((line[i + 1] == '+' or line[i + 1] == '-') and i + 2 < line.len and std.ascii.isDigit(line[i + 2]))))
        {
            i += 2;
            while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        }
        // The unit or `%`.
        if (i < line.len and line[i] == '%') {
            i += 1;
        } else if (identAt(line, i)) i = identEnd(line, i);
        s.pos = @intCast(i);
        l.emit(start, Kind.number, .number);
    }

    /// Whether the declaration-position text from the cursor is a nested
    /// selector: a `{` comes before any `;` or `}` on the line.
    fn nestedSelector(l: *const Lexer) bool {
        const line = l.s.line;
        var i: usize = l.s.pos;
        while (i < line.len) : (i += 1) switch (line[i]) {
            '{' => return true,
            ';', '}' => return false,
            '"', '\'' => {
                const q = line[i];
                i += 1;
                while (i < line.len and line[i] != q) : (i += 1) {
                    if (line[i] == '\\') i += 1;
                }
                if (i >= line.len) return false;
            },
            else => {},
        };
        return false;
    }

    /// Tokens shared by every context; returns false when the byte is not
    /// one of them.
    fn common(l: *Lexer) bool {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        switch (line[start]) {
            ' ', '\t', '\r', 0x0c => {
                _ = s.eatWhile(isSpaceB);
                l.emit(start, Kind.ws, .none);
            },
            '/' => if (s.peekAt(1) == '*') {
                s.advanceBy(2);
                l.blockComment(start);
            } else return false,
            '"', '\'' => l.string(),
            '{' => {
                l.single(Kind.bracket, .punctuation_bracket);
                l.st.depth +|= 1;
                l.st.mode &= ~(Bits.value | Bits.prelude);
                l.in_attr = false;
            },
            '}' => {
                l.single(Kind.bracket, .punctuation_bracket);
                l.st.depth -|= 1;
                l.st.mode &= ~(Bits.value | Bits.prelude);
            },
            ';' => {
                l.single(Kind.punctuation, .punctuation_delimiter);
                l.st.mode &= ~(Bits.value | Bits.prelude);
            },
            '@' => if (identAt(line, start + 1)) {
                s.pos = @intCast(identEnd(line, start + 1));
                l.emit(start, Kind.at_rule, .keyword);
                l.st.mode |= Bits.prelude;
                l.st.mode &= ~Bits.value;
            } else return false,
            else => return false,
        }
        return true;
    }

    /// A function name and its `(`; `url(` with an unquoted argument takes
    /// the argument as one string.
    fn function(l: *Lexer, start: u32, end: usize) void {
        const s = l.s;
        const line = s.line;
        s.pos = @intCast(end);
        const name = line[start..end];
        const is_url = std.ascii.eqlIgnoreCase(name, "url");
        l.emit(start, Kind.function, .function_builtin);
        l.single(Kind.bracket, .punctuation_bracket);
        if (!is_url) return;
        var i: usize = s.pos;
        while (i < line.len and isSpaceB(line[i])) i += 1;
        if (i < line.len and (line[i] == '"' or line[i] == '\'')) return;
        const close = std.mem.indexOfScalarPos(u8, line, s.pos, ')') orelse line.len;
        if (close > s.pos) {
            const u = s.pos;
            s.pos = @intCast(close);
            l.emit(u, Kind.url, .string_special);
        }
        if (s.pos < line.len) l.single(Kind.bracket, .punctuation_bracket);
    }

    /// Selectors (and at-rule preludes, which share the token shapes).
    fn selector(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        const c = line[start];
        const prelude = l.st.mode & Bits.prelude != 0;
        if (std.ascii.isDigit(c) or (prelude and numberAt(line, start))) return l.number();
        switch (c) {
            '.' => if (identAt(line, start + 1)) {
                s.pos = @intCast(identEnd(line, start + 1));
                l.emit(start, Kind.selector, .type);
            } else l.single(Kind.punctuation, .punctuation_delimiter),
            '#' => {
                s.advance();
                s.pos = @intCast(identEnd(line, s.pos));
                l.emit(start, Kind.selector, .label);
            },
            ':' => {
                s.advance();
                _ = s.eatByte(':');
                if (identAt(line, s.pos)) {
                    s.pos = @intCast(identEnd(line, s.pos));
                    l.emit(start, Kind.selector, .attribute);
                    if (s.peek() == '(') l.single(Kind.bracket, .punctuation_bracket);
                } else l.emit(start, Kind.punctuation, .punctuation_delimiter);
            },
            '[' => {
                l.single(Kind.bracket, .punctuation_bracket);
                l.in_attr = true;
            },
            ']' => {
                l.single(Kind.bracket, .punctuation_bracket);
                l.in_attr = false;
            },
            '(', ')' => l.single(Kind.bracket, .punctuation_bracket),
            ',' => l.single(Kind.punctuation, .punctuation_delimiter),
            '>', '+', '~', '*', '&', '|', '=', '^', '$' => {
                s.advance();
                _ = s.eatByte('=');
                l.emit(start, Kind.operator, .operator);
            },
            else => if (identAt(line, start)) {
                const end = identEnd(line, start);
                const w = line[start..end];
                if (end < line.len and line[end] == '(') return l.function(start, end);
                s.pos = @intCast(end);
                if (l.in_attr) {
                    l.emit(start, Kind.selector, .property);
                } else if (prelude) {
                    const op = std.mem.eql(u8, w, "and") or std.mem.eql(u8, w, "not") or std.mem.eql(u8, w, "only") or std.mem.eql(u8, w, "or");
                    const feature = s.peek() == ':';
                    l.emit(start, Kind.value, if (op) .keyword_operator else if (feature) .property else .constant);
                } else l.emit(start, Kind.selector, .tag);
            } else l.single(Kind.invalid, .invalid),
        }
    }

    /// A declaration's property name and its `:`.
    fn property(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        const c = line[start];
        if (c == ':') {
            l.single(Kind.punctuation, .punctuation_delimiter);
            l.st.mode |= Bits.value;
            return;
        }
        if (identAt(line, start)) {
            s.pos = @intCast(identEnd(line, start));
            const custom = std.mem.startsWith(u8, line[start..s.pos], "--");
            l.emit(start, Kind.property, if (custom) .variable else .property);
            return;
        }
        // Legacy hacks such as `*zoom`, and stray bytes.
        l.single(Kind.operator, .operator);
    }

    /// A declaration value.
    fn value(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        const c = line[start];
        if (numberAt(line, start)) return l.number();
        if (identAt(line, start)) {
            const end = identEnd(line, start);
            if (end < line.len and line[end] == '(') return l.function(start, end);
            s.pos = @intCast(end);
            const custom = std.mem.startsWith(u8, line[start..end], "--");
            l.emit(start, Kind.value, if (custom) .variable else .constant);
            return;
        }
        switch (c) {
            '#' => {
                s.advance();
                _ = s.eatWhile(isName);
                l.emit(start, Kind.hash, .constant);
            },
            '!' => {
                s.advance();
                _ = s.eatWhile(isSpaceB);
                _ = s.eatWhile(isName);
                l.emit(start, Kind.important, .keyword);
            },
            '(', ')', '[', ']' => l.single(Kind.bracket, .punctuation_bracket),
            ',' => l.single(Kind.punctuation, .punctuation_delimiter),
            '/', '*', '+', '-', '=', '>', '<' => l.single(Kind.operator, .operator),
            ':' => l.single(Kind.punctuation, .punctuation_delimiter),
            else => l.single(Kind.invalid, .invalid),
        }
    }

    fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
        var sc = s_in.*;
        defer s_in.* = sc;
        var l: Lexer = .{ .st = st, .s = &sc, .out = out };
        if (st.mode & Bits.block_comment != 0) l.blockComment(0);
        // Whether the current declaration is a nested selector; decided at
        // its first token.
        var nested: ?bool = null;
        while (sc.pos < sc.line.len) {
            if (l.common()) {
                // A new statement starts after `{`, `}` and `;`.
                switch (sc.line[sc.pos - 1]) {
                    '{', '}', ';' => nested = null,
                    else => {},
                }
                continue;
            }
            if (st.mode & Bits.prelude != 0 or st.depth == 0) {
                l.selector();
            } else if (st.mode & Bits.value != 0) {
                l.value();
            } else {
                if (nested == null) nested = l.nestedSelector();
                if (nested.?) l.selector() else l.property();
            }
        }
    }
};

fn lexLine(st: *LexState, s: *Scanner, out: *TokenSink) void {
    Lexer.lexLine(st, s, out);
}

fn resync(line: []const u8) bool {
    // A rule or at-rule at column 0.
    return line.len > 0 and (isNameStart(line[0]) or line[0] == '.' or line[0] == '#' or line[0] == '@' or line[0] == ':' or line[0] == '[');
}

/// CSS.
pub const css_language: language.Language = .{
    .id = .css,
    .name = "css",
    .extensions = &.{".css"},
    .lexer = .{ .lexLineFn = lexLine },
    .resync = resync,
    .decl_keywords = &.{},
    .edit_rules = .{
        .block_comment = .{ .open = "/*", .close = "*/" },
        .auto_close = &.{
            .{ .open = "(", .close = ")" },
            .{ .open = "[", .close = "]" },
            .{ .open = "{", .close = "}" },
            .{ .open = "\"", .close = "\"" },
            .{ .open = "'", .close = "'" },
        },
        .insert_spaces = true,
        .indent_after = &.{"{"},
        .dedent_on = &.{"}"},
    },
    .brackets = &.{
        .{ .open = "{", .close = "}" },
        .{ .open = "(", .close = ")" },
        .{ .open = "[", .close = "]" },
    },
    .word_chars = &.{'-'},
};
