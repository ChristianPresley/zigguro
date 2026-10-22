//! The device-memory manager every E02 resource goes through
//! (E02.F03.S01.T02): memory-type selection per `Usage`, per-type block
//! pools suballocated with TLSF, dedicated allocations, persistent
//! mapping, flushes for non-coherent memory, budget tracking, statistics
//! and leak reports.
//!
//! Linear resources (buffers, linear images) and optimal-tiled images
//! never share a block, which sidesteps `bufferImageGranularity`.
//! Defragmentation is out of scope (UI workloads keep long-lived atlases
//! and per-frame rings); `stats` shows when it would be needed.

const DeviceMemory = @This();

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("../vk/vk.zig");
const Gpu = @import("../gpu/Gpu.zig");
const Tlsf = @import("tlsf.zig").Tlsf;
const types = @import("types.zig");

const log = std.log.scoped(.vk);

pub const Usage = types.Usage;
pub const Allocation = types.Allocation;
pub const Buffer = types.Buffer;
pub const Image = types.Image;
pub const HeapBudget = types.HeapBudget;
pub const Stats = types.Stats;

pub const Options = struct {
    /// Default block size; heaps under 1 GiB use heap/8 (see `types.blockSizeFor`).
    block_size: u64 = 64 << 20,
    /// Most `upload` bytes placed in device-local host-visible memory on
    /// non-UMA devices (the BAR window may be only 256 MiB).
    rebar_limit: u64 = 64 << 20,
    /// Frames an empty block (not the last of its pool) waits before it is freed.
    free_after_frames: u64 = 3,
};

pub const Error = error{ OutOfMemory, NoMemoryType } || vk.Error;

/// Dedicated-allocation needs of a resource.
pub const Dedicated = union(enum) {
    no,
    /// The driver prefers (or requires) a dedicated allocation for this resource.
    buffer: struct { handle: vk.Buffer, required: bool },
    image: struct { handle: vk.Image, required: bool },
};

/// What `allocFor` needs to know.
pub const Request = struct {
    reqs: vk.MemoryRequirements,
    dedicated: Dedicated = .no,
    /// Export as a dmabuf (always dedicated).
    export_dmabuf: bool = false,
};

const Block = struct {
    memory: vk.DeviceMemory,
    size: u64,
    tlsf: Tlsf,
    mapped: ?[*]u8,
    live: u32 = 0,
    empty_since: ?u64 = null,
};

const Pool = struct {
    blocks: std.ArrayList(?Block) = .empty,
    /// The next block's size: starts at a quarter of the default, doubles.
    next_size: u64 = 0,
};

gpu: *Gpu,
gpa: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
opts: Options,
props: vk.PhysicalDeviceMemoryProperties,
/// Pools per (memory type, linear class).
pools: [32][2]Pool = @splat(@splat(.{})),
/// Live allocations: id → name (for leak reports).
live: std.AutoHashMapUnmanaged(u32, [:0]u8) = .empty,
next_id: u32 = 1,
counters: Stats = .{},
heap_ours: [vk.max_memory_heaps]u64 = @splat(0),
budgets: [vk.max_memory_heaps]HeapBudget = undefined,
budget_frame: ?u64 = null,
frame: u64 = 0,
rebar_used: u64 = 0,

pub fn init(gpu: *Gpu, gpa: std.mem.Allocator, opts: Options) DeviceMemory {
    var props: vk.PhysicalDeviceMemoryProperties = .{};
    gpu.instance.disp.get_physical_device_memory_properties(gpu.pdev, &props);
    return .{ .gpu = gpu, .gpa = gpa, .io = gpu.io, .opts = opts, .props = props };
}

/// Frees every block. Live allocations are leaks: they are logged (by
/// name) and freed.
pub fn deinit(self: *DeviceMemory) void {
    if (self.live.count() > 0) {
        var it = self.live.valueIterator();
        while (it.next()) |n| log.err("leaked GPU allocation \"{s}\"", .{n.*});
    }
    const dd = &self.gpu.ddisp;
    for (&self.pools) |*per_type| for (per_type) |*pool| {
        for (pool.blocks.items) |*slot| if (slot.*) |*b| {
            b.tlsf.deinit();
            dd.free_memory(self.gpu.dev, b.memory, null);
        };
        pool.blocks.deinit(self.gpa);
    };
    var it = self.live.valueIterator();
    while (it.next()) |n| self.gpa.free(n.*);
    self.live.deinit(self.gpa);
    self.* = undefined;
}

/// Writes the names of live allocations; returns how many there are.
pub fn reportLeaks(self: *DeviceMemory, w: *std.Io.Writer) std.Io.Writer.Error!usize {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var it = self.live.valueIterator();
    while (it.next()) |n| try w.print("leaked GPU allocation \"{s}\"\n", .{n.*});
    return self.live.count();
}

fn flagsOf(self: *const DeviceMemory, t: u5) vk.MemoryPropertyFlags {
    return self.props.memory_types[t].property_flags;
}

fn isRebar(self: *const DeviceMemory, t: u5) bool {
    const f = self.flagsOf(t);
    return f.device_local and f.host_visible and !self.gpu.info.uma;
}

/// Allocates memory for a resource with requirements `req`.
pub fn allocFor(self: *DeviceMemory, req: Request, usage: Usage, linear: bool, name: [:0]const u8) Error!Allocation {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const r = req.reqs;
    var t = types.findMemoryType(&self.props, r.memory_type_bits, usage) orelse return error.NoMemoryType;
    if (usage == .upload and self.isRebar(t) and self.rebar_used + r.size > self.opts.rebar_limit)
        t = types.findMemoryTypeOpts(&self.props, r.memory_type_bits, usage, false) orelse t;

    const heap_size = self.props.memory_heaps[self.props.memory_types[t].heap_index].size;
    const block_size = types.blockSizeFor(heap_size, self.opts.block_size);
    const wants_dedicated = req.dedicated != .no or req.export_dmabuf or r.size >= block_size / 2;

    const name_copy = try self.gpa.dupeZ(u8, name);
    errdefer self.gpa.free(name_copy);
    try self.live.ensureUnusedCapacity(self.gpa, 1);
    var a = if (wants_dedicated) try self.allocDedicated(t, req, name) else try self.allocBlock(t, r, linear, block_size);
    a.id = self.next_id;
    self.next_id +%= 1;
    self.live.putAssumeCapacity(a.id, name_copy);
    if (usage == .upload and self.isRebar(t)) self.rebar_used += a.size;
    return a;
}

fn allocBlock(self: *DeviceMemory, t: u5, r: vk.MemoryRequirements, linear: bool, block_size: u64) Error!Allocation {
    const pool = &self.pools[t][@intFromBool(linear)];
    // Newest blocks first.
    var i = pool.blocks.items.len;
    while (i > 0) {
        i -= 1;
        if (pool.blocks.items[i]) |*b| {
            if (try b.tlsf.alloc(r.size, @max(r.alignment, 1))) |range| return self.fromBlock(b, range, t, @intCast(i), linear);
        }
    }
    // A new block: a quarter of the default first, doubling, shrunk to fit the budget.
    if (pool.next_size == 0) pool.next_size = @max(block_size / 4, types.min_block_size);
    var size = @max(pool.next_size, std.math.ceilPowerOfTwo(u64, r.size + r.alignment) catch r.size);
    const heap = self.props.memory_types[t].heap_index;
    const bud = self.budgetLocked()[heap];
    while (size > types.min_block_size and size / 2 >= r.size + r.alignment and bud.usage + size > bud.budget) size /= 2;
    pool.next_size = @min(pool.next_size * 2, block_size);

    const memory = try self.allocateMemory(t, size, null, false);
    errdefer self.freeMemory(t, memory, size);
    const mapped = try self.mapWhole(t, memory);
    var tlsf = try Tlsf.init(self.gpa, size, .{});
    errdefer tlsf.deinit();
    const slot = for (pool.blocks.items, 0..) |s, k| {
        if (s == null) break k;
    } else blk: {
        try pool.blocks.append(self.gpa, null);
        break :blk pool.blocks.items.len - 1;
    };
    pool.blocks.items[slot] = .{ .memory = memory, .size = size, .tlsf = tlsf, .mapped = mapped };
    var name_buf: [48]u8 = undefined;
    self.gpu.name(memory, std.fmt.bufPrintZ(&name_buf, "mem-type{d}-block{d}{s}", .{ t, slot, if (linear) "-linear" else "" }) catch "mem-block");
    const b = &pool.blocks.items[slot].?;
    const range = (try b.tlsf.alloc(r.size, @max(r.alignment, 1))) orelse unreachable;
    return self.fromBlock(b, range, t, @intCast(slot), linear);
}

fn fromBlock(self: *DeviceMemory, b: *Block, range: @import("tlsf.zig").Range, t: u5, slot: u16, linear: bool) Allocation {
    _ = self;
    b.live += 1;
    b.empty_since = null;
    return .{
        .memory = b.memory,
        .offset = range.offset,
        .size = range.size,
        .mapped = if (b.mapped) |p| p + range.offset else null,
        .type_index = t,
        .kind = .block,
        .handle = range.handle,
        .block = slot,
        .linear = linear,
        .id = 0,
    };
}

fn allocDedicated(self: *DeviceMemory, t: u5, req: Request, name: [:0]const u8) Error!Allocation {
    var ded: vk.MemoryDedicatedAllocateInfo = .{};
    switch (req.dedicated) {
        .no => {},
        .buffer => |b| ded.buffer = b.handle,
        .image => |i| ded.image = i.handle,
    }
    const memory = try self.allocateMemory(t, req.reqs.size, if (req.dedicated != .no) &ded else null, req.export_dmabuf);
    errdefer self.freeMemory(t, memory, req.reqs.size);
    const mapped = if (req.export_dmabuf) null else try self.mapWhole(t, memory);
    self.gpu.name(memory, name);
    self.counters.dedicated_count += 1;
    self.counters.per_type[t].allocations += 1;
    self.counters.per_type[t].used += req.reqs.size;
    return .{ .memory = memory, .offset = 0, .size = req.reqs.size, .mapped = mapped, .type_index = t, .kind = .dedicated, .handle = 0, .block = 0, .linear = false, .id = 0 };
}

fn allocateMemory(self: *DeviceMemory, t: u5, size: u64, ded: ?*vk.MemoryDedicatedAllocateInfo, export_dmabuf: bool) Error!vk.DeviceMemory {
    var ai: vk.MemoryAllocateInfo = .{ .allocation_size = size, .memory_type_index = t };
    if (ded) |d| vk.chain(&ai, d);
    var exp: vk.ExportMemoryAllocateInfo = .{ .handle_types = .{ .dma_buf_ext = true } };
    if (export_dmabuf) vk.chain(&ai, &exp);
    var m: vk.DeviceMemory = .null_handle;
    _ = try vk.check(self.gpu.ddisp.allocate_memory(self.gpu.dev, &ai, null, &m));
    self.counters.allocate_calls += 1;
    self.counters.total_allocations += 1;
    self.heap_ours[self.props.memory_types[t].heap_index] += size;
    return m;
}

fn freeMemory(self: *DeviceMemory, t: u5, m: vk.DeviceMemory, size: u64) void {
    self.gpu.ddisp.free_memory(self.gpu.dev, m, null);
    self.counters.total_allocations -= 1;
    self.heap_ours[self.props.memory_types[t].heap_index] -= size;
}

fn mapWhole(self: *DeviceMemory, t: u5, m: vk.DeviceMemory) Error!?[*]u8 {
    if (!self.flagsOf(t).host_visible) return null;
    var p: ?*anyopaque = null;
    _ = try vk.check(self.gpu.ddisp.map_memory(self.gpu.dev, m, 0, vk.whole_size, .{}, &p));
    return @ptrCast(p);
}

/// Frees `a`. Empty blocks are released `free_after_frames` frames later
/// (the GPU may still use them), except the last block of a pool.
pub fn free(self: *DeviceMemory, a: Allocation) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.live.fetchRemove(a.id)) |kv| self.gpa.free(kv.value);
    if (self.isRebar(a.type_index)) self.rebar_used -|= a.size;
    switch (a.kind) {
        .dedicated => {
            self.freeMemory(a.type_index, a.memory, a.size);
            self.counters.dedicated_count -= 1;
            self.counters.per_type[a.type_index].allocations -= 1;
            self.counters.per_type[a.type_index].used -= a.size;
        },
        .block => {
            const pool = &self.pools[a.type_index][@intFromBool(a.linear)];
            const b = &pool.blocks.items[a.block].?;
            b.tlsf.free(a.handle);
            b.live -= 1;
            if (b.live == 0) b.empty_since = self.frame;
        },
    }
}

/// Advances the frame counter and releases blocks that have been empty
/// for `free_after_frames` frames. Call once per frame on the render thread.
pub fn nextFrame(self: *DeviceMemory) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.frame += 1;
    for (&self.pools, 0..) |*per_type, t| for (per_type) |*pool| {
        var live_blocks: usize = 0;
        for (pool.blocks.items) |s| live_blocks += @intFromBool(s != null);
        for (pool.blocks.items) |*slot| {
            if (slot.*) |*b| {
                const since = b.empty_since orelse continue;
                if (live_blocks <= 1 or self.frame - since < self.opts.free_after_frames) continue;
                b.tlsf.deinit();
                self.freeMemory(@intCast(t), b.memory, b.size);
                slot.* = null;
                live_blocks -= 1;
            }
        }
    };
}

/// Makes host writes to `a[off..off+len]` visible to the device. A no-op
/// for coherent memory.
pub fn flush(self: *DeviceMemory, a: Allocation, off: u64, len: u64) vk.Error!void {
    if (self.flagsOf(a.type_index).host_coherent) return;
    const range = self.mappedRange(a, off, len);
    _ = try vk.check(self.gpu.ddisp.flush_mapped_memory_ranges(self.gpu.dev, 1, @ptrCast(&range)));
}

/// Makes device writes to `a[off..off+len]` visible to the host. A no-op
/// for coherent memory.
pub fn invalidate(self: *DeviceMemory, a: Allocation, off: u64, len: u64) vk.Error!void {
    if (self.flagsOf(a.type_index).host_coherent) return;
    const range = self.mappedRange(a, off, len);
    _ = try vk.check(self.gpu.ddisp.invalidate_mapped_memory_ranges(self.gpu.dev, 1, @ptrCast(&range)));
}

fn mappedRange(self: *DeviceMemory, a: Allocation, off: u64, len: u64) vk.MappedMemoryRange {
    const mem_size = switch (a.kind) {
        .dedicated => a.size,
        .block => self.pools[a.type_index][@intFromBool(a.linear)].blocks.items[a.block].?.size,
    };
    const r = types.flushRange(a.offset + off, len, self.gpu.info.limits.non_coherent_atom, mem_size);
    return .{ .memory = a.memory, .offset = r.offset, .size = r.size };
}

/// Per-heap budgets, refreshed at most once per frame.
pub fn budget(self: *DeviceMemory) []const HeapBudget {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.budgetLocked();
}

fn budgetLocked(self: *DeviceMemory) []const HeapBudget {
    const n = self.props.memory_heap_count;
    if (self.budget_frame != self.frame) {
        self.budget_frame = self.frame;
        var mb: vk.PhysicalDeviceMemoryBudgetPropertiesEXT = .{};
        const ext = self.gpu.exts.contains(.ext_memory_budget);
        if (ext) {
            var p2: vk.PhysicalDeviceMemoryProperties2 = .{};
            vk.chain(&p2, &mb);
            self.gpu.instance.disp.get_physical_device_memory_properties2(self.gpu.pdev, &p2);
        }
        for (0..n) |h| {
            const size = self.props.memory_heaps[h].size;
            self.budgets[h] = .{
                .heap = @intCast(h),
                .budget = if (ext and mb.heap_budget[h] > 0) mb.heap_budget[h] else size / 10 * 8,
                .usage = if (ext and mb.heap_budget[h] > 0) mb.heap_usage[h] else self.heap_ours[h],
                .ours = self.heap_ours[h],
            };
        }
    }
    return self.budgets[0..n];
}

/// Block and allocation counts per memory type.
pub fn stats(self: *DeviceMemory) Stats {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var s = self.counters;
    for (&self.pools, 0..) |*per_type, t| for (per_type) |*pool| for (pool.blocks.items) |slot| {
        const b = slot orelse continue;
        const st = b.tlsf.stats();
        s.per_type[t].blocks += 1;
        s.per_type[t].block_bytes += b.size;
        s.per_type[t].used += st.used;
        s.per_type[t].allocations += st.live;
    };
    return s;
}

/// True if dedicated memory is required, false if preferred, null if neither.
fn dedicatedOf(ded: *const vk.MemoryDedicatedRequirements) ?bool {
    if (ded.requires_dedicated_allocation == .true) return true;
    if (ded.prefers_dedicated_allocation == .true) return false;
    return null;
}

/// Creates a buffer, allocates its memory and binds it.
pub fn createBuffer(self: *DeviceMemory, info: vk.BufferCreateInfo, usage: Usage, name: [:0]const u8) Error!Buffer {
    const dd = &self.gpu.ddisp;
    var h: vk.Buffer = .null_handle;
    _ = try vk.check(dd.create_buffer(self.gpu.dev, &info, null, &h));
    errdefer dd.destroy_buffer(self.gpu.dev, h, null);
    var ded: vk.MemoryDedicatedRequirements = .{};
    var r2: vk.MemoryRequirements2 = .{};
    vk.chain(&r2, &ded);
    dd.get_buffer_memory_requirements2(self.gpu.dev, &.{ .buffer = h }, &r2);
    const d: Dedicated = if (dedicatedOf(&ded)) |req| .{ .buffer = .{ .handle = h, .required = req } } else .no;
    const a = try self.allocFor(.{ .reqs = r2.memory_requirements, .dedicated = d }, usage, true, name);
    errdefer self.free(a);
    const bind = [_]vk.BindBufferMemoryInfo{.{ .buffer = h, .memory = a.memory, .memory_offset = a.offset }};
    _ = try vk.check(dd.bind_buffer_memory2(self.gpu.dev, 1, &bind));
    self.gpu.name(h, name);
    return .{ .handle = h, .alloc = a, .size = info.size };
}

pub fn destroyBuffer(self: *DeviceMemory, b: Buffer) void {
    self.gpu.ddisp.destroy_buffer(self.gpu.dev, b.handle, null);
    self.free(b.alloc);
}

/// Creates a 2D image, allocates its memory and binds it. With
/// `export_dmabuf` the memory is dedicated and exportable as a dmabuf.
pub fn createImage(self: *DeviceMemory, info: vk.ImageCreateInfo, usage: Usage, name: [:0]const u8, export_dmabuf: bool) Error!Image {
    const dd = &self.gpu.ddisp;
    var ci = info;
    var ext: vk.ExternalMemoryImageCreateInfo = .{ .handle_types = .{ .dma_buf_ext = true } };
    if (export_dmabuf) vk.chain(&ci, &ext);
    var h: vk.Image = .null_handle;
    _ = try vk.check(dd.create_image(self.gpu.dev, &ci, null, &h));
    errdefer dd.destroy_image(self.gpu.dev, h, null);
    var ded: vk.MemoryDedicatedRequirements = .{};
    var r2: vk.MemoryRequirements2 = .{};
    vk.chain(&r2, &ded);
    dd.get_image_memory_requirements2(self.gpu.dev, &.{ .image = h }, &r2);
    const required = dedicatedOf(&ded);
    const d: Dedicated = if (required != null or export_dmabuf) .{ .image = .{ .handle = h, .required = required orelse true } } else .no;
    const linear = info.tiling == .linear;
    const a = try self.allocFor(.{ .reqs = r2.memory_requirements, .dedicated = d, .export_dmabuf = export_dmabuf }, usage, linear, name);
    errdefer self.free(a);
    const bind = [_]vk.BindImageMemoryInfo{.{ .image = h, .memory = a.memory, .memory_offset = a.offset }};
    _ = try vk.check(dd.bind_image_memory2(self.gpu.dev, 1, &bind));
    self.gpu.name(h, name);
    return .{ .handle = h, .alloc = a, .extent = .{ .width = info.extent.width, .height = info.extent.height }, .format = info.format, .layout = info.initial_layout };
}

pub fn destroyImage(self: *DeviceMemory, img: Image) void {
    self.gpu.ddisp.destroy_image(self.gpu.dev, img.handle, null);
    self.free(img.alloc);
}
