//! Version selection and the effective capability set between a client and
//! a server.

const std = @import("std");
const Value = std.json.Value;
const revision = @import("revision.zig");
const capabilities = @import("capabilities.zig");
const Revision = revision.Revision;
const Capabilities = capabilities.Capabilities;

/// The outcome of version selection plus both sides' capabilities.
pub const Negotiated = struct {
    revision: Revision,
    client: Capabilities,
    server: Capabilities,

    /// Whether the server declared dotted `path` (`"resources.subscribe"`).
    pub fn serverSupports(n: Negotiated, comptime path: []const u8) bool {
        return n.server.has(path);
    }

    /// Whether the client declared dotted `path`. An empty `elicitation: {}`
    /// means form mode only (ELICITATION "Capabilities").
    pub fn clientDeclared(n: Negotiated, comptime path: []const u8) bool {
        if (comptime std.mem.eql(u8, path, "elicitation.form")) {
            if (n.client.get("elicitation")) |e| if (e == .object and e.object.count() == 0) return true;
        }
        return n.client.has(path);
    }

    /// The server's settings for extension `id`, if both sides declared it.
    pub fn extension(n: Negotiated, id: []const u8) ?Value {
        _ = n.client.extension(id) orelse return null;
        return n.server.extension(id);
    }
};

/// The highest revision in both `ours` and `theirs` (wire strings from
/// `server/discover` `supportedVersions` or `-32022` `data.supported`), or
/// null when there is none; the caller then reports both lists.
pub fn pickRevision(ours: []const Revision, theirs: []const []const u8) ?Revision {
    var best: ?Revision = null;
    for (theirs) |s| {
        const r = Revision.parse(s) orelse continue;
        if (std.mem.indexOfScalar(Revision, ours, r) == null) continue;
        if (best == null or @intFromEnum(r) > @intFromEnum(best.?)) best = r;
    }
    return best;
}

/// Legacy `initialize` semantics: the client requested `requested`; the
/// server replied with `server_reply`. The client accepts any legacy
/// revision it implements and otherwise must disconnect.
pub fn legacyNegotiate(requested: Revision, server_reply: []const u8) error{UnsupportedRevision}!Revision {
    std.debug.assert(requested.era() == .legacy);
    const r = Revision.parse(server_reply) orelse return error.UnsupportedRevision;
    if (r.era() != .legacy) return error.UnsupportedRevision;
    return r;
}

const testing = std.testing;
const codec = @import("codec.zig");

test "negotiate: pickRevision highest common" {
    const ours = std.enums.values(Revision);
    try testing.expectEqual(Revision.v2025_11_25, pickRevision(ours, &.{ "2025-06-18", "2025-11-25", "2099-01-01" }).?);
    try testing.expectEqual(Revision.v2026_07_28, pickRevision(ours, &.{ "2026-07-28", "2025-11-25" }).?);
    try testing.expectEqual(Revision.v2025_06_18, pickRevision(&.{ .v2025_03_26, .v2025_06_18 }, &.{ "2026-07-28", "2025-06-18", "2025-03-26" }).?);
}

test "negotiate: no common => null" {
    try testing.expect(pickRevision(std.enums.values(Revision), &.{ "1900-01-01", "2099-01-01" }) == null);
    try testing.expect(pickRevision(&.{.v2026_07_28}, &.{"2025-11-25"}) == null);
}

test "negotiate: legacy initialize" {
    try testing.expectEqual(Revision.v2025_06_18, try legacyNegotiate(.v2025_11_25, "2025-06-18"));
    try testing.expectError(error.UnsupportedRevision, legacyNegotiate(.v2025_11_25, "2026-07-28"));
    try testing.expectError(error.UnsupportedRevision, legacyNegotiate(.v2025_11_25, "1.0"));
}

test "negotiate: elicitation {} == form only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n: Negotiated = .{
        .revision = .v2025_11_25,
        .client = try codec.decodeBytes(Capabilities, a, "{\"elicitation\":{}}", .{}),
        .server = .empty,
    };
    try testing.expect(n.clientDeclared("elicitation.form"));
    try testing.expect(!n.clientDeclared("elicitation.url"));
    const both: Negotiated = .{
        .revision = .v2026_07_28,
        .client = try codec.decodeBytes(Capabilities, a, "{\"elicitation\":{\"url\":{}}}", .{}),
        .server = .empty,
    };
    try testing.expect(!both.clientDeclared("elicitation.form"));
    try testing.expect(both.clientDeclared("elicitation.url"));
}

test "negotiate: extension lookup" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n: Negotiated = .{
        .revision = .v2026_07_28,
        .client = try capabilities.defaultClient(a, .{}),
        .server = try codec.decodeBytes(Capabilities, a,
            \\{"tools":{},"extensions":{"io.modelcontextprotocol/tasks":{"x":1},"com.example/other":{}}}
        , .{}),
    };
    try testing.expect(n.serverSupports("tools"));
    try testing.expect(!n.serverSupports("prompts"));
    try testing.expectEqual(@as(i64, 1), n.extension(capabilities.tasks_extension).?.object.get("x").?.integer);
    try testing.expect(n.extension("com.example/other") == null);
}
