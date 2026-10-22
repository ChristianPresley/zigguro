//! The UI mailbox: a bounded multi-producer queue drained by the UI thread
//! without blocking, with coalesced wakes.
//!
//! Implementation note: `std.Io.Queue` is a mutex-protected ring, not
//! lock-free. That meets the < 1 µs post/drain budget at UI message rates
//! (see the core bench); if it ever misses, per-producer `SpscRing`s can
//! replace the producer side behind the same API.

const std = @import("std");
const RingBuffer = @import("../containers/ring_buffer.zig").RingBuffer;
const Waker = @import("waker.zig").Waker;

/// A message for the UI thread: plain data, 40 bytes. Large payloads travel
/// as `SlotMap` handles or `Pool` pointers in the payload words; ownership of
/// whatever they reference transfers to the UI thread when `drain` returns
/// the message.
pub const UiMsg = extern struct {
    /// Subsystem-defined message kind.
    kind: u32,
    /// Subsystem id (assigned by the app composition root).
    source: u32 = 0,
    /// Payload words: handles, pointers (as `usize`), ids or small values.
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
    d: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(UiMsg) == 40);
    }
};

/// Errors from `Mailbox.post`.
pub const PostError = error{
    /// The mailbox was closed (shutdown).
    Closed,
    /// The mailbox is full; coalesce (e.g. post a "dirty" flag) and retry later.
    Full,
};

/// Bounded MPSC mailbox for `UiMsg`.
pub const Mailbox = struct {
    queue: std.Io.Queue(UiMsg),
    buffer: []UiMsg,
    /// Messages the UI thread posts to itself; never touched by other threads.
    local: RingBuffer(UiMsg),
    /// Set by the first post after a drain; cleared by drain. Coalesces wakes.
    pending: std.atomic.Value(bool) = .init(false),
    waker: Waker = .noop,

    /// Allocates a mailbox holding up to `capacity` messages (a power of two)
    /// from other threads plus `capacity` UI self-posts.
    pub fn init(gpa: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!Mailbox {
        const buffer = try gpa.alloc(UiMsg, capacity);
        errdefer gpa.free(buffer);
        return .{ .queue = .init(buffer), .buffer = buffer, .local = try .init(gpa, capacity) };
    }

    /// Frees the storage. No producer may be running.
    pub fn deinit(self: *Mailbox, gpa: std.mem.Allocator) void {
        gpa.free(self.buffer);
        self.local.deinit(gpa);
        self.* = undefined;
    }

    /// Posts `msg`. `from_ui` must be true exactly when called on the UI
    /// thread; then the message goes to the UI-local ring, so the UI thread
    /// never waits on the queue. Never blocks, never allocates.
    pub fn post(self: *Mailbox, io: std.Io, msg: UiMsg, from_ui: bool) PostError!void {
        if (from_ui) {
            if (!self.local.push(msg)) return error.Full;
        } else {
            const n = self.queue.putUncancelable(io, &.{msg}, 0) catch return error.Closed;
            if (n == 0) return error.Full;
        }
        if (!self.pending.swap(true, .acq_rel)) self.waker.wake();
    }

    /// UI thread only: copies up to `out.len` messages into `out` without
    /// blocking and returns the count. UI self-posts come first, then other
    /// threads' messages in FIFO order per producer. If the result equals
    /// `out.len`, call again: more may be waiting.
    pub fn drain(self: *Mailbox, io: std.Io, out: []UiMsg) usize {
        self.pending.store(false, .release);
        var n: usize = 0;
        while (n < out.len) : (n += 1) out[n] = self.local.pop() orelse break;
        if (n < out.len) n += self.queue.getUncancelable(io, out[n..], 0) catch 0;
        return n;
    }

    /// Closes the mailbox: further `post`s from other threads fail with `error.Closed`.
    pub fn close(self: *Mailbox, io: std.Io) void {
        self.queue.close(io);
    }
};

test "mailbox: post then drain, local first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mb = try Mailbox.init(gpa, 8);
    defer mb.deinit(gpa);
    try mb.post(io, .{ .kind = 1 }, false);
    try mb.post(io, .{ .kind = 2 }, true);
    var out: [8]UiMsg = undefined;
    const n = mb.drain(io, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 2), out[0].kind);
    try std.testing.expectEqual(@as(u32, 1), out[1].kind);
    try std.testing.expectEqual(@as(usize, 0), mb.drain(io, &out));
}

test "mailbox: full and closed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var mb = try Mailbox.init(gpa, 2);
    defer mb.deinit(gpa);
    try mb.post(io, .{ .kind = 1 }, false);
    try mb.post(io, .{ .kind = 1 }, false);
    try std.testing.expectError(error.Full, mb.post(io, .{ .kind = 1 }, false));
    mb.close(io);
    try std.testing.expectError(error.Closed, mb.post(io, .{ .kind = 1 }, false));
}
