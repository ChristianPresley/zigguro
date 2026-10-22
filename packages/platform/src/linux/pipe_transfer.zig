//! Non-blocking pipe transfers for selections and drops (Wayland
//! `receive`/`send`, later X11 INCR-like transfers). Each transfer is one
//! pipe end registered in the platform thread's epoll under its own tag;
//! the thread calls `onReady` for those tags and `expire` on its timeout,
//! so a 50 MB paste never touches the UI thread.
//!
//! Writes may hit a reader that went away: the thread that drives the
//! transfers must block SIGPIPE (`blockSigpipe`), so the write fails with
//! EPIPE instead of killing the process.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const MimeId = @import("../api/clipboard.zig").MimeId;

const log = std.log.scoped(.pipe_transfer);

/// Which way the bytes flow.
pub const Dir = enum(u1) {
    /// We read from the pipe until EOF.
    read,
    /// We write our bytes and close.
    write,
};

/// One transfer in flight.
pub const Transfer = struct {
    /// Our end of the pipe (owned).
    fd: i32,
    dir: Dir,
    /// `.read`: the bytes so far. `.write`: the bytes to send.
    buf: std.ArrayList(u8) = .empty,
    /// `.write`: bytes already written.
    done: usize = 0,
    /// The app's request id (`.read`), echoed in `Finished`.
    request: u32 = 0,
    mime: MimeId = .text_utf8,
    /// Monotonic deadline in ns; the transfer fails after it.
    deadline_ns: u64,
};

/// A transfer that ended.
pub const Finished = struct {
    dir: Dir,
    request: u32,
    mime: MimeId,
    /// `.read` and `ok`: the bytes, owned by the caller. Empty otherwise.
    data: []u8 = &.{},
    /// False on timeout, I/O error or an oversized payload.
    ok: bool,
};

/// The transfers of one platform thread.
pub const Transfers = struct {
    gpa: Allocator,
    /// The epoll set the pipe ends join.
    epfd: i32,
    /// By id; the epoll tag is `tag_base + id`.
    items: std.AutoArrayHashMapUnmanaged(u32, Transfer) = .empty,
    next_id: u32 = 0,
    /// Reads beyond this fail (a hostile or runaway source).
    max_bytes: usize = 512 * 1024 * 1024,

    /// Epoll tags at and above this belong to transfers.
    pub const tag_base: u64 = 1 << 32;

    /// Closes every pipe end and frees the buffers.
    pub fn deinit(t: *Transfers) void {
        for (t.items.values()) |*x| {
            _ = linux.close(x.fd);
            x.buf.deinit(t.gpa);
        }
        t.items.deinit(t.gpa);
    }

    /// Whether `tag` is a transfer's.
    pub fn owns(tag: u64) bool {
        return tag >= tag_base;
    }

    /// Reads `fd` (a pipe's read end, owned from now on) until EOF.
    pub fn startRead(t: *Transfers, fd: i32, request: u32, mime: MimeId, deadline_ns: u64) !void {
        errdefer _ = linux.close(fd);
        try setNonblock(fd);
        try t.add(.{ .fd = fd, .dir = .read, .request = request, .mime = mime, .deadline_ns = deadline_ns }, linux.EPOLL.IN);
    }

    /// Writes a copy of `data` to `fd` (owned from now on), then closes it.
    /// Small payloads usually finish here without waiting.
    pub fn startWrite(t: *Transfers, fd: i32, data: []const u8, deadline_ns: u64) !void {
        errdefer _ = linux.close(fd);
        try setNonblock(fd);
        var x: Transfer = .{ .fd = fd, .dir = .write, .deadline_ns = deadline_ns };
        try x.buf.appendSlice(t.gpa, data);
        switch (writeSome(&x)) {
            .done, .failed => {
                _ = linux.close(fd);
                x.buf.deinit(t.gpa);
                return;
            },
            .again => {},
        }
        errdefer x.buf.deinit(t.gpa);
        try t.add(x, linux.EPOLL.OUT);
    }

    fn add(t: *Transfers, x: Transfer, events: u32) !void {
        try t.items.ensureUnusedCapacity(t.gpa, 1);
        const id = t.next_id;
        var ev: linux.epoll_event = .{ .events = events, .data = .{ .u64 = tag_base + id } };
        if (linux.errno(linux.epoll_ctl(t.epfd, linux.EPOLL.CTL_ADD, x.fd, &ev)) != .SUCCESS) return error.SystemResources;
        t.next_id +%= 1;
        t.items.putAssumeCapacity(id, x);
    }

    /// Drives the transfer of `tag`; appends to `out` when it ends.
    pub fn onReady(t: *Transfers, tag: u64, out: *std.ArrayList(Finished)) !void {
        const id: u32 = @intCast(tag - tag_base);
        const x = t.items.getPtr(id) orelse return;
        try out.ensureUnusedCapacity(t.gpa, 1);
        switch (x.dir) {
            .read => switch (t.readSome(x)) {
                .again => {},
                .done => t.finish(id, true, out),
                .failed => t.finish(id, false, out),
            },
            .write => switch (writeSome(x)) {
                .again => {},
                .done => t.finish(id, true, out),
                .failed => t.finish(id, false, out),
            },
        }
    }

    /// Fails every transfer whose deadline has passed.
    pub fn expire(t: *Transfers, now_ns: u64, out: *std.ArrayList(Finished)) !void {
        var i: usize = 0;
        while (i < t.items.count()) {
            const x = t.items.values()[i];
            if (now_ns < x.deadline_ns) {
                i += 1;
                continue;
            }
            try out.ensureUnusedCapacity(t.gpa, 1);
            log.warn("{t} transfer timed out after {d} bytes", .{ x.dir, x.buf.items.len });
            t.finish(t.items.keys()[i], false, out);
        }
    }

    /// The earliest deadline, if any transfer is running.
    pub fn nextDeadline(t: *const Transfers) ?u64 {
        var next: ?u64 = null;
        for (t.items.values()) |x| next = if (next) |n| @min(n, x.deadline_ns) else x.deadline_ns;
        return next;
    }

    /// `out` has room for one more.
    fn finish(t: *Transfers, id: u32, ok: bool, out: *std.ArrayList(Finished)) void {
        var x = (t.items.fetchSwapRemove(id) orelse return).value;
        _ = linux.epoll_ctl(t.epfd, linux.EPOLL.CTL_DEL, x.fd, null);
        _ = linux.close(x.fd);
        var f: Finished = .{ .dir = x.dir, .request = x.request, .mime = x.mime, .ok = ok };
        if (ok and x.dir == .read) {
            f.data = x.buf.toOwnedSlice(t.gpa) catch blk: {
                f.ok = false;
                break :blk &.{};
            };
        }
        x.buf.deinit(t.gpa);
        out.appendAssumeCapacity(f);
    }

    const Step = enum { again, done, failed };

    fn readSome(t: *Transfers, x: *Transfer) Step {
        while (true) {
            x.buf.ensureUnusedCapacity(t.gpa, 64 * 1024) catch return .failed;
            const dst = x.buf.unusedCapacitySlice();
            const rc = linux.read(x.fd, dst.ptr, dst.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return .done;
                    x.buf.items.len += rc;
                    if (x.buf.items.len > t.max_bytes) return .failed;
                },
                .INTR => {},
                .AGAIN => return .again,
                else => return .failed,
            }
        }
    }

    fn writeSome(x: *Transfer) Step {
        while (x.done < x.buf.items.len) {
            const src = x.buf.items[x.done..];
            const rc = linux.write(x.fd, src.ptr, src.len);
            switch (linux.errno(rc)) {
                .SUCCESS => x.done += rc,
                .INTR => {},
                .AGAIN => return .again,
                else => return .failed,
            }
        }
        return .done;
    }
};

fn setNonblock(fd: i32) !void {
    const fl = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(fl) != .SUCCESS) return error.SystemResources;
    const nb: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, fl | nb)) != .SUCCESS) return error.SystemResources;
}

/// Blocks SIGPIPE on the calling thread, so writes to a closed pipe fail
/// with EPIPE.
pub fn blockSigpipe() void {
    var set = linux.sigemptyset();
    linux.sigaddset(&set, .PIPE);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &set, null);
}

/// A non-blocking, close-on-exec pipe: `{ read end, write end }`.
pub fn pipe() ![2]i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true })) != .SUCCESS) return error.SystemResources;
    return fds;
}

// ---- tests ----

const testing = std.testing;

const Loop = struct {
    t: Transfers,
    out: std.ArrayList(Finished) = .empty,

    fn init() !Loop {
        const ep = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.errno(ep) != .SUCCESS) return error.SystemResources;
        return .{ .t = .{ .gpa = testing.allocator, .epfd = @intCast(ep) } };
    }

    fn deinit(l: *Loop) void {
        for (l.out.items) |f| testing.allocator.free(f.data);
        l.out.deinit(testing.allocator);
        l.t.deinit();
        _ = linux.close(l.t.epfd);
    }

    /// One epoll round; returns the wakeups handled.
    fn step(l: *Loop, timeout_ms: i32) !usize {
        var evs: [8]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(l.t.epfd, &evs, evs.len, timeout_ms);
        if (linux.errno(rc) != .SUCCESS) return 0;
        for (evs[0..rc]) |e| if (Transfers.owns(e.data.u64)) try l.t.onReady(e.data.u64, &l.out);
        return rc;
    }
};

test "receive reads until EOF across many epoll wakeups" {
    var l = try Loop.init();
    defer l.deinit();
    const fds = try pipe();
    try l.t.startRead(fds[0], 7, .text_utf8, std.math.maxInt(u64));
    var wakeups: usize = 0;
    var sent: usize = 0;
    var chunk: [1000]u8 = undefined;
    for (0..20) |i| {
        @memset(&chunk, @intCast('a' + i));
        sent += linux.write(fds[1], &chunk, chunk.len);
        wakeups += try l.step(1000);
    }
    _ = linux.close(fds[1]);
    while (l.out.items.len == 0) wakeups += try l.step(1000);
    try testing.expect(wakeups >= 20);
    const f = l.out.items[0];
    try testing.expect(f.ok and f.dir == .read and f.request == 7);
    try testing.expectEqual(@as(usize, 20_000), f.data.len);
    try testing.expectEqual(@as(u8, 'a'), f.data[0]);
    try testing.expectEqual(@as(u8, 't'), f.data[19_999]);
    try testing.expectEqual(@as(usize, 0), l.t.items.count());
}

test "send writes a large payload with EAGAIN handling" {
    var l = try Loop.init();
    defer l.deinit();
    const fds = try pipe();
    const data = try testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 31);
    try l.t.startWrite(fds[1], data, std.math.maxInt(u64));
    // The pipe holds far less: the write is still pending.
    try testing.expectEqual(@as(usize, 1), l.t.items.count());
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var buf: [256 * 1024]u8 = undefined;
    while (true) {
        const rc = linux.read(fds[0], &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                try got.appendSlice(testing.allocator, buf[0..rc]);
            },
            .AGAIN => _ = try l.step(1000),
            else => return error.Unexpected,
        }
    }
    _ = linux.close(fds[0]);
    try testing.expectEqualSlices(u8, data, got.items);
    try testing.expectEqual(@as(usize, 1), l.out.items.len);
    try testing.expect(l.out.items[0].ok and l.out.items[0].dir == .write);
}

test "a vanished reader fails the write; deadlines expire" {
    blockSigpipe();
    var l = try Loop.init();
    defer l.deinit();
    const fds = try pipe();
    const data = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(data);
    @memset(data, 'x');
    try l.t.startWrite(fds[1], data, std.math.maxInt(u64));
    _ = linux.close(fds[0]);
    while (l.out.items.len == 0) _ = try l.step(1000);
    try testing.expect(!l.out.items[0].ok);

    const r = try pipe();
    defer _ = linux.close(r[1]);
    try l.t.startRead(r[0], 9, .html, 1000);
    try testing.expectEqual(@as(?u64, 1000), l.t.nextDeadline());
    try l.t.expire(999, &l.out);
    try testing.expectEqual(@as(usize, 1), l.out.items.len);
    try l.t.expire(1000, &l.out);
    try testing.expectEqual(@as(usize, 2), l.out.items.len);
    try testing.expect(!l.out.items[1].ok and l.out.items[1].request == 9 and l.out.items[1].data.len == 0);
    try testing.expectEqual(@as(?u64, null), l.t.nextDeadline());
}
