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

/// Feature drivers: request results from the routed server and hand
/// them to the editor.
pub const features = struct {
    pub const SemTokDriver = @import("features/semtok.zig");
    pub const FoldingDriver = @import("features/folding.zig");
    pub const SelectionDriver = @import("features/selection.zig");
    pub const LinkDriver = @import("features/links.zig");
    pub const position = @import("features/position.zig");
};

/// Diagnostics: the snapshot store, the push/pull driver, editor
/// decorations and the settle detector behind the agent's edit tools.
pub const diagnostics = struct {
    pub const Store = @import("diagnostics/Store.zig");
    pub const convert = @import("diagnostics/convert.zig");
    pub const Driver = @import("diagnostics/Driver.zig");
    pub const Decorator = @import("diagnostics/decorate.zig");
    pub const SettleDetector = @import("diagnostics/settle.zig");
};

/// LSP language ids for zg_syntax languages.
pub const language = @import("language.zig");

/// Starts language servers on demand and routes documents and requests
/// to them.
pub const Manager = @import("Manager.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("sync/sink_test.zig");
    _ = @import("registry/registry_test.zig");
    _ = @import("Manager_test.zig");
    _ = @import("features/semtok_test.zig");
    _ = @import("features/features_test.zig");
    _ = @import("diagnostics/diagnostics_test.zig");
}
