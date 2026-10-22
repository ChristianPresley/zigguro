//! The bindless descriptor heap (E02.F05.S02.T01): one descriptor set
//! with the prim and clip storage buffers and an array of combined image
//! samplers. A texture's slot in the array is its `r2d.TextureId`; slot
//! 0 means "no texture" and is never handed out.
//!
//! Slots are written with update-after-bind. A freed slot is retired
//! with the timeline value of the last frame that may use it and handed
//! out again only after `reclaim` sees that value completed, so a pending
//! command buffer never sees its descriptor change.

const DescriptorHeap = @This();

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const iface = @import("../shaders/interface.zig");
const layout = @import("layout.zig");

pub const SamplerKind = enum { linear_clamp, nearest_clamp, linear_repeat };

/// Default and largest slot count (also capped by the device limit).
pub const default_max_textures = 4096;

const no_copies = [0]vk.CopyDescriptorSet{};
const no_offsets = [0]u32{};

const Retired = struct { slot: u32, value: u64 };

gpu: *Gpu,
features: layout.Features,
set_layout: vk.DescriptorSetLayout,
pipeline_layout: vk.PipelineLayout,
pool: vk.DescriptorPool,
set: vk.DescriptorSet,
samplers: [3]vk.Sampler,
/// Slots in the array (slot 0 included).
max_textures: u32,
/// Slots never handed out start here.
next: u32 = 1,
free: std.ArrayList(u32) = .empty,
retired: std.ArrayList(Retired) = .empty,

/// Creates the layouts, the samplers, a pool and the set for up to
/// `max_textures` slots (clamped to the device limit).
pub fn init(gpu: *Gpu, max_textures: u32) !DescriptorHeap {
    const d = &gpu.ddisp;
    const limit = gpu.info.limits.max_sampled_images_update_after_bind;
    const n = @max(2, @min(max_textures, if (limit == 0) max_textures else limit));
    const f = layout.Features.of(gpu);

    const set_layout = try layout.createSetLayout(gpu, n, f);
    errdefer d.destroy_descriptor_set_layout(gpu.dev, set_layout, null);
    const pipeline_layout = try layout.createPipelineLayout(gpu, set_layout);
    errdefer d.destroy_pipeline_layout(gpu.dev, pipeline_layout, null);

    var samplers: [3]vk.Sampler = @splat(.null_handle);
    errdefer for (samplers) |s| if (s != .null_handle) d.destroy_sampler(gpu.dev, s, null);
    for (&samplers, std.enums.values(SamplerKind)) |*s, kind| {
        const filter: vk.Filter = if (kind == .nearest_clamp) .nearest else .linear;
        const address: vk.SamplerAddressMode = if (kind == .linear_repeat) .repeat else .clamp_to_edge;
        _ = try vk.check(d.create_sampler(gpu.dev, &.{
            .mag_filter = filter,
            .min_filter = filter,
            .mipmap_mode = .nearest,
            .address_mode_u = address,
            .address_mode_v = address,
            .address_mode_w = address,
            .mip_lod_bias = 0,
            .max_anisotropy = 1,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .float_transparent_black,
        }, null, s));
        gpu.name(s.*, @tagName(kind));
    }

    const sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .storage_buffer, .descriptor_count = 2 },
        .{ .type = .combined_image_sampler, .descriptor_count = n },
    };
    var pool: vk.DescriptorPool = .null_handle;
    _ = try vk.check(d.create_descriptor_pool(gpu.dev, &.{ .flags = .{ .update_after_bind = true }, .max_sets = 1, .pool_size_count = sizes.len, .p_pool_sizes = &sizes }, null, &pool));
    errdefer d.destroy_descriptor_pool(gpu.dev, pool, null);
    gpu.name(pool, "bindless-pool");

    const counts = [_]u32{n};
    const variable: vk.DescriptorSetVariableDescriptorCountAllocateInfo = .{ .descriptor_set_count = 1, .p_descriptor_counts = &counts };
    const layouts = [_]vk.DescriptorSetLayout{set_layout};
    var set: vk.DescriptorSet = .null_handle;
    _ = try vk.check(d.allocate_descriptor_sets(gpu.dev, &.{
        .p_next = if (f.variable_count) &variable else null,
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = &layouts,
    }, @ptrCast(&set)));
    gpu.name(set, "bindless-set");

    return .{
        .gpu = gpu,
        .features = f,
        .set_layout = set_layout,
        .pipeline_layout = pipeline_layout,
        .pool = pool,
        .set = set,
        .samplers = samplers,
        .max_textures = n,
    };
}

pub fn deinit(self: *DescriptorHeap) void {
    const d = &self.gpu.ddisp;
    const dev = self.gpu.dev;
    d.destroy_descriptor_pool(dev, self.pool, null);
    for (self.samplers) |s| d.destroy_sampler(dev, s, null);
    d.destroy_pipeline_layout(dev, self.pipeline_layout, null);
    d.destroy_descriptor_set_layout(dev, self.set_layout, null);
    self.free.deinit(self.gpu.gpa);
    self.retired.deinit(self.gpu.gpa);
    self.* = undefined;
}

pub fn sampler(self: *const DescriptorHeap, kind: SamplerKind) vk.Sampler {
    return self.samplers[@intFromEnum(kind)];
}

/// Takes a free slot and points it at `view` (in SHADER_READ_ONLY_OPTIMAL)
/// with `kind`.
pub fn allocSlot(self: *DescriptorHeap, view: vk.ImageView, kind: SamplerKind) !u32 {
    const slot = self.free.pop() orelse blk: {
        if (self.next >= self.max_textures) return error.OutOfSlots;
        self.next += 1;
        break :blk self.next - 1;
    };
    self.writeSlot(slot, view, kind);
    return slot;
}

/// Repoints a slot the caller owns (a resized texture keeps its id). The
/// slot must not be used by a pending frame unless the device enabled
/// update-unused-while-pending and that frame does not draw with it.
pub fn writeSlot(self: *DescriptorHeap, slot: u32, view: vk.ImageView, kind: SamplerKind) void {
    std.debug.assert(slot != 0 and slot < self.max_textures);
    const info = [_]vk.DescriptorImageInfo{.{ .sampler = self.sampler(kind), .image_view = view, .image_layout = .shader_read_only_optimal }};
    const w = [_]vk.WriteDescriptorSet{.{
        .dst_set = self.set,
        .dst_binding = iface.binding_textures,
        .dst_array_element = slot,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = &info,
    }};
    self.gpu.ddisp.update_descriptor_sets(self.gpu.dev, w.len, &w, 0, &no_copies);
}

/// Returns `slot` for reuse once the timeline reaches `retire_value`
/// (the last frame that may sample it).
pub fn freeSlot(self: *DescriptorHeap, slot: u32, retire_value: u64) void {
    std.debug.assert(slot != 0 and slot < self.next);
    self.retired.append(self.gpu.gpa, .{ .slot = slot, .value = retire_value }) catch {
        // Leaking one slot is better than reusing it too early.
        return;
    };
}

/// Makes every slot retired at or before `completed` allocatable.
pub fn reclaim(self: *DescriptorHeap, completed: u64) void {
    var i: usize = 0;
    while (i < self.retired.items.len) {
        const r = self.retired.items[i];
        if (r.value <= completed) {
            self.free.append(self.gpu.gpa, r.slot) catch return;
            _ = self.retired.swapRemove(i);
        } else i += 1;
    }
}

/// Points bindings 0 and 1 at the prim and clip buffers. Call while no
/// frame using the set is pending (at creation and after the upload ring
/// grows, deferred through the timeline).
pub fn bindBuffers(self: *DescriptorHeap, prims: vk.DescriptorBufferInfo, clips: vk.DescriptorBufferInfo) void {
    const p = [_]vk.DescriptorBufferInfo{prims};
    const c = [_]vk.DescriptorBufferInfo{clips};
    const w = [_]vk.WriteDescriptorSet{
        .{ .dst_set = self.set, .dst_binding = iface.binding_prims, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_buffer_info = &p },
        .{ .dst_set = self.set, .dst_binding = iface.binding_clips, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_buffer_info = &c },
    };
    self.gpu.ddisp.update_descriptor_sets(self.gpu.dev, w.len, &w, 0, &no_copies);
}

/// Binds the set for graphics pipelines.
pub fn bind(self: *const DescriptorHeap, cb: vk.CommandBuffer) void {
    const sets = [_]vk.DescriptorSet{self.set};
    self.gpu.ddisp.cmd_bind_descriptor_sets(cb, .graphics, self.pipeline_layout, iface.set, sets.len, &sets, 0, &no_offsets);
}
