//! Small helpers over `VkImageMemoryBarrier2` / `VkDependencyInfo`
//! (synchronization2 only; on 1.2 devices the same dispatch slots hold
//! the KHR functions) (E02.F03.S02.T01).

const std = @import("std");
const vk = @import("../vk/vk.zig");
const tables = @import("../loader/tables.zig");

/// How an image is used on one side of a barrier.
pub const Access = enum {
    undefined,
    transfer_dst,
    transfer_src,
    shader_read,
    color_attachment,
    present,
    /// Owned by another process or API (dmabuf to the compositor).
    external_foreign,

    pub const State = struct { stage: vk.PipelineStageFlags2, access: vk.AccessFlags2, layout: vk.ImageLayout };

    pub fn state(a: Access) State {
        return switch (a) {
            .undefined => .{ .stage = .{}, .access = .{}, .layout = .undefined },
            .transfer_dst => .{ .stage = .{ .all_transfer = true }, .access = .{ .transfer_write = true }, .layout = .transfer_dst_optimal },
            .transfer_src => .{ .stage = .{ .all_transfer = true }, .access = .{ .transfer_read = true }, .layout = .transfer_src_optimal },
            .shader_read => .{ .stage = .{ .fragment_shader = true }, .access = .{ .shader_sampled_read = true }, .layout = .shader_read_only_optimal },
            .color_attachment => .{ .stage = .{ .color_attachment_output = true }, .access = .{ .color_attachment_read = true, .color_attachment_write = true }, .layout = .color_attachment_optimal },
            .present => .{ .stage = .{}, .access = .{}, .layout = .present_src_khr },
            .external_foreign => .{ .stage = .{ .all_commands = true }, .access = .{ .memory_read = true, .memory_write = true }, .layout = .general },
        };
    }
};

/// The whole color subresource of a single-level, single-layer image.
pub const color_range: vk.ImageSubresourceRange = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };

/// A barrier moving `img` from `from` to `to` (same queue family).
pub fn imageBarrier(img: vk.Image, from: Access, to: Access, aspect: vk.ImageAspectFlags) vk.ImageMemoryBarrier2 {
    const s = from.state();
    const d = to.state();
    var range = color_range;
    range.aspect_mask = aspect;
    return .{
        .src_stage_mask = s.stage,
        .src_access_mask = s.access,
        .dst_stage_mask = d.stage,
        .dst_access_mask = d.access,
        .old_layout = s.layout,
        .new_layout = d.layout,
        .src_queue_family_index = vk.queue_family_ignored,
        .dst_queue_family_index = vk.queue_family_ignored,
        .image = img,
        .subresource_range = range,
    };
}

/// Records one image transition.
pub fn imageTransition(cb: vk.CommandBuffer, dd: *const tables.Device, img: vk.Image, from: Access, to: Access, aspect: vk.ImageAspectFlags) void {
    const b = [_]vk.ImageMemoryBarrier2{imageBarrier(img, from, to, aspect)};
    dd.cmd_pipeline_barrier2(cb, &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = &b });
}

/// Records one `vkCmdPipelineBarrier2` with all the given barriers.
pub fn pipelineBarrier(cb: vk.CommandBuffer, dd: *const tables.Device, images: []const vk.ImageMemoryBarrier2, buffers: []const vk.BufferMemoryBarrier2) void {
    if (images.len == 0 and buffers.len == 0) return;
    dd.cmd_pipeline_barrier2(cb, &.{
        .image_memory_barrier_count = @intCast(images.len),
        .p_image_memory_barriers = images.ptr,
        .buffer_memory_barrier_count = @intCast(buffers.len),
        .p_buffer_memory_barriers = buffers.ptr,
    });
}

/// A buffer barrier from transfer writes to shader and vertex reads.
pub fn transferToShaderRead(buf: vk.Buffer, offset: u64, size: u64) vk.BufferMemoryBarrier2 {
    return .{
        .src_stage_mask = .{ .all_transfer = true },
        .src_access_mask = .{ .transfer_write = true },
        .dst_stage_mask = .{ .vertex_shader = true, .fragment_shader = true, .vertex_attribute_input = true, .index_input = true },
        .dst_access_mask = .{ .shader_storage_read = true, .shader_read = true, .vertex_attribute_read = true, .index_read = true },
        .src_queue_family_index = vk.queue_family_ignored,
        .dst_queue_family_index = vk.queue_family_ignored,
        .buffer = buf,
        .offset = offset,
        .size = size,
    };
}

test "barriers: upload transition pair" {
    const to = imageBarrier(@enumFromInt(1), .undefined, .transfer_dst, .{ .color = true });
    try std.testing.expectEqual(vk.ImageLayout.undefined, to.old_layout);
    try std.testing.expectEqual(vk.ImageLayout.transfer_dst_optimal, to.new_layout);
    try std.testing.expect(to.dst_access_mask.transfer_write);
    const back = imageBarrier(@enumFromInt(1), .transfer_dst, .shader_read, .{ .color = true });
    try std.testing.expect(back.src_stage_mask.all_transfer and back.dst_stage_mask.fragment_shader);
    try std.testing.expectEqual(vk.ImageLayout.shader_read_only_optimal, back.new_layout);
}
