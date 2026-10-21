//! Per-protocol cancellation notifications.
//!
//! - `lsp`: `$/cancelRequest {"id": <id>}`.
//! - `mcp`: `notifications/cancelled {"requestId": <id>, "reason": "..."}`
//!   (stdio; E11 cancels HTTP requests by closing the stream).
//! - `plain`: no cancellation message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const message = @import("message.zig");
const Id = message.Id;

pub const Dialect = enum { plain, lsp, mcp };

/// The dialect's cancel notification method, or null for `plain`.
pub fn cancelMethod(d: Dialect) ?[]const u8 {
    return switch (d) {
        .plain => null,
        .lsp => "$/cancelRequest",
        .mcp => "notifications/cancelled",
    };
}

/// Writes the cancel notification for `id`; does nothing for `plain`.
pub fn writeCancel(d: Dialect, w: *std.Io.Writer, id: Id, reason: []const u8) !void {
    switch (d) {
        .plain => {},
        .lsp => try message.writeNotification(w, "$/cancelRequest", .{ .id = id }),
        .mcp => try message.writeNotification(w, "notifications/cancelled", .{ .requestId = id, .reason = reason }),
    }
}

/// If `n` is the dialect's cancel notification, the cancelled request id.
pub fn cancelledId(d: Dialect, arena: Allocator, n: message.Notification) ?Id {
    const method = cancelMethod(d) orelse return null;
    if (!std.mem.eql(u8, n.method, method)) return null;
    const params = n.params orelse return null;
    const v = params.parseLeaky(std.json.Value, arena, .{}) catch return null;
    if (v != .object) return null;
    const field = v.object.get(if (d == .lsp) "id" else "requestId") orelse return null;
    return switch (field) {
        .integer => |i| .{ .int = i },
        .string => |s| .{ .str = s },
        else => null,
    };
}

test "dialect: cancel round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]Dialect{ .lsp, .mcp }) |d| {
        for ([_]Id{ .{ .int = 7 }, .{ .str = "r1" } }) |id| {
            var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer aw.deinit();
            try writeCancel(d, &aw.writer, id, "user");
            const n = message.parse(arena.allocator(), aw.written()).single.notification;
            try std.testing.expect(cancelledId(d, arena.allocator(), n).?.eql(id));
            try std.testing.expect(cancelledId(if (d == .lsp) .mcp else .lsp, arena.allocator(), n) == null);
        }
    }
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeCancel(.lsp, &aw.writer, .{ .int = 3 }, "");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":3}}", aw.written());
}
