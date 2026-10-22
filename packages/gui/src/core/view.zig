//! Views, entities and `Context` (GPUI-style ownership, no closures).
//!
//! - An entity is app state owned by `App` and addressed by `Entity(T)`.
//! - A view is any object with a `build(*Ui)` function; it is the unit of
//!   invalidation. `Context.notify` rebuilds the current view;
//!   `Context.observe(id)` rebuilds it whenever entity `id` notifies.
//! - `notify` and `emit` are queued as effects and flushed between frame
//!   phases (run-to-completion, never re-entrant).

const std = @import("std");
const ids = @import("ids.zig");

/// A generational entity handle.
pub const EntityId = packed struct(u32) {
    index: u24,
    gen: u8,

    /// No entity.
    pub const none: EntityId = @bitCast(@as(u32, 0));

    /// The id as one integer.
    pub fn raw(id: EntityId) u32 {
        return @bitCast(id);
    }

    /// True for `none`.
    pub fn isNone(id: EntityId) bool {
        return id.raw() == 0;
    }
};

/// The operations of a view.
pub const ViewVTable = struct {
    build: *const fn (*anyopaque, *anyopaque) void,
    deinit: ?*const fn (*anyopaque) void = null,
    name: []const u8,
};

/// A type-erased view. `of(v)` wraps any pointer to a struct with
/// `pub fn build(self: *T, ui: *Ui) void` (and optionally `deinit(self)`).
pub const AnyView = struct {
    ptr: *anyopaque,
    vtable: *const ViewVTable,

    /// Wraps `v` (a `*T`).
    pub fn of(v: anytype) AnyView {
        const P = @TypeOf(v);
        const T = @typeInfo(P).pointer.child;
        const Gen = struct {
            fn build(p: *anyopaque, ui: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(p));
                self.build(@ptrCast(@alignCast(ui)));
            }
            fn deinit(p: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(p));
                self.deinit();
            }
            const vt: ViewVTable = .{
                .build = build,
                .deinit = if (@hasDecl(T, "deinit")) deinit else null,
                .name = if (@hasDecl(T, "view_name")) T.view_name else @typeName(T),
            };
        };
        return .{ .ptr = @ptrCast(v), .vtable = &Gen.vt };
    }
};

/// A typed handle to an entity of type `T`.
pub fn Entity(comptime T: type) type {
    return struct {
        id: EntityId,

        const Self = @This();

        /// Read access.
        pub fn read(e: Self, app: anytype) *const T {
            return app.entities.get(T, e.id);
        }

        /// Write access; call `notify` (or use `App.update`) so observers rebuild.
        pub fn update(e: Self, app: anytype) *T {
            return app.entities.get(T, e.id);
        }
    };
}

/// The App-owned entity storage.
pub const EntityStore = struct {
    gpa: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    free_list: std.ArrayList(u24) = .empty,

    const Slot = struct {
        ptr: ?*anyopaque = null,
        type_tag: u64 = 0,
        gen: u8 = 0,
        refs: u32 = 0,
        destroy: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
    };

    /// Frees every entity.
    pub fn deinit(s: *EntityStore) void {
        for (s.slots.items) |*slot| {
            if (slot.ptr) |p| slot.destroy.?(s.gpa, p);
        }
        s.slots.deinit(s.gpa);
        s.free_list.deinit(s.gpa);
    }

    /// Stores `init` and returns a handle with one reference.
    pub fn new(s: *EntityStore, comptime T: type, value: T) !Entity(T) {
        const p = try s.gpa.create(T);
        errdefer s.gpa.destroy(p);
        p.* = value;
        const Gen = struct {
            fn destroy(gpa: std.mem.Allocator, raw: *anyopaque) void {
                const t: *T = @ptrCast(@alignCast(raw));
                if (comptime hasDeinit(T)) t.deinit();
                gpa.destroy(t);
            }
        };
        var index: u24 = undefined;
        if (s.free_list.pop()) |i| {
            index = i;
        } else {
            if (s.slots.items.len == 0) try s.slots.append(s.gpa, .{}); // index 0 is `none`
            try s.slots.append(s.gpa, .{});
            index = @intCast(s.slots.items.len - 1);
        }
        const slot = &s.slots.items[index];
        slot.gen +%= 1;
        if (slot.gen == 0) slot.gen = 1;
        slot.ptr = p;
        slot.type_tag = ids.kindTag(T);
        slot.refs = 1;
        slot.destroy = Gen.destroy;
        return .{ .id = .{ .index = index, .gen = slot.gen } };
    }

    /// True when `id` is live.
    pub fn alive(s: *const EntityStore, id: EntityId) bool {
        if (id.isNone() or id.index >= s.slots.items.len) return false;
        const slot = s.slots.items[id.index];
        return slot.ptr != null and slot.gen == id.gen;
    }

    /// The entity's value (asserts the id is live and of type `T`).
    pub fn get(s: *EntityStore, comptime T: type, id: EntityId) *T {
        std.debug.assert(s.alive(id));
        const slot = s.slots.items[id.index];
        std.debug.assert(slot.type_tag == ids.kindTag(T));
        return @ptrCast(@alignCast(slot.ptr.?));
    }

    /// Adds a reference.
    pub fn retain(s: *EntityStore, id: EntityId) void {
        if (s.alive(id)) s.slots.items[id.index].refs += 1;
    }

    /// Drops a reference; frees the entity at the last one. Returns true
    /// when it was freed.
    pub fn release(s: *EntityStore, id: EntityId) bool {
        if (!s.alive(id)) return false;
        const slot = &s.slots.items[id.index];
        slot.refs -= 1;
        if (slot.refs > 0) return false;
        slot.destroy.?(s.gpa, slot.ptr.?);
        slot.ptr = null;
        s.free_list.append(s.gpa, id.index) catch {};
        return true;
    }
};

test "entity lifecycle" {
    var s: EntityStore = .{ .gpa = std.testing.allocator };
    defer s.deinit();
    const e = try s.new(u32, 5);
    try std.testing.expectEqual(@as(u32, 5), s.get(u32, e.id).*);
    s.retain(e.id);
    try std.testing.expect(!s.release(e.id));
    try std.testing.expect(s.release(e.id));
    try std.testing.expect(!s.alive(e.id));
    const f = try s.new(u32, 6);
    try std.testing.expectEqual(e.id.index, f.id.index);
    try std.testing.expect(e.id.gen != f.id.gen);
}

fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}
