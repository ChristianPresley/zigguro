//! The document API for language servers and agents (E05.F08).

/// Open documents, handles, paths and URIs.
pub const registry = @import("api/registry.zig");
/// LSP text synchronization.
pub const lsp_sync = @import("api/lsp_sync.zig");
/// Version-stamped reads for agents.
pub const text_query = @import("api/text_query.zig");
/// The agent edit API.
pub const agent_edit = @import("api/agent_edit.zig");

test {
    _ = @import("api/registry_test.zig");
    _ = @import("api/lsp_sync_test.zig");
    _ = @import("api/agent_edit_test.zig");
}
