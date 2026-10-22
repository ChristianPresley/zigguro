//! Change notifications for both eras.
//!
//! Modern clients open a `subscriptions/listen` stream: the server first
//! sends `notifications/subscriptions/acknowledged` (tagged with the
//! subscription id, which is the listen request's id, and carrying the
//! honored filter), then only the notification types the client opted
//! into, each tagged with the same id. A graceful end answers the listen
//! request with `resultType: complete`; a client `notifications/cancelled`
//! for the listen id ends it silently. Request-scoped notifications never
//! travel on a listen stream.
//!
//! Legacy clients get `*/list_changed` on their session once initialized,
//! and `notifications/resources/updated` only for URIs they subscribed to
//! (`Server` keeps that per connection).

const Hub = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const Server = @import("Server.zig");
const ListKind = @import("registry.zig").ListKind;

const messages = protocol.messages;
const codec = protocol.codec;
const RequestId = protocol.RequestId;
const Conn = Server.Conn;

/// One open listen stream.
pub const Listen = struct {
    conn: *Conn,
    id: RequestId,
    filter: messages.SubscriptionFilter,
    arena: std.heap.ArenaAllocator,

    fn wants(l: *const Listen, k: ListKind) bool {
        const f = switch (k) {
            .tools => l.filter.tools_list_changed,
            .prompts => l.filter.prompts_list_changed,
            .resources, .templates => l.filter.resources_list_changed,
        };
        return f orelse false;
    }

    fn wantsUri(l: *const Listen, uri: []const u8) bool {
        for (l.filter.resource_subscriptions orelse return false) |u| if (std.mem.eql(u8, u, uri)) return true;
        return false;
    }
};

gpa: Allocator,
io: Io,
mutex: Io.Mutex = .init,
listens: std.ArrayList(*Listen) = .empty,

/// An empty hub.
pub fn init(gpa: Allocator, io: Io) Hub {
    return .{ .gpa = gpa, .io = io };
}

/// Drops every stream without answering.
pub fn deinit(h: *Hub) void {
    for (h.listens.items) |l| h.free(l);
    h.listens.deinit(h.gpa);
}

/// Opens a stream for listen request `id` on `conn`, sending the
/// acknowledgement before any notification can reach it.
pub fn listen(h: *Hub, conn: *Conn, id: RequestId, filter: messages.SubscriptionFilter) error{OutOfMemory}!void {
    const l = try h.gpa.create(Listen);
    l.* = .{ .conn = conn, .id = undefined, .filter = undefined, .arena = .init(h.gpa) };
    errdefer h.free(l);
    const a = l.arena.allocator();
    l.id = switch (id) {
        .str => |s| .{ .str = try a.dupe(u8, s) },
        else => id,
    };
    // We honor every type we know; unknown members are not echoed.
    l.filter = .{
        .tools_list_changed = filter.tools_list_changed,
        .prompts_list_changed = filter.prompts_list_changed,
        .resources_list_changed = filter.resources_list_changed,
        .resource_subscriptions = if (filter.resource_subscriptions) |uris| blk: {
            const out = try a.alloc([]const u8, uris.len);
            for (uris, out) |u, *o| o.* = try a.dupe(u8, u);
            break :blk out;
        } else null,
    };
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    try h.listens.append(h.gpa, l);
    sendNotification(l.conn, .{ .subscriptions_acknowledged = .{
        .notifications = l.filter,
        .meta = .{ .subscription_id = l.id },
    } });
}

/// Ends the stream for `id` on `conn` without answering (the client
/// cancelled it). False when there is none.
pub fn cancel(h: *Hub, conn: *Conn, id: RequestId) bool {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    for (h.listens.items, 0..) |l, i| if (l.conn == conn and l.id.eql(id)) {
        _ = h.listens.swapRemove(i);
        h.free(l);
        return true;
    };
    return false;
}

/// Ends every stream gracefully: each listen request gets its
/// `resultType: complete` response.
pub fn endAll(h: *Hub, server_info: messages.Implementation) void {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    for (h.listens.items) |l| {
        l.conn.sendResult(l.id, codec.withResultType(.complete, messages.SubscriptionsListenResult{
            .meta = .{ .subscription_id = l.id, .server_info = server_info },
        }));
        h.free(l);
    }
    h.listens.clearRetainingCapacity();
}

/// Drops the streams of a closed connection.
pub fn dropConn(h: *Hub, conn: *Conn) void {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    var i: usize = 0;
    while (i < h.listens.items.len) {
        const l = h.listens.items[i];
        if (l.conn == conn) {
            _ = h.listens.swapRemove(i);
            h.free(l);
        } else i += 1;
    }
}

/// Sends `*/list_changed` for `k` to the streams that opted in.
pub fn listChanged(h: *Hub, k: ListKind) void {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    for (h.listens.items) |l| if (l.wants(k)) sendNotification(l.conn, listChangedNote(k, .{ .subscription_id = l.id }));
}

/// Sends `notifications/resources/updated` to the streams watching `uri`.
pub fn resourceUpdated(h: *Hub, uri: []const u8) void {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    for (h.listens.items) |l| if (l.wantsUri(uri)) sendNotification(l.conn, .{ .resources_updated = .{
        .uri = uri,
        .meta = .{ .subscription_id = l.id },
    } });
}

/// The `list_changed` notification for `k`.
pub fn listChangedNote(k: ListKind, meta: ?protocol.meta.NotificationMeta) protocol.Notification {
    const p: messages.NotificationParams = .{ .meta = meta };
    return switch (k) {
        .tools => .{ .tools_list_changed = p },
        .prompts => .{ .prompts_list_changed = p },
        .resources, .templates => .{ .resources_list_changed = p },
    };
}

/// Writes `n` to `conn`.
pub fn sendNotification(conn: *Conn, n: protocol.Notification) void {
    var aw: std.Io.Writer.Allocating = .init(conn.server.gpa);
    defer aw.deinit();
    n.write(&aw.writer) catch return;
    conn.send(aw.written());
}

fn free(h: *Hub, l: *Listen) void {
    l.arena.deinit();
    h.gpa.destroy(l);
}
