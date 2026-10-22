//! The global registry: collects `wl_registry.global` announcements and
//! binds globals at a negotiated version.

const std = @import("std");
const wl = @import("wl_gen");
const Connection = @import("connection.zig").Connection;
const display_id = @import("connection.zig").display_id;
const Handler = @import("objects.zig").Handler;
const FdQueue = @import("fdqueue.zig").FdQueue;

/// One advertised global.
pub const Global = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

/// Told about removed globals (outputs and seats unplugged).
pub const RemoveCallback = struct {
    ctx: *anyopaque,
    on_remove: *const fn (ctx: *anyopaque, global: Global) void,
};

/// Told about globals announced after `Registry.init` (outputs and seats
/// plugged in).
pub const AddCallback = struct {
    ctx: *anyopaque,
    on_add: *const fn (ctx: *anyopaque, global: Global) void,
};

/// The registry of one connection.
pub const Registry = struct {
    conn: *Connection,
    id: wl.wl_registry.Id,
    globals: std.ArrayList(Global) = .empty,
    remove_cb: ?RemoveCallback = null,
    add_cb: ?AddCallback = null,

    /// Gets the registry and waits (one roundtrip) for the initial globals.
    pub fn init(conn: *Connection) !*Registry {
        const r = try conn.gpa.create(Registry);
        errdefer conn.gpa.destroy(r);
        r.* = .{ .conn = conn, .id = undefined };
        errdefer r.freeGlobals();
        r.id = try conn.newIdVersion(wl.wl_registry, 1, .{ .ctx = r, .on_event = onEvent });
        errdefer conn.setHandler(@intFromEnum(r.id), null);
        try wl.wl_display.getRegistry(conn, display_id, r.id);
        try conn.roundtrip();
        return r;
    }

    /// Frees the registry; the protocol has no request to destroy it, so
    /// the object stays alive with no handler.
    pub fn deinit(r: *Registry) void {
        r.conn.setHandler(@intFromEnum(r.id), null);
        r.freeGlobals();
        r.conn.gpa.destroy(r);
    }

    fn freeGlobals(r: *Registry) void {
        for (r.globals.items) |g| r.conn.gpa.free(g.interface);
        r.globals.deinit(r.conn.gpa);
    }

    /// The first global with interface `name`.
    pub fn find(r: *const Registry, name: []const u8) ?Global {
        for (r.globals.items) |g| if (std.mem.eql(u8, g.interface, name)) return g;
        return null;
    }

    /// Binds the first global of interface `I` at
    /// `min(advertised, max_version, I.version)`; null when the global is
    /// absent or older than `min_version`.
    pub fn bind(r: *Registry, comptime I: type, min_version: u32, max_version: u32, handler: ?Handler) !?I.Id {
        const g = r.find(I.name) orelse return null;
        return try r.bindGlobal(I, g, min_version, max_version, handler);
    }

    /// `bind` for a specific global (one of several outputs or seats).
    pub fn bindGlobal(r: *Registry, comptime I: type, g: Global, min_version: u32, max_version: u32, handler: ?Handler) !?I.Id {
        std.debug.assert(std.mem.eql(u8, g.interface, I.name));
        if (g.version < min_version) return null;
        const v = @min(g.version, max_version, I.version);
        const id = try r.conn.newIdVersion(I, v, handler);
        try wl.wl_registry.bind(r.conn, r.id, g.name, I.name, v, @intFromEnum(id));
        return id;
    }

    /// Sets the callback for removed globals.
    pub fn onGlobalRemove(r: *Registry, cb: ?RemoveCallback) void {
        r.remove_cb = cb;
    }

    /// Sets the callback for globals added from now on.
    pub fn onGlobalAdd(r: *Registry, cb: ?AddCallback) void {
        r.add_cb = cb;
    }

    fn onEvent(ctx: *anyopaque, _: *Connection, _: u32, opcode: u16, body: []const u32, fds: *FdQueue) anyerror!void {
        const r: *Registry = @ptrCast(@alignCast(ctx));
        switch (try wl.wl_registry.decodeEvent(opcode, body, fds)) {
            .global => |g| {
                const iface = try r.conn.gpa.dupe(u8, g.interface);
                errdefer r.conn.gpa.free(iface);
                try r.globals.append(r.conn.gpa, .{ .name = g.name, .interface = iface, .version = g.version });
                if (r.add_cb) |cb| cb.on_add(cb.ctx, r.globals.items[r.globals.items.len - 1]);
            },
            .global_remove => |g| {
                for (r.globals.items, 0..) |x, i| if (x.name == g.name) {
                    if (r.remove_cb) |cb| cb.on_remove(cb.ctx, x);
                    r.conn.gpa.free(x.interface);
                    _ = r.globals.orderedRemove(i);
                    break;
                };
            },
        }
    }
};
