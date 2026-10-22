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
    pub const common = @import("langs/common.zig");
    pub const zig = @import("langs/zig.zig");
    pub const c = @import("langs/c.zig");
    pub const rust = @import("langs/rust.zig");
    pub const go = @import("langs/go.zig");
    pub const python = @import("langs/python.zig");
    pub const yaml = @import("langs/yaml.zig");
    pub const json = @import("langs/json.zig");
    pub const toml = @import("langs/toml.zig");
    pub const shell = @import("langs/shell.zig");
    pub const js = @import("langs/js.zig");
    pub const css = @import("langs/css.zig");
};
pub const structure = struct {
    pub const structure = @import("structure/structure.zig");
    pub const zig_ast_adapter = @import("structure/zig_ast_adapter.zig");
    pub const fallback = @import("structure/fallback.zig");
    pub const query = @import("structure/query.zig");
};
pub const brackets = struct {
    pub const bracket_tree = @import("brackets/bracket_tree.zig");
    pub const highlight_source = @import("brackets/highlight_source.zig");
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
pub const Structure = structure.structure.Structure;
pub const ByteRange = structure.structure.ByteRange;
pub const FoldRange = structure.structure.FoldRange;
pub const Symbol = structure.structure.Symbol;
pub const Scope = structure.structure.Scope;
pub const BracketTree = brackets.bracket_tree.BracketTree;
pub const BracketSource = brackets.bracket_tree.BracketSource;
pub const fallbackStructure = structure.fallback.fallbackStructure;

/// Every built-in language, in registration order.
pub const builtin_languages = [_]*const Language{
    &langs.zig.zig_language,
    &langs.c.c_language,
    &langs.c.cpp_language,
    &langs.rust.rust_language,
    &langs.go.go_language,
    &langs.python.python_language,
    &langs.yaml.yaml_language,
    &langs.json.json_language,
    &langs.json.jsonc_language,
    &langs.toml.toml_language,
    &langs.shell.shell_language,
    &langs.js.javascript_language,
    &langs.js.typescript_language,
    &langs.js.jsx_language,
    &langs.js.tsx_language,
    &langs.css.css_language,
};

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
    std.testing.refAllDecls(structure);
    std.testing.refAllDecls(brackets);
    _ = @import("brackets/bracket_tree_test.zig");
    _ = @import("structure/fallback_test.zig");
    _ = @import("highlight/highlighter_test.zig");
    _ = @import("langs/zig_test.zig");
    _ = @import("langs/c_test.zig");
    _ = @import("langs/rust_test.zig");
    _ = @import("langs/go_test.zig");
    _ = @import("langs/python_test.zig");
    _ = @import("langs/yaml_test.zig");
    _ = @import("langs/json_test.zig");
    _ = @import("langs/toml_test.zig");
    _ = @import("langs/shell_test.zig");
    _ = @import("langs/js_test.zig");
    _ = @import("langs/css_test.zig");
}
