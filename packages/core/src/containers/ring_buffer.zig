//! Fixed-capacity rings: `RingBuffer` (single-threaded) and `SpscRing`
//! (lock-free single-producer/single-consumer). Both have a power-of-two
//! capacity and reject pushes when full.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A fixed-capacity FIFO ring of `T`. Not thread-safe. `push` rejects when
/// full; `pushOverwrite` drops the oldest element instead.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        buf: []T,
        head: usize = 0, // index of the oldest element (monotonic, masked on use)
        tail: usize = 0, // one past the newest element (monotonic)

        /// Allocates a ring with capacity `capacity`, which must be a power of two.
        pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!Self {
            std.debug.assert(std.math.isPowerOfTwo(capacity));
            return .{ .buf = try gpa.alloc(T, capacity) };
        }

        /// Frees the storage.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.buf);
            self.* = undefined;
        }

        /// Number of stored elements.
        pub fn len(self: *const Self) usize {
            return self.tail - self.head;
        }

        /// True when no further `push` can succeed.
        pub fn isFull(self: *const Self) bool {
            return self.len() == self.buf.len;
        }

        /// Appends `v`; returns false (and stores nothing) when full.
        pub fn push(self: *Self, v: T) bool {
            if (self.isFull()) return false;
            self.buf[self.tail & (self.buf.len - 1)] = v;
            self.tail += 1;
            return true;
        }

        /// Appends `v`, dropping the oldest element when full.
        pub fn pushOverwrite(self: *Self, v: T) void {
            if (self.isFull()) self.head += 1;
            self.buf[self.tail & (self.buf.len - 1)] = v;
            self.tail += 1;
        }

        /// Removes and returns the oldest element.
        pub fn pop(self: *Self) ?T {
            if (self.head == self.tail) return null;
            const v = self.buf[self.head & (self.buf.len - 1)];
            self.head += 1;
            return v;
        }

        /// The `i`-th oldest element without removing it.
        pub fn peek(self: *const Self, i: usize) ?T {
            if (i >= self.len()) return null;
            return self.buf[(self.head + i) & (self.buf.len - 1)];
        }
    };
}

/// A lock-free single-producer/single-consumer ring with inline storage.
/// Exactly one thread may call `push` and exactly one (possibly other) thread
/// may call `pop`. Head and tail live on separate cache lines.
pub fn SpscRing(comptime T: type, comptime capacity: u32) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        /// Consumer position.
        head: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
        /// Producer position.
        tail: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
        buf: [capacity]T align(std.atomic.cache_line) = undefined,

        /// An empty ring.
        pub const empty: Self = .{};

        /// Producer: appends `v`; returns false when full.
        pub fn push(self: *Self, v: T) bool {
            const t = self.tail.raw; // only the producer writes tail
            const h = self.head.load(.acquire);
            if (t -% h == capacity) return false;
            self.buf[t & mask] = v;
            self.tail.store(t +% 1, .release);
            return true;
        }

        /// Consumer: removes and returns the oldest element.
        pub fn pop(self: *Self) ?T {
            const h = self.head.raw; // only the consumer writes head
            const t = self.tail.load(.acquire);
            if (h == t) return null;
            const v = self.buf[h & mask];
            self.head.store(h +% 1, .release);
            return v;
        }

        /// Approximate number of stored elements (exact when quiescent).
        pub fn len(self: *const Self) u32 {
            return self.tail.load(.acquire) -% self.head.load(.acquire);
        }

        /// True when approximately full.
        pub fn isFull(self: *const Self) bool {
            return self.len() == capacity;
        }
    };
}

test "ring: wraparound" {
    const gpa = std.testing.allocator;
    var r = try RingBuffer(u32).init(gpa, 4);
    defer r.deinit(gpa);
    for (0..10) |round| {
        for (0..3) |i| try std.testing.expect(r.push(@intCast(round * 10 + i)));
        for (0..3) |i| try std.testing.expectEqual(@as(?u32, @intCast(round * 10 + i)), r.pop());
    }
    for (0..4) |i| try std.testing.expect(r.push(@intCast(i)));
    try std.testing.expect(r.isFull());
    try std.testing.expect(!r.push(99));
    r.pushOverwrite(4);
    try std.testing.expectEqual(@as(?u32, 1), r.peek(0));
    try std.testing.expectEqual(@as(usize, 4), r.len());
}

test "spsc: 2 threads 1e6 items in order" {
    const Ring = SpscRing(u64, 1024);
    const ring = try std.testing.allocator.create(Ring);
    defer std.testing.allocator.destroy(ring);
    ring.* = .empty;
    const n: u64 = 1_000_000;
    const Producer = struct {
        fn run(r: *Ring) void {
            var i: u64 = 0;
            while (i < n) {
                if (r.push(i)) i += 1 else std.atomic.spinLoopHint();
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{ring});
    var expect: u64 = 0;
    while (expect < n) {
        if (ring.pop()) |v| {
            try std.testing.expectEqual(expect, v);
            expect += 1;
        } else std.atomic.spinLoopHint();
    }
    t.join();
    try std.testing.expectEqual(@as(?u64, null), ring.pop());
}
