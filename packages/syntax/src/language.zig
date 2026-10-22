//! Language definitions: identity, detection data, the tier-1 lexer and
//! editing rules. Definitions are static data registered in a `Registry`.

const std = @import("std");
const state_mod = @import("lex/state.zig");
const scanner_mod = @import("lex/scanner.zig");
const HighlightId = @import("highlight_names.zig").HighlightId;
const structure = @import("structure/structure.zig");

const LexState = state_mod.LexState;
const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;

/// Stable language ids. Unnamed values are free for languages registered
/// at run time (extensions).
pub const LanguageId = enum(u16) {
    plain = 0,
    zig,
    c,
    cpp,
    rust,
    go,
    python,
    javascript,
    typescript,
    jsx,
    tsx,
    json,
    jsonc,
    markdown,
    toml,
    yaml,
    html,
    css,
    shell,
    dockerfile,
    make,
    _,
};

/// A tier-1 lexer.
pub const Lexer = struct {
    /// Lexes `s.line` from `s.pos`, emitting tokens and updating `st`. Must
    /// be total: any input produces tokens and a state. To start an
    /// injected language it calls `st.push(guest)` and returns (the
    /// framework hands the rest of the line to the guest); a guest that
    /// detects its own end calls `st.pop()` and returns.
    lexLineFn: *const fn (st: *LexState, s: *Scanner, out: *TokenSink) void,
};

/// What kind of text a position is in, for smart editing (auto-close,
/// comment toggling, spell checking).
pub const ContextKind = enum { code, string, comment, regex, char };

/// A bracket pair the language uses.
pub const BracketPair = struct { open: []const u8, close: []const u8 };

/// A declaration keyword and the outline kind it starts.
pub const DeclKeyword = struct { word: []const u8, kind: structure.SymbolKind };

/// Declaration keywords common to C-like and scripting languages.
pub const default_decl_keywords = [_]DeclKeyword{
    .{ .word = "fn", .kind = .function },
    .{ .word = "func", .kind = .function },
    .{ .word = "function", .kind = .function },
    .{ .word = "def", .kind = .function },
    .{ .word = "class", .kind = .class },
    .{ .word = "struct", .kind = .@"struct" },
    .{ .word = "union", .kind = .@"union" },
    .{ .word = "enum", .kind = .@"enum" },
    .{ .word = "impl", .kind = .class },
    .{ .word = "trait", .kind = .interface },
    .{ .word = "interface", .kind = .interface },
    .{ .word = "mod", .kind = .module },
    .{ .word = "module", .kind = .module },
    .{ .word = "namespace", .kind = .namespace },
    .{ .word = "test", .kind = .test_decl },
};

/// Editing rules used by the editor's smart editing.
pub const EditRules = struct {
    line_comment: ?[]const u8 = null,
    block_comment: ?BracketPair = null,
    auto_close: []const BracketPair = &.{},
};

/// A language definition.
pub const Language = struct {
    id: LanguageId,
    /// Display and lookup name, e.g. "zig".
    name: []const u8,
    /// Other names accepted by `Registry.byName` and modelines.
    aliases: []const []const u8 = &.{},
    /// File extensions with the dot, e.g. ".zig" or ".d.ts".
    extensions: []const []const u8 = &.{},
    /// Exact file names, e.g. "Makefile".
    filenames: []const []const u8 = &.{},
    /// Interpreter names in `#!` lines, e.g. "python3".
    shebangs: []const []const u8 = &.{},
    lexer: Lexer,
    /// For a host language: where the running guest ends on `line` at or
    /// after `from` (the host's own end delimiter, e.g. a closing code
    /// fence), given the host's suspended mode. Null: the guest runs on.
    injection_end: ?*const fn (host_mode: u16, line: []const u8, from: u32) ?u32 = null,
    /// Whether `line` is known to start in the initial state (a top-level
    /// declaration at column 0). Used to approximate a far viewport before
    /// background relexing reaches it.
    resync: ?*const fn (line: []const u8) bool = null,
    /// Tier-2 structure (folds, outline, scopes, selection ranges). Null:
    /// the bracket tree and indentation are the only structure.
    structure: ?structure.ParseFn = null,
    /// Context of a token kind, overriding the highlight-based default.
    context_of: ?*const fn (kind: u16) ?ContextKind = null,
    edit_rules: EditRules = .{},
    /// Bracket pairs, for matching and the bracket tree (at most 64).
    /// Leave out `<`/`>` unless they always pair.
    brackets: []const BracketPair = &.{},
    /// Fold by indentation (Python, YAML) instead of by brackets.
    fold_by_indent: bool = false,
    /// Words that start a declaration line, for the fallback outline and
    /// scopes.
    decl_keywords: []const DeclKeyword = &default_decl_keywords,
    /// Extra word characters beyond letters, digits and `_`.
    word_chars: []const u21 = &.{},
    /// Files larger than this get no tier-1 highlighting.
    max_tier1_bytes: u64 = 256 << 20,

    /// The context of a token.
    pub fn contextOf(l: *const Language, kind: u16, hl: HighlightId) ContextKind {
        if (l.context_of) |f| if (f(kind & ~scanner_mod.Token.injected_bit)) |c| return c;
        return switch (hl) {
            .comment, .comment_doc => .comment,
            .string, .string_escape, .string_special => .string,
            .character => .char,
            else => .code,
        };
    }
};

fn plainLex(_: *LexState, s: *Scanner, out: *TokenSink) void {
    s.emit(out, s.pos, 0, .none);
    s.skipToEnd();
}

/// Text without highlighting; the fallback when nothing is detected.
pub const plain: Language = .{
    .id = .plain,
    .name = "plain",
    .aliases = &.{"text"},
    .extensions = &.{".txt"},
    .lexer = .{ .lexLineFn = plainLex },
};
