//! zg_codeintel: the E07 language services that bridge the zg_lsp
//! protocol client to the editor model (zg_editor) and highlighting
//! (zg_syntax): text sync, server routing, diagnostics and the feature
//! drivers. It sits above both, so zg_lsp stays protocol-only and zg_dap
//! does not pull in the editor.

const std = @import("std");

/// `file:` URIs and paths (zg_lsp's), for callers that open targets.
pub const uri = @import("zg_lsp").uri;

/// Snippets: the VS Code grammar, variables, transforms and expansion.
pub const snippet = struct {
    pub const Snippet = @import("snippet/Snippet.zig");
    pub const variables = @import("snippet/variables.zig");
    pub const transform = @import("snippet/transform.zig");
    pub const Session = @import("snippet/Session.zig");
};

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
    pub const request = @import("features/request.zig");
    pub const HoverService = @import("features/hover.zig");
    pub const HighlightService = @import("features/highlight.zig");
    pub const NavService = @import("features/navigation.zig");
    pub const CompletionService = @import("features/completion.zig");
    pub const completion_rank = @import("features/completion_rank.zig");
    pub const SignatureService = @import("features/signature.zig");
};

/// Diagnostics: the snapshot store, the push/pull driver, editor
/// decorations and the settle detector behind the agent's edit tools.
pub const diagnostics = struct {
    pub const Store = @import("diagnostics/Store.zig");
    pub const convert = @import("diagnostics/convert.zig");
    pub const Driver = @import("diagnostics/Driver.zig");
    pub const Decorator = @import("diagnostics/decorate.zig");
    pub const SettleDetector = @import("diagnostics/settle.zig");
    pub const Problems = @import("diagnostics/problems.zig");
};

/// Language-server tools for agents (zg_ai's foreign-tool contract).
pub const agent = struct {
    pub const tools = @import("agent/tools.zig");
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
    _ = @import("features/nav_hover_test.zig");
    _ = @import("features/completion_test.zig");
    _ = @import("features/signature.zig");
    _ = @import("snippet/Snippet.zig");
    _ = @import("features/position_test.zig");
    _ = @import("diagnostics/diagnostics_test.zig");
    _ = @import("agent/tools_test.zig");
}
