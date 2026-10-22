//! The `solid` shaders end to end on the system Vulkan driver (lavapipe
//! in CI, validation on; E02.F05.S01.T02): shader modules, a dynamic-
//! rendering pipeline, a 64x64 offscreen render and a readback where
//! every pixel must equal the push-constant colour.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const shaders = @import("gen/shaders.zig");
const DeviceMemory = @import("../mem/DeviceMemory.zig");
const Texture = @import("../mem/Texture.zig");
const barriers = @import("../mem/barriers.zig");
const validation = @import("../testing/validation.zig");
const testing_gpu = @import("../testing/gpu.zig");
const tables = @import("../loader/tables.zig");

fn shaderModule(d: *const tables.Device, dev: vk.Device, code: []align(4) const u8) !vk.ShaderModule {
    var m: vk.ShaderModule = .null_handle;
    _ = try vk.check(d.create_shader_module(dev, &.{ .code_size = code.len, .p_code = @ptrCast(code.ptr) }, null, &m));
    return m;
}

test "gpu: shaders: solid fills a 64x64 target with the push-constant colour" {
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    const d = &gpu.ddisp;
    const dev = gpu.dev;
    var mem = DeviceMemory.init(gpu, std.testing.allocator, .{});
    defer mem.deinit();

    const vert = try shaderModule(d, dev, shaders.solid_vert);
    defer d.destroy_shader_module(dev, vert, null);
    const frag = try shaderModule(d, dev, shaders.solid_frag);
    defer d.destroy_shader_module(dev, frag, null);

    const range = [_]vk.PushConstantRange{.{ .stage_flags = .{ .fragment = true }, .offset = 0, .size = 16 }};
    var layout: vk.PipelineLayout = .null_handle;
    _ = try vk.check(d.create_pipeline_layout(dev, &.{ .push_constant_range_count = 1, .p_push_constant_ranges = &range }, null, &layout));
    defer d.destroy_pipeline_layout(dev, layout, null);

    const fmt = [_]vk.Format{.r8g8b8a8_unorm};
    const rendering: vk.PipelineRenderingCreateInfo = .{ .view_mask = 0, .color_attachment_count = 1, .p_color_attachment_formats = &fmt, .depth_attachment_format = .undefined, .stencil_attachment_format = .undefined };
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment = true }, .module = frag, .p_name = "main" },
    };
    const blend = [_]vk.PipelineColorBlendAttachmentState{.{
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
    }};
    const dyn = [_]vk.DynamicState{ .viewport, .scissor };
    const info = [_]vk.GraphicsPipelineCreateInfo{.{
        .p_next = &rendering,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &.{},
        .p_input_assembly_state = &.{ .topology = .triangle_list },
        .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
        .p_rasterization_state = &.{ .polygon_mode = .fill, .front_face = .counter_clockwise, .depth_bias_constant_factor = 0, .depth_bias_clamp = 0, .depth_bias_slope_factor = 0, .line_width = 1 },
        .p_multisample_state = &.{ .rasterization_samples = .{ .@"1" = true }, .min_sample_shading = 0 },
        .p_color_blend_state = &.{ .logic_op = .copy, .attachment_count = 1, .p_attachments = &blend, .blend_constants = .{ 0, 0, 0, 0 } },
        .p_dynamic_state = &.{ .dynamic_state_count = dyn.len, .p_dynamic_states = &dyn },
        .layout = layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    }};
    var pipeline: vk.Pipeline = .null_handle;
    _ = try vk.check(d.create_graphics_pipelines(dev, .null_handle, 1, &info, null, @ptrCast(&pipeline)));
    defer d.destroy_pipeline(dev, pipeline, null);

    var target = try Texture.create(&mem, 64, 64, .rgba8_unorm, .render_target, "solid-target");
    defer target.destroy(&mem);
    const readback = try mem.createBuffer(.{ .size = 64 * 64 * 4, .usage = .{ .transfer_dst = true }, .sharing_mode = .exclusive }, .readback, "solid-readback");
    defer mem.destroyBuffer(readback);

    var os = try testing_gpu.OneShot.begin(gpu);
    defer os.deinit();
    const cb = os.cb;
    barriers.imageTransition(cb, d, target.image.handle, .undefined, .color_attachment, .{ .color = true });
    const attach = [_]vk.RenderingAttachmentInfo{.{
        .image_view = target.view,
        .image_layout = .color_attachment_optimal,
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } },
    }};
    d.cmd_begin_rendering(cb, &.{ .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 64, .height = 64 } }, .layer_count = 1, .view_mask = 0, .color_attachment_count = 1, .p_color_attachments = &attach });
    d.cmd_bind_pipeline(cb, .graphics, pipeline);
    const vp = [_]vk.Viewport{.{ .x = 0, .y = 0, .width = 64, .height = 64, .min_depth = 0, .max_depth = 1 }};
    d.cmd_set_viewport(cb, 0, 1, &vp);
    const sc = [_]vk.Rect2D{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 64, .height = 64 } }};
    d.cmd_set_scissor(cb, 0, 1, &sc);
    const color = [4]f32{ 0.2, 0.4, 0.6, 1.0 };
    d.cmd_push_constants(cb, layout, .{ .fragment = true }, 0, 16, &color);
    d.cmd_draw(cb, 3, 1, 0, 0);
    d.cmd_end_rendering(cb);
    barriers.imageTransition(cb, d, target.image.handle, .color_attachment, .transfer_src, .{ .color = true });
    const region = [_]vk.BufferImageCopy{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = 64, .height = 64, .depth = 1 },
    }};
    d.cmd_copy_image_to_buffer(cb, target.image.handle, .transfer_src_optimal, readback.handle, 1, &region);
    try os.submit();
    try mem.invalidate(readback.alloc, 0, readback.size);

    const want = [4]u8{ 51, 102, 153, 255 };
    const px = readback.mappedSlice().?;
    for (0..64 * 64) |i| try std.testing.expectEqualSlices(u8, &want, px[i * 4 ..][0..4]);
    try validation.expectNoValidationErrors(gpu);
}
