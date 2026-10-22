//! The bindless descriptor set layout and the pipeline layout of the
//! frozen shader interface (`shaders/interface.zig`, E02.F05.S02.T01):
//!
//! - binding 0: prims, storage buffer, vertex + fragment;
//! - binding 1: clips, storage buffer, vertex + fragment;
//! - binding 2: `sampler2D textures[max_textures]`, fragment, partially
//!   bound and update-after-bind (plus variable count and
//!   update-unused-while-pending where the device enabled them);
//! - 32 bytes of push constants, vertex + fragment.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const iface = @import("../shaders/interface.zig");

/// The optional descriptor-indexing features the layout uses.
pub const Features = struct {
    variable_count: bool,
    unused_while_pending: bool,

    /// What `gpu` enabled (`features.wanted` ∩ supported).
    pub fn of(gpu: *const Gpu) Features {
        const f = &gpu.probes[gpu.chosen].feat.v12;
        return .{
            .variable_count = f.descriptor_binding_variable_descriptor_count == .true,
            .unused_while_pending = f.descriptor_binding_update_unused_while_pending == .true,
        };
    }
};

/// The binding flags of `binding_textures`. Pure.
pub fn textureFlags(f: Features) vk.DescriptorBindingFlags {
    return .{
        .update_after_bind = true,
        .partially_bound = true,
        .variable_descriptor_count = f.variable_count,
        .update_unused_while_pending = f.unused_while_pending,
    };
}

pub const shader_stages: vk.ShaderStageFlags = .{ .vertex = true, .fragment = true };

/// The three bindings for `max_textures` textures. Pure.
pub fn bindings(max_textures: u32) [3]vk.DescriptorSetLayoutBinding {
    return .{
        .{ .binding = iface.binding_prims, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = shader_stages },
        .{ .binding = iface.binding_clips, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = shader_stages },
        .{ .binding = iface.binding_textures, .descriptor_type = .combined_image_sampler, .descriptor_count = max_textures, .stage_flags = .{ .fragment = true } },
    };
}

/// Creates the set layout (`UPDATE_AFTER_BIND_POOL`).
pub fn createSetLayout(gpu: *Gpu, max_textures: u32, f: Features) !vk.DescriptorSetLayout {
    const b = bindings(max_textures);
    // Bindings 0 and 1 are written while no frame is in flight.
    const flags = [3]vk.DescriptorBindingFlags{ .{}, .{}, textureFlags(f) };
    const flags_info: vk.DescriptorSetLayoutBindingFlagsCreateInfo = .{ .binding_count = flags.len, .p_binding_flags = &flags };
    var out: vk.DescriptorSetLayout = .null_handle;
    _ = try vk.check(gpu.ddisp.create_descriptor_set_layout(gpu.dev, &.{
        .p_next = &flags_info,
        .flags = .{ .update_after_bind_pool = true },
        .binding_count = b.len,
        .p_bindings = &b,
    }, null, &out));
    gpu.name(out, "bindless-set-layout");
    return out;
}

/// Creates the pipeline layout every zigguro pipeline shares.
pub fn createPipelineLayout(gpu: *Gpu, set_layout: vk.DescriptorSetLayout) !vk.PipelineLayout {
    const range = [_]vk.PushConstantRange{.{ .stage_flags = shader_stages, .offset = 0, .size = iface.push_constant_bytes }};
    const sets = [_]vk.DescriptorSetLayout{set_layout};
    var out: vk.PipelineLayout = .null_handle;
    _ = try vk.check(gpu.ddisp.create_pipeline_layout(gpu.dev, &.{
        .set_layout_count = sets.len,
        .p_set_layouts = &sets,
        .push_constant_range_count = range.len,
        .p_push_constant_ranges = &range,
    }, null, &out));
    gpu.name(out, "bindless-pipeline-layout");
    return out;
}

test "layout: bindings follow the frozen interface" {
    const b = bindings(4096);
    try std.testing.expectEqual(@as(u32, iface.binding_textures), b[2].binding);
    try std.testing.expectEqual(vk.DescriptorType.combined_image_sampler, b[2].descriptor_type);
    try std.testing.expectEqual(@as(u32, 4096), b[2].descriptor_count);
    try std.testing.expect(b[0].stage_flags.vertex and b[1].stage_flags.fragment);
    const f = textureFlags(.{ .variable_count = false, .unused_while_pending = true });
    try std.testing.expect(f.partially_bound and f.update_after_bind and f.update_unused_while_pending and !f.variable_descriptor_count);
}
