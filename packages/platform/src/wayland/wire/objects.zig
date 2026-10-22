//! The object table. Client ids (from 1, the display) index a dense array
//! and are reused, newest first, only after the compositor confirms with
//! `wl_display.delete_id`. Server ids (0xff000000 and up, created by
//! events) live in a hash map.

const std = @import("std");
const Connection = @import("connection.zig").Connection;
const FdQueue = @import("fdqueue.zig").FdQueue;

/// The first server-allocated id.
pub const server_base: u32 = 0xff000000;

/// Receives the events of the objects it was registered for. `body` (the
/// words after the header) is valid only during the call; fds the handler
/// does not pop are closed after it returns.
pub const Handler = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, conn: *Connection, obj: u32, opcode: u16, body: []const u32, fds: *FdQueue) anyerror!void,
};

/// An object an event creates.
pub const Created = struct { id: u32, info: *const Info };

/// What the connection knows of an interface without its type.
pub const Info = struct {
    name: []const u8,
    event_fds: []const u8,
    event_destructors: []const bool,
    /// The object event `opcode` creates, if it creates one.
    created: *const fn (opcode: u16, body: []const u32) error{Protocol}!?Created,
};

/// The `Info` of generated interface `I`.
pub fn infoOf(comptime I: type) *const Info {
    return &struct {
        const info: Info = .{
            .name = I.name,
            .event_fds = &I.event_fds,
            .event_destructors = &I.event_destructors,
            .created = created,
        };

        fn created(opcode: u16, body: []const u32) error{Protocol}!?Created {
            inline for (I.event_new_ids, 0..) |maybe, op| {
                if (maybe) |n| if (op == opcode) {
                    var no_fds: NoFds = .{};
                    const ev = try I.decodeEvent(opcode, body, &no_fds);
                    const tag: std.meta.Tag(I.Event) = @enumFromInt(op);
                    const payload = @field(ev, @tagName(tag));
                    return .{ .id = @intFromEnum(@field(payload, n.field)), .info = infoOf(n.interface) };
                };
            }
            return null;
        }
    }.info;
}

/// Lets a decoder run without consuming fds.
const NoFds = struct {
    fn pop(_: *NoFds) ?i32 {
        return -1;
    }
};

/// A slot's state. `zombie`: destroyed by us, waiting for `delete_id`;
/// its events are dropped.
pub const State = enum(u8) { free, live, zombie };

/// One object.
pub const Object = struct {
    state: State = .free,
    info: *const Info = undefined,
    version: u32 = 0,
    handler: ?Handler = null,
};

/// Errors from the table.
pub const Error = error{ OutOfMemory, Protocol, IdsExhausted };

/// The table.
pub const Table = struct {
    client: std.ArrayList(Object) = .empty,
    server: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    free_ids: std.ArrayList(u32) = .empty,

    /// Frees the table.
    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        t.client.deinit(gpa);
        t.server.deinit(gpa);
        t.free_ids.deinit(gpa);
    }

    /// Reserves a client id for a new object.
    pub fn alloc(t: *Table, gpa: std.mem.Allocator, info: *const Info, version: u32, handler: ?Handler) Error!u32 {
        const obj: Object = .{ .state = .live, .info = info, .version = version, .handler = handler };
        if (t.free_ids.pop()) |id| {
            t.client.items[id] = obj;
            return id;
        }
        if (t.client.items.len == 0) try t.client.append(gpa, .{}); // id 0 is null
        if (t.client.items.len >= server_base) return error.IdsExhausted;
        const id: u32 = @intCast(t.client.items.len);
        try t.client.append(gpa, obj);
        // Keep room for the free list too, so delete_id never allocates.
        try t.free_ids.ensureTotalCapacity(gpa, t.client.items.len);
        return id;
    }

    /// Registers a server-allocated object created by an event.
    pub fn insertServer(t: *Table, gpa: std.mem.Allocator, id: u32, info: *const Info, version: u32) Error!void {
        if (id < server_base) return error.Protocol;
        const gop = try t.server.getOrPut(gpa, id);
        if (gop.found_existing and gop.value_ptr.state == .live) return error.Protocol;
        gop.value_ptr.* = .{ .state = .live, .info = info, .version = version };
    }

    /// The object with `id`, unless the slot is free.
    pub fn get(t: *Table, id: u32) ?*Object {
        const o = if (id >= server_base) t.server.getPtr(id) orelse return null else if (id < t.client.items.len) &t.client.items[id] else return null;
        return if (o.state == .free) null else o;
    }

    /// Marks `id` destroyed: client objects wait for `delete_id`, server
    /// objects go at once.
    pub fn destroy(t: *Table, id: u32) void {
        if (id >= server_base) {
            _ = t.server.remove(id);
            return;
        }
        if (t.get(id)) |o| o.state = .zombie;
    }

    /// Handles `wl_display.delete_id`: the id may be reused.
    pub fn deleteId(t: *Table, id: u32) Error!void {
        if (id <= 1 or id >= t.client.items.len) return error.Protocol;
        const o = &t.client.items[id];
        if (o.state == .free) return error.Protocol;
        o.* = .{};
        t.free_ids.appendAssumeCapacity(id);
    }
};

const testing = std.testing;

const test_info: Info = .{ .name = "t", .event_fds = &.{}, .event_destructors = &.{}, .created = noCreated };
fn noCreated(_: u16, _: []const u32) error{Protocol}!?Created {
    return null;
}

test "ids are reused only after delete_id, newest first" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try testing.expectEqual(1, try t.alloc(testing.allocator, &test_info, 1, null));
    const a = try t.alloc(testing.allocator, &test_info, 1, null);
    const b = try t.alloc(testing.allocator, &test_info, 1, null);
    try testing.expectEqual(2, a);
    try testing.expectEqual(3, b);
    t.destroy(a);
    t.destroy(b);
    try testing.expectEqual(State.zombie, t.get(a).?.state);
    try testing.expectEqual(4, try t.alloc(testing.allocator, &test_info, 1, null));
    try t.deleteId(a);
    try t.deleteId(b);
    try testing.expectEqual(null, t.get(a));
    try testing.expectError(error.Protocol, t.deleteId(a));
    try testing.expectEqual(b, try t.alloc(testing.allocator, &test_info, 1, null));
    try testing.expectEqual(a, try t.alloc(testing.allocator, &test_info, 1, null));
    try testing.expectEqual(5, try t.alloc(testing.allocator, &test_info, 1, null));
}

test "server ids" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try testing.expectError(error.Protocol, t.insertServer(testing.allocator, 5, &test_info, 1));
    try t.insertServer(testing.allocator, server_base, &test_info, 3);
    try testing.expectEqual(3, t.get(server_base).?.version);
    try testing.expectError(error.Protocol, t.insertServer(testing.allocator, server_base, &test_info, 3));
    t.destroy(server_base);
    try testing.expectEqual(null, t.get(server_base));
}
