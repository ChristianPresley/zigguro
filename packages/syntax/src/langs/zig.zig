//! Zig, the reference language. The tier-1 lexer is hand-written for speed
//! and its token boundaries agree with `std.zig.Tokenizer` (checked by the
//! tests). Zig tokens never span lines (multiline strings are one `\\`
//! token per line), so every line ends in the initial state and an edit
//! relexes only the edited lines.

const std = @import("std");
const language = @import("../language.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;
const zig_ast_adapter = @import("../structure/zig_ast_adapter.zig");

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Zig token kinds. String pieces after the first (`str_escape`,
/// `str_cont`) continue the token before them in `std.zig.Tokenizer` terms.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    pub const doc_comment: u16 = 3;
    pub const string: u16 = 4 | atomic;
    pub const str_escape: u16 = 5;
    pub const str_cont: u16 = 6;
    pub const char: u16 = 7 | atomic;
    pub const multiline_string: u16 = 8;
    pub const number: u16 = 9 | atomic;
    pub const ident: u16 = 10 | atomic;
    pub const keyword: u16 = 11 | atomic;
    pub const builtin: u16 = 12 | atomic;
    pub const operator: u16 = 13 | atomic;
    pub const bracket: u16 = 14 | atomic;
    pub const punctuation: u16 = 15 | atomic;
    pub const invalid: u16 = 16;
};

const Tag = std.zig.Token.Tag;

fn keywordHl(tag: Tag) HighlightId {
    return switch (tag) {
        .keyword_if, .keyword_else, .keyword_switch, .keyword_while, .keyword_for, .keyword_break, .keyword_continue, .keyword_return, .keyword_try, .keyword_catch, .keyword_orelse, .keyword_defer, .keyword_errdefer, .keyword_unreachable, .keyword_suspend, .keyword_resume, .keyword_nosuspend => .keyword_control,
        .keyword_const, .keyword_var, .keyword_fn, .keyword_pub, .keyword_extern, .keyword_export, .keyword_inline, .keyword_noinline, .keyword_comptime, .keyword_threadlocal, .keyword_packed, .keyword_volatile, .keyword_allowzero, .keyword_align, .keyword_linksection, .keyword_callconv, .keyword_addrspace, .keyword_noalias => .keyword_storage,
        .keyword_and, .keyword_or => .keyword_operator,
        else => .keyword,
    };
}

fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}

fn isIdent(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn isNumberBody(b: u8) bool {
    return switch (b) {
        '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => true,
        else => false,
    };
}

fn isExp(b: u8) bool {
    return b == 'e' or b == 'E' or b == 'p' or b == 'P';
}

/// A number, following the tokenizer's int/float states.
inline fn number(s: *Scanner) void {
    s.advance();
    var float = false;
    while (s.peek()) |c| {
        if (isNumberBody(c)) {
            s.advance();
        } else if (isExp(c)) {
            s.advance();
            if (s.peek()) |d| if (d == '+' or d == '-') {
                s.advance();
                float = true;
            };
        } else if (c == '.' and !float) {
            const d = s.peekAt(1) orelse break;
            if (isNumberBody(d)) {
                s.advanceBy(2);
                float = true;
            } else if (isExp(d)) {
                s.advance();
                float = true;
            } else break;
        } else break;
    }
}

/// The body of a string, char or `@"..."` literal after its opening quote,
/// with escapes as separate tokens. Stops after the closing quote or at the
/// end of the line; a control byte makes the rest of the line invalid (as
/// in the tokenizer).
inline fn quoted(s: *Scanner, out: *TokenSink, quote: u8, hl: HighlightId) void {
    quotedBody(s, out, quote, hl) catch {
        s.emit(out, s.pos, Kind.invalid, .invalid);
        s.skipToEnd();
    };
}

inline fn quotedBody(s: *Scanner, out: *TokenSink, quote: u8, hl: HighlightId) error{Invalid}!void {
    while (s.peek()) |c| {
        if (c == quote) {
            s.advance();
            return;
        }
        if (c == '\\') {
            const start = s.pos;
            s.advance();
            const e = s.peek() orelse {
                s.emit(out, start, Kind.str_escape, .string_escape);
                return;
            };
            if (isControl(e)) return error.Invalid;
            s.advance();
            if (e == 'x') {
                var n: u32 = 0;
                while (n < 2 and s.peek() != null and std.ascii.isHex(s.peek().?)) : (n += 1) s.advance();
            } else if (e == 'u' and s.peek() == '{') {
                s.advance();
                while (s.peek()) |h| {
                    if (!std.ascii.isHex(h)) break;
                    s.advance();
                }
                _ = s.eatByte('}');
            }
            s.emit(out, start, Kind.str_escape, .string_escape);
            if (s.peek()) |n| if (n != '\\') s.emit(out, s.pos, Kind.str_cont, hl);
            continue;
        }
        if (isControl(c)) return error.Invalid;
        // Plain bytes up to the next quote, backslash or control byte.
        const line = s.line;
        var i: usize = s.pos + 1;
        while (i < line.len) : (i += 1) {
            const b = line[i];
            if (b == quote or b == '\\' or isControl(b)) break;
        }
        s.pos = @intCast(i);
    }
}

/// Bytes the tokenizer rejects inside literals (tab included).
fn isControl(b: u8) bool {
    return b < 0x20 or b == 0x7f;
}

const Ctx = struct {
    /// The previous significant token was `break` or `continue`.
    after_jump: bool = false,
    /// The previous significant token was `:` right after a jump.
    label_next: bool = false,
};

fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    _ = st;
    // Work on a local copy that never escapes, so the cursor stays in
    // registers instead of being reloaded after every token store.
    var sc = s_in.*;
    defer s_in.* = sc;
    const s = &sc;
    var cx: Ctx = .{};
    while (s.peek()) |c| {
        const start = s.pos;
        var jump = false;
        var colon_after_jump = false;
        switch (c) {
            ' ', '\t', '\r' => {
                _ = s.eatWhile(struct {
                    fn f(b: u8) bool {
                        return b == ' ' or b == '\t' or b == '\r';
                    }
                }.f);
                s.emit(out, start, Kind.ws, .none);
                continue;
            },
            '/' => if (s.eat("//")) {
                const doc = (s.peek() == '!') or (s.peek() == '/' and s.peekAt(1) != '/');
                s.skipToEnd();
                s.emit(out, start, if (doc) Kind.doc_comment else Kind.comment, if (doc) .comment_doc else .comment);
                continue;
            } else {
                s.advance();
                _ = s.eatByte('=');
                s.emit(out, start, Kind.operator, .operator);
            },
            '"' => {
                s.advance();
                s.emit(out, start, Kind.string, .string);
                quoted(s, out, '"', .string);
                cx = .{};
                continue;
            },
            '\'' => {
                s.advance();
                s.emit(out, start, Kind.char, .character);
                quoted(s, out, '\'', .character);
                cx = .{};
                continue;
            },
            '\\' => {
                if (s.peekAt(1) == '\\') {
                    s.skipToEnd();
                    s.emit(out, start, Kind.multiline_string, .string);
                } else {
                    s.skipToEnd();
                    s.emit(out, start, Kind.invalid, .invalid);
                }
                continue;
            },
            '@' => {
                s.advance();
                if (s.peek() == '"') {
                    s.advance();
                    s.emit(out, start, Kind.string, .variable);
                    quoted(s, out, '"', .variable);
                    cx = .{};
                    continue;
                } else if (s.peek() != null and isIdentStart(s.peek().?)) {
                    _ = s.eatWhile(isIdent);
                    s.emit(out, start, Kind.builtin, .function_builtin);
                } else {
                    s.skipToEnd();
                    s.emit(out, start, Kind.invalid, .invalid);
                    continue;
                }
            },
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
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
                colon_after_jump = cx.after_jump;
            },
            '.' => {
                s.advance();
                if (s.eatByte('.')) {
                    _ = s.eatByte('.');
                } else _ = s.eatByte('*');
                s.emit(out, start, Kind.operator, if (s.pos - start == 1) .punctuation_delimiter else .operator);
            },
            else => if (isIdentStart(c)) {
                _ = s.eatWhile(isIdent);
                const word = s.line[start..s.pos];
                if (reserved.get(word)) |r| switch (r) {
                    .keyword => |hl| {
                        s.emit(out, start, Kind.keyword, hl);
                        jump = std.mem.eql(u8, word, "break") or std.mem.eql(u8, word, "continue");
                    },
                    .value => s.emit(out, start, Kind.ident, if (cx.label_next) .label else .constant_builtin),
                    .type => s.emit(out, start, Kind.ident, if (cx.label_next) .label else .type_builtin),
                } else {
                    s.emit(out, start, Kind.ident, identHl(s, word, cx.label_next));
                }
            } else if (operatorLen(s.rest())) |n| {
                s.advanceBy(n);
                s.emit(out, start, Kind.operator, .operator);
            } else {
                // Invalid bytes (non-ASCII outside literals and comments): the
                // tokenizer's invalid token runs to the end of the line.
                s.skipToEnd();
                s.emit(out, start, Kind.invalid, .invalid);
                continue;
            },
        }
        cx = .{ .after_jump = jump, .label_next = colon_after_jump };
    }
}

/// A reserved word: a keyword, a primitive value, or a primitive type.
const Reserved = union(enum) { keyword: HighlightId, value, type };

/// Keywords and primitives in one open-addressing table keyed by a cheap
/// hash of the length and the first and last bytes, so an identifier
/// costs about one probe and at most one comparison.
const reserved = struct {
    const Entry = struct { word: []const u8 = "", r: Reserved = .value };
    const size = 512;

    fn hash(w: []const u8) usize {
        return ((@as(usize, w[0]) * 31 + w[w.len - 1]) * 31 + w.len * 7 + @as(usize, w[w.len / 2])) & (size - 1);
    }

    const table: [size]Entry = blk: {
        @setEvalBranchQuota(100_000);
        var t: [size]Entry = @splat(.{});
        const kws = std.zig.Token.keywords.keys();
        const prims = std.zig.primitives.names.keys();
        for (kws ++ prims) |w| {
            const r: Reserved = if (std.zig.Token.getKeyword(w)) |tag|
                .{ .keyword = keywordHl(tag) }
            else if (std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "false") or
                std.mem.eql(u8, w, "null") or std.mem.eql(u8, w, "undefined"))
                .value
            else
                .type;
            var i = hash(w);
            while (t[i].word.len != 0) i = (i + 1) & (size - 1);
            t[i] = .{ .word = w, .r = r };
        }
        break :blk t;
    };

    fn get(w: []const u8) ?Reserved {
        if (w.len < 2 or w.len > 14) return null;
        var i = hash(w);
        while (true) : (i = (i + 1) & (size - 1)) {
            const e = &table[i];
            if (e.word.len == 0) return null;
            if (e.word.len == w.len and std.mem.eql(u8, e.word, w)) return e.r;
        }
    }
};

/// Whether `word` is an integer type name (`u8`, `i64`).
fn isIntType(word: []const u8) bool {
    if (word.len < 2 or (word[0] != 'u' and word[0] != 'i')) return false;
    for (word[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The highlight of an identifier that is not reserved: a label, an
/// integer type, a call, a type by capitalization, or a variable.
inline fn identHl(s: *const Scanner, word: []const u8, label: bool) HighlightId {
    if (label) return .label;
    if (isIntType(word)) return .type_builtin;
    const next = s.peek();
    if (next == '(') return .function;
    if (next == ':') {
        // `blk: {`, `outer: while`, `outer: for`, `blk: switch`: a label.
        var i: usize = s.pos + 1;
        while (i < s.line.len and (s.line[i] == ' ' or s.line[i] == '\t')) i += 1;
        const rest = s.line[i..];
        if (std.mem.startsWith(u8, rest, "{") or startsWord(rest, "while") or startsWord(rest, "for") or
            startsWord(rest, "inline") or startsWord(rest, "switch")) return .label;
    }
    if (std.ascii.isUpper(word[0])) return .type;
    return .variable;
}

fn startsWord(s: []const u8, w: []const u8) bool {
    return std.mem.startsWith(u8, s, w) and (s.len == w.len or !isIdent(s[w.len]));
}

/// Length of the operator at the start of `r`, following the tokenizer.
fn operatorLen(r: []const u8) ?usize {
    const at = struct {
        fn f(x: []const u8, i: usize) u8 {
            return if (i < x.len) x[i] else 0;
        }
    }.f;
    const c0 = r[0];
    const c1 = at(r, 1);
    const c2 = at(r, 2);
    return switch (c0) {
        '!', '^', '%', '&' => if (c1 == '=') 2 else 1,
        '|' => if (c1 == '=' or c1 == '|') 2 else 1,
        '=' => if (c1 == '=' or c1 == '>') 2 else 1,
        '?', '~' => 1,
        '*' => switch (c1) {
            '=', '*' => 2,
            '%', '|' => if (c2 == '=') 3 else 2,
            else => 1,
        },
        '+' => switch (c1) {
            '=', '+' => 2,
            '%', '|' => if (c2 == '=') 3 else 2,
            else => 1,
        },
        '-' => switch (c1) {
            '>', '=' => 2,
            '%', '|' => if (c2 == '=') 3 else 2,
            else => 1,
        },
        '<' => switch (c1) {
            '=' => 2,
            '<' => switch (c2) {
                '=' => 3,
                '|' => if (at(r, 3) == '=') 4 else 3,
                else => 2,
            },
            else => 1,
        },
        '>' => switch (c1) {
            '=' => 2,
            '>' => if (c2 == '=') 3 else 2,
            else => 1,
        },
        else => null,
    };
}

fn resync(line: []const u8) bool {
    // Every Zig line starts in the initial state; any line will do.
    _ = line;
    return true;
}

/// The Zig language definition.
pub const zig_language: language.Language = .{
    .id = .zig,
    .name = "zig",
    .extensions = &.{ ".zig", ".zon" },
    .lexer = .{ .lexLineFn = lexLine },
    .resync = resync,
    .structure = zig_ast_adapter.parse,
    .edit_rules = .{
        .line_comment = "//",
        .auto_close = &.{
            .{ .open = "(", .close = ")" },
            .{ .open = "[", .close = "]" },
            .{ .open = "{", .close = "}" },
            .{ .open = "\"", .close = "\"" },
            .{ .open = "'", .close = "'" },
        },
    },
    .brackets = &.{
        .{ .open = "(", .close = ")" },
        .{ .open = "[", .close = "]" },
        .{ .open = "{", .close = "}" },
    },
};
