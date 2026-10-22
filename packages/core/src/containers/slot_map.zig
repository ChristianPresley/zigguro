//! SlotMap: dense storage addressed by generational handles. Stale handles
//! (after `remove`) never alias a newer value.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A slot map of `T`. Values live densely in an array (swap-remove);
/// `Handle`s index a sparse slot table carrying a generation.
pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        /// A generational handle. Generation 0 is never valid.
        pub const Handle = packed struct(u64) {
            index: u32,
            generation: u32,

            /// A handle that never resolves.
            pub const invalid: Handle = .{ .index = std.math.maxInt(u32), .generation = 0 };
        };

        const Slot = struct {
            generation: u32,
            /// Dense index when occupied, next free slot otherwise.
            link: u32,
            occupied: bool,
        };

        const none = std.math.maxInt(u32);

        values: std.ArrayList(T) = .empty,
        /// Slot index of each dense value.
        owners: std.ArrayList(u32) = .empty,
        slots: std.ArrayList(Slot) = .empty,
        free_head: u32 = none,

        /// An empty map.
        pub const empty: Self = .{};

        /// Number of live values.
        pub fn count(self: *const Self) usize {
            return self.values.items.len;
        }

        /// Inserts `value` and returns its handle.
        pub fn insert(self: *Self, gpa: Allocator, value: T) Allocator.Error!Handle {
            try self.values.ensureUnusedCapacity(gpa, 1);
            try self.owners.ensureUnusedCapacity(gpa, 1);
            const dense: u32 = @intCast(self.values.items.len);
            var index: u32 = undefined;
            if (self.free_head != none) {
                index = self.free_head;
                const slot = &self.slots.items[index];
                self.free_head = slot.link;
                slot.link = dense;
                slot.occupied = true;
            } else {
                index = @intCast(self.slots.items.len);
                if (index == none) return error.OutOfMemory;
                try self.slots.append(gpa, .{ .generation = 1, .link = dense, .occupied = true });
            }
            self.values.appendAssumeCapacity(value);
            self.owners.appendAssumeCapacity(index);
            return .{ .index = index, .generation = self.slots.items[index].generation };
        }

        fn slotOf(self: *const Self, h: Handle) ?*Slot {
            if (h.generation == 0 or h.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[h.index];
            if (!slot.occupied or slot.generation != h.generation) return null;
            return slot;
        }

        /// Removes and returns the value for `h`, or null for a stale or
        /// invalid handle. Invalidates pointers returned by `get`.
        pub fn remove(self: *Self, h: Handle) ?T {
            const slot = self.slotOf(h) orelse return null;
            const dense = slot.link;
            const value = self.values.items[dense];
            const last: u32 = @intCast(self.values.items.len - 1);
            if (dense != last) {
                self.values.items[dense] = self.values.items[last];
                const moved_owner = self.owners.items[last];
                self.owners.items[dense] = moved_owner;
                self.slots.items[moved_owner].link = dense;
            }
            _ = self.values.pop();
            _ = self.owners.pop();
            slot.occupied = false;
            if (slot.generation == std.math.maxInt(u32)) {
                // Retire the slot: its generations are exhausted.
                return value;
            }
            slot.generation += 1;
            slot.link = self.free_head;
            self.free_head = h.index;
            return value;
        }

        /// A pointer to the value for `h`, or null for a stale or invalid
        /// handle. Valid until the next `insert` or `remove`.
        pub fn get(self: *const Self, h: Handle) ?*T {
            const slot = self.slotOf(h) orelse return null;
            return &self.values.items[slot.link];
        }

        /// Iterates live values in dense (unspecified) order.
        pub const Iterator = struct {
            map: *const Self,
            i: usize = 0,

            /// One live entry.
            pub const Entry = struct { handle: Handle, value: *T };

            /// The next entry, or null when done.
            pub fn next(it: *Iterator) ?Entry {
                if (it.i >= it.map.values.items.len) return null;
                const idx = it.map.owners.items[it.i];
                const e: Entry = .{
                    .handle = .{ .index = idx, .generation = it.map.slots.items[idx].generation },
                    .value = &it.map.values.items[it.i],
                };
                it.i += 1;
                return e;
            }
        };

        /// An iterator over live values.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .map = self };
        }

        /// Frees all memory. Values are not deinitialised.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.values.deinit(gpa);
            self.owners.deinit(gpa);
            self.slots.deinit(gpa);
            self.* = undefined;
        }
    };
}

test "slot_map: stale handle returns null" {
    const gpa = std.testing.allocator;
    var m: SlotMap(u32) = .empty;
    defer m.deinit(gpa);
    const a = try m.insert(gpa, 1);
    const b = try m.insert(gpa, 2);
    try std.testing.expectEqual(@as(?u32, 1), m.remove(a));
    try std.testing.expect(m.get(a) == null);
    try std.testing.expect(m.remove(a) == null);
    const c = try m.insert(gpa, 3);
    try std.testing.expectEqual(a.index, c.index);
    try std.testing.expect(m.get(a) == null);
    try std.testing.expectEqual(@as(u32, 3), m.get(c).?.*);
    try std.testing.expectEqual(@as(u32, 2), m.get(b).?.*);
    try std.testing.expect(m.get(SlotMap(u32).Handle.invalid) == null);
    var it = m.iterator();
    var n: usize = 0;
    while (it.next()) |e| : (n += 1) try std.testing.expectEqual(e.value.*, m.get(e.handle).?.*);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "fuzz: slot_map insert/remove vs reference model" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            const gpa = std.testing.allocator;
            var m: SlotMap(u64) = .empty;
            defer m.deinit(gpa);
            var model: std.AutoHashMapUnmanaged(u64, u64) = .empty; // handle bits -> value
            defer model.deinit(gpa);
            var handles: std.ArrayList(SlotMap(u64).Handle) = .empty;
            defer handles.deinit(gpa);
            var ops: usize = 0;
            while (!s.eos() and ops < 512) : (ops += 1) {
                if (handles.items.len == 0 or s.boolWeighted(1, 2)) {
                    const v = s.value(u64);
                    const h = try m.insert(gpa, v);
                    try handles.append(gpa, h);
                    try model.put(gpa, @bitCast(h), v);
                } else {
                    const h = handles.items[s.index(handles.items.len)];
                    const expect = model.fetchRemove(@bitCast(h));
                    const got = m.remove(h);
                    if (expect) |kv| {
                        try std.testing.expectEqual(kv.value, got.?);
                    } else try std.testing.expect(got == null);
                }
                try std.testing.expectEqual(model.count(), m.count());
            }
            for (handles.items) |h| {
                const got = m.get(h);
                if (model.get(@bitCast(h))) |v| try std.testing.expectEqual(v, got.?.*) else try std.testing.expect(got == null);
            }
        }
    }.one, .{});
}
