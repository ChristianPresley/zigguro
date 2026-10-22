//! The Readback target (E02.F04.S02.T02): the GPU renders into an
//! optimal-tiled offscreen image, the repainted rects are copied into a
//! host-visible buffer of the frame slot, and once the slot's timeline
//! value completes the pixels are delivered to a CPU sink:
//!
//! - `.headless`: a persistent CPU backbuffer is patched and handed to
//!   E01's `HeadlessSink.write` with the frame's rects;
//! - `.shm`: the backbuffer is patched the same way, then `ShmRing`
//!   copies it into a released `allocCpuBuffer` buffer of an external
//!   presenter (buffer-age repaint) and presents the frame's rects;
//! - `.memory`: the rects are copied into a caller-owned `CpuImage`
//!   (tests and the parity runner).
//!
//! One offscreen image is kept (frames on one queue are ordered), so its
//! age is 1 after the first frame and 0 after creation or resize.

const Readback = @This();

const std = @import("std");
const platform = @import("zg_platform");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const DeviceMemory = @import("../mem/DeviceMemory.zig");
const Texture = @import("../mem/Texture.zig");
const types = @import("../mem/types.zig");
const barriers = @import("../mem/barriers.zig");
const CpuImage = @import("../testing/CpuImage.zig");
const FrameScheduler = @import("FrameScheduler.zig");
const Damage = @import("Damage.zig");
const ShmRing = @import("ShmRing.zig");
const rect = @import("../r2d/rect.zig");

const PxRect = rect.PxRect;
const Size = rect.Size;

pub const Sink = union(enum) {
    headless: *platform.surface.HeadlessSink,
    /// An external presenter without dmabuf (wl_shm, MIT-SHM).
    shm: *platform.surface.Presenter,
    memory: *CpuImage,
};

/// One region of a slot's copy: where `rect` lands in the buffer.
pub const Region = struct { rect: PxRect, offset: u64 };

/// Tightly packed regions for `rects` (`bufferRowLength = rect.w`), and
/// the bytes they need. Pure.
pub fn packRegions(rects: []const PxRect, out: []Region) struct { regions: []Region, bytes: u64 } {
    var off: u64 = 0;
    const n = @min(rects.len, out.len);
    for (rects[0..n], out[0..n]) |r, *o| {
        o.* = .{ .rect = r, .offset = off };
        off += rect.area(r) * 4;
    }
    return .{ .regions = out[0..n], .bytes = off };
}

const Pending = struct {
    buffer: ?types.Buffer = null,
    regions: [Damage.RectList.capacity]Region = undefined,
    len: u8 = 0,
    /// The image size when the copy was recorded.
    extent: Size = .{ .w = 0, .h = 0 },
    /// The timeline value after which the copy is readable (0 = nothing
    /// pending).
    value: u64 = 0,
    recorded: bool = false,
};

gpu: *Gpu,
mem: *DeviceMemory,
sched: *FrameScheduler,
sink: Sink,
window: platform.types.WindowId,
format: Texture.Format,
image: ?Texture = null,
extent: Size = .{ .w = 0, .h = 0 },
pending: [FrameScheduler.max_frames_in_flight]Pending = @splat(.{}),
/// The headless and shm sinks' persistent backbuffer.
back: ?CpuImage = null,
/// The shm sink's presenter buffers.
shm: ?ShmRing = null,
/// Bytes delivered so far (tests and the trace counter).
copied_bytes: u64 = 0,

/// A readback target delivering to `sink`. Headless output is BGRA; a
/// memory sink gets its image's channel order.
pub fn init(gpu: *Gpu, mem: *DeviceMemory, sched: *FrameScheduler, sink: Sink, window: platform.types.WindowId) Readback {
    const format: Texture.Format = switch (sink) {
        .headless, .shm => .bgra8_unorm,
        .memory => |img| if (img.order == .bgra) .bgra8_unorm else .rgba8_unorm,
    };
    return .{
        .gpu = gpu,
        .mem = mem,
        .sched = sched,
        .sink = sink,
        .window = window,
        .format = format,
        .shm = if (sink == .shm) ShmRing.init(sink.shm) else null,
    };
}

/// Delivers what is complete; the GPU must be idle or the scheduler about
/// to wait for it (the renderer calls this before `sched.deinit`).
pub fn deinit(self: *Readback) void {
    self.waitIdle();
    for (&self.pending) |*p| if (p.buffer) |b| self.mem.destroyBuffer(b);
    if (self.image) |*img| img.destroy(self.mem);
    if (self.back) |*b| b.deinit(self.gpu.gpa);
    if (self.shm) |*r| r.deinit();
    self.* = undefined;
}

/// The colour attachment format pipelines must target.
pub fn vkFormat(self: *const Readback) vk.Format {
    return self.format.vkFormat();
}

/// Switches to a memory sink (same channel order) or back to the sink
/// given to `init`.
pub fn setSink(self: *Readback, sink: Sink) void {
    self.waitIdle();
    self.sink = sink;
}

pub const Acquired = struct { image: *Texture, age: u32 };

/// The offscreen image for this frame, (re)created for `extent`.
pub fn acquire(self: *Readback, extent: Size) !Acquired {
    var age: u32 = 1;
    if (self.image == null or self.extent.w != extent.w or self.extent.h != extent.h) {
        if (self.image) |img| self.sched.deferDestroy(.{ .texture = img });
        self.image = null;
        self.image = try Texture.create(self.mem, extent.w, extent.h, self.format, .render_target, "readback-target");
        self.extent = extent;
        age = 0;
    }
    return .{ .image = &self.image.?, .age = age };
}

/// Records the copy of `rects` of the image (left in COLOR_ATTACHMENT)
/// into slot `fs`'s buffer. Call `present` after the frame is submitted.
pub fn recordCopy(self: *Readback, fs: *FrameScheduler.FrameSlot, rects: []const PxRect) !void {
    const p = &self.pending[fs.index];
    std.debug.assert(p.value == 0 and !p.recorded);
    const img = &self.image.?;
    const packed_regions = packRegions(rects, &p.regions);
    p.len = @intCast(packed_regions.regions.len);
    p.extent = self.extent;
    if (p.len == 0) return;
    if (p.buffer == null or p.buffer.?.size < packed_regions.bytes) {
        if (p.buffer) |b| self.sched.deferDestroy(.{ .buffer = b });
        p.buffer = null;
        // Grow to the full frame at least, so damage changes rarely reallocate.
        const size = @max(packed_regions.bytes, @as(u64, self.extent.w) * self.extent.h * 4);
        p.buffer = try self.mem.createBuffer(.{ .size = size, .usage = .{ .transfer_dst = true }, .sharing_mode = .exclusive }, .readback, "readback-buffer");
    }
    const d = &self.gpu.ddisp;
    barriers.imageTransition(fs.cb, d, img.image.handle, .color_attachment, .transfer_src, .{ .color = true });
    img.access = .transfer_src;
    var regions: [Damage.RectList.capacity]vk.BufferImageCopy = undefined;
    for (packed_regions.regions, regions[0..p.len]) |r, *o| o.* = .{
        .buffer_offset = r.offset,
        .buffer_row_length = r.rect.w,
        .buffer_image_height = r.rect.h,
        .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = r.rect.x, .y = r.rect.y, .z = 0 },
        .image_extent = .{ .width = r.rect.w, .height = r.rect.h, .depth = 1 },
    };
    d.cmd_copy_image_to_buffer(fs.cb, img.image.handle, .transfer_src_optimal, p.buffer.?.handle, p.len, &regions);
    p.recorded = true;
}

/// Marks slot `fs`'s copy for delivery once its submission completes.
pub fn present(self: *Readback, fs: *const FrameScheduler.FrameSlot) void {
    const p = &self.pending[fs.index];
    if (!p.recorded) return;
    p.recorded = false;
    p.value = fs.timeline_value;
}

/// Delivers every copy whose frame has completed, oldest first, and
/// presents an shm frame that waited for a free buffer. Never waits.
pub fn poll(self: *Readback) void {
    const done = self.sched.completed();
    defer if (self.shm) |*r| {
        if (r.pending() and self.back != null and self.sink == .shm) _ = r.flush(&self.back.?);
    };
    while (true) {
        var oldest: ?*Pending = null;
        for (&self.pending) |*p| if (p.value != 0 and p.value <= done and (oldest == null or p.value < oldest.?.value)) {
            oldest = p;
        };
        const p = oldest orelse return;
        self.deliver(p);
    }
}

/// Blocks until every submitted copy is delivered (tests, shutdown).
pub fn waitIdle(self: *Readback) void {
    var latest: u64 = 0;
    for (self.pending) |p| latest = @max(latest, p.value);
    if (latest != 0) self.sched.waitValue(latest) catch {};
    self.poll();
}

fn deliver(self: *Readback, p: *Pending) void {
    defer p.value = 0;
    const b = p.buffer orelse return;
    self.mem.invalidate(b.alloc, 0, b.size) catch {};
    const src = b.mappedSlice() orelse return;
    const dst: *CpuImage = switch (self.sink) {
        .memory => |img| img,
        .headless, .shm => blk: {
            if (self.back == null or self.back.?.width != p.extent.w or self.back.?.height != p.extent.h) {
                if (self.back) |*bb| bb.deinit(self.gpu.gpa);
                self.back = null;
                self.back = CpuImage.initOrder(self.gpu.gpa, p.extent.w, p.extent.h, .bgra) catch return;
            }
            break :blk &self.back.?;
        },
    };
    var rects: [Damage.RectList.capacity]PxRect = undefined;
    var n: usize = 0;
    for (p.regions[0..p.len]) |r| {
        const c = rect.clamp(r.rect, .{ .w = dst.width, .h = dst.height });
        if (rect.isEmpty(c) or !std.meta.eql(c, r.rect)) continue;
        const row = @as(usize, r.rect.w) * 4;
        for (0..r.rect.h) |y| {
            const from = src[r.offset + y * row ..][0..row];
            const to = dst.pixels[(@as(usize, @intCast(r.rect.y)) + y) * dst.stride + @as(usize, @intCast(r.rect.x)) * 4 ..][0..row];
            @memcpy(to, from);
        }
        self.copied_bytes += row * r.rect.h;
        rects[n] = r.rect;
        n += 1;
    }
    switch (self.sink) {
        .headless => |sink| sink.write(sink.ptr, self.window, rects[0..n], dst.pixels, dst.stride),
        .shm => if (n != 0) {
            const full = n == 1 and std.meta.eql(rects[0], rect.full(.{ .w = dst.width, .h = dst.height }));
            self.shm.?.submit(dst, rects[0..n], full);
        },
        .memory => {},
    }
}

test "readback: rect packing offsets" {
    var buf: [4]Region = undefined;
    const r = packRegions(&.{ .{ .x = 0, .y = 0, .w = 10, .h = 2 }, .{ .x = 5, .y = 5, .w = 3, .h = 3 } }, &buf);
    try std.testing.expectEqual(@as(usize, 2), r.regions.len);
    try std.testing.expectEqual(@as(u64, 0), r.regions[0].offset);
    try std.testing.expectEqual(@as(u64, 80), r.regions[1].offset);
    try std.testing.expectEqual(@as(u64, 80 + 36), r.bytes);
}
