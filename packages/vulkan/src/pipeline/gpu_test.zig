//! Pipeline tests on the system Vulkan driver (lavapipe in CI, validation
//! on; `zig build test-vulkan-gpu`): pipeline creation, the pipeline
//! cache round trip, and GPU vs software parity of the production
//! shaders on the scene corpus (E02.F05.S01.T05, E02.F05.S02.T01).
//!
//! The parity runner here is a minimal stand-in for the Vulkan backend
//! (E02.F06.S01.T02): it uploads a frame's prims and clips, draws them in
//! paint order (subpixel glyphs through `text_subpixel`) into an RGBA8
//! target and reads it back. Layer and multi-frame scenes wait for that
//! backend.

const std = @import("std");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const r2d = @import("../r2d/root.zig");
const iface = @import("../shaders/interface.zig");
const DeviceMemory = @import("../mem/DeviceMemory.zig");
const Texture = @import("../mem/Texture.zig");
const types = @import("../mem/types.zig");
const barriers = @import("../mem/barriers.zig");
const validation = @import("../testing/validation.zig");
const testing_gpu = @import("../testing/gpu.zig");
const scenes = @import("../testing/scenes.zig");
const atlas = @import("../testing/synthetic_atlas.zig");
const CpuImage = @import("../testing/CpuImage.zig");
const golden = @import("../testing/golden_image.zig");
const parity = @import("../testing/parity.zig");
const DescriptorHeap = @import("DescriptorHeap.zig");
const PipelineCache = @import("cache.zig").PipelineCache;
const pipelines = @import("pipelines.zig");

const testing = std.testing;

test "gpu: pipelines: create all under validation" {
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var cache = PipelineCache.load(testing.io, gpu, null, pipelines.shaderIdentity());
    defer cache.destroy();
    var heap = try DescriptorHeap.init(gpu, DescriptorHeap.default_max_textures);
    defer heap.deinit();
    for ([_]vk.Format{ .r8g8b8a8_unorm, .b8g8r8a8_unorm }) |fmt| {
        var p = try pipelines.createPipelines(gpu, &cache, &heap, fmt);
        defer p.deinit();
        try testing.expect(p.prim != .null_handle and p.composite != .null_handle);
        try testing.expectEqual(gpu.info.caps.dual_src_blend, p.text_subpixel != null);
    }
    try testing.expect(cache.created >= 4);
    try validation.expectNoValidationErrors(gpu);
}

test "gpu: cache: save then load" {
    const io = testing.io;
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var heap = try DescriptorHeap.init(gpu, 16);
    defer heap.deinit();
    const id = pipelines.shaderIdentity();

    // Cold: no file, an empty cache; creating pipelines makes it dirty.
    {
        var cache = PipelineCache.load(io, gpu, tmp.dir, id);
        defer cache.destroy();
        try testing.expect(!cache.loaded and cache.rejected == null);
        var p = try pipelines.createPipelines(gpu, &cache, &heap, .r8g8b8a8_unorm);
        p.deinit();
        cache.saveIfChanged(io, tmp.dir);
        try testing.expectEqual(@as(u32, 0), cache.created);
    }
    var name_buf: [64]u8 = undefined;
    const name = @import("cache.zig").fileName(&name_buf, gpu.info.vendor_id, gpu.info.device_id);
    // Warm: the file validates and seeds the driver cache.
    {
        var cache = PipelineCache.load(io, gpu, tmp.dir, id);
        defer cache.destroy();
        try testing.expect(cache.loaded and cache.rejected == null);
        var p = try pipelines.createPipelines(gpu, &cache, &heap, .r8g8b8a8_unorm);
        p.deinit();
    }
    // Different shaders: the file is ignored.
    {
        var other = id;
        other[15] ^= 1;
        var cache = PipelineCache.load(io, gpu, tmp.dir, other);
        defer cache.destroy();
        try testing.expect(!cache.loaded);
        try testing.expectEqual(@as(?@import("cache.zig").Reject, .shaders_changed), cache.rejected);
    }
    // A corrupt file is ignored, not fatal.
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "ZGPC garbage" });
    {
        var cache = PipelineCache.load(io, gpu, tmp.dir, id);
        defer cache.destroy();
        try testing.expect(!cache.loaded and cache.rejected != null and cache.handle != .null_handle);
    }
    try validation.expectNoValidationErrors(gpu);
}

/// The minimal renderer behind the parity test.
const Harness = struct {
    gpu: *Gpu,
    mem: DeviceMemory,
    heap: DescriptorHeap,
    cache: PipelineCache,
    pipes: pipelines.Pipelines,
    textures: std.ArrayList(Texture) = .empty,
    os: testing_gpu.OneShot,

    fn init(self: *Harness, gpu: *Gpu) !void {
        self.gpu = gpu;
        self.mem = DeviceMemory.init(gpu, testing.allocator, .{});
        self.heap = try DescriptorHeap.init(gpu, 64);
        self.cache = PipelineCache.load(testing.io, gpu, null, pipelines.shaderIdentity());
        self.pipes = try pipelines.createPipelines(gpu, &self.cache, &self.heap, .r8g8b8a8_unorm);
        self.textures = .empty;
        self.os = try testing_gpu.OneShot.begin(gpu);
    }

    fn deinit(self: *Harness) void {
        self.os.deinit();
        for (self.textures.items) |*t| t.destroy(&self.mem);
        self.textures.deinit(testing.allocator);
        self.pipes.deinit();
        self.cache.destroy();
        self.heap.deinit();
        self.mem.deinit();
    }

    /// Creates and uploads a texture; its id is its descriptor slot.
    fn texture(self: *Harness, w: u32, h: u32, fmt: Texture.Format, pixels: []const u8) !r2d.TextureId {
        var tex = try Texture.create(&self.mem, w, h, fmt, .sampled, "parity-texture");
        errdefer tex.destroy(&self.mem);
        const staging = try self.mem.createBuffer(.{ .size = pixels.len, .usage = .{ .transfer_src = true }, .sharing_mode = .exclusive }, .upload_staging, "parity-staging");
        defer self.mem.destroyBuffer(staging);
        @memcpy(staging.mappedSlice().?, pixels);
        try self.mem.flush(staging.alloc, 0, staging.size);
        const d = &self.gpu.ddisp;
        const cb = self.os.cb;
        barriers.imageTransition(cb, d, tex.image.handle, .undefined, .transfer_dst, .{ .color = true });
        const region = [_]vk.BufferImageCopy{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = w, .height = h, .depth = 1 },
        }};
        d.cmd_copy_buffer_to_image(cb, staging.handle, tex.image.handle, .transfer_dst_optimal, 1, &region);
        barriers.imageTransition(cb, d, tex.image.handle, .transfer_dst, .shader_read, .{ .color = true });
        try self.os.submit();
        try self.os.again();
        tex.slot = try self.heap.allocSlot(tex.view, .linear_clamp);
        try self.textures.append(testing.allocator, tex);
        return @enumFromInt(tex.slot);
    }

    /// The synthetic atlas pages and test image, as `parity.Textures`.
    fn syntheticTextures(self: *Harness) !parity.Textures {
        const gpa = testing.allocator;
        const n = atlas.page_size;
        const buf = try gpa.alloc(u8, n * n * 4);
        defer gpa.free(buf);
        var t: parity.Textures = undefined;
        atlas.grayPage(buf[0 .. n * n]);
        t.pages[0] = try self.texture(n, n, .r8_unorm, buf[0 .. n * n]);
        atlas.subpixelPage(buf);
        t.pages[1] = try self.texture(n, n, .rgba8_unorm, buf);
        atlas.colorPage(buf);
        t.pages[2] = try self.texture(n, n, .rgba8_unorm, buf);
        atlas.testImage(buf[0 .. 32 * 32 * 4]);
        t.image = try self.texture(32, 32, .rgba8_unorm, buf[0 .. 32 * 32 * 4]);
        return t;
    }

    fn storage(self: *Harness, bytes: []const u8, name: [:0]const u8) !types.Buffer {
        const size = @max(bytes.len, 64);
        const b = try self.mem.createBuffer(.{ .size = size, .usage = .{ .storage_buffer = true }, .sharing_mode = .exclusive }, .upload, name);
        @memcpy(b.mappedSlice().?[0..bytes.len], bytes);
        try self.mem.flush(b.alloc, 0, b.size);
        return b;
    }

    /// Draws `dl` into a cleared RGBA8 target and reads it back.
    fn render(self: *Harness, dl: *const r2d.DrawList, out: *CpuImage) !void {
        const gpa = testing.allocator;
        const d = &self.gpu.ddisp;
        const w = dl.extent.w;
        const h = dl.extent.h;
        const clips = try gpa.alloc(iface.ClipGpu, dl.clips.items.len);
        defer gpa.free(clips);
        for (clips, dl.clips.items) |*c, src| c.* = .{ .bounds = src.bounds, .radii = src.radii };
        const prim_buf = try self.storage(std.mem.sliceAsBytes(dl.prims.items), "parity-prims");
        defer self.mem.destroyBuffer(prim_buf);
        const clip_buf = try self.storage(std.mem.sliceAsBytes(clips), "parity-clips");
        defer self.mem.destroyBuffer(clip_buf);
        self.heap.bindBuffers(.{ .buffer = prim_buf.handle, .offset = 0, .range = vk.whole_size }, .{ .buffer = clip_buf.handle, .offset = 0, .range = vk.whole_size });

        var target = try Texture.create(&self.mem, w, h, .rgba8_unorm, .render_target, "parity-target");
        defer target.destroy(&self.mem);
        const readback = try self.mem.createBuffer(.{ .size = @as(u64, w) * h * 4, .usage = .{ .transfer_dst = true }, .sharing_mode = .exclusive }, .readback, "parity-readback");
        defer self.mem.destroyBuffer(readback);

        const cb = self.os.cb;
        barriers.imageTransition(cb, d, target.image.handle, .undefined, .color_attachment, .{ .color = true });
        const attach = [_]vk.RenderingAttachmentInfo{.{
            .image_view = target.view,
            .image_layout = .color_attachment_optimal,
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } },
        }};
        const area: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = w, .height = h } };
        d.cmd_begin_rendering(cb, &.{ .render_area = area, .layer_count = 1, .view_mask = 0, .color_attachment_count = 1, .p_color_attachments = &attach });
        const vp = [_]vk.Viewport{.{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h), .min_depth = 0, .max_depth = 1 }};
        d.cmd_set_viewport(cb, 0, 1, &vp);
        d.cmd_set_scissor(cb, 0, 1, @ptrCast(&area));
        self.heap.bind(cb);
        const text: r2d.shading.TextParams = .{};
        const pc: iface.PushConstants = .{
            .viewport_px = .{ @floatFromInt(w), @floatFromInt(h) },
            .inv_viewport = .{ 1.0 / @as(f32, @floatFromInt(w)), 1.0 / @as(f32, @floatFromInt(h)) },
            .clip_base = 0,
            .text_gamma = text.gamma,
            .text_contrast = text.contrast,
        };
        d.cmd_push_constants(cb, self.heap.pipeline_layout, .{ .vertex = true, .fragment = true }, 0, @sizeOf(iface.PushConstants), &pc);
        // Runs of prims sharing a pipeline, in paint order.
        const prims = dl.prims.items;
        var i: usize = 0;
        var bound: vk.Pipeline = .null_handle;
        while (i < prims.len) {
            const pipe = self.pipelineFor(prims[i].kind);
            var j = i + 1;
            while (j < prims.len and self.pipelineFor(prims[j].kind) == pipe) j += 1;
            if (pipe != bound) {
                d.cmd_bind_pipeline(cb, .graphics, pipe);
                bound = pipe;
            }
            d.cmd_draw(cb, 4, @intCast(j - i), 0, @intCast(i));
            i = j;
        }
        d.cmd_end_rendering(cb);
        barriers.imageTransition(cb, d, target.image.handle, .color_attachment, .transfer_src, .{ .color = true });
        const region = [_]vk.BufferImageCopy{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = w, .height = h, .depth = 1 },
        }};
        d.cmd_copy_image_to_buffer(cb, target.image.handle, .transfer_src_optimal, readback.handle, 1, &region);
        try self.os.submit();
        try self.os.again();
        try self.mem.invalidate(readback.alloc, 0, readback.size);
        @memcpy(out.pixels, readback.mappedSlice().?[0..out.pixels.len]);
    }

    fn pipelineFor(self: *const Harness, kind: r2d.prim.Kind) vk.Pipeline {
        if (kind == .glyph_subpixel) if (self.pipes.text_subpixel) |p| return p;
        return self.pipes.prim;
    }
};

test "gpu: parity: scene corpus matches the software goldens" {
    const gpa = testing.allocator;
    const gpu = try testing_gpu.gpuOrSkip();
    defer gpu.destroy();
    var hs: Harness = undefined;
    try hs.init(gpu);
    defer hs.deinit();
    const tex = try hs.syntheticTextures();

    var dl = r2d.DrawList.init(gpa);
    defer dl.deinit();
    dl.setGlyphPages(&tex.pages);
    var failed: u32 = 0;
    var ran: u32 = 0;
    for (scenes.all) |scene| {
        if (scene.frames != 1 or scene.needs.layers) continue;
        if (scene.needs.dual_src and hs.pipes.text_subpixel == null) continue;
        var prng = std.Random.DefaultPrng.init(0x5eed_0000 + scene.name.len);
        var ctx: scenes.SceneCtx = .{ .frame = 0, .image = tex.image, .rnd = prng.random() };
        dl.reset(scene.size, scene.scale);
        dl.damageAll();
        scene.build(&dl, &ctx);
        try testing.expect(!dl.alloc_failed);
        var img = try CpuImage.init(gpa, scene.size.w, scene.size.h);
        defer img.deinit(gpa);
        try hs.render(&dl, &img);
        ran += 1;
        const tol = scene.gpu_tolerance orelse golden.Tolerance.gpu(scene.size.w, scene.size.h);
        golden.compareInDir(testing.io, parity.golden_dir, scene.name, &img, tol, .{ .update = false }) catch |err| switch (err) {
            error.GoldenMismatch, error.GoldenMissing => failed += 1,
            else => return err,
        };
    }
    try testing.expect(ran >= 20);
    try testing.expectEqual(@as(u32, 0), failed);
    try validation.expectNoValidationErrors(gpu);
}
