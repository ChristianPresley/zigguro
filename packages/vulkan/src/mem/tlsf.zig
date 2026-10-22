//! A two-level segregated fit (TLSF) suballocator for GPU memory blocks
//! (Masmano et al. 2008). Metadata lives out of band in a node pool because
//! device memory is not host-visible. Every operation is O(1): two bitmap
//! scans and a constant number of list updates.
//!
//! All offsets and sizes are multiples of `min_block`, so any alignment up
//! to `min_block` is free; larger power-of-two alignments (≤ 64 KiB)
//! over-allocate and split off a leading block.

const std = @import("std");

const nil = std.math.maxInt(u32);
const fl_count = 64;

/// Tuning.
pub const Options = struct {
    /// Smallest block and allocation granule (a power of two ≥ 2^sl_log2).
    min_block: u32 = 256,
    /// log2 of the second-level lists per first-level class (≤ 5).
    sl_log2: u3 = 5,
};

/// An allocation.
pub const Range = struct {
    /// Byte offset in the block.
    offset: u64,
    /// Size in bytes (the request rounded up to `min_block`).
    size: u64,
    /// Pass to `free`.
    handle: u32,
};

/// Occupancy figures.
pub const Stats = struct {
    /// Bytes in live allocations.
    used: u64,
    /// Bytes free.
    free: u64,
    /// The largest free range.
    largest_free: u64,
    /// Number of free ranges.
    free_ranges: u32,
    /// Number of live allocations.
    live: u32,
};

const Node = struct {
    offset: u64,
    size: u64,
    prev_phys: u32 = nil,
    next_phys: u32 = nil,
    prev_free: u32 = nil,
    next_free: u32 = nil,
    is_free: bool = false,
    in_use: bool = true, // false = node slot recycled
};

/// The allocator for one memory block of `size` bytes.
pub const Tlsf = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    size: u64,
    nodes: std.ArrayList(Node) = .empty,
    spare: std.ArrayList(u32) = .empty,
    fl_bitmap: u64 = 0,
    sl_bitmap: [fl_count]u32 = @splat(0),
    heads: [fl_count][32]u32 = @splat(@splat(nil)),
    used: u64 = 0,
    live: u32 = 0,

    /// An allocator managing `size` bytes (rounded down to `min_block`).
    pub fn init(gpa: std.mem.Allocator, size: u64, opts: Options) error{OutOfMemory}!Tlsf {
        std.debug.assert(std.math.isPowerOfTwo(opts.min_block));
        std.debug.assert(opts.sl_log2 <= 5 and opts.min_block >= (@as(u32, 1) << opts.sl_log2));
        var t: Tlsf = .{ .gpa = gpa, .opts = opts, .size = size - size % opts.min_block };
        if (t.size > 0) {
            const n = try t.newNode(.{ .offset = 0, .size = t.size });
            t.insertFree(n);
        }
        return t;
    }

    /// Frees the metadata.
    pub fn deinit(self: *Tlsf) void {
        self.nodes.deinit(self.gpa);
        self.spare.deinit(self.gpa);
        self.* = undefined;
    }

    /// Allocates `size` bytes aligned to `alignment` (a power of two up to
    /// 64 KiB). Returns null when this block has no suitable free range;
    /// `error.OutOfMemory` only when the node pool cannot grow.
    pub fn alloc(self: *Tlsf, size: u64, alignment: u64) error{OutOfMemory}!?Range {
        std.debug.assert(std.math.isPowerOfTwo(alignment) and alignment <= 65536);
        if (size == 0 or size > self.size) return null;
        // Two spare nodes cover both splits, so nothing fails half-way.
        try self.nodes.ensureUnusedCapacity(self.gpa, 2);
        const mb = self.opts.min_block;
        const need = std.mem.alignForward(u64, size, mb);
        const pad = if (alignment > mb) alignment - mb else 0;
        const search = need + pad;
        if (search > self.size) return null;
        const n = self.findFree(search) orelse return null;
        self.removeFree(n);
        // Leading padding for alignment.
        const off = self.nodes.items[n].offset;
        const aligned = std.mem.alignForward(u64, off, alignment);
        var cur = n;
        if (aligned != off) cur = self.splitFront(n, aligned - off);
        // Tail.
        if (self.nodes.items[cur].size - need >= mb) self.splitBack(cur, need);
        const node = &self.nodes.items[cur];
        node.is_free = false;
        self.used += node.size;
        self.live += 1;
        return .{ .offset = node.offset, .size = node.size, .handle = cur };
    }

    /// Frees the allocation `handle`.
    pub fn free(self: *Tlsf, handle: u32) void {
        var n = handle;
        const node = &self.nodes.items[n];
        std.debug.assert(node.in_use and !node.is_free);
        self.used -= node.size;
        self.live -= 1;
        node.is_free = true;
        const prev = node.prev_phys;
        if (prev != nil and self.nodes.items[prev].is_free) {
            self.removeFree(prev);
            self.merge(prev, n);
            n = prev;
        }
        const next = self.nodes.items[n].next_phys;
        if (next != nil and self.nodes.items[next].is_free) {
            self.removeFree(next);
            self.merge(n, next);
        }
        self.insertFree(n);
    }

    /// Whether nothing is allocated.
    pub fn isEmpty(self: *const Tlsf) bool {
        return self.live == 0;
    }

    /// Occupancy (walks the nodes; for diagnostics).
    pub fn stats(self: *const Tlsf) Stats {
        var s: Stats = .{ .used = self.used, .free = 0, .largest_free = 0, .free_ranges = 0, .live = self.live };
        for (self.nodes.items) |n| if (n.in_use and n.is_free) {
            s.free += n.size;
            s.largest_free = @max(s.largest_free, n.size);
            s.free_ranges += 1;
        };
        return s;
    }

    /// Checks every invariant; panics on corruption. Tests only.
    pub fn validate(self: *const Tlsf) void {
        // Physical list: contiguous from 0 to size, no two free neighbours.
        var first: u32 = nil;
        var live: u32 = 0;
        var free_count: u32 = 0;
        for (self.nodes.items, 0..) |n, i| if (n.in_use and n.prev_phys == nil) {
            std.debug.assert(first == nil);
            first = @intCast(i);
        };
        var off: u64 = 0;
        var cur = first;
        var prev_free = false;
        while (cur != nil) {
            const n = self.nodes.items[cur];
            std.debug.assert(n.offset == off and n.size > 0 and n.size % self.opts.min_block == 0);
            std.debug.assert(!(prev_free and n.is_free));
            prev_free = n.is_free;
            if (n.is_free) free_count += 1 else live += 1;
            off += n.size;
            if (n.next_phys != nil) std.debug.assert(self.nodes.items[n.next_phys].prev_phys == cur);
            cur = n.next_phys;
        }
        std.debug.assert(off == self.size);
        std.debug.assert(live == self.live);
        // Free lists match the bitmaps and the mapping.
        var listed: u32 = 0;
        for (0..fl_count) |fl| {
            std.debug.assert(((self.fl_bitmap >> @intCast(fl)) & 1 == 1) == (self.sl_bitmap[fl] != 0));
            for (0..32) |sl| {
                const head = self.heads[fl][sl];
                std.debug.assert(((self.sl_bitmap[fl] >> @intCast(sl)) & 1 == 1) == (head != nil));
                var f = head;
                var p: u32 = nil;
                while (f != nil) {
                    const n = self.nodes.items[f];
                    std.debug.assert(n.is_free and n.prev_free == p);
                    const m = self.mapping(n.size);
                    std.debug.assert(m.fl == fl and m.sl == sl);
                    listed += 1;
                    p = f;
                    f = n.next_free;
                }
            }
        }
        std.debug.assert(listed == free_count);
    }

    const Map = struct { fl: u32, sl: u32 };

    fn mapping(self: *const Tlsf, size: u64) Map {
        const fl: u32 = 63 - @as(u32, @clz(size));
        const sh: u6 = @intCast(fl - self.opts.sl_log2);
        const sl: u32 = @intCast((size >> sh) ^ (@as(u64, 1) << self.opts.sl_log2));
        return .{ .fl = fl, .sl = sl };
    }

    fn findFree(self: *const Tlsf, size: u64) ?u32 {
        // Round up to the next list so any block in it fits.
        const fl0: u32 = 63 - @as(u32, @clz(size));
        const round = (@as(u64, 1) << @intCast(fl0 - self.opts.sl_log2)) - 1;
        const r = size +| round;
        var m = self.mapping(r);
        if (m.fl >= fl_count) return null;
        var sl_map = self.sl_bitmap[m.fl] & (@as(u32, std.math.maxInt(u32)) << @intCast(m.sl));
        if (sl_map == 0) {
            if (m.fl + 1 >= fl_count) return null;
            const fl_map = self.fl_bitmap & (@as(u64, std.math.maxInt(u64)) << @intCast(m.fl + 1));
            if (fl_map == 0) return null;
            m.fl = @ctz(fl_map);
            sl_map = self.sl_bitmap[m.fl];
        }
        m.sl = @ctz(sl_map);
        return self.heads[m.fl][m.sl];
    }

    fn newNode(self: *Tlsf, n: Node) error{OutOfMemory}!u32 {
        if (self.spare.pop()) |i| {
            self.nodes.items[i] = n;
            return i;
        }
        try self.nodes.append(self.gpa, n);
        return @intCast(self.nodes.items.len - 1);
    }

    fn newNodeAssumeCapacity(self: *Tlsf, n: Node) u32 {
        if (self.spare.pop()) |i| {
            self.nodes.items[i] = n;
            return i;
        }
        self.nodes.appendAssumeCapacity(n);
        return @intCast(self.nodes.items.len - 1);
    }

    fn insertFree(self: *Tlsf, n: u32) void {
        const node = &self.nodes.items[n];
        node.is_free = true;
        const m = self.mapping(node.size);
        const head = self.heads[m.fl][m.sl];
        node.prev_free = nil;
        node.next_free = head;
        if (head != nil) self.nodes.items[head].prev_free = n;
        self.heads[m.fl][m.sl] = n;
        self.fl_bitmap |= @as(u64, 1) << @intCast(m.fl);
        self.sl_bitmap[m.fl] |= @as(u32, 1) << @intCast(m.sl);
    }

    fn removeFree(self: *Tlsf, n: u32) void {
        const node = &self.nodes.items[n];
        const m = self.mapping(node.size);
        if (node.prev_free != nil) self.nodes.items[node.prev_free].next_free = node.next_free else self.heads[m.fl][m.sl] = node.next_free;
        if (node.next_free != nil) self.nodes.items[node.next_free].prev_free = node.prev_free;
        node.prev_free = nil;
        node.next_free = nil;
        if (self.heads[m.fl][m.sl] == nil) {
            self.sl_bitmap[m.fl] &= ~(@as(u32, 1) << @intCast(m.sl));
            if (self.sl_bitmap[m.fl] == 0) self.fl_bitmap &= ~(@as(u64, 1) << @intCast(m.fl));
        }
    }

    /// Splits `lead` bytes off the front of free (unlisted) node `n` into a
    /// new free listed node; returns `n`, which now starts after it.
    fn splitFront(self: *Tlsf, n: u32, lead: u64) u32 {
        const node = self.nodes.items[n];
        const f = self.newNodeAssumeCapacity(.{ .offset = node.offset, .size = lead, .prev_phys = node.prev_phys, .next_phys = n });
        if (node.prev_phys != nil) self.nodes.items[node.prev_phys].next_phys = f;
        const cur = &self.nodes.items[n];
        cur.prev_phys = f;
        cur.offset += lead;
        cur.size -= lead;
        self.insertFree(f);
        return n;
    }

    /// Keeps the first `keep` bytes of node `n` and lists the rest as free.
    fn splitBack(self: *Tlsf, n: u32, keep: u64) void {
        const node = self.nodes.items[n];
        const t = self.newNodeAssumeCapacity(.{ .offset = node.offset + keep, .size = node.size - keep, .prev_phys = n, .next_phys = node.next_phys });
        if (node.next_phys != nil) self.nodes.items[node.next_phys].prev_phys = t;
        const cur = &self.nodes.items[n];
        cur.next_phys = t;
        cur.size = keep;
        self.insertFree(t);
    }

    /// Appends physical successor `b` to `a` and recycles `b`.
    fn merge(self: *Tlsf, a: u32, b: u32) void {
        const nb = self.nodes.items[b];
        const na = &self.nodes.items[a];
        na.size += nb.size;
        na.next_phys = nb.next_phys;
        if (nb.next_phys != nil) self.nodes.items[nb.next_phys].prev_phys = a;
        self.nodes.items[b].in_use = false;
        self.nodes.items[b].is_free = false;
        self.spare.append(self.gpa, b) catch {
            // The slot leaks until deinit; harmless.
        };
    }
};

const testing = std.testing;

test "tlsf: single alloc free" {
    var t = try Tlsf.init(testing.allocator, 1 << 20, .{});
    defer t.deinit();
    const r = (try t.alloc(1000, 1)).?;
    try testing.expectEqual(@as(u64, 0), r.offset);
    try testing.expectEqual(@as(u64, 1024), r.size);
    t.validate();
    try testing.expect(!t.isEmpty());
    t.free(r.handle);
    t.validate();
    try testing.expect(t.isEmpty());
    const s = t.stats();
    try testing.expectEqual(@as(u64, 1 << 20), s.largest_free);
    try testing.expectEqual(@as(u32, 1), s.free_ranges);
}

test "tlsf: alignment honoured 1..65536" {
    var t = try Tlsf.init(testing.allocator, 8 << 20, .{});
    defer t.deinit();
    _ = (try t.alloc(300, 1)).?; // misalign what follows
    var a: u64 = 1;
    while (a <= 65536) : (a *= 2) {
        const r = (try t.alloc(777, a)).?;
        try testing.expectEqual(@as(u64, 0), r.offset % a);
        try testing.expect(r.size >= 777);
        t.validate();
    }
}

test "tlsf: coalescing restores one range" {
    var t = try Tlsf.init(testing.allocator, 1 << 20, .{});
    defer t.deinit();
    var hs: [64]u32 = undefined;
    for (&hs) |*h| h.* = (try t.alloc(4096, 256)).?.handle;
    // Free odd, then even ones.
    var i: usize = 1;
    while (i < hs.len) : (i += 2) t.free(hs[i]);
    t.validate();
    i = 0;
    while (i < hs.len) : (i += 2) t.free(hs[i]);
    t.validate();
    const s = t.stats();
    try testing.expectEqual(@as(u32, 1), s.free_ranges);
    try testing.expectEqual(@as(u64, 1 << 20), s.free);
}

test "tlsf: exhaustion returns null" {
    var t = try Tlsf.init(testing.allocator, 64 * 1024, .{});
    defer t.deinit();
    var n: u32 = 0;
    while (try t.alloc(1024, 1)) |_| n += 1;
    try testing.expectEqual(@as(u32, 64), n);
    try testing.expectEqual(@as(?Range, null), try t.alloc(1, 1));
    try testing.expectEqual(@as(?Range, null), try t.alloc(1 << 30, 1));
    t.validate();
}

fn randomOps(t: *Tlsf, rnd: std.Random, ops: u32) !void {
    const Live = struct { off: u64, size: u64, h: u32 };
    var live: std.ArrayList(Live) = .empty;
    defer live.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < ops) : (i += 1) {
        if (live.items.len > 0 and (rnd.boolean() or live.items.len > 200)) {
            const k = rnd.uintLessThan(usize, live.items.len);
            t.free(live.items[k].h);
            _ = live.swapRemove(k);
        } else {
            const size = 1 + rnd.uintLessThan(u64, if (rnd.boolean()) 4096 else 200_000);
            const al = @as(u64, 1) << rnd.uintLessThan(u6, 17);
            if (try t.alloc(size, al)) |r| {
                try testing.expect(r.offset % al == 0 and r.size >= size and r.offset + r.size <= t.size);
                // Reference model: no overlap with any live range.
                for (live.items) |l| try testing.expect(r.offset + r.size <= l.off or l.off + l.size <= r.offset);
                try live.append(testing.allocator, .{ .off = r.offset, .size = r.size, .h = r.handle });
            }
        }
        if (i % 64 == 0) t.validate();
    }
    for (live.items) |l| t.free(l.h);
    t.validate();
    try testing.expect(t.isEmpty());
    try testing.expectEqual(@as(u32, 1), t.stats().free_ranges);
}

test "tlsf: randomized vs reference model" {
    var t = try Tlsf.init(testing.allocator, 32 << 20, .{});
    defer t.deinit();
    var prng = std.Random.DefaultPrng.init(99);
    try randomOps(&t, prng.random(), 20_000);
}

test "fuzz: tlsf ops" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var t = try Tlsf.init(testing.allocator, 1 << 20, .{});
            defer t.deinit();
            var live: [64]u32 = undefined;
            var n: usize = 0;
            var i: usize = 0;
            while (i + 2 < input.len) : (i += 3) {
                if (input[i] & 1 == 1 and n > 0) {
                    const k = input[i + 1] % n;
                    t.free(live[k]);
                    live[k] = live[n - 1];
                    n -= 1;
                } else if (n < live.len) {
                    const size = (@as(u64, input[i + 1]) << 8 | input[i + 2]) * 7 + 1;
                    const al = @as(u64, 1) << @intCast(input[i] >> 4);
                    if (try t.alloc(size, al)) |r| {
                        live[n] = r.handle;
                        n += 1;
                    }
                }
                t.validate();
            }
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "tlsf") });
}
