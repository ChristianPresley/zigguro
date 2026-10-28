//! Sources without a path (E07.F06.S04.T01): a frame whose `source` has a
//! `sourceReference > 0` and no `path` is fetched with the `source`
//! request and opened as a read-only virtual document
//! `dap-source:<session>/<reference>`. Contents are kept per session.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const scheme = "dap-source";

/// `dap-source:<session>/<reference>`, in `a`.
pub fn uri(a: Allocator, session: u32, reference: i64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, scheme ++ ":{d}/{d}", .{ session, reference });
}

pub const Parsed = struct { session: u32, reference: i64 };

/// The inverse of `uri`; null for anything else.
pub fn parseUri(text: []const u8) ?Parsed {
    if (!std.mem.startsWith(u8, text, scheme ++ ":")) return null;
    const rest = text[scheme.len + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return .{
        .session = std.fmt.parseInt(u32, rest[0..slash], 10) catch return null,
        .reference = std.fmt.parseInt(i64, rest[slash + 1 ..], 10) catch return null,
    };
}

/// A frame source needs the `source` request.
pub fn needsFetch(path: ?[]const u8, reference: ?i64) bool {
    return path == null and (reference orelse 0) > 0;
}

pub const Content = struct {
    text: []const u8,
    mime_type: ?[]const u8,
};

/// Decodes a `source` response body, strings in `a`.
pub fn decode(a: Allocator, body: []const u8) ?Content {
    const B = struct { content: []const u8 = "", mimeType: ?[]const u8 = null };
    const b = std.json.parseFromSliceLeaky(B, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return .{ .text = b.content, .mime_type = b.mimeType };
}

/// Fetched contents by reference.
pub const Cache = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMapUnmanaged(i64, Content) = .empty,

    pub fn init(gpa: Allocator) Cache {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(c: *Cache) void {
        c.arena.deinit();
        c.* = undefined;
    }

    pub fn get(c: *const Cache, reference: i64) ?Content {
        return c.map.get(reference);
    }

    /// Keeps a copy of `content`.
    pub fn put(c: *Cache, reference: i64, content: Content) Allocator.Error!Content {
        const a = c.arena.allocator();
        const copy: Content = .{ .text = try a.dupe(u8, content.text), .mime_type = if (content.mime_type) |m| try a.dupe(u8, m) else null };
        try c.map.put(a, reference, copy);
        return copy;
    }

    pub fn clear(c: *Cache) void {
        _ = c.arena.reset(.retain_capacity);
        c.map = .empty;
    }
};

test "dap-source uri roundtrip" {
    const t = std.testing;
    const u = try uri(t.allocator, 3, 1007);
    defer t.allocator.free(u);
    try t.expectEqualStrings("dap-source:3/1007", u);
    const p = parseUri(u).?;
    try t.expectEqual(@as(u32, 3), p.session);
    try t.expectEqual(@as(i64, 1007), p.reference);
    try t.expect(parseUri("file:///a") == null);
    try t.expect(needsFetch(null, 4));
    try t.expect(!needsFetch("/a.zig", 4));
    try t.expect(!needsFetch(null, 0));
}
