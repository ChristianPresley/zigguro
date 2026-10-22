//! Measured-width cache: `XxHash3(text) ^ style hash` to a width in px.
//! A fixed table of 16k slots probed in groups of eight; a full group
//! evicts by CLOCK (second chance on the reference bit). Lookups and
//! inserts never allocate.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Number of slots.
pub const capacity = 16 * 1024;
const group = 8;

const Slot = struct {
    /// 0 is empty.
    key: u64 = 0,
    len: u32 = 0,
    width: f32 = 0,
    referenced: bool = false,
};

/// The cache.
pub const WidthCache = struct {
    gpa: Allocator,
    slots: []Slot,
    hits: u64 = 0,
    misses: u64 = 0,

    /// An empty cache.
    pub fn init(gpa: Allocator) Allocator.Error!WidthCache {
        const slots = try gpa.alloc(Slot, capacity);
        @memset(slots, .{});
        return .{ .gpa = gpa, .slots = slots };
    }

    /// Frees the table.
    pub fn deinit(c: *WidthCache) void {
        c.gpa.free(c.slots);
        c.* = undefined;
    }

    /// Drops every entry (fonts changed).
    pub fn clear(c: *WidthCache) void {
        @memset(c.slots, .{});
    }

    /// The key of `text` in a style with hash `style_hash`.
    pub fn key(text: []const u8, style_hash: u64) u64 {
        const k = std.hash.XxHash3.hash(0, text) ^ style_hash;
        return if (k == 0) 1 else k;
    }

    /// The cached width, if any.
    pub fn get(c: *WidthCache, k: u64, len: u32) ?f32 {
        const base = groupOf(k);
        for (c.slots[base..][0..group]) |*s| if (s.key == k and s.len == len) {
            s.referenced = true;
            c.hits += 1;
            return s.width;
        };
        c.misses += 1;
        return null;
    }

    /// Stores a width, evicting within the key's group when it is full.
    pub fn put(c: *WidthCache, k: u64, len: u32, width: f32) void {
        const slots = c.slots[groupOf(k)..][0..group];
        for (slots) |*s| if (s.key == 0 or (s.key == k and s.len == len)) {
            s.* = .{ .key = k, .len = len, .width = width };
            return;
        };
        // CLOCK over the group, starting at a key-derived hand.
        var hand: usize = @intCast((k >> 32) % group);
        while (true) : (hand = (hand + 1) % group) {
            const s = &slots[hand];
            if (s.referenced) {
                s.referenced = false;
                continue;
            }
            s.* = .{ .key = k, .len = len, .width = width };
            return;
        }
    }

    fn groupOf(k: u64) usize {
        return @intCast((k % (capacity / group)) * group);
    }
};

test "width cache: hit, miss and eviction" {
    var c = try WidthCache.init(std.testing.allocator);
    defer c.deinit();
    const k = WidthCache.key("hello", 42);
    try std.testing.expect(c.get(k, 5) == null);
    c.put(k, 5, 31.5);
    try std.testing.expectEqual(@as(?f32, 31.5), c.get(k, 5));
    try std.testing.expect(c.get(k, 6) == null);
    // Fill one group past capacity: the referenced entry survives.
    const g = (k % (capacity / group));
    var n: u64 = 0;
    var added: usize = 0;
    while (added < group * 2) : (n += 1) {
        const other = g + n * (capacity / group) + capacity / group;
        if (other == k) continue;
        _ = c.get(k, 5);
        c.put(other, 1, 1);
        added += 1;
    }
    try std.testing.expectEqual(@as(?f32, 31.5), c.get(k, 5));
}
