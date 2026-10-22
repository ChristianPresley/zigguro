//! TOML 1.0. Multi-line basic (`"""`) and literal (`'''`) strings span
//! lines (`mode`), and so do arrays (and TOML 1.1 inline tables): the open
//! brackets are kept in `aux` (their count in `depth`), so a `[` on a line
//! inside a multi-line array is an array, not a table header.

const std = @import("std");
const language = @import("../language.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// TOML token kinds.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    pub const key: u16 = 3 | atomic;
    pub const string: u16 = 4 | atomic;
    pub const str_escape: u16 = 5;
    pub const str_cont: u16 = 6;
    pub const number: u16 = 7 | atomic;
    pub const boolean: u16 = 8 | atomic;
    pub const datetime: u16 = 9 | atomic;
    pub const table_header: u16 = 10 | atomic;
    pub const bracket: u16 = 11 | atomic;
    pub const punctuation: u16 = 12 | atomic;
    pub const equals: u16 = 13 | atomic;
    pub const invalid: u16 = 14;
};

/// Line-end modes.
pub const Mode = struct {
    pub const normal: u16 = 0;
    /// Inside `"""`.
    pub const ml_basic: u16 = 1;
    /// Inside `'''`.
    pub const ml_literal: u16 = 2;
};

fn isSpaceB(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r';
}

fn isBareKey(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-';
}

fn isValueByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '+' or b == '-' or b == '.' or b == ':';
}

/// The innermost open bracket (`[` or `{`), or 0 at the top level.
fn innermost(st: *const LexState) u8 {
    if (st.depth == 0) return 0;
    const n = st.aux_len;
    // Brackets deeper than `aux` holds are taken as arrays.
    return if (st.depth > n) '[' else st.aux[n - 1];
}

fn pushBracket(st: *LexState, b: u8) void {
    if (st.aux_len < LexState.max_aux and st.depth == st.aux_len) {
        st.aux[st.aux_len] = b;
        st.aux_len += 1;
    }
    st.depth +|= 1;
}

fn popBracket(st: *LexState) void {
    if (st.depth == 0) return;
    if (st.depth == st.aux_len) {
        st.aux_len -= 1;
        st.aux[st.aux_len] = 0;
    }
    st.depth -= 1;
}

/// A multi-line string body from the cursor, up to and including its
/// closing delimiter (a run of 3 to 5 quotes ends it: up to two quotes
/// belong to the content). Returns whether it closed.
fn mlBody(s: *Scanner, out: *TokenSink, comptime q: u8) bool {
    const line = s.line;
    while (s.pos < line.len) {
        const c = line[s.pos];
        if (c == q) {
            var n: usize = 0;
            while (s.pos + n < line.len and line[s.pos + n] == q) n += 1;
            if (n >= 3) {
                s.pos += @intCast(@min(n, 5));
                return true;
            }
            s.pos += @intCast(n);
            continue;
        }
        if (q == '"' and c == '\\') {
            escape(s, out);
            continue;
        }
        const set = if (q == '"') "\"\\" else "'";
        s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, s.pos + 1, set) orelse line.len);
    }
    return false;
}

/// One escape sequence at the cursor, then a string continuation.
fn escape(s: *Scanner, out: *TokenSink) void {
    const line = s.line;
    const e = s.pos;
    s.pos += 1;
    if (s.pos < line.len) {
        const k = line[s.pos];
        s.pos += 1;
        const hex: u32 = switch (k) {
            'x' => 2,
            'u' => 4,
            'U' => 8,
            else => 0,
        };
        var n: u32 = 0;
        while (n < hex and s.pos < line.len and std.ascii.isHex(line[s.pos])) : (n += 1) s.pos += 1;
    }
    s.emit(out, e, Kind.str_escape, .string_escape);
    if (s.pos < line.len and line[s.pos] != '\\') s.emit(out, s.pos, Kind.str_cont, .string);
}

/// A single-line string at the cursor (`"` or `'`); `key` selects the
/// key kind. Unterminated strings end at the line end.
fn shortString(s: *Scanner, out: *TokenSink, key: bool) void {
    const line = s.line;
    const q = line[s.pos];
    const start = s.pos;
    if (key) {
        // Keys are one token, escapes included.
        var i: usize = s.pos + 1;
        while (i < line.len and line[i] != q) : (i += 1) {
            if (q == '"' and line[i] == '\\') i += 1;
        }
        s.pos = @intCast(@min(i + 1, line.len));
        s.emit(out, start, Kind.key, .property);
        return;
    }
    s.pos += 1;
    s.emit(out, start, Kind.string, .string);
    while (s.pos < line.len) {
        const c = line[s.pos];
        if (c == q) {
            s.pos += 1;
            return;
        }
        if (q == '"' and c == '\\') {
            escape(s, out);
            continue;
        }
        const set = if (q == '"') "\"\\" else "'";
        s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, s.pos + 1, set) orelse line.len);
    }
}

/// Whether `v` looks like a date, time or date-time.
fn isDatetime(v: []const u8) bool {
    if (v.len >= 8 and std.ascii.isDigit(v[0]) and std.ascii.isDigit(v[1]) and v[2] == ':') return true;
    return v.len >= 10 and std.ascii.isDigit(v[0]) and std.ascii.isDigit(v[3]) and v[4] == '-' and v[7] == '-';
}

fn valueHl(v: []const u8) struct { u16, HighlightId } {
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "false")) return .{ Kind.boolean, .constant_builtin };
    if (isDatetime(v)) return .{ Kind.datetime, .constant };
    var t = v;
    if (t.len > 0 and (t[0] == '+' or t[0] == '-')) t = t[1..];
    if (std.mem.eql(u8, t, "inf") or std.mem.eql(u8, t, "nan")) return .{ Kind.number, .number };
    if (t.len > 0 and std.ascii.isDigit(t[0])) return .{ Kind.number, .number };
    return .{ Kind.invalid, .invalid };
}

/// A bare value (number, boolean, date-time) at the cursor. A date
/// followed by a space and a time is one date-time.
fn bareValue(s: *Scanner, out: *TokenSink) void {
    const line = s.line;
    const start = s.pos;
    var i: usize = s.pos;
    while (i < line.len and isValueByte(line[i])) i += 1;
    if (i == start) i += 1;
    if (i - start == 10 and isDatetime(line[start..i]) and i + 3 < line.len and line[i] == ' ' and
        std.ascii.isDigit(line[i + 1]) and std.ascii.isDigit(line[i + 2]) and line[i + 3] == ':')
    {
        i += 1;
        while (i < line.len and isValueByte(line[i])) i += 1;
    }
    s.pos = @intCast(i);
    const k = valueHl(line[start..i]);
    s.emit(out, start, k[0], k[1]);
}

/// A table header (`[a.b]` or `[[a.b]]`) from `[` at the cursor through its
/// closing bracket.
fn header(s: *Scanner, out: *TokenSink) void {
    const line = s.line;
    const start = s.pos;
    const double = s.peekAt(1) == '[';
    var i: usize = s.pos + @as(usize, if (double) 2 else 1);
    while (i < line.len and line[i] != ']') : (i += 1) {
        const q = line[i];
        if (q == '"' or q == '\'') {
            i += 1;
            while (i < line.len and line[i] != q) : (i += 1) {
                if (q == '"' and line[i] == '\\') i += 1;
            }
            if (i >= line.len) break;
        }
    }
    if (i < line.len) i += 1;
    if (double and i < line.len and line[i] == ']') i += 1;
    s.pos = @intCast(@min(i, line.len));
    s.emit(out, start, Kind.table_header, .type);
}

fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    var sc = s_in.*;
    defer s_in.* = sc;
    const s = &sc;
    const line = s.line;

    switch (st.mode) {
        Mode.ml_basic, Mode.ml_literal => {
            const ml = st.mode;
            if (line.len > 0) s.emit(out, 0, Kind.str_cont, .string);
            const closed = if (ml == Mode.ml_basic) mlBody(s, out, '"') else mlBody(s, out, '\'');
            if (!closed) return;
            st.mode = Mode.normal;
        },
        else => {},
    }

    // Keys are expected at the top level and in inline tables; values in
    // arrays and after `=`.
    var expect_key = st.mode == Mode.normal and s.pos == 0 and innermost(st) != '[';
    var first = s.pos == 0;
    while (s.pos < line.len) {
        const start = s.pos;
        const c = line[start];
        switch (c) {
            ' ', '\t', '\r' => {
                _ = s.eatWhile(isSpaceB);
                s.emit(out, start, Kind.ws, .none);
                continue;
            },
            '#' => {
                s.skipToEnd();
                s.emit(out, start, Kind.comment, .comment);
            },
            '[' => if (first and st.depth == 0) {
                header(s, out);
            } else {
                s.advance();
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
                pushBracket(st, '[');
                expect_key = false;
            },
            '{' => {
                s.advance();
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
                pushBracket(st, '{');
                expect_key = true;
            },
            ']', '}' => {
                s.advance();
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
                popBracket(st);
                expect_key = false;
            },
            ',' => {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
                expect_key = innermost(st) == '{';
            },
            '.' => if (expect_key) {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            } else bareValue(s, out),
            '=' => {
                s.advance();
                s.emit(out, start, Kind.equals, .operator);
                expect_key = false;
            },
            '"', '\'' => if (expect_key) {
                shortString(s, out, true);
            } else if (s.peekAt(1) == c and s.peekAt(2) == c) {
                s.advanceBy(3);
                s.emit(out, start, Kind.string, .string);
                const closed = if (c == '"') mlBody(s, out, '"') else mlBody(s, out, '\'');
                if (!closed) {
                    st.mode = if (c == '"') Mode.ml_basic else Mode.ml_literal;
                    return;
                }
            } else shortString(s, out, false),
            else => if (expect_key and isBareKey(c)) {
                _ = s.eatWhile(isBareKey);
                s.emit(out, start, Kind.key, .property);
            } else if (expect_key) {
                s.advance();
                s.emit(out, start, Kind.invalid, .invalid);
            } else bareValue(s, out),
        }
        first = false;
    }
}

fn resync(line: []const u8) bool {
    // A table header at column 0.
    return line.len > 1 and line[0] == '[' and (line[1] == '[' or isBareKey(line[1]) or line[1] == '"' or line[1] == '\'');
}

/// The TOML language definition.
pub const toml_language: language.Language = .{
    .id = .toml,
    .name = "toml",
    .extensions = &.{".toml"},
    .filenames = &.{ "Cargo.lock", "Pipfile", "poetry.lock", "uv.lock" },
    .lexer = .{ .lexLineFn = lexLine },
    .resync = resync,
    .decl_keywords = &.{},
    .edit_rules = .{
        .line_comment = "#",
        .auto_close = &.{
            .{ .open = "[", .close = "]" },
            .{ .open = "{", .close = "}" },
            .{ .open = "\"", .close = "\"" },
            .{ .open = "'", .close = "'" },
        },
        .insert_spaces = true,
        .indent_after = &.{ "[", "{" },
        .dedent_on = &.{ "]", "}" },
    },
    .brackets = &.{
        .{ .open = "[", .close = "]" },
        .{ .open = "{", .close = "}" },
    },
};
