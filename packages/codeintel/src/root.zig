//! zg_codeintel: the E07 language services that bridge the zg_lsp
//! protocol client to the editor model (zg_editor) and highlighting
//! (zg_syntax): text sync, server routing, diagnostics and the feature
//! drivers. It sits above both, so zg_lsp stays protocol-only and zg_dap
//! does not pull in the editor.

const std = @import("std");

/// Text synchronization: the `LspSink` that serializes `didOpen`,
/// `didChange`, `didSave` and `didClose` for one server.
pub const sync = struct {
    pub const sink = @import("sync/sink.zig");
    pub const Sink = sink.Sink;
};

/// Language server definitions, PATH discovery, roots and routing.
pub const registry = struct {
    pub const Registry = @import("registry/Registry.zig");
    pub const routing = @import("registry/routing.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("sync/sink_test.zig");
    _ = @import("registry/registry_test.zig");
}
