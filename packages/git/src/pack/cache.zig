//! Delta-base cache: resolved objects keyed by (pack id, offset), so delta
//! chains that share bases do not re-inflate them. Sharded by key, each shard
//! behind an `std.Io.Mutex`, evicting with a CLOCK (second chance) hand.
//! Lookups copy the cached bytes out, so callers never hold borrowed data
//! that a concurrent eviction could free.

const std = @import("std");
const ObjectType = @import("../object.zig").ObjectType;
const Allocator = std.mem.Allocator;

const shard_count = 16;

/// Cache key: a pack and an entry offset inside it.
pub const Key = struct {
    /// `Pack.id` of the pack.
    pack: u32,
    /// Entry offset in the pack.
    offset: u64,
};

const Entry = struct {
    type: ObjectType,
    data: []u8,
    referenced: bool,
};

const Shard = struct {
    mutex: std.Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    ring: std.ArrayList(Key) = .empty,
    hand: usize = 0,
    bytes: usize = 0,
};

/// A cached object handed back by `get` (owned by the caller).
pub const Hit = struct {
    /// Object type.
    type: ObjectType,
    /// Copy of the cached data.
    data: []u8,
};

/// The delta-base cache. Safe for concurrent use.
pub const DeltaBaseCache = struct {
    gpa: Allocator,
    io: std.Io,
    shard_budget: usize,
    shards: [shard_count]Shard = @splat(.{}),

    /// Default size: 96 MiB.
    pub const default_max_bytes = 96 * 1024 * 1024;

    /// A cache holding at most about `max_bytes` of object data.
    pub fn init(gpa: Allocator, io: std.Io, max_bytes: usize) DeltaBaseCache {
        return .{ .gpa = gpa, .io = io, .shard_budget = max_bytes / shard_count };
    }

    /// Frees every entry.
    pub fn deinit(c: *DeltaBaseCache) void {
        for (&c.shards) |*s| {
            var it = s.map.valueIterator();
            while (it.next()) |e| c.gpa.free(e.data);
            s.map.deinit(c.gpa);
            s.ring.deinit(c.gpa);
        }
        c.* = undefined;
    }

    fn shardOf(c: *DeltaBaseCache, k: Key) *Shard {
        const h = std.hash.int(k.offset ^ (@as(u64, k.pack) << 48));
        return &c.shards[@intCast(h % shard_count)];
    }

    /// Copies a cached object into `gpa` memory, or returns null.
    pub fn get(c: *DeltaBaseCache, gpa: Allocator, k: Key) Allocator.Error!?Hit {
        const s = c.shardOf(k);
        s.mutex.lockUncancelable(c.io);
        defer s.mutex.unlock(c.io);
        const e = s.map.getPtr(k) orelse return null;
        e.referenced = true;
        return .{ .type = e.type, .data = try gpa.dupe(u8, e.data) };
    }

    /// Whether `k` is cached (does not mark it referenced).
    pub fn contains(c: *DeltaBaseCache, k: Key) bool {
        const s = c.shardOf(k);
        s.mutex.lockUncancelable(c.io);
        defer s.mutex.unlock(c.io);
        return s.map.contains(k);
    }

    /// Caches a copy of `data`. Objects larger than a shard's budget and
    /// allocation failures are silently skipped.
    pub fn put(c: *DeltaBaseCache, k: Key, t: ObjectType, data: []const u8) void {
        if (data.len > c.shard_budget) return;
        const s = c.shardOf(k);
        s.mutex.lockUncancelable(c.io);
        defer s.mutex.unlock(c.io);
        if (s.map.contains(k)) return;
        while (s.bytes + data.len > c.shard_budget and s.ring.items.len > 0) c.evictOne(s);
        const copy = c.gpa.dupe(u8, data) catch return;
        s.ring.append(c.gpa, k) catch {
            c.gpa.free(copy);
            return;
        };
        s.map.put(c.gpa, k, .{ .type = t, .data = copy, .referenced = false }) catch {
            _ = s.ring.pop();
            c.gpa.free(copy);
            return;
        };
        s.bytes += copy.len;
    }

    fn evictOne(c: *DeltaBaseCache, s: *Shard) void {
        while (true) {
            if (s.hand >= s.ring.items.len) s.hand = 0;
            const k = s.ring.items[s.hand];
            const e = s.map.getPtr(k).?;
            if (e.referenced) {
                e.referenced = false;
                s.hand += 1;
                continue;
            }
            s.bytes -= e.data.len;
            c.gpa.free(e.data);
            _ = s.map.remove(k);
            _ = s.ring.swapRemove(s.hand);
            return;
        }
    }

    /// Total bytes cached (approximate under concurrency).
    pub fn size(c: *DeltaBaseCache) usize {
        var n: usize = 0;
        for (&c.shards) |*s| n += @atomicLoad(usize, &s.bytes, .monotonic);
        return n;
    }
};

test "cache: put/get and eviction under budget" {
    const t = std.testing;
    var c: DeltaBaseCache = .init(t.allocator, t.io, shard_count * 100);
    defer c.deinit();
    c.put(.{ .pack = 1, .offset = 12 }, .blob, "hello");
    const hit = (try c.get(t.allocator, .{ .pack = 1, .offset = 12 })).?;
    defer t.allocator.free(hit.data);
    try t.expectEqualStrings("hello", hit.data);
    try t.expect((try c.get(t.allocator, .{ .pack = 2, .offset = 12 })) == null);
    // Too large for a shard: not cached.
    c.put(.{ .pack = 1, .offset = 99 }, .blob, &(@as([200]u8, @splat(0))));
    try t.expect(!c.contains(.{ .pack = 1, .offset = 99 }));
    // Fill well past the budget; total stays bounded.
    var i: u64 = 0;
    while (i < 1000) : (i += 1) c.put(.{ .pack = 3, .offset = i }, .blob, &(@as([40]u8, @splat(1))));
    try t.expect(c.size() <= shard_count * 100);
}
