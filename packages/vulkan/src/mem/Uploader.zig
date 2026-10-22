//! Batches texture sub-rect and buffer uploads (E02.F03.S02.T01).
//!
//! `writeRegion`/`writeBuffer` copy the bytes into the upload ring (or a
//! staging buffer when they do not fit) right away; `record` then emits,
//! before rendering, one barrier batch to TRANSFER_DST, one
//! `vkCmdCopyBufferToImage` per (texture, source buffer) with all its
//! regions, the buffer copies, and one barrier batch back to shader reads.

const Uploader = @This();

const std = @import("std");
const vk = @import("../vk/vk.zig");
const tables = @import("../loader/tables.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const UploadRing = @import("UploadRing.zig");
const Texture = @import("Texture.zig");
const types = @import("types.zig");
const barriers = @import("barriers.zig");

/// A texture sub-rectangle (textures are at most 16384 texels a side).
pub const Rect16 = struct { x: u16, y: u16, w: u16, h: u16 };

const ImageOp = struct {
    tex: *Texture,
    /// Order of the texture's first queued region.
    group: u32,
    src: vk.Buffer,
    region: vk.BufferImageCopy,
};

const BufferOp = struct {
    src: vk.Buffer,
    dst: vk.Buffer,
    region: vk.BufferCopy,
};

gpa: std.mem.Allocator,
mem: ?*DeviceMemory,
ring: ?*UploadRing,
image_ops: std.ArrayList(ImageOp) = .empty,
/// Textures with queued regions, in first-appearance order.
groups: std.ArrayList(*Texture) = .empty,
buffer_ops: std.ArrayList(BufferOp) = .empty,
/// Staging buffers of recorded uploads, freed by `retire`.
staging: std.ArrayList(types.Buffer) = .empty,
pending: u64 = 0,
/// Scratch for `record`.
scratch_regions: std.ArrayList(vk.BufferImageCopy) = .empty,
scratch_barriers: std.ArrayList(vk.ImageMemoryBarrier2) = .empty,
scratch_buf_barriers: std.ArrayList(vk.BufferMemoryBarrier2) = .empty,

pub fn init(gpa: std.mem.Allocator, mem: *DeviceMemory, ring: *UploadRing) Uploader {
    return .{ .gpa = gpa, .mem = mem, .ring = ring };
}

pub fn deinit(self: *Uploader) void {
    self.retire();
    self.image_ops.deinit(self.gpa);
    self.groups.deinit(self.gpa);
    self.buffer_ops.deinit(self.gpa);
    self.staging.deinit(self.gpa);
    self.scratch_regions.deinit(self.gpa);
    self.scratch_barriers.deinit(self.gpa);
    self.scratch_buf_barriers.deinit(self.gpa);
    self.* = undefined;
}

/// Bytes queued and not yet recorded.
pub fn pendingBytes(self: *const Uploader) u64 {
    return self.pending;
}

/// Space for `len` bytes: the ring, or a new staging buffer.
fn space(self: *Uploader, len: u64, alignment: u64) !struct { buffer: vk.Buffer, offset: u64, ptr: [*]u8, alloc: ?types.Allocation } {
    if (self.ring) |r| if (r.alloc(len, alignment)) |s| {
        return .{ .buffer = s.buffer, .offset = s.offset, .ptr = s.ptr, .alloc = null };
    } else |_| {};
    const mem = self.mem.?;
    const b = try mem.createBuffer(.{ .size = len, .usage = .{ .transfer_src = true }, .sharing_mode = .exclusive }, .upload_staging, "upload-staging");
    errdefer mem.destroyBuffer(b);
    try self.staging.append(self.gpa, b);
    return .{ .buffer = b.handle, .offset = 0, .ptr = b.alloc.mapped.?, .alloc = b.alloc };
}

/// Copies `pixels` (rows `row_pitch` bytes apart) for `rect` of `tex`
/// into upload memory now; `record` emits the copy.
pub fn writeRegion(self: *Uploader, tex: *Texture, rect: Rect16, pixels: []const u8, row_pitch: u32) !void {
    if (rect.w == 0 or rect.h == 0) return error.EmptyRect;
    if (@as(u32, rect.x) + rect.w > tex.width or @as(u32, rect.y) + rect.h > tex.height) return error.OutOfBounds;
    const bpt = tex.format.bytesPerTexel();
    const row: u64 = @as(u64, rect.w) * bpt;
    if (row_pitch < row or pixels.len < @as(u64, row_pitch) * (rect.h - 1) + row) return error.ShortPixels;
    const len = row * rect.h;
    // Texel-size alignment (4 for RGBA) keeps bufferOffset valid for the format.
    const dst = try self.space(len, @max(bpt, 4));
    if (row_pitch == row) {
        @memcpy(dst.ptr[0..len], pixels[0..len]);
    } else for (0..rect.h) |y| {
        @memcpy(dst.ptr[y * row ..][0..row], pixels[y * row_pitch ..][0..row]);
    }
    if (dst.alloc) |a| try self.mem.?.flush(a, 0, len);
    try self.queueRegion(tex, dst.buffer, dst.offset, rect);
    self.pending += len;
}

/// Queues a copy of tightly packed texels at `src[src_offset..]` into `rect`.
pub fn queueRegion(self: *Uploader, tex: *Texture, src: vk.Buffer, src_offset: u64, rect: Rect16) !void {
    const group = for (self.groups.items, 0..) |t, k| {
        if (t == tex) break k;
    } else blk: {
        try self.groups.append(self.gpa, tex);
        break :blk self.groups.items.len - 1;
    };
    try self.image_ops.append(self.gpa, .{ .tex = tex, .group = @intCast(group), .src = src, .region = .{
        .buffer_offset = src_offset,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = rect.x, .y = rect.y, .z = 0 },
        .image_extent = .{ .width = rect.w, .height = rect.h, .depth = 1 },
    } });
}

/// Copies `bytes` into upload memory now; `record` copies them to
/// `dst[dst_off..]`.
pub fn writeBuffer(self: *Uploader, dst: vk.Buffer, dst_off: u64, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const s = try self.space(bytes.len, 4);
    @memcpy(s.ptr[0..bytes.len], bytes);
    if (s.alloc) |a| try self.mem.?.flush(a, 0, bytes.len);
    try self.buffer_ops.append(self.gpa, .{ .src = s.buffer, .dst = dst, .region = .{ .src_offset = s.offset, .dst_offset = dst_off, .size = bytes.len } });
    self.pending += bytes.len;
}

/// Records every queued upload into `cb` (before rendering) and clears
/// the queue. Ring contents must be flushed first (`UploadRing.endFrame`
/// flushes; staging buffers are flushed on write).
pub fn record(self: *Uploader, cb: vk.CommandBuffer, dd: *const tables.Device) !void {
    defer {
        self.image_ops.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.buffer_ops.clearRetainingCapacity();
        self.pending = 0;
    }
    // Group by texture, keeping first-appearance order (stable sort).
    std.sort.block(ImageOp, self.image_ops.items, {}, struct {
        fn lt(_: void, a: ImageOp, b: ImageOp) bool {
            return a.group < b.group;
        }
    }.lt);
    const ops = self.image_ops.items;

    self.scratch_barriers.clearRetainingCapacity();
    var i: usize = 0;
    while (i < ops.len) : (i += 1) {
        if (i > 0 and ops[i].tex == ops[i - 1].tex) continue;
        const t = ops[i].tex;
        try self.scratch_barriers.append(self.gpa, barriers.imageBarrier(t.image.handle, t.access, .transfer_dst, .{ .color = true }));
    }
    barriers.pipelineBarrier(cb, dd, self.scratch_barriers.items, &.{});

    i = 0;
    while (i < ops.len) {
        var j = i;
        self.scratch_regions.clearRetainingCapacity();
        while (j < ops.len and ops[j].tex == ops[i].tex and ops[j].src == ops[i].src) : (j += 1) try self.scratch_regions.append(self.gpa, ops[j].region);
        dd.cmd_copy_buffer_to_image(cb, ops[i].src, ops[i].tex.image.handle, .transfer_dst_optimal, @intCast(self.scratch_regions.items.len), self.scratch_regions.items.ptr);
        i = j;
    }

    self.scratch_buf_barriers.clearRetainingCapacity();
    for (self.buffer_ops.items) |op| {
        dd.cmd_copy_buffer(cb, op.src, op.dst, 1, &.{op.region});
        try self.scratch_buf_barriers.append(self.gpa, barriers.transferToShaderRead(op.dst, op.region.dst_offset, op.region.size));
    }

    for (self.scratch_barriers.items) |*b| b.* = barriers.imageBarrier(b.image, .transfer_dst, .shader_read, .{ .color = true });
    barriers.pipelineBarrier(cb, dd, self.scratch_barriers.items, self.scratch_buf_barriers.items);
    i = 0;
    while (i < ops.len) : (i += 1) ops[i].tex.access = .shader_read;
}

/// Frees the staging buffers of recorded uploads. Call when the frame
/// that used them has completed on the GPU.
pub fn retire(self: *Uploader) void {
    for (self.staging.items) |b| self.mem.?.destroyBuffer(b);
    self.staging.clearRetainingCapacity();
}

// A recording fake of the three commands `record` uses.
const Fake = struct {
    var barrier_calls: u32 = 0;
    var image_barriers: u32 = 0;
    var copy_calls: u32 = 0;
    var regions: u32 = 0;
    var buffer_copies: u32 = 0;
    var last_layouts: [8]vk.ImageLayout = undefined;

    fn barrier(_: vk.CommandBuffer, d: *const vk.DependencyInfo) callconv(vk.cc) void {
        barrier_calls += 1;
        image_barriers += d.image_memory_barrier_count;
        if (d.p_image_memory_barriers) |p| for (p[0..d.image_memory_barrier_count], 0..) |b, k| {
            last_layouts[k] = b.new_layout;
        };
    }
    fn copyToImage(_: vk.CommandBuffer, _: vk.Buffer, _: vk.Image, layout: vk.ImageLayout, n: u32, _: [*]const vk.BufferImageCopy) callconv(vk.cc) void {
        std.debug.assert(layout == .transfer_dst_optimal);
        copy_calls += 1;
        regions += n;
    }
    fn copyBuffer(_: vk.CommandBuffer, _: vk.Buffer, _: vk.Buffer, n: u32, _: [*]const vk.BufferCopy) callconv(vk.cc) void {
        buffer_copies += n;
    }
};

test "uploader: regions grouped per texture" {
    var dd: tables.Device = undefined;
    dd.cmd_pipeline_barrier2 = Fake.barrier;
    dd.cmd_copy_buffer_to_image = Fake.copyToImage;
    dd.cmd_copy_buffer = Fake.copyBuffer;

    var atlas: Texture = .{ .image = .{ .handle = @enumFromInt(10), .alloc = undefined, .extent = .{ .width = 1024, .height = 1024 }, .format = .r8_unorm }, .view = .null_handle, .format = .r8_unorm, .width = 1024, .height = 1024 };
    var image: Texture = atlas;
    image.image.handle = @enumFromInt(11);
    image.access = .shader_read;

    var up: Uploader = .{ .gpa = std.testing.allocator, .mem = null, .ring = null };
    defer up.deinit();
    const ring: vk.Buffer = @enumFromInt(1);
    // 100 glyph rects into the atlas, interleaved with two image rects.
    for (0..100) |k| {
        try up.queueRegion(&atlas, ring, k * 4096, .{ .x = @intCast(k * 8), .y = 0, .w = 8, .h = 8 });
        if (k == 10 or k == 60) try up.queueRegion(&image, ring, 900_000 + k, .{ .x = 0, .y = 0, .w = 4, .h = 4 });
    }
    up.buffer_ops.append(std.testing.allocator, .{ .src = ring, .dst = @enumFromInt(2), .region = .{ .src_offset = 0, .dst_offset = 0, .size = 64 } }) catch unreachable;
    try up.record(@enumFromInt(5), &dd);

    try std.testing.expectEqual(@as(u32, 2), Fake.barrier_calls); // one pair
    try std.testing.expectEqual(@as(u32, 4), Fake.image_barriers); // two textures, each way
    try std.testing.expectEqual(@as(u32, 2), Fake.copy_calls); // one copy per texture
    try std.testing.expectEqual(@as(u32, 102), Fake.regions);
    try std.testing.expectEqual(@as(u32, 1), Fake.buffer_copies);
    try std.testing.expectEqual(vk.ImageLayout.shader_read_only_optimal, Fake.last_layouts[0]);
    try std.testing.expectEqual(barriers.Access.shader_read, atlas.access);
    try std.testing.expectEqual(@as(usize, 0), up.image_ops.items.len);
}
