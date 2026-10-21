//! Allocator primitives shared by every package.
//!
//! Repository-wide conventions:
//! - `gpa` is the first parameter of a function that allocates, `io` the
//!   second, then everything else (matching std 0.16, e.g. `Bundle.rescan(gpa, io, now)`).
//! - Functions returning slices document who owns them; by default the caller
//!   owns the result and frees it with the same allocator.
//! - Never keep an arena allocator (or memory from it) past the arena's reset.
//! - The process GPA is `std.heap.DebugAllocator` in Debug/ReleaseSafe (leak
//!   and safety checks) and `std.heap.smp_allocator` in ReleaseFast/ReleaseSmall;
//!   `-Dgpa=debug|smp` overrides the choice.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("zg_options");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Which general-purpose allocator backs a `Gpa`.
pub const GpaKind = enum { debug, smp, page };

/// The GPA kind selected by `-Dgpa` (`zg_options.gpa`); `.auto` resolves to
/// `.debug` in Debug/ReleaseSafe and `.smp` in ReleaseFast/ReleaseSmall.
pub fn defaultGpaKind() GpaKind {
    return switch (options.gpa) {
        .debug => .debug,
        .smp => if (builtin.single_threaded) .page else .smp,
        .auto => switch (builtin.mode) {
            .Debug, .ReleaseSafe => .debug,
            .ReleaseFast, .ReleaseSmall => if (builtin.single_threaded) .page else .smp,
        },
    };
}

/// The process-wide general-purpose allocator. Must not be copied after
/// `allocator()` has been called, because the debug state lives inline.
pub const Gpa = struct {
    kind: GpaKind,
    debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 8, .enable_memory_limit = true }) = .init,

    /// A Gpa of the default kind.
    pub fn init() Gpa {
        return .{ .kind = defaultGpaKind() };
    }

    /// The allocator interface. Thread-safe for every kind.
    pub fn allocator(self: *Gpa) Allocator {
        return switch (self.kind) {
            .debug => self.debug.allocator(),
            .smp => std.heap.smp_allocator,
            .page => std.heap.page_allocator,
        };
    }

    /// Bytes currently requested and not freed; `null` for non-debug kinds,
    /// which do not track it. Lets tests detect leaks without the error log
    /// `deinit` emits.
    pub fn liveBytes(self: *const Gpa) ?usize {
        return switch (self.kind) {
            .debug => self.debug.total_requested_bytes,
            .smp, .page => null,
        };
    }

    /// Releases debug state; returns `.leak` if allocations are outstanding
    /// (only detectable for `.debug`; other kinds always return `.ok`).
    pub fn deinit(self: *Gpa) std.heap.Check {
        return switch (self.kind) {
            .debug => self.debug.deinit(),
            .smp, .page => .ok,
        };
    }
};

/// Two arenas swapped every frame. Memory from `current()` stays valid for
/// the current and the previous frame.
///
/// Threading: allocating through `current()` is thread-safe (the 0.16
/// ArenaAllocator is lock-free), so workers may allocate frame-scoped data.
/// `next()` and `deinit()` are not thread-safe: call them on the UI thread
/// only, after every borrower of the older frame has called `release()`.
pub const FrameArena = struct {
    arenas: [2]std.heap.ArenaAllocator,
    index: u1 = 0,
    retain_limit: usize,
    /// Outstanding `borrow()`s of the current frame (Debug check only).
    borrowers: std.atomic.Value(u32) = .init(0),

    /// Creates both arenas on `backing`; on reset each keeps at most `retain_limit` bytes.
    pub fn init(backing: Allocator, retain_limit: usize) FrameArena {
        return .{
            .arenas = .{ .init(backing), .init(backing) },
            .retain_limit = retain_limit,
        };
    }

    /// The allocator of the current frame.
    pub fn current(self: *FrameArena) Allocator {
        return self.arenas[self.index].allocator();
    }

    /// Like `current()`, but records a borrower that must `release()` before
    /// the frame after next begins; use when handing the allocator to a task.
    pub fn borrow(self: *FrameArena) Allocator {
        _ = self.borrowers.fetchAdd(1, .acq_rel);
        return self.current();
    }

    /// Ends a `borrow()`.
    pub fn release(self: *FrameArena) void {
        const prev = self.borrowers.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
    }

    /// Number of outstanding borrowers.
    pub fn borrowCount(self: *const FrameArena) u32 {
        return self.borrowers.load(.acquire);
    }

    /// Advances to the next frame: resets the older arena (retaining up to
    /// `retain_limit` bytes) and makes it current. UI thread only; asserts in
    /// safe builds that no borrower is outstanding.
    pub fn next(self: *FrameArena) void {
        if (std.debug.runtime_safety and self.borrowCount() != 0) @panic("FrameArena.next() with outstanding borrowers");
        self.index +%= 1;
        _ = self.arenas[self.index].reset(.{ .retain_with_limit = self.retain_limit });
    }

    /// Frees both arenas.
    pub fn deinit(self: *FrameArena) void {
        self.arenas[0].deinit();
        self.arenas[1].deinit();
        self.* = undefined;
    }
};

/// One arena per LSP/HTTP/agent request, reset when the request completes.
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,

    /// Creates an empty arena on `backing`.
    pub fn init(backing: Allocator) RequestArena {
        return .{ .arena = .init(backing) };
    }

    /// The request-scoped allocator.
    pub fn allocator(self: *RequestArena) Allocator {
        return self.arena.allocator();
    }

    /// Frees everything allocated for the request, keeping the capacity.
    pub fn reset(self: *RequestArena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Releases all memory.
    pub fn deinit(self: *RequestArena) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// A pool of fixed-size `T` objects; the allocator is passed per call.
/// Not thread-safe. Wraps `std.heap.MemoryPool(T)` (unmanaged in 0.16).
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        inner: std.heap.MemoryPool(T) = .empty,

        /// An empty pool.
        pub const empty: Self = .{};

        /// Returns a pointer to uninitialised storage for one `T`, reusing a
        /// destroyed slot when available.
        pub fn create(self: *Self, gpa: Allocator) Allocator.Error!*T {
            return self.inner.create(gpa);
        }

        /// Returns `ptr` to the pool's free list.
        pub fn destroy(self: *Self, ptr: *T) void {
            self.inner.destroy(ptr);
        }

        /// Destroys every object at once (see `std.heap.ArenaAllocator.ResetMode`).
        pub fn reset(self: *Self, gpa: Allocator, mode: std.heap.ArenaAllocator.ResetMode) bool {
            return self.inner.reset(gpa, mode);
        }

        /// Frees all memory owned by the pool.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.inner.deinit(gpa);
            self.* = undefined;
        }
    };
}

/// Wraps a child allocator and counts allocations with relaxed atomics.
/// Used by the bench harness and E14 budget checks. Thread-safe if the child is.
pub const CountingAllocator = struct {
    child: Allocator,
    /// Successful `alloc` calls.
    allocs: std.atomic.Value(u64) = .init(0),
    /// `free` calls.
    frees: std.atomic.Value(u64) = .init(0),
    /// Bytes currently allocated.
    bytes_live: std.atomic.Value(i64) = .init(0),
    /// Highest observed `bytes_live`.
    bytes_peak: std.atomic.Value(u64) = .init(0),
    /// Total bytes ever allocated (including growth by resize/remap).
    bytes_total: std.atomic.Value(u64) = .init(0),

    /// Wraps `child`.
    pub fn init(child: Allocator) CountingAllocator {
        return .{ .child = child };
    }

    /// The counting allocator interface.
    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Resets every counter to zero.
    pub fn resetCounters(self: *CountingAllocator) void {
        self.allocs.store(0, .monotonic);
        self.frees.store(0, .monotonic);
        self.bytes_live.store(0, .monotonic);
        self.bytes_peak.store(0, .monotonic);
        self.bytes_total.store(0, .monotonic);
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn grow(self: *CountingAllocator, delta: i64) void {
        const live = self.bytes_live.fetchAdd(delta, .monotonic) + delta;
        if (delta > 0) _ = self.bytes_total.fetchAdd(@intCast(delta), .monotonic);
        if (live > 0) _ = self.bytes_peak.fetchMax(@intCast(live), .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        _ = self.allocs.fetchAdd(1, .monotonic);
        self.grow(@intCast(len));
        return p;
    }

    fn resize(ctx: *anyopaque, mem: []u8, a: Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(mem, a, new_len, ra)) return false;
        self.grow(@as(i64, @intCast(new_len)) - @as(i64, @intCast(mem.len)));
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(mem, a, new_len, ra) orelse return null;
        self.grow(@as(i64, @intCast(new_len)) - @as(i64, @intCast(mem.len)));
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, a: Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, a, ra);
        _ = self.frees.fetchAdd(1, .monotonic);
        self.grow(-@as(i64, @intCast(mem.len)));
    }
};

/// Fails with `error.OutOfMemory` rather than exceed `limit` live bytes, even
/// transiently (space is reserved before the child is called). Used for agent
/// sandboxes and untrusted input such as JSON. Thread-safe if the child is.
pub const LimitAllocator = struct {
    child: Allocator,
    limit: usize,
    live: std.atomic.Value(usize) = .init(0),

    /// Wraps `child` with a cap of `limit` live bytes.
    pub fn init(child: Allocator, limit: usize) LimitAllocator {
        return .{ .child = child, .limit = limit };
    }

    /// The limited allocator interface.
    pub fn allocator(self: *LimitAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Bytes currently allocated through this allocator.
    pub fn liveBytes(self: *const LimitAllocator) usize {
        return self.live.load(.monotonic);
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn reserve(self: *LimitAllocator, n: usize) bool {
        var cur = self.live.load(.monotonic);
        while (true) {
            if (n > self.limit or cur > self.limit - n) return false;
            cur = self.live.cmpxchgWeak(cur, cur + n, .monotonic, .monotonic) orelse return true;
        }
    }

    fn unreserve(self: *LimitAllocator, n: usize) void {
        _ = self.live.fetchSub(n, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: Alignment, ra: usize) ?[*]u8 {
        const self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (!self.reserve(len)) return null;
        return self.child.rawAlloc(len, a, ra) orelse {
            self.unreserve(len);
            return null;
        };
    }

    fn resize(ctx: *anyopaque, mem: []u8, a: Alignment, new_len: usize, ra: usize) bool {
        const self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len) {
            const extra = new_len - mem.len;
            if (!self.reserve(extra)) return false;
            if (self.child.rawResize(mem, a, new_len, ra)) return true;
            self.unreserve(extra);
            return false;
        }
        if (!self.child.rawResize(mem, a, new_len, ra)) return false;
        self.unreserve(mem.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, a: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len) {
            const extra = new_len - mem.len;
            if (!self.reserve(extra)) return null;
            return self.child.rawRemap(mem, a, new_len, ra) orelse {
                self.unreserve(extra);
                return null;
            };
        }
        const p = self.child.rawRemap(mem, a, new_len, ra) orelse return null;
        self.unreserve(mem.len - new_len);
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, a: Alignment, ra: usize) void {
        const self: *LimitAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, a, ra);
        self.unreserve(mem.len);
    }
};

test "alloc: Gpa debug detects leak" {
    // `deinit` reports leaks through std.log.err, which fails the test runner,
    // so the outstanding allocation is observed through liveBytes() instead.
    var gpa: Gpa = .{ .kind = .debug };
    const a = gpa.allocator();
    const p = try a.alloc(u8, 16);
    try std.testing.expectEqual(@as(?usize, 16), gpa.liveBytes());
    a.free(p);
    try std.testing.expectEqual(@as(?usize, 0), gpa.liveBytes());
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "alloc: Gpa smp and page kinds report ok" {
    var gpa: Gpa = .{ .kind = .page };
    const p = try gpa.allocator().alloc(u8, 16);
    gpa.allocator().free(p);
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "alloc: FrameArena retains capacity across 1000 frames" {
    var counting = CountingAllocator.init(std.testing.allocator);
    var fa = FrameArena.init(counting.allocator(), 1 << 20);
    defer fa.deinit();
    for (0..10) |_| {
        _ = try fa.current().alloc(u8, 4096);
        fa.next();
    }
    const warm = counting.allocs.load(.monotonic);
    for (0..1000) |_| {
        _ = try fa.current().alloc(u8, 4096);
        fa.next();
    }
    try std.testing.expectEqual(warm, counting.allocs.load(.monotonic));
}

test "alloc: FrameArena borrow/release counter" {
    var fa = FrameArena.init(std.testing.allocator, 1024);
    defer fa.deinit();
    _ = fa.borrow();
    try std.testing.expectEqual(@as(u32, 1), fa.borrowCount());
    fa.release();
    try std.testing.expectEqual(@as(u32, 0), fa.borrowCount());
    fa.next(); // must not panic with no borrowers
}

test "alloc: RequestArena reset keeps working" {
    var ra = RequestArena.init(std.testing.allocator);
    defer ra.deinit();
    _ = try ra.allocator().alloc(u8, 100);
    ra.reset();
    const s = try ra.allocator().dupe(u8, "hello");
    try std.testing.expectEqualStrings("hello", s);
}

test "alloc: Pool create/destroy reuse" {
    const gpa = std.testing.allocator;
    var pool: Pool(u64) = .empty;
    defer pool.deinit(gpa);
    const a = try pool.create(gpa);
    pool.destroy(a);
    const b = try pool.create(gpa);
    try std.testing.expectEqual(a, b);
}

test "alloc: CountingAllocator counts" {
    var c = CountingAllocator.init(std.testing.allocator);
    const a = c.allocator();
    const x = try a.alloc(u8, 10);
    const y = try a.alloc(u8, 30);
    try std.testing.expectEqual(@as(u64, 2), c.allocs.load(.monotonic));
    try std.testing.expectEqual(@as(i64, 40), c.bytes_live.load(.monotonic));
    a.free(x);
    a.free(y);
    try std.testing.expectEqual(@as(u64, 2), c.frees.load(.monotonic));
    try std.testing.expectEqual(@as(i64, 0), c.bytes_live.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 40), c.bytes_peak.load(.monotonic));
}

test "alloc: LimitAllocator rejects over-limit and recovers after free" {
    var l = LimitAllocator.init(std.testing.allocator, 100);
    const a = l.allocator();
    const x = try a.alloc(u8, 60);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 41));
    a.free(x);
    const y = try a.alloc(u8, 100);
    a.free(y);
    try std.testing.expectEqual(@as(usize, 0), l.liveBytes());
}

test "alloc: LimitAllocator passes std allocator test suite" {
    var l = LimitAllocator.init(std.testing.allocator, 64 << 20);
    try std.heap.testAllocator(l.allocator());
    try std.heap.testAllocatorAligned(l.allocator());
    var c = CountingAllocator.init(std.testing.allocator);
    try std.heap.testAllocator(c.allocator());
    try std.heap.testAllocatorAligned(c.allocator());
}
