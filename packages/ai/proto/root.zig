//! zg_ai_proto: the leaf module of canonical AI types (E10.F01.S01.T01).
//! Depends only on `std` and `zg_core`, so layer-4 packages (editor,
//! terminal, lsp, workspace, notes, scm, review) can export tool specs and
//! context items without importing `zg_ai`.
//!
//! Ownership: every slice in these types is borrowed. Strings belong to the
//! arena of the containing transcript segment (or request); codecs take an
//! arena and never free. Nothing here allocates on its own.

const std = @import("std");

pub const message = @import("message.zig");
pub const tool = @import("tool.zig");
pub const context_item = @import("context_item.zig");
pub const agent_ref = @import("agent_ref.zig");
pub const assist = @import("assist.zig");
pub const json = @import("json.zig");

/// See `message.ProviderId`.
pub const ProviderId = message.ProviderId;
/// See `message.Role`.
pub const Role = message.Role;
/// See `message.Blob`.
pub const Blob = message.Blob;
/// See `message.ContentBlock`.
pub const ContentBlock = message.ContentBlock;
/// See `message.ResultPart`.
pub const ResultPart = message.ResultPart;
/// See `message.Message`.
pub const Message = message.Message;
/// See `message.Meta`.
pub const Meta = message.Meta;
/// See `message.Usage`.
pub const Usage = message.Usage;
/// See `message.StopReason`.
pub const StopReason = message.StopReason;
/// See `tool.ToolSpec`.
pub const ToolSpec = tool.ToolSpec;
/// See `tool.ToolHandler`.
pub const ToolHandler = tool.ToolHandler;
/// See `tool.ToolCall`.
pub const ToolCall = tool.ToolCall;
/// See `tool.ToolOutput`.
pub const ToolOutput = tool.ToolOutput;
/// See `tool.ToolError`.
pub const ToolError = tool.ToolError;
/// See `tool.Effects`.
pub const Effects = tool.Effects;
/// See `context_item.ContextRef`.
pub const ContextRef = context_item.ContextRef;
/// See `context_item.ContextItem`.
pub const ContextItem = context_item.ContextItem;
/// See `agent_ref.SessionId`.
pub const SessionId = agent_ref.SessionId;
/// See `agent_ref.AgentRef`.
pub const AgentRef = agent_ref.AgentRef;
/// See `assist.AssistKind`.
pub const AssistKind = assist.AssistKind;
/// See `assist.AssistRequest`.
pub const AssistRequest = assist.AssistRequest;

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests/json_roundtrip.zig");
}
