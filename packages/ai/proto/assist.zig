//! One-shot assist requests raised by other subsystems (E06 terminal, E07
//! diagnostics, E12) and answered by an E10 agent.

const ContextItem = @import("context_item.zig").ContextItem;

/// The kind of help requested.
pub const AssistKind = enum { explain_error, fix_command, generate_command, explain_code, fix_diagnostic, custom };

/// A request for help with attached context.
pub const AssistRequest = struct {
    kind: AssistKind,
    prompt: []const u8,
    context: []const ContextItem = &.{},
    /// When set, the answer must match this JSON Schema.
    output_schema_json: ?[]const u8 = null,
    open_agent_pane: bool = true,
    /// Producer, e.g. "terminal".
    origin: []const u8,
};
