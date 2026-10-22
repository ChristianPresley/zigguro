//! `_meta` keys (BASIC "_meta") and the typed request `_meta` object.

const std = @import("std");
const Value = std.json.Value;
const ids = @import("ids.zig");
const messages = @import("messages.zig");
const capabilities = @import("capabilities.zig");

/// Reserved `_meta` keys used by zigguro.
pub const meta_keys = struct {
    /// Protocol revision of a modern request (2026-07-28).
    pub const protocol_version = "io.modelcontextprotocol/protocolVersion";
    /// The client's `Implementation` on each modern request.
    pub const client_info = "io.modelcontextprotocol/clientInfo";
    /// The client's capabilities on each modern request.
    pub const client_capabilities = "io.modelcontextprotocol/clientCapabilities";
    /// Minimum log level for notifications about one request (2026-07-28).
    pub const log_level = "io.modelcontextprotocol/logLevel";
    /// Correlates a notification with its `subscriptions/listen` stream.
    pub const subscription_id = "io.modelcontextprotocol/subscriptionId";
    /// The server's `Implementation` in each modern result.
    pub const server_info = "io.modelcontextprotocol/serverInfo";
    /// Associates a message with a task (2025-11-25 tasks).
    pub const related_task = "io.modelcontextprotocol/related-task";
    /// Opts a request into progress notifications.
    pub const progress_token = "progressToken";
    /// OpenTelemetry trace context.
    pub const traceparent = "traceparent";
    /// OpenTelemetry trace state.
    pub const tracestate = "tracestate";
    /// OpenTelemetry baggage.
    pub const baggage = "baggage";
};

/// Whether `key` is a well-formed `_meta` key: an optional prefix of
/// dot-separated labels ending in `/`, then a name that, unless empty,
/// starts and ends with an alphanumeric and contains only alphanumerics,
/// `-`, `_` and `.`.
pub fn isValidMetaKey(key: []const u8) bool {
    var name = key;
    if (std.mem.lastIndexOfScalar(u8, key, '/')) |slash| {
        if (!isValidPrefix(key[0..slash])) return false;
        name = key[slash + 1 ..];
    }
    if (name.len == 0) return true;
    if (!std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

/// Labels separated by dots; each starts with a letter, ends with a letter
/// or digit and has only letters, digits and `-` inside.
fn isValidPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    var it = std.mem.splitScalar(u8, prefix, '.');
    while (it.next()) |label| {
        if (label.len == 0) return false;
        if (!std.ascii.isAlphabetic(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return false;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// Whether `prefix` (with or without the trailing `/`) is reserved for MCP:
/// its second label is `modelcontextprotocol` or `mcp`.
pub fn isReservedMetaPrefix(prefix: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, "/");
    var it = std.mem.splitScalar(u8, p, '.');
    _ = it.next() orelse return false;
    const second = it.next() orelse return false;
    return std.mem.eql(u8, second, "modelcontextprotocol") or std.mem.eql(u8, second, "mcp");
}

/// The `_meta` object of a request. In 2026-07-28 `protocol_version` and
/// `client_capabilities` are required on every request; legacy peers send
/// neither, so both are optional here and checked by the era-specific layer.
pub const RequestMeta = struct {
    progress_token: ?ids.ProgressToken = null,
    protocol_version: ?[]const u8 = null,
    client_info: ?messages.Implementation = null,
    client_capabilities: ?capabilities.Capabilities = null,
    log_level: ?messages.LoggingLevel = null,
    related_task: ?messages.RelatedTask = null,
    traceparent: ?[]const u8 = null,
    tracestate: ?[]const u8 = null,
    baggage: ?[]const u8 = null,
    extra: ?Value = null,

    pub const json_names = .{
        .progress_token = meta_keys.progress_token,
        .protocol_version = meta_keys.protocol_version,
        .client_info = meta_keys.client_info,
        .client_capabilities = meta_keys.client_capabilities,
        .log_level = meta_keys.log_level,
        .related_task = meta_keys.related_task,
    };
};

/// The `_meta` object of a result.
pub const ResultMeta = struct {
    server_info: ?messages.Implementation = null,
    subscription_id: ?ids.RequestId = null,
    related_task: ?messages.RelatedTask = null,
    extra: ?Value = null,

    pub const json_names = .{
        .server_info = meta_keys.server_info,
        .subscription_id = meta_keys.subscription_id,
        .related_task = meta_keys.related_task,
    };
};

/// The `_meta` object of a notification.
pub const NotificationMeta = struct {
    subscription_id: ?ids.RequestId = null,
    related_task: ?messages.RelatedTask = null,
    extra: ?Value = null,

    pub const json_names = .{
        .subscription_id = meta_keys.subscription_id,
        .related_task = meta_keys.related_task,
    };
};

const testing = std.testing;

test "protocol: meta key validation" {
    // https://modelcontextprotocol.io/specification/2026-07-28/basic/index#_meta
    try testing.expect(isReservedMetaPrefix("io.modelcontextprotocol/"));
    try testing.expect(isReservedMetaPrefix("dev.mcp/"));
    try testing.expect(isReservedMetaPrefix("org.modelcontextprotocol.api/"));
    try testing.expect(isReservedMetaPrefix("com.mcp.tools/"));
    try testing.expect(!isReservedMetaPrefix("com.example.mcp/"));
    try testing.expect(!isReservedMetaPrefix("mcp/"));

    try testing.expect(isValidMetaKey("progressToken"));
    try testing.expect(isValidMetaKey(meta_keys.protocol_version));
    try testing.expect(isValidMetaKey(meta_keys.related_task));
    try testing.expect(isValidMetaKey("com.example/my_key.v2"));
    try testing.expect(isValidMetaKey("com.example/"));
    try testing.expect(!isValidMetaKey("com.example/-bad"));
    try testing.expect(!isValidMetaKey("1com.example/x"));
    try testing.expect(!isValidMetaKey("com..example/x"));
    try testing.expect(!isValidMetaKey("com.example-/x"));
    try testing.expect(!isValidMetaKey("/x"));
    try testing.expect(!isValidMetaKey("bad key"));
}
