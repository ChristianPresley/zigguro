//! The graphics pipelines (E02.F05.S02.T01): `prim`, `text_subpixel`
//! (when the device has `dualSrcBlend`) and `composite`, for one colour
//! format, with dynamic rendering, vertex pulling (no vertex input),
//! triangle strips, dynamic viewport and scissor, and premultiplied
//! source-over blending.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const shaders = @import("../shaders/gen/shaders.zig");
const iface = @import("../shaders/interface.zig");
const DescriptorHeap = @import("DescriptorHeap.zig");
const PipelineCache = @import("cache.zig").PipelineCache;

const log = std.log.scoped(.zg_vulkan);

comptime {
    // The generated SPIR-V was built against this interface.
    if (shaders.interface_hash != iface.hash()) @compileError("shaders are stale: run `zig build shaderc`");
}

/// The shader identity the pipeline cache file records: the interface
/// hash and a hash of every SPIR-V module.
pub fn shaderIdentity() [16]u8 {
    var h = std.hash.Wyhash.init(0);
    inline for (.{ shaders.prim_vert, shaders.prim_frag, shaders.text_subpixel_frag, shaders.composite_vert, shaders.composite_frag }) |code| h.update(code);
    var out: [16]u8 = undefined;
    std.mem.writeInt(u64, out[0..8], shaders.interface_hash, .little);
    std.mem.writeInt(u64, out[8..16], h.final(), .little);
    return out;
}

pub const Pipelines = struct {
    gpu: *Gpu,
    color_format: vk.Format,
    prim: vk.Pipeline,
    /// Null without `dualSrcBlend`: draw subpixel glyphs with `prim`
    /// (averaged coverage) instead.
    text_subpixel: ?vk.Pipeline,
    composite: vk.Pipeline,

    pub fn deinit(self: *Pipelines) void {
        const d = &self.gpu.ddisp;
        d.destroy_pipeline(self.gpu.dev, self.prim, null);
        if (self.text_subpixel) |p| d.destroy_pipeline(self.gpu.dev, p, null);
        d.destroy_pipeline(self.gpu.dev, self.composite, null);
        self.* = undefined;
    }
};

const all_channels: vk.ColorComponentFlags = .{ .r = true, .g = true, .b = true, .a = true };

/// `out = src + dst * (1 - src.a)` for premultiplied colour and alpha.
pub const premultiplied_over: vk.PipelineColorBlendAttachmentState = .{
    .blend_enable = .true,
    .src_color_blend_factor = .one,
    .dst_color_blend_factor = .one_minus_src_alpha,
    .color_blend_op = .add,
    .src_alpha_blend_factor = .one,
    .dst_alpha_blend_factor = .one_minus_src_alpha,
    .alpha_blend_op = .add,
    .color_write_mask = all_channels,
};

/// `shading.blendSubpixel` through the blend unit (see
/// `shaders/text_subpixel.zig`): source 0 is colour × coverage, source 1
/// is alpha × coverage.
pub const subpixel_over: vk.PipelineColorBlendAttachmentState = .{
    .blend_enable = .true,
    .src_color_blend_factor = .one,
    .dst_color_blend_factor = .one_minus_src1_color,
    .color_blend_op = .add,
    .src_alpha_blend_factor = .one,
    .dst_alpha_blend_factor = .one_minus_src_alpha,
    .alpha_blend_op = .add,
    .color_write_mask = all_channels,
};

fn shaderModule(gpu: *Gpu, code: []align(4) const u8, label: [:0]const u8) !vk.ShaderModule {
    var m: vk.ShaderModule = .null_handle;
    _ = try vk.check(gpu.ddisp.create_shader_module(gpu.dev, &.{ .code_size = code.len, .p_code = @ptrCast(code.ptr) }, null, &m));
    gpu.name(m, label);
    return m;
}

/// Creates every pipeline for `color_format` through `cache`.
pub fn createPipelines(gpu: *Gpu, cache: *PipelineCache, heap: *const DescriptorHeap, color_format: vk.Format) !Pipelines {
    const d = &gpu.ddisp;
    const dev = gpu.dev;
    var modules: [5]vk.ShaderModule = @splat(.null_handle);
    defer for (modules) |m| if (m != .null_handle) d.destroy_shader_module(dev, m, null);
    modules[0] = try shaderModule(gpu, shaders.prim_vert, "prim.vert");
    modules[1] = try shaderModule(gpu, shaders.prim_frag, "prim.frag");
    modules[2] = try shaderModule(gpu, shaders.text_subpixel_frag, "text_subpixel.frag");
    modules[3] = try shaderModule(gpu, shaders.composite_vert, "composite.vert");
    modules[4] = try shaderModule(gpu, shaders.composite_frag, "composite.frag");
    const dual_src = gpu.info.caps.dual_src_blend;

    const fmt = [_]vk.Format{color_format};
    const rendering: vk.PipelineRenderingCreateInfo = .{ .view_mask = 0, .color_attachment_count = 1, .p_color_attachment_formats = &fmt, .depth_attachment_format = .undefined, .stencil_attachment_format = .undefined };
    const dyn = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic: vk.PipelineDynamicStateCreateInfo = .{ .dynamic_state_count = dyn.len, .p_dynamic_states = &dyn };
    const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{};
    const strip: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_strip };
    const list: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_list };
    const viewport: vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .scissor_count = 1 };
    const raster: vk.PipelineRasterizationStateCreateInfo = .{ .polygon_mode = .fill, .cull_mode = .{}, .front_face = .counter_clockwise, .depth_bias_constant_factor = 0, .depth_bias_clamp = 0, .depth_bias_slope_factor = 0, .line_width = 1 };
    const multisample: vk.PipelineMultisampleStateCreateInfo = .{ .rasterization_samples = .{ .@"1" = true }, .min_sample_shading = 0 };
    const over = [_]vk.PipelineColorBlendAttachmentState{premultiplied_over};
    const sub = [_]vk.PipelineColorBlendAttachmentState{subpixel_over};
    const blend_over: vk.PipelineColorBlendStateCreateInfo = .{ .logic_op = .copy, .attachment_count = 1, .p_attachments = &over, .blend_constants = .{ 0, 0, 0, 0 } };
    const blend_sub: vk.PipelineColorBlendStateCreateInfo = .{ .logic_op = .copy, .attachment_count = 1, .p_attachments = &sub, .blend_constants = .{ 0, 0, 0, 0 } };

    const Stages = [2]vk.PipelineShaderStageCreateInfo;
    const stages = [3]Stages{
        .{ .{ .stage = .{ .vertex = true }, .module = modules[0], .p_name = "main" }, .{ .stage = .{ .fragment = true }, .module = modules[1], .p_name = "main" } },
        .{ .{ .stage = .{ .vertex = true }, .module = modules[0], .p_name = "main" }, .{ .stage = .{ .fragment = true }, .module = modules[2], .p_name = "main" } },
        .{ .{ .stage = .{ .vertex = true }, .module = modules[3], .p_name = "main" }, .{ .stage = .{ .fragment = true }, .module = modules[4], .p_name = "main" } },
    };
    const blends = [3]*const vk.PipelineColorBlendStateCreateInfo{ &blend_over, &blend_sub, &blend_over };
    const topologies = [3]*const vk.PipelineInputAssemblyStateCreateInfo{ &strip, &strip, &list };
    var infos: [3]vk.GraphicsPipelineCreateInfo = undefined;
    for (&infos, 0..) |*info, i| info.* = .{
        .p_next = &rendering,
        .stage_count = 2,
        .p_stages = &stages[i],
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = topologies[i],
        .p_viewport_state = &viewport,
        .p_rasterization_state = &raster,
        .p_multisample_state = &multisample,
        .p_color_blend_state = blends[i],
        .p_dynamic_state = &dynamic,
        .layout = heap.pipeline_layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    // Without dual-source blending the subpixel pipeline is skipped.
    const order = if (dual_src) [3]usize{ 0, 1, 2 } else [3]usize{ 0, 2, 2 };
    var create: [3]vk.GraphicsPipelineCreateInfo = undefined;
    const n: u32 = if (dual_src) 3 else 2;
    for (order[0..n], 0..) |src, i| create[i] = infos[src];
    var out: [3]vk.Pipeline = @splat(.null_handle);
    _ = try vk.check(d.create_graphics_pipelines(dev, cache.handle, n, &create, null, &out));
    cache.created += n;
    const prim = out[0];
    const text_subpixel: ?vk.Pipeline = if (dual_src) out[1] else null;
    const composite = out[n - 1];
    gpu.name(prim, "prim");
    if (text_subpixel) |p| gpu.name(p, "text_subpixel");
    gpu.name(composite, "composite");
    if (!dual_src) log.info("no dualSrcBlend: subpixel text draws as grayscale", .{});
    return .{ .gpu = gpu, .color_format = color_format, .prim = prim, .text_subpixel = text_subpixel, .composite = composite };
}

test "pipelines: shader identity is stable" {
    try std.testing.expectEqualSlices(u8, &shaderIdentity(), &shaderIdentity());
    try std.testing.expectEqual(shaders.interface_hash, std.mem.readInt(u64, shaderIdentity()[0..8], .little));
}
