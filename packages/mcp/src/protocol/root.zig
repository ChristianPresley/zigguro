//! `zg_mcp.protocol`: the MCP message model for every supported revision
//! and its JSON codec.
//!
//! Every decode takes an arena and returns values that borrow from it only;
//! `zg_jsonrpc` `RawJson` bodies may be freed once a decode returns.

const std = @import("std");

pub const codec = @import("codec.zig");
pub const ids = @import("ids.zig");
pub const meta = @import("meta.zig");
pub const content = @import("content.zig");
pub const capabilities = @import("capabilities.zig");
pub const messages = @import("messages.zig");
pub const errors = @import("errors.zig");
pub const revision = @import("revision.zig");
pub const negotiate = @import("negotiate.zig");

/// See `revision.Revision`.
pub const Revision = revision.Revision;
/// See `revision.Feature`.
pub const Feature = revision.Feature;
/// See `negotiate.Negotiated`.
pub const Negotiated = negotiate.Negotiated;

/// A JSON-RPC request id (never null on requests).
pub const RequestId = ids.RequestId;
/// A progress token.
pub const ProgressToken = ids.ProgressToken;
/// Reserved `_meta` key names.
pub const meta_keys = meta.meta_keys;
/// See `meta.isValidMetaKey`.
pub const isValidMetaKey = meta.isValidMetaKey;
/// See `meta.isReservedMetaPrefix`.
pub const isReservedMetaPrefix = meta.isReservedMetaPrefix;
/// See `meta.RequestMeta`.
pub const RequestMeta = meta.RequestMeta;
/// See `capabilities.Capabilities`.
pub const Capabilities = capabilities.Capabilities;
/// Client capabilities are a `Capabilities` object.
pub const ClientCapabilities = Capabilities;
/// Server capabilities are a `Capabilities` object.
pub const ServerCapabilities = Capabilities;
/// See `content.ContentBlock`.
pub const ContentBlock = content.ContentBlock;
/// See `content.Annotations`.
pub const Annotations = content.Annotations;
/// See `content.Role`.
pub const Role = content.Role;
/// See `messages.Implementation`.
pub const Implementation = messages.Implementation;
/// See `messages.Icon`.
pub const Icon = messages.Icon;
/// See `messages.Method`.
pub const Method = messages.Method;
/// See `messages.Notification`.
pub const Notification = messages.Notification;
/// See `messages.InputRequiredResult`.
pub const InputRequiredResult = messages.InputRequiredResult;
/// See `messages.CreateTaskResult`.
pub const CreateTaskResult = messages.CreateTaskResult;
/// See `codec.Decoded`.
pub const Decoded = codec.Decoded;

test {
    std.testing.refAllDecls(@This());
    _ = @import("golden_test.zig");
    _ = @import("fuzz_test.zig");
}
