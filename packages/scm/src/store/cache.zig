//! Decode cache: decompressed objects keyed by ID, so repeated reads of a
//! deflated record do not inflate it again. Sharded, each shard behind an
//! `std.Io.Mutex`, evicting with a CLOCK (second chance) hand.
//!
//! Entries are reference counted. The cache holds one reference while an
//! entry is cached, and every `get`/`put` hands one to the caller, so an
//! entry evicted while a reader still uses it is freed on that reader's
//! `release` instead.

const std = @import("std");
const id_mod = @import("id.zig");
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Allocator = std.mem.Allocator;

const shard_count = 16;

/// A cached object. Read `kind` and `data` while holding a reference.
pub const Entry = struct {
    id: ObjectId,
    kind: Kind,
    data: []u8,
    refs: std.atomic.Value(u32),
    referenced: bool = true,
    gpa: Allocator,

    /// Drops one reference; frees the entry with the last one.
    pub fn release(e: *Entry) void {
        if (e.refs.fetchSub(1, .acq_rel) == 1) {
            e.gpa.free(e.data);
            e.gpa.destroy(e);
        }
    }

    fn retain(e: *Entry) void {
        _ = e.refs.fetchAdd(1, .monotonic);
    }
};

const Shard = struct {
    mutex: std.Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(ObjectId, *Entry) = .empty,
    ring: std.ArrayList(*Entry) = .empty,
    hand: usize = 0,
    bytes: usize = 0,
};

/// The decode cache. Safe for concurrent use.
pub const Cache = struct {
    gpa: Allocator,
    io: std.Io,
    shard_budget: usize,
    shards: [shard_count]Shard = @splat(.{}),

    /// A cache holding at most about `max_bytes` of object data.
    pub fn init(gpa: Allocator, io: std.Io, max_bytes: usize) Cache {
        return .{ .gpa = gpa, .io = io, .shard_budget = max_bytes / shard_count };
    }

    /// Drops the cache's references (entries still in use survive until
    /// released).
    pub fn deinit(c: *Cache) void {
        for (&c.shards) |*s| {
            for (s.ring.items) |e| e.release();
            s.map.deinit(c.gpa);
            s.ring.deinit(c.gpa);
        }
        c.* = undefined;
    }

    fn shardOf(c: *Cache, id: ObjectId) *Shard {
        return &c.shards[id.bytes[31] % shard_count];
    }

    /// The cached entry for `id` with a reference for the caller, or null.
    pub fn get(c: *Cache, id: ObjectId) ?*Entry {
        const s = c.shardOf(id);
        s.mutex.lockUncancelable(c.io);
        defer s.mutex.unlock(c.io);
        const e = s.map.get(id) orelse return null;
        e.referenced = true;
        e.retain();
        return e;
    }

    /// Caches `data` (taking ownership; it must come from the cache's
    /// allocator) and returns the entry with a reference for the caller.
    /// When `id` is already cached, frees `data` and returns that entry.
    /// Objects larger than a shard's budget are returned uncached.
    pub fn put(c: *Cache, id: ObjectId, kind: Kind, data: []u8) Allocator.Error!*Entry {
        const e = c.gpa.create(Entry) catch |err| {
            c.gpa.free(data);
            return err;
        };
        e.* = .{ .id = id, .kind = kind, .data = data, .refs = .init(1), .gpa = c.gpa };
        if (data.len > c.shard_budget) return e;
        const s = c.shardOf(id);
        s.mutex.lockUncancelable(c.io);
        defer s.mutex.unlock(c.io);
        const gop = s.map.getOrPut(c.gpa, id) catch return e;
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            old.retain();
            e.release();
            return old;
        }
        s.ring.append(c.gpa, e) catch {
            _ = s.map.remove(id);
            return e;
        };
        gop.value_ptr.* = e;
        e.retain();
        s.bytes += data.len;
        c.evict(s);
        return e;
    }

    /// CLOCK eviction until the shard fits its budget.
    fn evict(c: *Cache, s: *Shard) void {
        var spins: usize = 0;
        while (s.ring.items.len > 1 and s.bytes > c.shard_budget) : (spins += 1) {
            if (s.hand >= s.ring.items.len) s.hand = 0;
            const e = s.ring.items[s.hand];
            if (e.referenced and spins < 2 * s.ring.items.len) {
                e.referenced = false;
                s.hand += 1;
                continue;
            }
            _ = s.map.remove(e.id);
            _ = s.ring.swapRemove(s.hand);
            s.bytes -= e.data.len;
            e.release();
        }
    }

    /// Bytes currently cached.
    pub fn size(c: *Cache) usize {
        var n: usize = 0;
        for (&c.shards) |*s| {
            s.mutex.lockUncancelable(c.io);
            n += s.bytes;
            s.mutex.unlock(c.io);
        }
        return n;
    }
};

test "cache: get/put, eviction and outstanding references" {
    const t = std.testing;
    var c: Cache = .init(t.allocator, t.io, 16 * 100);
    defer c.deinit();
    const a = id_mod.hashObject(.blob, "a");
    const ea = try c.put(a, .blob, try t.allocator.dupe(u8, "x" ** 60));
    // A duplicate put returns the cached entry and frees the new data.
    const dup = try c.put(a, .blob, try t.allocator.dupe(u8, "y" ** 60));
    try t.expectEqual(ea, dup);
    dup.release();
    const g = c.get(a).?;
    try t.expectEqualStrings("x" ** 60, g.data);
    g.release();
    // Same shard (last byte), pushes `a` out while the caller still holds it.
    var i: u32 = 0;
    var evicted = false;
    while (i < 1000 and !evicted) : (i += 1) {
        const id = id_mod.hashObject(.blob, std.mem.asBytes(&i));
        if (id.bytes[31] % shard_count != a.bytes[31] % shard_count) continue;
        const e = try c.put(id, .blob, try t.allocator.dupe(u8, "z" ** 60));
        e.release();
        evicted = c.get(a) == null;
    }
    try t.expect(evicted);
    try t.expectEqualStrings("x" ** 60, ea.data);
    ea.release();
    try t.expect(c.size() <= 100);
    // Oversized objects come back uncached.
    const big = try c.put(id_mod.hashObject(.blob, "big"), .blob, try t.allocator.alloc(u8, 500));
    big.release();
    try t.expect(c.get(id_mod.hashObject(.blob, "big")) == null);
}
