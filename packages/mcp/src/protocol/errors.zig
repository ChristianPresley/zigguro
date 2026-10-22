//! JSON-RPC and MCP error codes (BASIC "Error Codes").
//!
//! Local failures (timeouts, closed transports) are Zig errors and are never
//! encoded as wire codes.

const std = @import("std");
const Value = std.json.Value;
const codec = @import("codec.zig");
const capabilities = @import("capabilities.zig");
const messages = @import("messages.zig");

/// Invalid JSON.
pub const parse_error: i32 = -32700;
/// Not a valid request object (also the answer to a batch).
pub const invalid_request: i32 = -32600;
/// Unknown method.
pub const method_not_found: i32 = -32601;
/// Invalid params; since 2026-07-28 also "resource not found".
pub const invalid_params: i32 = -32602;
/// Internal error.
pub const internal_error: i32 = -32603;
/// HTTP headers disagree with the body (2026-07-28).
pub const header_mismatch: i32 = -32020;
/// The request needs a client capability that was not declared (2026-07-28).
pub const missing_required_client_capability: i32 = -32021;
/// The requested protocol version is not supported (2026-07-28).
pub const unsupported_protocol_version: i32 = -32022;
/// Legacy "resource not found"; still accepted from older servers.
pub const legacy_resource_not_found: i32 = -32002;
/// URL elicitation required (2025-11-25).
pub const url_elicitation_required: i32 = -32042;

/// Start of the range reserved for MCP itself (`-32099..-32020`).
pub const mcp_reserved_min: i32 = -32099;
/// End of the range reserved for MCP itself.
pub const mcp_reserved_max: i32 = -32020;

/// A classified wire error code.
pub const Code = enum {
    parse_error,
    invalid_request,
    method_not_found,
    invalid_params,
    internal_error,
    header_mismatch,
    missing_required_client_capability,
    unsupported_protocol_version,
    resource_not_found_legacy,
    url_elicitation_required,
    /// `-32000..-32019`: implementation-defined server errors.
    implementation_defined,
    other,

    /// Classifies a code received from a peer.
    pub fn of(code: i64) Code {
        return switch (code) {
            parse_error => .parse_error,
            invalid_request => .invalid_request,
            method_not_found => .method_not_found,
            invalid_params => .invalid_params,
            internal_error => .internal_error,
            header_mismatch => .header_mismatch,
            missing_required_client_capability => .missing_required_client_capability,
            unsupported_protocol_version => .unsupported_protocol_version,
            legacy_resource_not_found => .resource_not_found_legacy,
            url_elicitation_required => .url_elicitation_required,
            else => if (code >= -32019 and code <= -32000) .implementation_defined else .other,
        };
    }
};

/// `error` member of a JSON-RPC error response.
pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data: ?Value = null,
    extra: ?Value = null,
};

/// `data` of `-32022 UnsupportedProtocolVersion`.
pub const UnsupportedProtocolVersionData = struct {
    supported: []const []const u8,
    requested: []const u8,
    extra: ?Value = null,
};

/// `data` of `-32021 MissingRequiredClientCapability`.
pub const MissingRequiredClientCapabilityData = struct {
    required_capabilities: capabilities.Capabilities,
    extra: ?Value = null,
};

/// `data` of `-32042 URLElicitationRequired` (2025-11-25).
pub const UrlElicitationRequiredData = struct {
    elicitations: []const messages.ElicitParams,
    extra: ?Value = null,
};

const testing = std.testing;

test "errors: classification" {
    try testing.expectEqual(Code.unsupported_protocol_version, Code.of(-32022));
    try testing.expectEqual(Code.resource_not_found_legacy, Code.of(-32002));
    try testing.expectEqual(Code.implementation_defined, Code.of(-32010));
    try testing.expectEqual(Code.other, Code.of(-32050));
    try testing.expectEqual(Code.other, Code.of(42));
}

test "errors: data decodes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try codec.decodeBytes(UnsupportedProtocolVersionData, arena.allocator(),
        \\{"supported":["2026-07-28","2025-11-25"],"requested":"1900-01-01"}
    , .{});
    try testing.expectEqual(@as(usize, 2), d.supported.len);
}
