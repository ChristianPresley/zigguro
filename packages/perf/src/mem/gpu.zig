//! GPU memory accounting (E14.F04.S01.T01). The renderer (E02) charges
//! each device-memory block (`vkAllocateMemory` / `vkFreeMemory`, not
//! sub-allocations) to a `GpuTag`, and implements a `GpuMemSource` that
//! reads the driver's numbers (`VK_EXT_memory_budget` heap usage and
//! budget for DEVICE_LOCAL heaps; the shared heap on UMA). `query` merges
//! both; it runs only when the memory sampler does.

const std = @import("std");

pub const GpuTag = enum(u3) { atlas, layers, instance_rings, images, swapchain, staging, other };

/// GPU memory at a point in time.
pub const GpuMem = struct {
    /// From the driver (`heapUsage`), or the tag sum without a source.
    device_local_used: u64 = 0,
    /// From the driver (`heapBudget`); 0 when unknown.
    device_local_budget: u64 = 0,
    host_visible_used: u64 = 0,
    /// Bytes charged per `GpuTag` (the budget `mem.gpu_device_local` is
    /// checked against their sum).
    per_tag: [8]u64 = @splat(0),

    /// Sum of the tag charges.
    pub fn taggedTotal(g: GpuMem) u64 {
        var t: u64 = 0;
        for (g.per_tag) |v| t += v;
        return t;
    }
};

/// Fills `out` with the driver's numbers; false when unavailable.
pub const GpuMemSource = struct {
    ctx: *anyopaque,
    query: *const fn (ctx: *anyopaque, out: *GpuMem) bool,
};

var per_tag: [8]std.atomic.Value(i64) = @splat(.init(0));
var source: ?GpuMemSource = null;
var source_mutex: std.atomic.Mutex = .unlocked;

/// Installs (or with null removes) the driver source.
pub fn setGpuSource(src: ?GpuMemSource) void {
    while (!source_mutex.tryLock()) std.atomic.spinLoopHint();
    defer source_mutex.unlock();
    source = src;
}

/// A block of `delta` bytes allocated (positive) or freed (negative).
pub fn gpuChargeTag(tag: GpuTag, delta: i64) void {
    _ = per_tag[@intFromEnum(tag)].fetchAdd(delta, .monotonic);
}

/// Tag charges plus the driver's numbers; null when nothing is known.
pub fn query() ?GpuMem {
    var g: GpuMem = .{};
    for (&g.per_tag, 0..) |*v, i| v.* = @intCast(@max(0, per_tag[i].load(.monotonic)));
    const src = blk: {
        while (!source_mutex.tryLock()) std.atomic.spinLoopHint();
        defer source_mutex.unlock();
        break :blk source;
    };
    if (src) |s| {
        var d: GpuMem = .{};
        if (s.query(s.ctx, &d)) {
            g.device_local_used = d.device_local_used;
            g.device_local_budget = d.device_local_budget;
            g.host_visible_used = d.host_visible_used;
            return g;
        }
    }
    const tagged = g.taggedTotal();
    if (tagged == 0) return null;
    g.device_local_used = tagged;
    return g;
}

test "gpu: charge and query via fake source" {
    defer setGpuSource(null);
    const base = if (query()) |q| q.per_tag[@intFromEnum(GpuTag.atlas)] else 0;
    gpuChargeTag(.atlas, 4 << 20);
    gpuChargeTag(.swapchain, 24 << 20);
    defer {
        gpuChargeTag(.atlas, -(4 << 20));
        gpuChargeTag(.swapchain, -(24 << 20));
    }
    // Without a source the tag sum stands in for the driver.
    const a = query().?;
    try std.testing.expectEqual(base + (4 << 20), a.per_tag[@intFromEnum(GpuTag.atlas)]);
    try std.testing.expectEqual(a.taggedTotal(), a.device_local_used);
    const Fake = struct {
        fn q(_: *anyopaque, out: *GpuMem) bool {
            out.device_local_used = 40 << 20;
            out.device_local_budget = 6 << 30;
            return true;
        }
    };
    var dummy: u8 = 0;
    setGpuSource(.{ .ctx = &dummy, .query = Fake.q });
    const b = query().?;
    try std.testing.expectEqual(@as(u64, 40 << 20), b.device_local_used);
    try std.testing.expectEqual(@as(u64, 6 << 30), b.device_local_budget);
    try std.testing.expectEqual(base + (4 << 20), b.per_tag[@intFromEnum(GpuTag.atlas)]);
}
