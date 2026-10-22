//! JSON (RFC 8259) and JSONC. Strings do not span lines, so the only
//! cross-line state is a block comment. Strict JSON highlights comments but
//! gives them the `Kind.bad_comment` kind; JSONC accepts them (and
//! trailing commas). A string followed by `:` is a property key.

const std = @import("std");
const language = @import("../language.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// JSON token kinds.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const comment: u16 = 2;
    /// A comment in strict JSON: highlighted as a comment, but invalid.
    pub const bad_comment: u16 = 3;
    pub const key: u16 = 4 | atomic;
    pub const string: u16 = 5 | atomic;
    pub const str_escape: u16 = 6;
    pub const str_cont: u16 = 7;
    pub const number: u16 = 8 | atomic;
    pub const constant: u16 = 9 | atomic;
    pub const bracket: u16 = 10 | atomic;
    pub const punctuation: u16 = 11 | atomic;
    pub const invalid: u16 = 12;
};

/// Line-end modes.
pub const Mode = struct {
    pub const code: u16 = 0;
    pub const block_comment: u16 = 1;
};

/// Which JSON the lexer accepts.
pub const Dialect = enum { json, jsonc };

fn isSpaceB(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r';
}

fn isNumberByte(b: u8) bool {
    return switch (b) {
        '0'...'9', '.', 'e', 'E', '+', '-' => true,
        else => false,
    };
}

/// A string from the opening quote at the cursor: emits the string (with
/// escape pieces) as a key when a `:` follows.
inline fn string(s: *Scanner, out: *TokenSink) void {
    const line = s.line;
    const start = s.pos;
    const n0 = out.toks.items.len;
    var i: usize = s.pos + 1;
    var escaped = false;
    // Fast path: no escapes.
    while (i < line.len) {
        const c = line[i];
        if (c == '"') {
            i += 1;
            break;
        }
        if (c == '\\') {
            escaped = true;
            break;
        }
        i += 1;
    }
    if (!escaped) {
        s.pos = @intCast(i);
        const key = isKey(line, i);
        s.emit(out, start, if (key) Kind.key else Kind.string, if (key) .property else .string);
        return;
    }
    // Slow path: escape pieces.
    s.emit(out, start, Kind.string, .string);
    s.pos = @intCast(i);
    while (s.pos < line.len) {
        const c = line[s.pos];
        if (c == '"') {
            s.pos += 1;
            break;
        }
        if (c == '\\') {
            const e = s.pos;
            s.pos += 1;
            if (s.pos < line.len) {
                const k = line[s.pos];
                s.pos += 1;
                if (k == 'u') {
                    var n: u32 = 0;
                    while (n < 4 and s.pos < line.len and std.ascii.isHex(line[s.pos])) : (n += 1) s.pos += 1;
                }
            }
            s.emit(out, e, Kind.str_escape, .string_escape);
            if (s.pos < line.len and line[s.pos] != '\\') s.emit(out, s.pos, Kind.str_cont, .string);
            continue;
        }
        const j = std.mem.indexOfAnyPos(u8, line, s.pos, "\"\\") orelse line.len;
        s.pos = @intCast(j);
    }
    if (isKey(line, s.pos)) {
        // The whole string is a key.
        out.toks.items.len = n0;
        s.emit(out, start, Kind.key, .property);
    }
}

/// Whether a `:` follows `i` (after blanks).
inline fn isKey(line: []const u8, i_in: usize) bool {
    var i = i_in;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i < line.len and line[i] == ':';
}

fn lexJson(st: *LexState, s: *Scanner, out: *TokenSink) void {
    lexLineWith(.json, st, s, out);
}

fn lexJsonc(st: *LexState, s: *Scanner, out: *TokenSink) void {
    lexLineWith(.jsonc, st, s, out);
}

/// Lexes one line of `dialect`.
pub fn lexLineWith(comptime dialect: Dialect, st: *LexState, s_in: *Scanner, out: *TokenSink) void {
    var sc = s_in.*;
    defer s_in.* = sc;
    const s = &sc;
    const comment_kind = if (dialect == .jsonc) Kind.comment else Kind.bad_comment;
    const line = s.line;

    if (st.mode == Mode.block_comment) {
        const start = s.pos;
        const end = std.mem.indexOfPos(u8, line, s.pos, "*/");
        s.pos = if (end) |e| @intCast(e + 2) else @intCast(line.len);
        s.emit(out, start, comment_kind, .comment);
        if (end == null) return;
        st.mode = Mode.code;
    }

    while (s.pos < line.len) {
        const start = s.pos;
        const c = line[start];
        switch (c) {
            ' ', '\t', '\r' => {
                var i: usize = s.pos + 1;
                while (i < line.len and isSpaceB(line[i])) i += 1;
                s.pos = @intCast(i);
                s.emit(out, start, Kind.ws, .none);
            },
            '"' => string(s, out),
            '{', '}', '[', ']' => {
                s.pos += 1;
                s.emit(out, start, Kind.bracket, .punctuation_bracket);
            },
            ',', ':' => {
                s.pos += 1;
                s.emit(out, start, Kind.punctuation, .punctuation_delimiter);
            },
            '-', '0'...'9' => {
                var i: usize = s.pos + 1;
                while (i < line.len and isNumberByte(line[i])) i += 1;
                s.pos = @intCast(i);
                s.emit(out, start, Kind.number, .number);
            },
            't', 'f', 'n' => {
                var i: usize = s.pos + 1;
                while (i < line.len and std.ascii.isAlphabetic(line[i])) i += 1;
                s.pos = @intCast(i);
                const w = line[start..i];
                const ok = std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "false") or std.mem.eql(u8, w, "null");
                s.emit(out, start, if (ok) Kind.constant else Kind.invalid, if (ok) .constant_builtin else .invalid);
            },
            '/' => if (s.peekAt(1) == '/') {
                s.skipToEnd();
                s.emit(out, start, comment_kind, .comment);
            } else if (s.peekAt(1) == '*') {
                const end = std.mem.indexOfPos(u8, line, s.pos + 2, "*/");
                s.pos = if (end) |e| @intCast(e + 2) else @intCast(line.len);
                s.emit(out, start, comment_kind, .comment);
                if (end == null) {
                    st.mode = Mode.block_comment;
                    return;
                }
            } else {
                s.pos += 1;
                s.emit(out, start, Kind.invalid, .invalid);
            },
            else => {
                // Anything else is invalid up to the next structural byte.
                var i: usize = s.pos + 1;
                while (i < line.len and std.mem.indexOfScalar(u8, " \t\r\",:[]{}/", line[i]) == null) i += 1;
                s.pos = @intCast(i);
                s.emit(out, start, Kind.invalid, .invalid);
            },
        }
    }
}

fn contextOf(kind: u16) ?language.ContextKind {
    if (kind == Kind.bad_comment) return .comment;
    return null;
}

fn resync(line: []const u8) bool {
    // Pretty-printed JSON: a line that starts at column 0 is a document
    // boundary (`{`, `}`, `[`, `]`).
    return line.len > 0 and std.mem.indexOfScalar(u8, "{}[]", line[0]) != null;
}

const brackets = [_]language.BracketPair{
    .{ .open = "[", .close = "]" },
    .{ .open = "{", .close = "}" },
};

const auto_close = [_]language.BracketPair{
    .{ .open = "[", .close = "]" },
    .{ .open = "{", .close = "}" },
    .{ .open = "\"", .close = "\"" },
};

/// Strict JSON.
pub const json_language: language.Language = .{
    .id = .json,
    .name = "json",
    .extensions = &.{ ".json", ".geojson", ".webmanifest" },
    .filenames = &.{ ".prettierrc", ".babelrc", "composer.lock", "flake.lock" },
    .lexer = .{ .lexLineFn = lexJson },
    .resync = resync,
    .context_of = contextOf,
    .decl_keywords = &.{},
    .edit_rules = .{
        .auto_close = &auto_close,
        .insert_spaces = true,
        .indent_after = &.{ "{", "[" },
        .dedent_on = &.{ "}", "]" },
    },
    .brackets = &brackets,
};

/// JSON with comments and trailing commas (VS Code settings, tsconfig).
pub const jsonc_language: language.Language = .{
    .id = .jsonc,
    .name = "jsonc",
    .aliases = &.{"json5"},
    .extensions = &.{ ".jsonc", ".code-workspace", ".json5" },
    .filenames = &.{
        "tsconfig.json",      "jsconfig.json",      "settings.json",   "launch.json",
        "tasks.json",         "keybindings.json",   "extensions.json", "devcontainer.json",
        ".devcontainer.json", "tsconfig.base.json", ".eslintrc.json",  "argv.json",
    },
    .lexer = .{ .lexLineFn = lexJsonc },
    .resync = resync,
    .decl_keywords = &.{},
    .edit_rules = .{
        .line_comment = "//",
        .block_comment = .{ .open = "/*", .close = "*/" },
        .auto_close = &auto_close,
        .insert_spaces = true,
        .indent_after = &.{ "{", "[" },
        .dedent_on = &.{ "}", "]" },
    },
    .brackets = &brackets,
};
