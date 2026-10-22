//! YAML 1.2.2. Block scalars (`|`, `>`, with chomping and indentation
//! indicators) and quoted scalars span lines: a block scalar's state keeps
//! its parent indentation in `depth` (plus one) and an explicit content
//! indentation in `aux[0]`; its content runs while lines are blank or
//! indented deeper.

const std = @import("std");
const language = @import("../language.zig");
const common = @import("common.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// YAML token kinds.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    pub const key: u16 = 3 | atomic;
    pub const string: u16 = 4 | atomic;
    pub const str_escape: u16 = 5;
    pub const str_cont: u16 = 6;
    pub const scalar: u16 = 7 | atomic;
    pub const anchor: u16 = 8 | atomic;
    pub const alias: u16 = 9 | atomic;
    pub const tag: u16 = 10 | atomic;
    pub const indicator: u16 = 11 | atomic;
    pub const bracket: u16 = 12 | atomic;
    pub const punctuation: u16 = 13 | atomic;
    pub const document: u16 = 14 | atomic;
    pub const directive: u16 = 15 | atomic;
    /// A line of block scalar content.
    pub const block: u16 = 16;
    pub const invalid: u16 = 17;
};

/// Line-end modes.
pub const Mode = struct {
    pub const normal: u16 = 0;
    /// `depth` is the parent indentation + 1; `aux[0]` the explicit
    /// content indentation (absent: any deeper line).
    pub const block_scalar: u16 = 1;
    pub const double_quoted: u16 = 2;
    pub const single_quoted: u16 = 3;
};

fn isSpaceB(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r';
}

fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    return i;
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!isSpaceB(c)) return false;
    return true;
}

/// Whether `c` (or the end) ends a plain scalar's `:` or `#`.
fn isBreak(c: ?u8) bool {
    return c == null or c.? == ' ' or c.? == '\t' or c.? == '\r';
}

/// A double-quoted scalar body from the cursor; returns whether it closed.
fn doubleBody(s: *Scanner, out: *TokenSink) bool {
    const line = s.line;
    while (s.pos < line.len) {
        const c = line[s.pos];
        if (c == '"') {
            s.pos += 1;
            return true;
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
                var k: u32 = 0;
                while (k < hex and s.peek() != null and std.ascii.isHex(s.peek().?)) : (k += 1) s.pos += 1;
            }
            s.emit(out, start, Kind.str_escape, .string_escape);
            if (s.pos < line.len and line[s.pos] != '\\') s.emit(out, s.pos, Kind.str_cont, .string);
            continue;
        }
        var i: usize = s.pos + 1;
        while (i < line.len and line[i] != '"' and line[i] != '\\') i += 1;
        s.pos = @intCast(i);
    }
    return false;
}

/// A single-quoted scalar body (`''` is a quote); returns whether it closed.
fn singleBody(s: *Scanner, out: *TokenSink) bool {
    const line = s.line;
    while (std.mem.indexOfScalarPos(u8, line, s.pos, '\'')) |q| {
        if (q + 1 < line.len and line[q + 1] == '\'') {
            s.pos = @intCast(q);
            s.emit(out, s.pos, Kind.str_escape, .string_escape);
            s.pos += 2;
            if (s.pos < line.len and line[s.pos] != '\'') s.emit(out, s.pos, Kind.str_cont, .string);
            continue;
        }
        s.pos = @intCast(q + 1);
        return true;
    }
    s.skipToEnd();
    return false;
}

/// The highlight of a plain scalar value: null, booleans, numbers, or a
/// string.
fn plainHl(v: []const u8) HighlightId {
    const consts = [_][]const u8{ "null", "Null", "NULL", "~", "true", "True", "TRUE", "false", "False", "FALSE", ".inf", ".Inf", ".INF", "-.inf", "+.inf", ".nan", ".NaN", ".NAN" };
    for (consts) |k| if (std.mem.eql(u8, v, k)) return .constant_builtin;
    if (isNumber(v)) return .number;
    return .string;
}

fn isNumber(v: []const u8) bool {
    if (v.len == 0) return false;
    var t = v;
    if (t[0] == '-' or t[0] == '+') t = t[1..];
    if (t.len == 0) return false;
    if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'o')) {
        for (t[2..]) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }
    var digits = false;
    var dot = false;
    var exp = false;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (std.ascii.isDigit(c)) {
            digits = true;
        } else if (c == '.' and !dot and !exp) {
            dot = true;
        } else if ((c == 'e' or c == 'E') and digits and !exp) {
            exp = true;
            if (i + 1 < t.len and (t[i + 1] == '+' or t[i + 1] == '-')) i += 1;
        } else return false;
    }
    return digits;
}

/// Block scalar header after `|` or `>`: chomping and indentation
/// indicators in either order. Returns the explicit indentation (0: none),
/// or null when the header is not followed by a blank or a comment.
fn blockHeader(s: *Scanner) ?u8 {
    var explicit: u8 = 0;
    var k: u32 = 0;
    while (k < 2) : (k += 1) {
        const c = s.peek() orelse break;
        if (c == '+' or c == '-') {
            s.advance();
        } else if (c >= '1' and c <= '9' and explicit == 0) {
            explicit = c - '0';
            s.advance();
        } else break;
    }
    const rest = std.mem.trimStart(u8, s.rest(), " \t\r");
    if (rest.len != 0 and rest[0] != '#') return null;
    return explicit;
}

fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    var sc = s_in.*;
    defer s_in.* = sc;
    const s = &sc;
    const line = s.line;

    switch (st.mode) {
        Mode.block_scalar => {
            const parent: usize = st.depth - 1;
            const content: usize = if (st.aux_len > 0) parent + st.aux[0] else parent + 1;
            if (isBlank(line) or indentOf(line) >= content) {
                if (line.len > 0) s.emit(out, 0, Kind.block, .string);
                s.skipToEnd();
                return;
            }
            st.mode = Mode.normal;
            st.depth = 0;
            st.clearAux();
        },
        Mode.double_quoted => {
            s.emit(out, 0, Kind.str_cont, .string);
            if (!doubleBody(s, out)) return;
            st.mode = Mode.normal;
        },
        Mode.single_quoted => {
            s.emit(out, 0, Kind.str_cont, .string);
            if (!singleBody(s, out)) return;
            st.mode = Mode.normal;
        },
        else => {
            st.mode = Mode.normal;
            st.depth = 0;
            st.clearAux();
        },
    }

    // Document markers and directives at column 0.
    if (s.pos == 0 and (std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "...")) and isBreak(if (line.len > 3) line[3] else null)) {
        s.advanceBy(3);
        s.emit(out, 0, Kind.document, .punctuation_delimiter);
    } else if (s.pos == 0 and line.len > 0 and line[0] == '%') {
        s.skipToEnd();
        s.emit(out, 0, Kind.directive, .keyword);
        return;
    }

    const indent = indentOf(line);
    // Brackets of flow collections on this line (flow context ends plain
    // scalars at `,[]{}`).
    var flow: u32 = 0;
    while (s.peek()) |c| {
        const start = s.pos;
        switch (c) {
            ' ', '\t', '\r' => {
                _ = s.eatWhile(isSpaceB);
                s.emit(out, start, Kind.ws, .none);
            },
            '#' => {
                s.skipToEnd();
                s.emit(out, start, Kind.comment, .comment);
            },
            '-', '?', ':' => if (isBreak(s.peekAt(1))) {
                s.advance();
                s.emit(out, start, Kind.indicator, .punctuation_delimiter);
            } else plain(s, out, flow),
            '[', '{' => {
                s.advance();
                flow += 1;
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
            },
            ']', '}' => {
                s.advance();
                flow -|= 1;
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
            },
            ',' => {
                s.advance();
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            '&', '*' => {
                s.advance();
                _ = s.eatWhile(struct {
                    fn f(b: u8) bool {
                        return b > ' ' and b != ',' and b != '[' and b != ']' and b != '{' and b != '}';
                    }
                }.f);
                s.emit(out, start, if (c == '&') Kind.anchor else Kind.alias, .label);
            },
            '!' => {
                s.advance();
                if (s.peek() == '<') {
                    _ = s.eatUntilAny(">");
                    _ = s.eatByte('>');
                } else _ = s.eatWhile(struct {
                    fn f(b: u8) bool {
                        return b > ' ' and b != ',' and b != '[' and b != ']' and b != '{' and b != '}';
                    }
                }.f);
                s.emit(out, start, Kind.tag, .type);
            },
            '|', '>' => {
                s.advance();
                if (blockHeader(s)) |explicit| {
                    s.emit(out, start, Kind.indicator, .operator);
                    const ws = s.pos;
                    if (s.eatWhile(isSpaceB) > 0) s.emit(out, ws, Kind.ws, .none);
                    if (s.peek() == '#') {
                        s.emit(out, s.pos, Kind.comment, .comment);
                        s.skipToEnd();
                    }
                    st.mode = Mode.block_scalar;
                    st.depth = @intCast(@min(indent, 0xfffe) + 1);
                    if (explicit != 0) st.setAux(&.{explicit});
                    return;
                }
                s.pos = start;
                plain(s, out, flow);
            },
            '"' => {
                s.advance();
                s.emit(out, start, Kind.string, .string);
                if (!doubleBody(s, out)) {
                    st.mode = Mode.double_quoted;
                    return;
                }
                keyIfColon(s, out, start);
            },
            '\'' => {
                s.advance();
                s.emit(out, start, Kind.string, .string);
                if (!singleBody(s, out)) {
                    st.mode = Mode.single_quoted;
                    return;
                }
                keyIfColon(s, out, start);
            },
            else => plain(s, out, flow),
        }
    }
}

/// A quoted scalar from `start` that is followed by `: ` is a key.
fn keyIfColon(s: *Scanner, out: *TokenSink, start: u32) void {
    var i: usize = s.pos;
    while (i < s.line.len and (s.line[i] == ' ' or s.line[i] == '\t')) i += 1;
    if (i < s.line.len and s.line[i] == ':' and isBreak(if (i + 1 < s.line.len) s.line[i + 1] else null)) {
        // Re-emit the scalar as one key token.
        const toks = out.toks.items;
        var k = toks.len;
        while (k > 0 and toks[k - 1].start >= start) k -= 1;
        out.toks.items.len = k;
        s.emit(out, start, Kind.key, .property);
    }
}

/// A plain scalar: up to `: `, ` #`, the line end, or (in flow context)
/// `,[]{}`. Followed by `: ` it is a key.
fn plain(s: *Scanner, out: *TokenSink, flow: u32) void {
    const start = s.pos;
    const line = s.line;
    var i: usize = s.pos;
    var end: usize = s.pos;
    var key = false;
    while (i < line.len) {
        const c = line[i];
        if (c == ':' and isBreak(if (i + 1 < line.len) line[i + 1] else null)) {
            key = true;
            break;
        }
        if (c == ':' and flow > 0 and i + 1 < line.len and (line[i + 1] == ',' or line[i + 1] == ']' or line[i + 1] == '}')) {
            key = true;
            break;
        }
        if (c == '#' and i > start and (line[i - 1] == ' ' or line[i - 1] == '\t')) break;
        if (flow > 0 and (c == ',' or c == '[' or c == ']' or c == '{' or c == '}')) break;
        i += 1;
        if (c != ' ' and c != '\t' and c != '\r') end = i;
    }
    if (end == start) end = @max(start + 1, @min(i, line.len));
    s.pos = @intCast(end);
    const v = line[start..end];
    s.emit(out, start, if (key) Kind.key else Kind.scalar, if (key) .property else plainHl(v));
}

fn resync(line: []const u8) bool {
    // A top-level key or document marker.
    return line.len > 0 and line[0] != ' ' and line[0] != '#' and line[0] != '-';
}

/// The YAML language definition.
pub const yaml_language: language.Language = .{
    .id = .yaml,
    .name = "yaml",
    .aliases = &.{"yml"},
    .extensions = &.{ ".yaml", ".yml" },
    .filenames = &.{ ".clang-format", ".clang-tidy", ".yamllint" },
    .lexer = .{ .lexLineFn = lexLine },
    .resync = resync,
    .fold_by_indent = true,
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
        .indent_after = &.{ ":", "|", ">", "- " },
    },
    .brackets = &.{
        .{ .open = "[", .close = "]" },
        .{ .open = "{", .close = "}" },
    },
};
