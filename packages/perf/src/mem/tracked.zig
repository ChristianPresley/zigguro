//! `TrackedAllocator` (E14.F04.S01.T01): forwards to a child allocator and
//! charges what it hands out to a `MemTag`. `resize` and `remap` charge the
//! size change only when they succeed; `free` takes back the whole buffer.
//!
//! Wrap an arena's backing allocator, not the arena: arena growth is then
//! charged in chunks, which is the right granularity.

const std = @import("std");
const tags = @import("tags.zig");

const Alignment = std.mem.Alignment;
const MemTag = tags.MemTag;

pub const TrackedAllocator = struct {
    child: std.mem.Allocator,
    tag: MemTag,

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        tags.chargeAlloc(self.tag, len, true);
        return p;
    }

    fn charge(self: *TrackedAllocator, old: usize, new: usize) void {
        if (new > old) tags.chargeAlloc(self.tag, new - old, false) else tags.chargeFree(self.tag, old - new, false);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.charge(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.charge(memory.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        tags.chargeFree(self.tag, memory.len, true);
    }
};

var statics: [tags.max_tags]TrackedAllocator = undefined;
var statics_set: [tags.max_tags]std.atomic.Value(bool) = @splat(.init(false));

/// An allocator charging `tag`, backed by one static `TrackedAllocator` per
/// tag. The first call for a tag fixes its child (normally the process
/// gpa); use `trackedWith` for any other child.
pub fn tracked(tag: MemTag, child: std.mem.Allocator) std.mem.Allocator {
    const i = @intFromEnum(tag);
    if (!statics_set[i].load(.acquire)) {
        statics[i] = .{ .child = child, .tag = tag };
        statics_set[i].store(true, .release);
    } else std.debug.assert(statics[i].child.ptr == child.ptr and statics[i].child.vtable == child.vtable);
    return statics[i].allocator();
}

/// An allocator charging `tag` with caller-owned storage (arenas' backing
/// allocators, tests).
pub fn trackedWith(storage: *TrackedAllocator, tag: MemTag, child: std.mem.Allocator) std.mem.Allocator {
    storage.* = .{ .child = child, .tag = tag };
    return storage.allocator();
}

test "tracked: counts alloc/free/resize/remap" {
    var st: TrackedAllocator = undefined;
    const a = trackedWith(&st, .notes, std.testing.allocator);
    const before = tags.tagStats(.notes);
    const buf = try a.alloc(u8, 100);
    try std.testing.expectEqual(before.live + 100, tags.tagStats(.notes).live);
    const grown = try a.realloc(buf, 300);
    try std.testing.expectEqual(before.live + 300, tags.tagStats(.notes).live);
    if (a.resize(grown, 50)) {
        try std.testing.expectEqual(before.live + 50, tags.tagStats(.notes).live);
        const shrunk: []u8 = grown[0..50];
        a.free(shrunk);
    } else a.free(grown);
    const after = tags.tagStats(.notes);
    try std.testing.expectEqual(before.live, after.live);
    // realloc may move (a new allocation plus a free) when remap fails.
    try std.testing.expect(after.allocs > before.allocs);
    try std.testing.expectEqual(after.allocs - before.allocs, after.frees - before.frees);
}

test "tracked: peak tracks maximum" {
    var st: TrackedAllocator = undefined;
    const a = trackedWith(&st, .mcp, std.testing.allocator);
    const base = tags.tagStats(.mcp);
    const x = try a.alloc(u8, 1 << 20);
    const y = try a.alloc(u8, 1 << 19);
    a.free(x);
    a.free(y);
    const s = tags.tagStats(.mcp);
    try std.testing.expect(s.peak >= @as(u64, @intCast(base.live)) + (1 << 20) + (1 << 19));
    try std.testing.expectEqual(base.live, s.live);
}

test "tracked: std.heap.testAllocator passes on tracked(page_allocator)" {
    const a = tracked(.perf, std.heap.page_allocator);
    const before = tags.tagStats(.perf).live;
    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
    try std.testing.expectEqual(before, tags.tagStats(.perf).live);
}

test "tracked: 8 threads x 1 M alloc/free sums to zero" {
    var st: TrackedAllocator = undefined;
    const a = trackedWith(&st, .review, std.heap.smp_allocator);
    const before = tags.tagStats(.review);
    const n = if (@import("builtin").mode == .Debug) 50_000 else 1_000_000;
    const Worker = struct {
        fn run(al: std.mem.Allocator) void {
            for (0..n) |i| {
                const b = al.alloc(u8, 16 + (i & 63)) catch return;
                al.free(b);
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{a});
    for (threads) |t| t.join();
    const s = tags.tagStats(.review);
    try std.testing.expectEqual(before.live, s.live);
    try std.testing.expectEqual(before.allocs + 8 * n, s.allocs);
    try std.testing.expectEqual(before.frees + 8 * n, s.frees);
}
