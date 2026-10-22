//! Objects whose destruction waits until the GPU timeline passes their
//! last use (E02.F04.S03.T01). `FrameScheduler.deferDestroy` queues them;
//! `collect` destroys the ones whose value has completed.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const types = @import("../mem/types.zig");
const Texture = @import("../mem/Texture.zig");
const DeviceMemory = @import("../mem/DeviceMemory.zig");

pub const Deferred = union(enum) {
    buffer: types.Buffer,
    image: types.Image,
    view: vk.ImageView,
    texture: Texture,
    semaphore: vk.Semaphore,
    pipeline: vk.Pipeline,
    swapchain: vk.SwapchainKHR,

    /// Destroys the object now.
    pub fn destroy(self: *Deferred, mem: *DeviceMemory) void {
        const gpu = mem.gpu;
        const d = &gpu.ddisp;
        switch (self.*) {
            .buffer => |b| mem.destroyBuffer(b),
            .image => |i| mem.destroyImage(i),
            .view => |v| d.destroy_image_view(gpu.dev, v, null),
            .texture => |*t| t.destroy(mem),
            .semaphore => |s| d.destroy_semaphore(gpu.dev, s, null),
            .pipeline => |p| d.destroy_pipeline(gpu.dev, p, null),
            .swapchain => |s| d.destroy_swapchain_khr(gpu.dev, s, null),
        }
    }
};

/// Deferred objects ordered by the timeline value they wait for. Pure
/// bookkeeping: the caller supplies the completed value.
pub const Queue = struct {
    pub const Entry = struct { value: u64, item: Deferred };

    items: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
    }

    /// Queues `item` until the timeline reaches `value`.
    pub fn push(self: *Queue, gpa: std.mem.Allocator, value: u64, item: Deferred) !void {
        try self.items.append(gpa, .{ .value = value, .item = item });
    }

    /// Removes and returns, one per call, the entries whose value is at
    /// or below `completed`, in queue order.
    pub fn popReady(self: *Queue, completed: u64) ?Deferred {
        for (self.items.items, 0..) |e, i| if (e.value <= completed) {
            return self.items.orderedRemove(i).item;
        };
        return null;
    }

    pub fn len(self: *const Queue) usize {
        return self.items.items.len;
    }
};

test "deferred: destroyed only after timeline value" {
    const gpa = std.testing.allocator;
    var q: Queue = .{};
    defer q.deinit(gpa);
    try q.push(gpa, 3, .{ .view = @enumFromInt(1) });
    try q.push(gpa, 1, .{ .view = @enumFromInt(2) });
    try q.push(gpa, 5, .{ .view = @enumFromInt(3) });
    try std.testing.expect(q.popReady(0) == null);
    try std.testing.expectEqual(@as(vk.ImageView, @enumFromInt(2)), q.popReady(2).?.view);
    try std.testing.expect(q.popReady(2) == null);
    try std.testing.expectEqual(@as(vk.ImageView, @enumFromInt(1)), q.popReady(4).?.view);
    try std.testing.expectEqual(@as(usize, 1), q.len());
    try std.testing.expectEqual(@as(vk.ImageView, @enumFromInt(3)), q.popReady(9).?.view);
    try std.testing.expectEqual(@as(usize, 0), q.len());
}
