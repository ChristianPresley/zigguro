//! The Thompson NFA: program representation, compiler, UTF-8 sequences and
//! prefix literal extraction.

/// The compiled program.
pub const program = @import("nfa/program.zig");
/// HIR -> NFA compiler.
pub const compile = @import("nfa/compile.zig");
/// UTF-8 byte-range sequences.
pub const utf8_seq = @import("nfa/utf8_seq.zig");
/// Prefix literal extraction.
pub const literal_extract = @import("nfa/literal_extract.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
