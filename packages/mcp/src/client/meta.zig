//! Per-request `_meta` for the client (BASIC "_meta", VERS "Per-request
//! metadata"). Modern (2026-07-28) requests carry the protocol version,
//! the client's full capability set and, unless privacy settings forbid
//! it, the client's identity on every request. Legacy requests carry only
//! what the caller asked for (progress token, trace context).

const std = @import("std");
const protocol = @import("../protocol/root.zig");

const RequestMeta = protocol.RequestMeta;
const Era = protocol.revision.Era;

/// What the client adds to a request's `_meta`.
pub const Ours = struct {
    revision: protocol.Revision,
    client_capabilities: protocol.ClientCapabilities,
    /// Null when the privacy setting withholds the client's identity.
    client_info: ?protocol.Implementation,
    log_level: ?protocol.messages.LoggingLevel = null,
    progress_token: ?protocol.ProgressToken = null,
    traceparent: ?[]const u8 = null,
    tracestate: ?[]const u8 = null,
};

/// Why caller `_meta` was refused.
pub const Error = error{
    /// A caller key is not a well-formed `_meta` key.
    InvalidMetaKey,
    /// A caller key uses a prefix reserved for MCP (`io.modelcontextprotocol/`,
    /// `dev.mcp/`, ...); only zg_mcp's typed fields may write those.
    ReservedMetaKey,
};

/// Merges `ours` into the caller's `_meta` without clobbering caller keys:
/// the caller's progress token, log level and trace context win; the
/// protocol-owned version, capabilities and identity are always ours (and
/// absent in the legacy era). Returns null when nothing is left to send.
pub fn merge(caller: ?RequestMeta, era: Era, ours: Ours) Error!?RequestMeta {
    var m: RequestMeta = caller orelse .{};
    if (m.extra) |extra| if (extra == .object) {
        var it = extra.object.iterator();
        while (it.next()) |e| try checkKey(e.key_ptr.*);
    };
    switch (era) {
        .modern => {
            m.protocol_version = ours.revision.string();
            m.client_capabilities = ours.client_capabilities;
            m.client_info = ours.client_info;
            if (m.log_level == null) m.log_level = ours.log_level;
        },
        .legacy => {
            m.protocol_version = null;
            m.client_capabilities = null;
            m.client_info = null;
            // Legacy peers set the level with `logging/setLevel`.
            m.log_level = null;
        },
    }
    if (m.progress_token == null) m.progress_token = ours.progress_token;
    if (m.traceparent == null) m.traceparent = ours.traceparent;
    if (m.tracestate == null) m.tracestate = ours.tracestate;
    if (isEmpty(m)) return null;
    return m;
}

fn checkKey(key: []const u8) Error!void {
    if (!protocol.isValidMetaKey(key)) return error.InvalidMetaKey;
    if (std.mem.lastIndexOfScalar(u8, key, '/')) |slash| {
        if (protocol.isReservedMetaPrefix(key[0..slash])) return error.ReservedMetaKey;
    }
}

fn isEmpty(m: RequestMeta) bool {
    inline for (@typeInfo(RequestMeta).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "extra")) {
            if (m.extra) |e| if (e != .object or e.object.count() > 0) return false;
        } else if (@field(m, f.name) != null) return false;
    }
    return true;
}

const testing = std.testing;
const codec = protocol.codec;

test "meta: required keys on every modern request" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caps = try protocol.capabilities.defaultClient(a, .{});
    const m = (try merge(null, .modern, .{
        .revision = .v2026_07_28,
        .client_capabilities = caps,
        .client_info = .{ .name = "zigguro", .version = "0.1.0" },
    })).?;
    const v = try codec.toValue(a, m);
    try testing.expectEqualStrings("2026-07-28", v.object.get(protocol.meta_keys.protocol_version).?.string);
    try testing.expect(v.object.get(protocol.meta_keys.client_capabilities).?.object.get("elicitation") != null);
    try testing.expectEqualStrings("zigguro", v.object.get(protocol.meta_keys.client_info).?.object.get("name").?.string);

    // Privacy: identity withheld, version and capabilities still present.
    const anon = (try merge(null, .modern, .{ .revision = .v2026_07_28, .client_capabilities = caps, .client_info = null })).?;
    try testing.expect(anon.client_info == null and anon.protocol_version != null and anon.client_capabilities != null);
}

test "meta: caller _meta preserved" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caller = try codec.decodeBytes(RequestMeta, a,
        \\{"progressToken":"mine","com.example/trace":"abc","io.modelcontextprotocol/protocolVersion":"1999-01-01"}
    , .{});
    // Typed fields are zg_mcp's; a stale version from the caller is replaced.
    const m = (try merge(caller, .modern, .{
        .revision = .v2026_07_28,
        .client_capabilities = .empty,
        .client_info = null,
        .progress_token = .{ .int = 9 },
    })).?;
    const v = try codec.toValue(a, m);
    try testing.expectEqualStrings("mine", v.object.get("progressToken").?.string);
    try testing.expectEqualStrings("abc", v.object.get("com.example/trace").?.string);
    try testing.expectEqualStrings("2026-07-28", v.object.get(protocol.meta_keys.protocol_version).?.string);

    // Legacy: only the caller's keys and the progress token.
    const l = (try merge(null, .legacy, .{ .revision = .v2025_11_25, .client_capabilities = .empty, .client_info = null, .progress_token = .{ .int = 3 } })).?;
    try testing.expectEqualStrings("{\"progressToken\":3}", try codec.encodeAlloc(a, l));
    try testing.expect(try merge(null, .legacy, .{ .revision = .v2025_11_25, .client_capabilities = .empty, .client_info = null }) == null);
}

test "meta: reserved and malformed caller keys refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ours: Ours = .{ .revision = .v2026_07_28, .client_capabilities = .empty, .client_info = null };
    const reserved = try codec.decodeBytes(RequestMeta, a, "{\"dev.mcp/x\":1}", .{});
    try testing.expectError(error.ReservedMetaKey, merge(reserved, .modern, ours));
    const bad = try codec.decodeBytes(RequestMeta, a, "{\"bad key\":1}", .{});
    try testing.expectError(error.InvalidMetaKey, merge(bad, .modern, ours));
}
