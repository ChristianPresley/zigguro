//! Tokens of the data query language (E13.F06.S02.T01).
//!
//! Identifiers are letters, digits and `_` (not starting with a digit),
//! or any text in backticks (a doubled backtick for a literal one).
//! Strings use double or single quotes with `\"`, `\'`, `\\`, `\n`, `\t`
//! and `\r` escapes. Numbers are ints or floats (`.`, exponent); an
//! unquoted `YYYY-MM-DD` is a date and `YYYY-MM-DDTHH:MM:SS[.f][Z|±HH:MM]`
//! a datetime. `#` starts a comment to the end of the line.

const std = @import("std");
const ast = @import("ast.zig");
const infer = @import("../infer.zig");

const Span = ast.Span;

pub const Tag = enum {
    ident,
    /// A backtick identifier (never a keyword).
    quoted_ident,
    string,
    int,
    float,
    date,
    datetime,
    pipe,
    comma,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    assign,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    plus,
    minus,
    star,
    slash,
    percent,
    eof,
    invalid,
};

pub const Token = struct {
    tag: Tag,
    span: Span,
    /// Identifier or string text with escapes undone (a slice of the
    /// source when there were none).
    text: []const u8 = "",
};

pub const max_len = 64 << 10;

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    /// Why the last `invalid` token was invalid.
    err: []const u8 = "",

    pub fn init(arena: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .arena = arena };
    }

    fn tok(l: *Lexer, tag: Tag, start: usize) Token {
        return .{ .tag = tag, .span = .{ .start = @intCast(start), .end = @intCast(l.pos) }, .text = l.src[start..l.pos] };
    }

    fn invalid(l: *Lexer, start: usize, why: []const u8) Token {
        l.err = why;
        return l.tok(.invalid, start);
    }

    pub fn next(l: *Lexer) std.mem.Allocator.Error!Token {
        const s = l.src;
        while (l.pos < s.len) {
            const c = s[l.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                l.pos += 1;
            } else if (c == '#') {
                while (l.pos < s.len and s[l.pos] != '\n') l.pos += 1;
            } else break;
        }
        const start = l.pos;
        if (l.pos >= s.len) return l.tok(.eof, start);
        const c = s[l.pos];
        l.pos += 1;
        const two = if (l.pos < s.len) s[l.pos] else 0;
        switch (c) {
            '|' => return l.tok(.pipe, start),
            ',' => return l.tok(.comma, start),
            '(' => return l.tok(.lparen, start),
            ')' => return l.tok(.rparen, start),
            '[' => return l.tok(.lbracket, start),
            ']' => return l.tok(.rbracket, start),
            '{' => return l.tok(.lbrace, start),
            '}' => return l.tok(.rbrace, start),
            '+' => return l.tok(.plus, start),
            '-' => return l.tok(.minus, start),
            '*' => return l.tok(.star, start),
            '/' => return l.tok(.slash, start),
            '%' => return l.tok(.percent, start),
            '=' => {
                if (two == '=') {
                    l.pos += 1;
                    return l.tok(.eq, start);
                }
                return l.tok(.assign, start);
            },
            '!' => {
                if (two == '=') {
                    l.pos += 1;
                    return l.tok(.ne, start);
                }
                return l.invalid(start, "unexpected `!` (use `not` or `!=`)");
            },
            '<' => {
                if (two == '=') {
                    l.pos += 1;
                    return l.tok(.le, start);
                }
                if (two == '>') {
                    l.pos += 1;
                    return l.tok(.ne, start);
                }
                return l.tok(.lt, start);
            },
            '>' => {
                if (two == '=') {
                    l.pos += 1;
                    return l.tok(.ge, start);
                }
                return l.tok(.gt, start);
            },
            '"', '\'' => return l.string(start, c),
            '`' => return l.backtick(start),
            '0'...'9' => return l.number(start),
            '.' => {
                if (std.ascii.isDigit(two)) return l.number(start);
                return l.invalid(start, "unexpected `.`");
            },
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80) {
                    while (l.pos < s.len and (std.ascii.isAlphanumeric(s[l.pos]) or s[l.pos] == '_' or s[l.pos] >= 0x80)) l.pos += 1;
                    return l.tok(.ident, start);
                }
                return l.invalid(start, "unexpected character");
            },
        }
    }

    fn string(l: *Lexer, start: usize, q: u8) !Token {
        const s = l.src;
        var esc = false;
        while (l.pos < s.len and s[l.pos] != q) {
            if (s[l.pos] == '\\') {
                esc = true;
                l.pos += 1;
            }
            l.pos += 1;
        }
        if (l.pos >= s.len) {
            l.pos = s.len;
            return l.invalid(start, "unterminated string");
        }
        l.pos += 1;
        var t = l.tok(.string, start);
        const body = s[start + 1 .. l.pos - 1];
        if (!esc) {
            t.text = body;
            return t;
        }
        var out: std.ArrayList(u8) = try .initCapacity(l.arena, body.len);
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\\' and i + 1 < body.len) {
                i += 1;
                out.appendAssumeCapacity(switch (body[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => body[i],
                });
            } else out.appendAssumeCapacity(body[i]);
        }
        t.text = out.items;
        return t;
    }

    fn backtick(l: *Lexer, start: usize) !Token {
        const s = l.src;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (l.pos >= s.len) return l.invalid(start, "unterminated `quoted` name");
            if (s[l.pos] == '`') {
                if (l.pos + 1 < s.len and s[l.pos + 1] == '`') {
                    try out.append(l.arena, '`');
                    l.pos += 2;
                    continue;
                }
                l.pos += 1;
                break;
            }
            try out.append(l.arena, s[l.pos]);
            l.pos += 1;
        }
        var t = l.tok(.quoted_ident, start);
        t.text = out.items;
        if (t.text.len == 0) return l.invalid(start, "empty `quoted` name");
        return t;
    }

    fn number(l: *Lexer, start: usize) Token {
        const s = l.src;
        // Dates and datetimes first: YYYY-MM-DD...
        if (start + 10 <= s.len and s[start + 4] == '-' and s[start + 7] == '-' and allDigits(s[start .. start + 4])) {
            var end = start + 10;
            if (end < s.len and (s[end] == 'T' or s[end] == 't')) {
                end += 1;
                while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == ':' or s[end] == '.' or s[end] == 'Z' or s[end] == 'z' or s[end] == '+' or s[end] == '-')) end += 1;
                l.pos = end;
                if (infer.parseDatetime(s[start..end]) == null) return l.invalid(start, "invalid datetime");
                return l.tok(.datetime, start);
            }
            l.pos = end;
            if (end < s.len and (std.ascii.isAlphanumeric(s[end]) or s[end] == '_')) {
                while (l.pos < s.len and std.ascii.isAlphanumeric(s[l.pos])) l.pos += 1;
                return l.invalid(start, "invalid date");
            }
            if (infer.parseIsoDate(s[start..end]) == null) return l.invalid(start, "invalid date");
            return l.tok(.date, start);
        }
        var float = s[start] == '.';
        while (l.pos < s.len and std.ascii.isDigit(s[l.pos])) l.pos += 1;
        if (l.pos < s.len and s[l.pos] == '.' and l.pos + 1 < s.len and std.ascii.isDigit(s[l.pos + 1])) {
            float = true;
            l.pos += 1;
            while (l.pos < s.len and std.ascii.isDigit(s[l.pos])) l.pos += 1;
        }
        if (l.pos < s.len and (s[l.pos] == 'e' or s[l.pos] == 'E')) {
            var p = l.pos + 1;
            if (p < s.len and (s[p] == '+' or s[p] == '-')) p += 1;
            if (p < s.len and std.ascii.isDigit(s[p])) {
                float = true;
                l.pos = p;
                while (l.pos < s.len and std.ascii.isDigit(s[l.pos])) l.pos += 1;
            }
        }
        if (l.pos < s.len and (std.ascii.isAlphabetic(s[l.pos]) or s[l.pos] == '_')) {
            while (l.pos < s.len and (std.ascii.isAlphanumeric(s[l.pos]) or s[l.pos] == '_')) l.pos += 1;
            return l.invalid(start, "invalid number");
        }
        return l.tok(if (float) .float else .int, start);
    }
};

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
