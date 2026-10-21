//! SmallArray: inline storage for up to `inline_cap` items, then the heap.
//! Replaces the `std.BoundedArray` use cases removed from std.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A growable array storing up to `inline_cap` items inline.
pub fn SmallArray(comptime T: type, comptime inline_cap: usize) type {
    return struct {
        const Self = @This();

        storage: union { inline_buf: [inline_cap]T, heap: []T } = .{ .inline_buf = undefined },
        len: usize = 0,
        /// 0 while inline; heap capacity otherwise.
        heap_cap: usize = 0,

        /// An empty array.
        pub const empty: Self = .{};

        fn isInline(self: *const Self) bool {
            return self.heap_cap == 0;
        }

        /// The items as a mutable slice; invalidated by `append`.
        pub fn slice(self: *Self) []T {
            return if (self.isInline()) self.storage.inline_buf[0..self.len] else self.storage.heap[0..self.len];
        }

        /// The items as a const slice; invalidated by `append`.
        pub fn constSlice(self: *const Self) []const T {
            return if (self.isInline()) self.storage.inline_buf[0..self.len] else self.storage.heap[0..self.len];
        }

        /// Appends `x`, moving to the heap when the inline storage is full.
        pub fn append(self: *Self, gpa: Allocator, x: T) Allocator.Error!void {
            const cap = if (self.isInline()) inline_cap else self.heap_cap;
            if (self.len == cap) {
                const new_cap = @max(cap * 2, 4);
                const mem = try gpa.alloc(T, new_cap);
                @memcpy(mem[0..self.len], self.constSlice());
                if (!self.isInline()) gpa.free(self.storage.heap);
                self.storage = .{ .heap = mem };
                self.heap_cap = new_cap;
            }
            if (self.isInline()) self.storage.inline_buf[self.len] = x else self.storage.heap[self.len] = x;
            self.len += 1;
        }

        /// Removes and returns the last item.
        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return if (self.isInline()) self.storage.inline_buf[self.len] else self.storage.heap[self.len];
        }

        /// True once the items have spilled to the heap.
        pub fn spilled(self: *const Self) bool {
            return !self.isInline();
        }

        /// Frees heap storage, if any.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (!self.isInline()) gpa.free(self.storage.heap);
            self.* = undefined;
        }
    };
}

test "small_array: spills to heap at cap+1" {
    const gpa = std.testing.allocator;
    var a: SmallArray(u32, 4) = .empty;
    defer a.deinit(gpa);
    for (0..4) |i| try a.append(gpa, @intCast(i));
    try std.testing.expect(!a.spilled());
    try a.append(gpa, 4);
    try std.testing.expect(a.spilled());
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, a.constSlice());
    try std.testing.expectEqual(@as(?u32, 4), a.pop());
    for (5..40) |i| try a.append(gpa, @intCast(i));
    try std.testing.expectEqual(@as(usize, 39), a.len);
    try std.testing.expect(@sizeOf(SmallArray(u32, 4)) <= 4 * @sizeOf(u32) + 3 * @sizeOf(usize));
}
