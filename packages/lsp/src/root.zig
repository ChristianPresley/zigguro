//! zg_lsp: the headless LSP client, server registry and code-intelligence
//! services (E07). See issue #8 for the package design.

const std = @import("std");

/// Generated LSP 3.18 protocol types (`zig build lspgen`).
pub const protocol = @import("gen/protocol.zig");
/// `std.json` support for the protocol types: union decoding, null
/// omission, open enums.
pub const json = @import("proto/json.zig");
/// LSP glob patterns (document selectors, watched files, file operations).
pub const glob = @import("proto/glob.zig");
/// Fuzzy scoring for completion, symbol pickers and REPL completions.
pub const fuzzy = @import("features/fuzzy.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("proto/glob_test.zig");
    _ = @import("features/fuzzy_test.zig");
    _ = @import("proto/protocol_test.zig");
}
