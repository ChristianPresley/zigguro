//! Revsets: a Jujutsu-compatible revision query language with zigguro
//! extensions for AI provenance, lanes and review state. See
//! `packages/scm/docs/revsets.md`.

pub const ast = @import("revset/ast.zig");
pub const lexer = @import("revset/lexer.zig");
pub const parser = @import("revset/parser.zig");
pub const functions = @import("revset/functions.zig");
pub const aliases = @import("revset/aliases.zig");
pub const eval = @import("revset/eval.zig");

pub const parse = parser.parse;
pub const ParseError = parser.ParseError;
pub const Aliases = aliases.Aliases;
pub const EvalContext = eval.EvalContext;
pub const RevIter = eval.RevIter;
pub const evaluate = eval.evaluate;
