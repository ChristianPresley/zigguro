//! GPU memory types and the pure helpers behind `DeviceMemory`
//! (E02.F03.S01.T02): memory-type selection, flush-range alignment and
//! block sizing.

const std = @import("std");
const vk = @import("../vk/vk.zig");

/// What an allocation is for; decides the memory type.
pub const Usage = enum {
    /// GPU reads and writes only.
    gpu_only,
    /// CPU writes, GPU reads; prefers device-local host-visible memory
    /// (ReBAR, UMA).
    upload,
    /// CPU reads back what the GPU wrote (host-cached when possible).
    readback,
    /// CPU-written staging for copies; avoids the device-local heap.
    upload_staging,
};

/// A suballocation (or a dedicated `VkDeviceMemory`).
pub const Allocation = struct {
    memory: vk.DeviceMemory,
    offset: u64,
    size: u64,
    /// The host pointer when the memory is mapped.
    mapped: ?[*]u8,
    type_index: u5,
    kind: Kind,
    /// The TLSF handle (blocks only).
    handle: u32,
    /// The block's slot in its pool (blocks only).
    block: u16,
    /// Linear (buffers, linear images) or optimal-tiled class.
    linear: bool,
    /// Unique id for leak tracking.
    id: u32,

    pub const Kind = enum(u2) { block, dedicated };
};

/// A buffer bound to its memory.
pub const Buffer = struct {
    handle: vk.Buffer,
    alloc: Allocation,
    size: u64,

    /// The mapped bytes, for host-visible buffers.
    pub fn mappedSlice(self: Buffer) ?[]u8 {
        const p = self.alloc.mapped orelse return null;
        return p[0..self.size];
    }
};

/// An image bound to its memory. `layout` is tracked by the owner.
pub const Image = struct {
    handle: vk.Image,
    alloc: Allocation,
    extent: vk.Extent2D,
    format: vk.Format,
    layout: vk.ImageLayout = .undefined,
};

/// One heap's budget (from `VK_EXT_memory_budget`, or 80% of the heap).
pub const HeapBudget = struct {
    heap: u32,
    budget: u64,
    /// The whole process's usage as reported by the driver (or ours).
    usage: u64,
    /// Bytes zigguro has allocated from the heap.
    ours: u64,
};

pub const TypeStats = struct {
    blocks: u32 = 0,
    block_bytes: u64 = 0,
    used: u64 = 0,
    allocations: u32 = 0,
};

pub const Stats = struct {
    per_type: [32]TypeStats = @splat(.{}),
    dedicated_count: u32 = 0,
    /// Live `VkDeviceMemory` objects.
    total_allocations: u32 = 0,
    /// `vkAllocateMemory` calls since init.
    allocate_calls: u32 = 0,
};

const Flags = vk.MemoryPropertyFlags;

const Want = struct { required: Flags, preferred: Flags = .{}, avoid: Flags = .{} };

fn wants(usage: Usage) Want {
    return switch (usage) {
        .gpu_only => .{ .required = .{ .device_local = true }, .avoid = .{ .host_visible = true } },
        .upload => .{ .required = .{ .host_visible = true, .host_coherent = true }, .preferred = .{ .device_local = true } },
        .upload_staging => .{ .required = .{ .host_visible = true }, .preferred = .{ .host_coherent = true }, .avoid = .{ .device_local = true } },
        .readback => .{ .required = .{ .host_visible = true }, .preferred = .{ .host_cached = true } },
    };
}

/// The memory type for `usage` among `type_bits`: the first type with
/// the required and preferred flags and none to avoid, then relaxing
/// avoid, then preferred. Protected and AMD device-coherent types are
/// never chosen. Pure.
pub fn findMemoryType(props: *const vk.PhysicalDeviceMemoryProperties, type_bits: u32, usage: Usage) ?u5 {
    return findMemoryTypeOpts(props, type_bits, usage, true);
}

/// `findMemoryType` that can rule out device-local host-visible types
/// for `upload` (once the ReBAR allowance is spent).
pub fn findMemoryTypeOpts(props: *const vk.PhysicalDeviceMemoryProperties, type_bits: u32, usage: Usage, allow_rebar: bool) ?u5 {
    var w = wants(usage);
    if (usage == .upload and !allow_rebar) {
        w.preferred = .{};
        w.avoid = .{ .device_local = true };
    }
    const tries = [_]struct { Flags, Flags }{
        .{ w.required.merge(w.preferred), w.avoid },
        .{ w.required.merge(w.preferred), .{} },
        .{ w.required, w.avoid },
        .{ w.required, .{} },
    };
    const never: Flags = .{ .protected = true, .device_coherent_amd = true };
    for (tries) |t| {
        for (props.memory_types[0..props.memory_type_count], 0..) |mt, i| {
            if (type_bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const f = mt.property_flags;
            if (!f.intersect(never).isEmpty()) continue;
            if (!f.contains(t[0])) continue;
            if (!f.intersect(t[1]).isEmpty()) continue;
            return @intCast(i);
        }
    }
    return null;
}

/// A mapped range aligned for `vkFlushMappedMemoryRanges`: the offset
/// rounded down and the end rounded up to `atom`, clamped to the memory
/// object's `mem_size`. Pure.
pub fn flushRange(offset: u64, len: u64, atom: u64, mem_size: u64) struct { offset: u64, size: u64 } {
    const a = @max(atom, 1);
    const start = offset / a * a;
    const end = @min(std.mem.alignForward(u64, offset + len, a), mem_size);
    return .{ .offset = start, .size = end - start };
}

pub const min_block_size: u64 = 4 << 20;

/// The block size for a heap: `default` (64 MiB), or heap/8 rounded down
/// to a power of two (at least 4 MiB) for heaps under 1 GiB. Pure.
pub fn blockSizeFor(heap_size: u64, default: u64) u64 {
    if (heap_size >= 1 << 30) return default;
    const eighth = heap_size / 8;
    if (eighth < min_block_size) return min_block_size;
    return @min(default, std.math.floorPowerOfTwo(u64, eighth));
}

/// Test fixtures: memory layouts of common devices.
pub const fixtures = struct {
    fn props(heaps: []const vk.MemoryHeap, types: []const vk.MemoryType) vk.PhysicalDeviceMemoryProperties {
        var p: vk.PhysicalDeviceMemoryProperties = .{};
        p.memory_heap_count = @intCast(heaps.len);
        @memcpy(p.memory_heaps[0..heaps.len], heaps);
        p.memory_type_count = @intCast(types.len);
        @memcpy(p.memory_types[0..types.len], types);
        return p;
    }
    const dl: Flags = .{ .device_local = true };
    const dl_heap: vk.MemoryHeapFlags = .{ .device_local = true };
    const hvc: Flags = .{ .host_visible = true, .host_coherent = true };
    const hvcc: Flags = .{ .host_visible = true, .host_coherent = true, .host_cached = true };
    const all: Flags = .{ .device_local = true, .host_visible = true, .host_coherent = true };

    /// A discrete GPU with resizable BAR: 8 GiB VRAM fully host-visible.
    pub fn discreteRebar() vk.PhysicalDeviceMemoryProperties {
        return props(&.{ .{ .size = 8 << 30, .flags = dl_heap }, .{ .size = 32 << 30 } }, &.{
            .{ .property_flags = dl, .heap_index = 0 },
            .{ .property_flags = hvc, .heap_index = 1 },
            .{ .property_flags = hvcc, .heap_index = 1 },
            .{ .property_flags = all, .heap_index = 0 },
        });
    }
    /// A discrete GPU without resizable BAR: a 256 MiB host-visible window.
    pub fn discreteNoRebar() vk.PhysicalDeviceMemoryProperties {
        return props(&.{ .{ .size = 8 << 30, .flags = dl_heap }, .{ .size = 32 << 30 }, .{ .size = 256 << 20, .flags = dl_heap } }, &.{
            .{ .property_flags = dl, .heap_index = 0 },
            .{ .property_flags = hvc, .heap_index = 1 },
            .{ .property_flags = hvcc, .heap_index = 1 },
            .{ .property_flags = all, .heap_index = 2 },
        });
    }
    /// An integrated GPU: one heap, every type host-visible.
    pub fn uma() vk.PhysicalDeviceMemoryProperties {
        return props(&.{.{ .size = 16 << 30, .flags = dl_heap }}, &.{
            .{ .property_flags = dl, .heap_index = 0 },
            .{ .property_flags = all, .heap_index = 0 },
            .{ .property_flags = .{ .device_local = true, .host_visible = true, .host_coherent = true, .host_cached = true }, .heap_index = 0 },
        });
    }
    /// lavapipe: one heap, one type with everything.
    pub fn lavapipe() vk.PhysicalDeviceMemoryProperties {
        return props(&.{.{ .size = 2 << 30, .flags = dl_heap }}, &.{
            .{ .property_flags = .{ .device_local = true, .host_visible = true, .host_coherent = true, .host_cached = true }, .heap_index = 0 },
        });
    }
};

test "mem: findMemoryType table" {
    const T = std.testing;
    const any: u32 = 0xffff_ffff;
    const cases = [_]struct { vk.PhysicalDeviceMemoryProperties, [4]?u5 }{
        // gpu_only, upload, readback, upload_staging
        .{ fixtures.discreteRebar(), .{ 0, 3, 2, 1 } },
        .{ fixtures.discreteNoRebar(), .{ 0, 3, 2, 1 } },
        .{ fixtures.uma(), .{ 0, 1, 2, 1 } },
        .{ fixtures.lavapipe(), .{ 0, 0, 0, 0 } },
    };
    for (cases) |c| {
        try T.expectEqual(c[1][0], findMemoryType(&c[0], any, .gpu_only));
        try T.expectEqual(c[1][1], findMemoryType(&c[0], any, .upload));
        try T.expectEqual(c[1][2], findMemoryType(&c[0], any, .readback));
        try T.expectEqual(c[1][3], findMemoryType(&c[0], any, .upload_staging));
    }
    // The ReBAR allowance spent: uploads go to system memory.
    const r = fixtures.discreteRebar();
    try T.expectEqual(@as(?u5, 1), findMemoryTypeOpts(&r, any, .upload, false));
    // type_bits restrict the choice.
    try T.expectEqual(@as(?u5, 3), findMemoryType(&r, 0b1000, .gpu_only));
    try T.expectEqual(@as(?u5, null), findMemoryType(&r, 0b0110, .gpu_only));
    // Protected types are never chosen.
    var p = fixtures.lavapipe();
    p.memory_types[0].property_flags.protected = true;
    try T.expectEqual(@as(?u5, null), findMemoryType(&p, any, .gpu_only));
}

test "mem: flush range alignment" {
    const r = flushRange(100, 10, 64, 4096);
    try std.testing.expectEqual(@as(u64, 64), r.offset);
    try std.testing.expectEqual(@as(u64, 64), r.size);
    const e = flushRange(4000, 96, 256, 4096);
    try std.testing.expectEqual(@as(u64, 3840), e.offset);
    try std.testing.expectEqual(@as(u64, 256), e.size); // clamped to the end
    const z = flushRange(5, 3, 0, 64);
    try std.testing.expectEqual(@as(u64, 5), z.offset);
    try std.testing.expectEqual(@as(u64, 3), z.size);
}

test "mem: block size per heap" {
    try std.testing.expectEqual(@as(u64, 64 << 20), blockSizeFor(8 << 30, 64 << 20));
    try std.testing.expectEqual(@as(u64, 32 << 20), blockSizeFor(256 << 20, 64 << 20));
    try std.testing.expectEqual(@as(u64, 16 << 20), blockSizeFor(200 << 20, 64 << 20));
    try std.testing.expectEqual(@as(u64, 4 << 20), blockSizeFor(16 << 20, 64 << 20));
}
