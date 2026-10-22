//! A FIFO of received file descriptors. Fds arrive as SCM_RIGHTS data in
//! the order the compositor sent them; decoders pop one per `fd` argument.

const std = @import("std");
const linux = std.os.linux;

/// A fixed-size ring of fds.
pub const FdQueue = struct {
    /// The ring holds at most this many fds.
    pub const capacity = 256;

    buf: [capacity]i32 = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Appends `fd`; `error.Full` when the ring is full (the caller still
    /// owns `fd`).
    pub fn push(q: *FdQueue, fd: i32) error{Full}!void {
        if (q.len == capacity) return error.Full;
        q.buf[(q.head + q.len) % capacity] = fd;
        q.len += 1;
    }

    /// Removes and returns the oldest fd; the caller owns it.
    pub fn pop(q: *FdQueue) ?i32 {
        if (q.len == 0) return null;
        const fd = q.buf[q.head];
        q.head = (q.head + 1) % capacity;
        q.len -= 1;
        return fd;
    }

    /// How many fds are queued.
    pub fn count(q: *const FdQueue) usize {
        return q.len;
    }

    /// Room left in the ring.
    pub fn free(q: *const FdQueue) usize {
        return capacity - q.len;
    }

    /// Pops and closes up to `n` fds.
    pub fn closeN(q: *FdQueue, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const fd = q.pop() orelse return;
            _ = linux.close(fd);
        }
    }

    /// Closes every queued fd.
    pub fn closeAll(q: *FdQueue) void {
        q.closeN(q.len);
    }
};

const testing = std.testing;

test "fd queue is FIFO and wraps" {
    var q: FdQueue = .{};
    var i: i32 = 0;
    while (i < 300) : (i += 1) {
        try q.push(i);
        try testing.expectEqual(i, q.pop().?);
    }
    try testing.expectEqual(null, q.pop());
    for (0..FdQueue.capacity) |k| try q.push(@intCast(k));
    try testing.expectError(error.Full, q.push(1));
    try testing.expectEqual(0, q.pop().?);
    try testing.expectEqual(FdQueue.capacity - 1, q.count());
}

test "closeN closes the oldest fds" {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    var q: FdQueue = .{};
    try q.push(fds[0]);
    try q.push(fds[1]);
    q.closeN(1);
    try testing.expectEqual(1, q.count());
    try testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fds[0], linux.F.GETFD, 0)));
    q.closeAll();
    try testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fds[1], linux.F.GETFD, 0)));
}
