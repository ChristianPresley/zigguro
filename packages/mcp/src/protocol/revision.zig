//! The single source of truth for MCP protocol revisions: which exist, which
//! era each belongs to, and which methods and features each supports.
//!
//! Adding a revision means editing only this file: add the enum value, its
//! wire string, and its row in every feature set (a test fails until every
//! feature classifies every revision).

const std = @import("std");
const Method = @import("messages.zig").Method;

/// A protocol revision zigguro speaks, oldest first.
pub const Revision = enum {
    v2024_11_05,
    v2025_03_26,
    v2025_06_18,
    v2025_11_25,
    v2026_07_28,

    /// The newest revision we implement.
    pub const latest: Revision = .v2026_07_28;

    /// The wire string, e.g. `"2025-06-18"`.
    pub fn string(r: Revision) []const u8 {
        return switch (r) {
            inline else => |t| comptime wire(@tagName(t)),
        };
    }

    /// The revision for a wire string, or null.
    pub fn parse(s: []const u8) ?Revision {
        for (std.enums.values(Revision)) |r| if (std.mem.eql(u8, s, r.string())) return r;
        return null;
    }

    /// The era of the revision.
    pub fn era(r: Revision) Era {
        return if (@intFromEnum(r) >= @intFromEnum(Revision.v2026_07_28)) .modern else .legacy;
    }

    fn wire(comptime tag: []const u8) []const u8 {
        comptime {
            var out: [tag.len - 1]u8 = undefined;
            for (tag[1..], 0..) |c, i| out[i] = if (c == '_') '-' else c;
            const final = out;
            return &final;
        }
    }
};

/// Every revision, newest first (what we offer in `supportedVersions` and
/// `-32022` data).
pub const supported_newest_first = blk: {
    const vals = std.enums.values(Revision);
    var out: [vals.len]Revision = undefined;
    for (vals, 0..) |v, i| out[vals.len - 1 - i] = v;
    break :blk out;
};

/// Modern revisions carry version, identity and capabilities per request;
/// legacy revisions establish a session with `initialize`.
pub const Era = enum { legacy, modern };

/// Protocol features whose presence differs between revisions.
pub const Feature = enum {
    initialize_handshake,
    server_discover,
    per_request_meta,
    mrtr,
    server_initiated_requests,
    subscriptions_listen,
    resources_subscribe_rpc,
    get_sse_stream,
    sessions,
    sse_resumability,
    mcp_protocol_version_header,
    mcp_method_name_headers,
    x_mcp_header,
    structured_content,
    elicitation_form,
    elicitation_url,
    url_elicitation_required_error,
    elicitation_complete_notification,
    sampling_tools,
    tasks_core,
    tasks_extension,
    result_type,
    cache_hints,
    icons,
    ping,
    logging_set_level,
    json_rpc_batch,
    http_sse_transport,
    streamable_http,
    resource_link,
    title_fields,
    json_schema_2020_12_default,
};

const R = Revision;

/// The revisions in which each feature exists. Each row cites its changelog.
const table = std.enums.EnumArray(Feature, []const R).init(.{
    // 2026-07-28 changelog, major 2: initialize removed.
    .initialize_handshake = &.{ .v2024_11_05, .v2025_03_26, .v2025_06_18, .v2025_11_25 },
    // 2026-07-28 changelog, major 3.
    .server_discover = &.{.v2026_07_28},
    // 2026-07-28 changelog, major 2.
    .per_request_meta = &.{.v2026_07_28},
    // 2026-07-28 changelog, major 7.
    .mrtr = &.{.v2026_07_28},
    // 2026-07-28 changelog, major 7: replaced by MRTR.
    .server_initiated_requests = &.{ .v2024_11_05, .v2025_03_26, .v2025_06_18, .v2025_11_25 },
    // 2026-07-28 changelog, major 4.
    .subscriptions_listen = &.{.v2026_07_28},
    // 2026-07-28 changelog, major 4: resources/subscribe replaced.
    .resources_subscribe_rpc = &.{ .v2024_11_05, .v2025_03_26, .v2025_06_18, .v2025_11_25 },
    // 2025-03-26 changelog (Streamable HTTP); 2026-07-28 major 4 removed the GET endpoint.
    .get_sse_stream = &.{ .v2025_03_26, .v2025_06_18, .v2025_11_25 },
    // 2025-03-26 changelog (Mcp-Session-Id); 2026-07-28 major 1 removed sessions.
    .sessions = &.{ .v2025_03_26, .v2025_06_18, .v2025_11_25 },
    // 2025-03-26 transports (Last-Event-ID); 2026-07-28 major 9 removed resumability.
    .sse_resumability = &.{ .v2025_03_26, .v2025_06_18, .v2025_11_25 },
    // 2025-06-18 changelog, major 8 (MCP-Protocol-Version header).
    .mcp_protocol_version_header = &.{ .v2025_06_18, .v2025_11_25, .v2026_07_28 },
    // 2026-07-28 changelog, minor 4 (Mcp-Method / Mcp-Name).
    .mcp_method_name_headers = &.{.v2026_07_28},
    // 2026-07-28 changelog, minor 4 (x-mcp-header).
    .x_mcp_header = &.{.v2026_07_28},
    // 2025-06-18 changelog, major 3 (structured tool output).
    .structured_content = &.{ .v2025_06_18, .v2025_11_25, .v2026_07_28 },
    // 2025-06-18 changelog, major 5 (elicitation).
    .elicitation_form = &.{ .v2025_06_18, .v2025_11_25, .v2026_07_28 },
    // 2025-11-25 changelog (URL mode elicitation, SEP-1036).
    .elicitation_url = &.{ .v2025_11_25, .v2026_07_28 },
    // 2025-11-25 changelog (-32042); absent from 2026-07-28 (schema: "2025-11-25 only").
    .url_elicitation_required_error = &.{.v2025_11_25},
    // 2025-11-25 changelog; 2026-07-28 minor 11 removed it.
    .elicitation_complete_notification = &.{.v2025_11_25},
    // 2025-11-25 changelog (tools/toolChoice in sampling, SEP-1577).
    .sampling_tools = &.{ .v2025_11_25, .v2026_07_28 },
    // 2025-11-25 changelog (experimental tasks, SEP-1686).
    .tasks_core = &.{.v2025_11_25},
    // 2026-07-28 changelog, major 6 (tasks moved to an extension).
    .tasks_extension = &.{.v2026_07_28},
    // 2026-07-28 changelog, major 8.
    .result_type = &.{.v2026_07_28},
    // 2026-07-28 changelog, minor 5 (ttlMs / cacheScope).
    .cache_hints = &.{.v2026_07_28},
    // 2025-11-25 changelog (icons, SEP-973).
    .icons = &.{ .v2025_11_25, .v2026_07_28 },
    // 2026-07-28 changelog, major 5: ping removed.
    .ping = &.{ .v2024_11_05, .v2025_03_26, .v2025_06_18, .v2025_11_25 },
    // 2026-07-28 changelog, major 5: logging/setLevel removed.
    .logging_set_level = &.{ .v2024_11_05, .v2025_03_26, .v2025_06_18, .v2025_11_25 },
    // JSON-RPC 2.0 allowed batches; 2025-06-18 changelog, major 1 removed them.
    .json_rpc_batch = &.{ .v2024_11_05, .v2025_03_26 },
    // 2025-03-26 changelog: HTTP+SSE replaced by Streamable HTTP.
    .http_sse_transport = &.{.v2024_11_05},
    // 2025-03-26 changelog, major 2.
    .streamable_http = &.{ .v2025_03_26, .v2025_06_18, .v2025_11_25, .v2026_07_28 },
    // 2025-06-18 changelog, major 7 (resource links in tool results).
    .resource_link = &.{ .v2025_06_18, .v2025_11_25, .v2026_07_28 },
    // 2025-06-18 changelog, minor 3 (`title` for human-friendly names).
    .title_fields = &.{ .v2025_06_18, .v2025_11_25, .v2026_07_28 },
    // 2025-11-25 changelog (JSON Schema 2020-12 as the default dialect, SEP-1613).
    .json_schema_2020_12_default = &.{ .v2025_11_25, .v2026_07_28 },
});

/// Whether revision `r` has feature `f`.
pub fn has(r: Revision, f: Feature) bool {
    for (table.get(f)) |x| if (x == r) return true;
    return false;
}

/// Which way a request travels.
pub const Direction = enum { client_to_server, server_to_client };

/// Whether `m` may be sent in direction `dir` under revision `r`.
pub fn methodAllowed(r: Revision, m: Method, dir: Direction) bool {
    return switch (dir) {
        .client_to_server => switch (m) {
            .server_discover => has(r, .server_discover),
            .initialize => has(r, .initialize_handshake),
            .ping => has(r, .ping),
            .tools_list, .tools_call, .resources_list, .resources_read, .resources_templates_list => true,
            .prompts_list, .prompts_get, .completion_complete => true,
            .resources_subscribe, .resources_unsubscribe => has(r, .resources_subscribe_rpc),
            .logging_set_level => has(r, .logging_set_level),
            .subscriptions_listen => has(r, .subscriptions_listen),
            .tasks_get, .tasks_cancel => has(r, .tasks_core) or has(r, .tasks_extension),
            .tasks_result, .tasks_list => has(r, .tasks_core),
            .tasks_update => has(r, .tasks_extension),
            .sampling_create_message, .elicitation_create, .roots_list => false,
        },
        .server_to_client => switch (m) {
            .ping => has(r, .ping),
            .sampling_create_message, .roots_list => has(r, .server_initiated_requests),
            .elicitation_create => has(r, .server_initiated_requests) and has(r, .elicitation_form),
            // 2025-11-25: a server may poll tasks it asked the client to run.
            .tasks_get, .tasks_result, .tasks_list, .tasks_cancel => has(r, .tasks_core),
            else => false,
        },
    };
}

const testing = std.testing;

test "revision: parse/string round-trip" {
    for (std.enums.values(Revision)) |r| try testing.expectEqual(r, Revision.parse(r.string()).?);
    try testing.expectEqualStrings("2025-06-18", Revision.v2025_06_18.string());
    try testing.expect(Revision.parse("1900-01-01") == null);
    try testing.expectEqual(Era.modern, Revision.latest.era());
    try testing.expectEqual(Era.legacy, Revision.v2025_11_25.era());
    try testing.expectEqual(Revision.v2026_07_28, supported_newest_first[0]);
}

test "revision: every feature classified for every revision" {
    // A feature's row lists revisions explicitly; every listed revision is
    // known, and each feature is present in at least one revision.
    for (std.enums.values(Feature)) |f| {
        try testing.expect(table.get(f).len > 0);
        for (table.get(f)) |r| _ = r.string();
    }
    // Era invariants that must hold for any new revision.
    for (std.enums.values(Revision)) |r| {
        try testing.expect(has(r, .initialize_handshake) != has(r, .per_request_meta));
        try testing.expect(has(r, .server_discover) == (r.era() == .modern));
        try testing.expect(has(r, .http_sse_transport) != has(r, .streamable_http));
    }
}

test "revision: table matches changelogs" {
    // https://modelcontextprotocol.io/specification/2025-03-26/changelog
    try testing.expect(has(.v2024_11_05, .http_sse_transport));
    try testing.expect(has(.v2024_11_05, .json_rpc_batch));
    try testing.expect(has(.v2024_11_05, .initialize_handshake));
    try testing.expect(has(.v2025_03_26, .sessions));
    try testing.expect(has(.v2025_03_26, .get_sse_stream));
    try testing.expect(has(.v2025_03_26, .sse_resumability));
    try testing.expect(!has(.v2025_03_26, .mcp_protocol_version_header));
    // https://modelcontextprotocol.io/specification/2025-06-18/changelog
    try testing.expect(!has(.v2025_06_18, .json_rpc_batch));
    try testing.expect(has(.v2025_06_18, .structured_content));
    try testing.expect(has(.v2025_06_18, .elicitation_form));
    try testing.expect(has(.v2025_06_18, .resource_link));
    try testing.expect(has(.v2025_06_18, .mcp_protocol_version_header));
    try testing.expect(has(.v2025_06_18, .title_fields));
    try testing.expect(!has(.v2025_06_18, .elicitation_url));
    // https://modelcontextprotocol.io/specification/2025-11-25/changelog
    try testing.expect(has(.v2025_11_25, .icons));
    try testing.expect(has(.v2025_11_25, .elicitation_url));
    try testing.expect(has(.v2025_11_25, .url_elicitation_required_error));
    try testing.expect(has(.v2025_11_25, .elicitation_complete_notification));
    try testing.expect(has(.v2025_11_25, .sampling_tools));
    try testing.expect(has(.v2025_11_25, .tasks_core));
    try testing.expect(has(.v2025_11_25, .json_schema_2020_12_default));
    try testing.expect(!has(.v2025_06_18, .tasks_core));
    // https://modelcontextprotocol.io/specification/2026-07-28/changelog
    const m = Revision.v2026_07_28;
    try testing.expect(!has(m, .initialize_handshake));
    try testing.expect(!has(m, .ping));
    try testing.expect(!has(m, .logging_set_level));
    try testing.expect(!has(m, .sessions));
    try testing.expect(!has(m, .get_sse_stream));
    try testing.expect(!has(m, .sse_resumability));
    try testing.expect(!has(m, .server_initiated_requests));
    try testing.expect(!has(m, .resources_subscribe_rpc));
    try testing.expect(!has(m, .tasks_core));
    try testing.expect(!has(m, .url_elicitation_required_error));
    try testing.expect(!has(m, .elicitation_complete_notification));
    try testing.expect(has(m, .server_discover));
    try testing.expect(has(m, .per_request_meta));
    try testing.expect(has(m, .mrtr));
    try testing.expect(has(m, .subscriptions_listen));
    try testing.expect(has(m, .result_type));
    try testing.expect(has(m, .cache_hints));
    try testing.expect(has(m, .mcp_method_name_headers));
    try testing.expect(has(m, .x_mcp_header));
    try testing.expect(has(m, .tasks_extension));
}

test "revision: methods per era" {
    try testing.expect(methodAllowed(.v2026_07_28, .server_discover, .client_to_server));
    try testing.expect(!methodAllowed(.v2026_07_28, .initialize, .client_to_server));
    try testing.expect(!methodAllowed(.v2026_07_28, .ping, .client_to_server));
    try testing.expect(!methodAllowed(.v2026_07_28, .elicitation_create, .server_to_client));
    try testing.expect(methodAllowed(.v2025_06_18, .elicitation_create, .server_to_client));
    try testing.expect(!methodAllowed(.v2025_03_26, .elicitation_create, .server_to_client));
    try testing.expect(methodAllowed(.v2025_11_25, .tasks_list, .client_to_server));
    try testing.expect(methodAllowed(.v2026_07_28, .tasks_update, .client_to_server));
    try testing.expect(!methodAllowed(.v2026_07_28, .tasks_list, .client_to_server));
}
