//! zg_syntax: the syntax engine (E05.F04). Tier 1 is incremental
//! highlighting with hand-written per-line lexers (the VS Code line-state
//! model); structure, the bracket tree and semantic overlays build on it.

const std = @import("std");

pub const highlight_names = @import("highlight_names.zig");
pub const language = @import("language.zig");
pub const detect = @import("detect.zig");
pub const registry = @import("registry.zig");
pub const lex = struct {
    pub const state = @import("lex/state.zig");
    pub const scanner = @import("lex/scanner.zig");
    pub const lexer = @import("lex/lexer.zig");
};
pub const langs = struct {
    pub const zig = @import("langs/zig.zig");
};
pub const highlight = struct {
    pub const token_store = @import("highlight/token_store.zig");
    pub const highlighter = @import("highlight/highlighter.zig");
};

pub const HighlightId = highlight_names.HighlightId;
pub const Language = language.Language;
pub const LanguageId = language.LanguageId;
pub const Lexer = language.Lexer;
pub const ContextKind = language.ContextKind;
pub const Registry = registry.Registry;
pub const LexState = lex.state.LexState;
pub const StateId = lex.state.StateId;
pub const StateTable = lex.state.StateTable;
pub const Token = lex.scanner.Token;
pub const TokenSink = lex.scanner.TokenSink;
pub const Scanner = lex.scanner.Scanner;
pub const TokenStore = highlight.token_store.TokenStore;
pub const Highlighter = highlight.highlighter.Highlighter;
pub const LineSource = highlight.highlighter.LineSource;
pub const LineEdit = highlight.highlighter.LineEdit;
pub const Deadline = highlight.highlighter.Deadline;

/// Every built-in language, in registration order.
pub const builtin_languages = [_]*const Language{&langs.zig.zig_language};

/// A registry with plain text and every built-in language.
pub fn defaultRegistry(gpa: std.mem.Allocator) std.mem.Allocator.Error!Registry {
    var r: Registry = try .init(gpa);
    errdefer r.deinit(gpa);
    for (builtin_languages) |l| try r.register(gpa, l);
    return r;
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(lex);
    std.testing.refAllDecls(highlight);
    std.testing.refAllDecls(langs);
    _ = @import("highlight/highlighter_test.zig");
    _ = @import("langs/zig_test.zig");
}
