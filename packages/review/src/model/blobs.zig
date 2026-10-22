//! Content-addressed blobs (base texts, created files, checkpoint
//! preimages): the `Blobs` port the queue writes through, and an
//! in-memory implementation for tests and for a store-less queue. The
//! durable store (E12.F01.S02.T01) implements the same port on disk.

const std = @import("std");
const ids = @import("ids.zig");

const Allocator = std.mem.Allocator;
const BlobHash = ids.BlobHash;

pub const Blobs = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Stores `bytes` (idempotent) and returns their hash.
        put: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!BlobHash,
        /// The bytes of `hash`, allocated in `arena`; null when unknown.
        get: *const fn (ctx: *anyopaque, arena: Allocator, hash: BlobHash) anyerror!?[]const u8,
    };

    pub fn put(b: Blobs, bytes: []const u8) anyerror!BlobHash {
        return b.vtable.put(b.ctx, bytes);
    }
    pub fn get(b: Blobs, arena: Allocator, hash: BlobHash) anyerror!?[]const u8 {
        return b.vtable.get(b.ctx, arena, hash);
    }
};

/// Blobs in memory. Not thread-safe: owner thread only.
pub const MemBlobs = struct {
    gpa: Allocator,
    map: std.AutoHashMapUnmanaged(BlobHash, []u8) = .empty,

    pub fn init(gpa: Allocator) MemBlobs {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *MemBlobs) void {
        var it = m.map.valueIterator();
        while (it.next()) |v| m.gpa.free(v.*);
        m.map.deinit(m.gpa);
    }

    pub fn blobs(m: *MemBlobs) Blobs {
        return .{ .ctx = m, .vtable = &.{ .put = put, .get = get } };
    }

    pub fn count(m: *const MemBlobs) usize {
        return m.map.count();
    }

    fn put(ctx: *anyopaque, bytes: []const u8) anyerror!BlobHash {
        const m: *MemBlobs = @ptrCast(@alignCast(ctx));
        const h = ids.blobHash(bytes);
        const gop = try m.map.getOrPut(m.gpa, h);
        if (!gop.found_existing) {
            gop.value_ptr.* = m.gpa.dupe(u8, bytes) catch |e| {
                _ = m.map.remove(h);
                return e;
            };
        }
        return h;
    }

    fn get(ctx: *anyopaque, arena: Allocator, hash: BlobHash) anyerror!?[]const u8 {
        const m: *MemBlobs = @ptrCast(@alignCast(ctx));
        const v = m.map.get(hash) orelse return null;
        return try arena.dupe(u8, v);
    }
};

test "blobs: memory store is content addressed" {
    var m: MemBlobs = .init(std.testing.allocator);
    defer m.deinit();
    const b = m.blobs();
    const h1 = try b.put("hello");
    const h2 = try b.put("hello");
    try std.testing.expectEqual(h1, h2);
    try std.testing.expectEqual(@as(usize, 1), m.count());
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("hello", (try b.get(arena.allocator(), h1)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try b.get(arena.allocator(), ids.blobHash("nope")));
}
