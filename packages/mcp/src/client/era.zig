//! Era detection: whether a server speaks the modern protocol (2026-07-28,
//! `server/discover` and per-request metadata) or a legacy one
//! (`initialize` sessions), and at which revision. These are the decision
//! tables of VERS, STDIO and SHTTP "Backward Compatibility" as pure
//! functions; `Client.connect` drives the probes.
//!
//! stdio and in-process: send `server/discover`; a result or a modern error
//! carrying `data.supported` selects the revision; anything else (any other
//! error, a timeout, garbage) means legacy. The fallback never keys on one
//! specific error code (STDIO MUST NOT).
//!
//! HTTP: as above for 2xx and for 4xx bodies holding a modern JSON-RPC
//! error; a 4xx without one means legacy, and if `initialize` then fails
//! with 400/404/405 the server is HTTP+SSE (2024-11-05).

const std = @import("std");
const protocol = @import("../protocol/root.zig");
const Transport = @import("../transport/Transport.zig");

const Revision = protocol.Revision;
const Era = protocol.revision.Era;
const Value = std.json.Value;

/// The result of detection, persisted by the host (F07) so that the next
/// connection can skip the probe (`Options.era_hint`).
pub const EraDetection = struct {
    era: Era,
    revision: Revision,
    transport: Transport.Kind,
    /// Human readable, for the manager UI.
    reason: []const u8,
};

/// What a `server/discover` probe produced.
pub const ProbeResponse = union(enum) {
    result: protocol.messages.DiscoverResult,
    /// A JSON-RPC error response (`data` parsed, or null).
    rpc_error: struct { code: i64, data: ?Value },
    /// No usable response: timeout, a non-JSON reply, a transport error or
    /// an HTTP status without a modern error body.
    no_response,
};

/// What to do next.
pub const Decision = union(enum) {
    /// Modern at this revision; the probe's result holds the capabilities.
    modern: Revision,
    /// Probe again at this (modern) revision: the server rejected ours with
    /// `-32022` and listed this one.
    retry_modern: Revision,
    /// Legacy: `initialize` asking for this revision.
    legacy: Revision,
    /// The server needs client capabilities we did not declare (`-32021`).
    missing_capability,
    /// The server lists revisions but none we implement.
    unsupported,
};

/// The newest legacy revision in `ours` (null when we speak none).
pub fn newestLegacy(ours: []const Revision) ?Revision {
    var best: ?Revision = null;
    for (ours) |r| if (r.era() == .legacy and (best == null or @intFromEnum(r) > @intFromEnum(best.?))) {
        best = r;
    };
    return best;
}

/// The newest modern revision in `ours` (what the first probe asks for).
pub fn newestModern(ours: []const Revision) ?Revision {
    var best: ?Revision = null;
    for (ours) |r| if (r.era() == .modern and (best == null or @intFromEnum(r) > @intFromEnum(best.?))) {
        best = r;
    };
    return best;
}

/// Applies the backward-compatibility table to a probe at `asked`.
pub fn decide(ours: []const Revision, asked: Revision, resp: ProbeResponse) Decision {
    const fallback: Decision = if (newestLegacy(ours)) |l| .{ .legacy = l } else .unsupported;
    switch (resp) {
        .result => |d| {
            const r = protocol.negotiate.pickRevision(ours, d.supported_versions) orelse return .unsupported;
            return if (r.era() == .modern) .{ .modern = r } else .{ .legacy = r };
        },
        .rpc_error => |e| {
            const code: i32 = std.math.cast(i32, e.code) orelse return fallback;
            const modern_code = code == protocol.errors.unsupported_protocol_version or
                code == protocol.errors.missing_required_client_capability or
                code == protocol.errors.header_mismatch;
            if (!modern_code) return fallback;
            if (supportedList(e.data)) |list| {
                const r = pickFromValues(ours, list) orelse return .unsupported;
                if (r.era() == .legacy) return .{ .legacy = r };
                // Asking again for the same revision would loop.
                return if (r == asked) .{ .modern = r } else .{ .retry_modern = r };
            }
            if (code == protocol.errors.missing_required_client_capability) return .missing_capability;
            return fallback;
        },
        .no_response => return fallback,
    }
}

fn supportedList(data: ?Value) ?[]const Value {
    const d = data orelse return null;
    if (d != .object) return null;
    const s = d.object.get("supported") orelse return null;
    if (s != .array) return null;
    return s.array.items;
}

fn pickFromValues(ours: []const Revision, list: []const Value) ?Revision {
    var best: ?Revision = null;
    for (list) |v| {
        if (v != .string) continue;
        const r = Revision.parse(v.string) orelse continue;
        if (std.mem.indexOfScalar(Revision, ours, r) == null) continue;
        if (best == null or @intFromEnum(r) > @intFromEnum(best.?)) best = r;
    }
    return best;
}

/// Whether an HTTP status during legacy `initialize` means the endpoint is
/// an HTTP+SSE (2024-11-05) server rather than Streamable HTTP.
pub fn isSseFallbackStatus(status: u16) bool {
    return status == 400 or status == 404 or status == 405;
}

/// The cache key for a detection: `stdio:<hash of command, args, cwd>` or
/// `http:<scheme://host[:port]>` (the origin).
pub fn cacheKey(buf: []u8, kind: enum { stdio, http }, parts: []const []const u8) []const u8 {
    switch (kind) {
        .stdio => {
            var h: std.hash.Wyhash = .init(0);
            for (parts) |p| {
                h.update(p);
                h.update(&.{0});
            }
            return std.fmt.bufPrint(buf, "stdio:{x:0>16}", .{h.final()}) catch buf[0..0];
        },
        .http => {
            const u = if (parts.len > 0) parts[0] else "";
            const scheme_end = std.mem.indexOf(u8, u, "://") orelse return std.fmt.bufPrint(buf, "http:{s}", .{u}) catch buf[0..0];
            const rest = u[scheme_end + 3 ..];
            const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
            var authority = rest[0..auth_end];
            // Userinfo is not part of the origin (and may be a credential).
            if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
            return std.fmt.bufPrint(buf, "http:{s}://{s}", .{ u[0..scheme_end], authority }) catch buf[0..0];
        },
    }
}

const testing = std.testing;
const all = std.enums.values(Revision);

fn errData(arena: std.mem.Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, json, .{});
}

test "era: decision table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Discover result: highest common revision.
    const d: protocol.messages.DiscoverResult = .{ .supported_versions = &.{ "2026-07-28", "2025-11-25" }, .capabilities = .empty };
    try testing.expectEqual(Decision{ .modern = .v2026_07_28 }, decide(all, .v2026_07_28, .{ .result = d }));
    // Any non-modern error, whatever the code, means legacy.
    for ([_]i64{ -32601, -32602, -32600, -32603, 1 }) |code|
        try testing.expectEqual(Decision{ .legacy = .v2025_11_25 }, decide(all, .v2026_07_28, .{ .rpc_error = .{ .code = code, .data = null } }));
    try testing.expectEqual(Decision{ .legacy = .v2025_11_25 }, decide(all, .v2026_07_28, .no_response));
    // -32022 listing only legacy revisions: initialize at the best one.
    const only_legacy = try errData(a, "{\"supported\":[\"2025-06-18\",\"2025-11-25\"],\"requested\":\"2026-07-28\"}");
    try testing.expectEqual(Decision{ .legacy = .v2025_11_25 }, decide(all, .v2026_07_28, .{ .rpc_error = .{ .code = -32022, .data = only_legacy } }));
    // -32022 listing nothing we speak.
    const none = try errData(a, "{\"supported\":[\"2099-01-01\"]}");
    try testing.expectEqual(Decision.unsupported, decide(all, .v2026_07_28, .{ .rpc_error = .{ .code = -32022, .data = none } }));
    // -32021 without a list: the server is modern but wants more.
    try testing.expectEqual(Decision.missing_capability, decide(all, .v2026_07_28, .{ .rpc_error = .{ .code = -32021, .data = null } }));
    // A client limited to legacy revisions never goes modern.
    try testing.expectEqual(Decision{ .legacy = .v2025_06_18 }, decide(&.{ .v2025_03_26, .v2025_06_18 }, .v2026_07_28, .{ .result = .{ .supported_versions = &.{ "2026-07-28", "2025-06-18" }, .capabilities = .empty } }));
}

test "era: cache keys" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("http:https://mcp.example.com:8443", cacheKey(&buf, .http, &.{"https://user:secret@mcp.example.com:8443/mcp?x=1"}));
    var b2: [128]u8 = undefined;
    const k1 = cacheKey(&buf, .stdio, &.{ "npx", "server" });
    const k2 = cacheKey(&b2, .stdio, &.{ "npxs", "erver" });
    try testing.expect(!std.mem.eql(u8, k1, k2));
}
