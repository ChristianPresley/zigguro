//! Revset tokens. Symbols are runs of letters, digits, `_`, `/` and
//! non-ASCII bytes, with `.`, `-` and `+` allowed between them (so
//! `release-1.2` is one symbol and `main-` is `main` then `-`).

const std = @import("std");
const ast = @import("ast.zig");
const Span = ast.Span;

pub const Tag = enum {
    symbol,
    /// A quoted string; `text` is the decoded value.
    string,
    at,
    colon,
    dag,
    range,
    amp,
    pipe,
    tilde,
    minus,
    plus,
    lparen,
    rparen,
    comma,
    eof,
};

pub const Token = struct {
    tag: Tag,
    span: Span,
    /// Symbol text, or the decoded string.
    text: []const u8 = "",
};

pub const Error = error{ InvalidCharacter, UnterminatedString, InvalidEscape, OutOfMemory };

pub const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    /// Decoded strings.
    arena: std.mem.Allocator,
    /// Where the last error happened.
    err_span: Span = .{ 0, 0 },

    pub fn next(l: *Lexer) Error!Token {
        while (l.i < l.src.len and std.ascii.isWhitespace(l.src[l.i])) l.i += 1;
        const start: u32 = @intCast(l.i);
        if (l.i >= l.src.len) return .{ .tag = .eof, .span = .{ start, start } };
        const c = l.src[l.i];
        if (ast.isSymbolChar(c)) return l.symbol();
        if (c == '"' or c == '\'') return l.string();
        const two: ?Tag = if (l.i + 1 < l.src.len) switch (c) {
            ':' => if (l.src[l.i + 1] == ':') .dag else null,
            '.' => if (l.src[l.i + 1] == '.') .range else null,
            else => null,
        } else null;
        if (two) |t| {
            l.i += 2;
            return .{ .tag = t, .span = .{ start, start + 2 } };
        }
        const tag: Tag = switch (c) {
            '@' => .at,
            ':' => .colon,
            '&' => .amp,
            '|' => .pipe,
            '~' => .tilde,
            '-' => .minus,
            '+' => .plus,
            '(' => .lparen,
            ')' => .rparen,
            ',' => .comma,
            else => {
                l.err_span = .{ start, start + 1 };
                return error.InvalidCharacter;
            },
        };
        l.i += 1;
        return .{ .tag = tag, .span = .{ start, start + 1 } };
    }

    fn symbol(l: *Lexer) Token {
        const start = l.i;
        while (l.i < l.src.len) {
            const c = l.src[l.i];
            if (ast.isSymbolChar(c)) {
                l.i += 1;
            } else if ((c == '.' or c == '-' or c == '+') and l.i + 1 < l.src.len and ast.isSymbolChar(l.src[l.i + 1]) and
                !(c == '.' and l.i + 1 < l.src.len and l.src[l.i + 1] == '.'))
            {
                l.i += 1;
            } else break;
        }
        return .{ .tag = .symbol, .span = .{ @intCast(start), @intCast(l.i) }, .text = l.src[start..l.i] };
    }

    fn string(l: *Lexer) Error!Token {
        const start = l.i;
        const q = l.src[l.i];
        l.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (l.i >= l.src.len) {
                l.err_span = .{ @intCast(start), @intCast(l.i) };
                return error.UnterminatedString;
            }
            const c = l.src[l.i];
            l.i += 1;
            if (c == q) break;
            // Single-quoted strings are raw.
            if (c != '\\' or q == '\'') {
                try out.append(l.arena, c);
                continue;
            }
            if (l.i >= l.src.len) continue;
            const e = l.src[l.i];
            l.i += 1;
            switch (e) {
                '"' => try out.append(l.arena, '"'),
                '\\' => try out.append(l.arena, '\\'),
                'n' => try out.append(l.arena, '\n'),
                't' => try out.append(l.arena, '\t'),
                'x' => {
                    if (l.i + 2 > l.src.len) {
                        l.err_span = .{ @intCast(l.i - 2), @intCast(l.src.len) };
                        return error.InvalidEscape;
                    }
                    const v = std.fmt.parseInt(u8, l.src[l.i..][0..2], 16) catch {
                        l.err_span = .{ @intCast(l.i - 2), @intCast(l.i + 2) };
                        return error.InvalidEscape;
                    };
                    try out.append(l.arena, v);
                    l.i += 2;
                },
                else => {
                    l.err_span = .{ @intCast(l.i - 2), @intCast(l.i) };
                    return error.InvalidEscape;
                },
            }
        }
        return .{ .tag = .string, .span = .{ @intCast(start), @intCast(l.i) }, .text = out.items };
    }
};
