//! The per-frame linear upload allocator for instance data, clip data
//! and small uploads (E02.F03.S02.T01).
//!
//! One host-visible buffer holds `frames_in_flight` slots of
//! `bytes_per_frame`. On ReBAR/UMA the shaders read it directly; otherwise
//! a GPU-only mirror receives one `vkCmdCopyBuffer` of the used prefix per
//! frame. The caller guarantees a slot's previous GPU use has completed
//! before `beginFrame` reuses it (E02.F04 frame timeline).

const UploadRing = @This();

const std = @import("std");
const vk = @import("../vk/vk.zig");
const tables = @import("../loader/tables.zig");
const DeviceMemory = @import("DeviceMemory.zig");
const types = @import("types.zig");
const barriers = @import("barriers.zig");

/// The bump arithmetic of one slot (pure).
pub const Bump = struct {
    base: u64,
    cap: u64,
    head: u64 = 0,
    /// Every offset is aligned to at least this (minStorageBufferOffsetAlignment).
    min_align: u64 = 16,

    /// The absolute offset of `len` bytes aligned to `alignment`, or null
    /// when the slot is full.
    pub fn take(self: *Bump, len: u64, alignment: u64) ?u64 {
        const a = @max(alignment, self.min_align);
        std.debug.assert(std.math.isPowerOfTwo(a));
        const start = std.mem.alignForward(u64, self.base + self.head, a);
        if (start + len > self.base + self.cap) return null;
        self.head = start + len - self.base;
        return start;
    }
};

/// Memory from `alloc`, valid until the slot is reused.
pub const Slice = struct {
    /// The buffer to copy from (the ring).
    buffer: vk.Buffer,
    /// Offset in `buffer` and in `gpuBuffer()`.
    offset: u64,
    ptr: [*]u8,
    len: u64,
    /// Shaders see the bytes without a copy.
    device_local: bool,

    pub fn bytes(self: Slice) []u8 {
        return self.ptr[0..self.len];
    }
};

mem: *DeviceMemory,
ring: types.Buffer,
mirror: ?types.Buffer,
frames: u8,
per_frame: u64,
slot: u8 = 0,
bump: Bump,
/// The largest request that did not fit; the owner grows the ring with
/// `resize` once every slot has retired.
wanted: u64 = 0,

pub fn init(mem: *DeviceMemory, frames_in_flight: u8, bytes_per_frame: u64) !UploadRing {
    std.debug.assert(frames_in_flight >= 1 and frames_in_flight <= 3);
    const total = bytes_per_frame * frames_in_flight;
    const ring = try mem.createBuffer(.{ .size = total, .usage = .{ .storage_buffer = true, .transfer_src = true, .vertex_buffer = true, .index_buffer = true }, .sharing_mode = .exclusive }, .upload, "upload-ring");
    errdefer mem.destroyBuffer(ring);
    const flags = mem.props.memory_types[ring.alloc.type_index].property_flags;
    const mirror: ?types.Buffer = if (flags.device_local) null else try mem.createBuffer(.{
        .size = total,
        .usage = .{ .storage_buffer = true, .transfer_dst = true, .vertex_buffer = true, .index_buffer = true },
        .sharing_mode = .exclusive,
    }, .gpu_only, "upload-ring-mirror");
    return .{
        .mem = mem,
        .ring = ring,
        .mirror = mirror,
        .frames = frames_in_flight,
        .per_frame = bytes_per_frame,
        .bump = .{ .base = 0, .cap = bytes_per_frame, .min_align = @max(16, mem.gpu.info.limits.min_storage_align) },
    };
}

pub fn deinit(self: *UploadRing) void {
    if (self.mirror) |m| self.mem.destroyBuffer(m);
    self.mem.destroyBuffer(self.ring);
    self.* = undefined;
}

/// True when shaders read the ring itself (ReBAR/UMA).
pub fn deviceLocal(self: *const UploadRing) bool {
    return self.mirror == null;
}

/// Starts writing slot `frame_slot` (its previous GPU use has completed).
pub fn beginFrame(self: *UploadRing, frame_slot: u8) void {
    std.debug.assert(frame_slot < self.frames);
    self.slot = frame_slot;
    self.bump = .{ .base = @as(u64, frame_slot) * self.per_frame, .cap = self.per_frame, .min_align = self.bump.min_align };
}

/// `len` bytes for this frame.
pub fn alloc(self: *UploadRing, len: u64, alignment: u64) error{RingFull}!Slice {
    const off = self.bump.take(len, alignment) orelse {
        self.wanted = @max(self.wanted, self.bump.head + len);
        return error.RingFull;
    };
    const base = self.ring.alloc.mapped.?;
    return .{ .buffer = self.ring.handle, .offset = off, .ptr = base + off, .len = len, .device_local = self.deviceLocal() };
}

/// Bytes used in the current slot.
pub fn used(self: *const UploadRing) u64 {
    return self.bump.head;
}

/// Flushes the slot and, without ReBAR/UMA, records the copy of the used
/// prefix into the mirror followed by a transfer→shader-read barrier.
pub fn endFrame(self: *UploadRing, cb: vk.CommandBuffer, dd: *const tables.Device) !void {
    const n = self.bump.head;
    if (n == 0) return;
    try self.mem.flush(self.ring.alloc, self.bump.base, n);
    const m = self.mirror orelse return;
    const region = [_]vk.BufferCopy{.{ .src_offset = self.bump.base, .dst_offset = self.bump.base, .size = n }};
    dd.cmd_copy_buffer(cb, self.ring.handle, m.handle, 1, &region);
    const b = [_]vk.BufferMemoryBarrier2{barriers.transferToShaderRead(m.handle, self.bump.base, n)};
    barriers.pipelineBarrier(cb, dd, &.{}, &b);
}

/// The buffer shaders bind: the mirror, or the ring itself.
pub fn gpuBuffer(self: *const UploadRing) vk.Buffer {
    return if (self.mirror) |m| m.handle else self.ring.handle;
}

/// Reallocates with `bytes_per_frame` per slot. Only when no slot is in
/// use by the GPU (after the frame timeline retires them all).
pub fn resize(self: *UploadRing, bytes_per_frame: u64) !void {
    const mem = self.mem;
    const frames = self.frames;
    self.deinit();
    self.* = try init(mem, frames, bytes_per_frame);
}

test "ring: alignment and wrap per slot" {
    var b: Bump = .{ .base = 4096, .cap = 1024, .min_align = 64 };
    try std.testing.expectEqual(@as(?u64, 4096), b.take(10, 4));
    try std.testing.expectEqual(@as(?u64, 4160), b.take(100, 16));
    try std.testing.expectEqual(@as(?u64, 4352), b.take(8, 256));
    try std.testing.expectEqual(@as(u64, 264), b.head);
    // Exactly full, then nothing more.
    try std.testing.expectEqual(@as(?u64, 4416), b.take(1024 - 320, 64));
    try std.testing.expectEqual(@as(?u64, null), b.take(1, 1));
    // A fresh slot starts at its own base.
    var c: Bump = .{ .base = 2 * 1024, .cap = 1024 };
    try std.testing.expectEqual(@as(?u64, 2048), c.take(1, 1));
    try std.testing.expectEqual(@as(?u64, 2064), c.take(1, 1));
}
