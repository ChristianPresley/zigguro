//! Regex syntax: the AST, the parser, errors, and translation to HIR.

/// The abstract syntax tree.
pub const ast = @import("syntax/ast.zig");
/// The parser.
pub const parse = @import("syntax/parse.zig");
/// Error kinds and messages.
pub const errors = @import("syntax/errors.zig");
/// Code point and byte sets.
pub const class = @import("syntax/class.zig");
/// Simple case-fold orbits.
pub const casefold = @import("syntax/casefold.zig");
/// Unicode property lookup.
pub const unicode = @import("syntax/unicode.zig");
/// The high-level IR.
pub const hir = @import("syntax/hir.zig");
/// AST -> HIR translation.
pub const translate = @import("syntax/translate.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
