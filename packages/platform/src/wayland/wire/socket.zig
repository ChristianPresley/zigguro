//! The Unix stream socket under a Wayland connection: connecting, and
//! `sendmsg`/`recvmsg` with fds as SCM_RIGHTS ancillary data. `std.Io.net`
//! has no ancillary-data API, so this uses `std.os.linux` directly.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const FdQueue = @import("fdqueue.zig").FdQueue;

/// Fds sent or received per message, as in libwayland.
pub const max_fds = 28;

/// Socket errors.
pub const Error = error{
    /// The socket path does not fit `sockaddr_un`.
    NameTooLong,
    /// `connect` failed (no compositor listening, or no permission).
    ConnectFailed,
    /// The compositor closed the connection, or the socket broke.
    ConnectionLost,
    /// Nothing to read yet (non-blocking receive).
    WouldBlock,
    /// Ancillary data was truncated: fds were lost.
    Protocol,
    /// The kernel is out of memory or fds.
    SystemResources,
};

/// Connects to the Unix socket at `path`.
pub fn connectPath(path: []const u8) Error!i32 {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    const len: u32 = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    const sock: i32 = @intCast(rc);
    while (true) switch (linux.errno(linux.connect(sock, &addr, len))) {
        .SUCCESS => return sock,
        .INTR => continue,
        else => {
            _ = linux.close(sock);
            return error.ConnectFailed;
        },
    };
}

/// Sets close-on-exec on `fd` (for an inherited `WAYLAND_SOCKET`).
pub fn setCloexec(fd: i32) Error!void {
    const flags = linux.fcntl(fd, linux.F.GETFD, 0);
    if (linux.errno(flags) != .SUCCESS) return error.ConnectFailed;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFD, flags | linux.FD_CLOEXEC)) != .SUCCESS) return error.ConnectFailed;
}

/// A close-on-exec duplicate of `fd`.
pub fn dupCloexec(fd: i32) Error!i32 {
    const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .BADF => error.Protocol,
        else => error.SystemResources,
    };
}

fn cmsgSpace(n: usize) usize {
    return @sizeOf(linux.cmsghdr) + std.mem.alignForward(usize, n, @alignOf(linux.cmsghdr));
}

const Control = [cmsgSpace(max_fds * 4)]u8;

/// Sends `bytes` (at least one byte) with `fds` attached; returns how many
/// bytes went out, which may be fewer than `bytes.len`. The fds go with
/// the first byte, so a caller resending the rest passes no fds.
pub fn sendMsg(sock: i32, bytes: []const u8, fds: []const i32) Error!usize {
    std.debug.assert(bytes.len > 0 and fds.len <= max_fds);
    var iov = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    var control: Control align(@alignOf(linux.cmsghdr)) = undefined;
    var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
    if (fds.len > 0) {
        const data_len = fds.len * 4;
        const h: *linux.cmsghdr = @ptrCast(&control);
        h.* = .{ .len = @sizeOf(linux.cmsghdr) + data_len, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
        @memcpy(control[@sizeOf(linux.cmsghdr)..][0..data_len], std.mem.sliceAsBytes(fds));
        msg.control = &control;
        msg.controllen = cmsgSpace(data_len);
    }
    while (true) {
        const rc = linux.sendmsg(sock, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => {
                waitWritable(sock);
                continue;
            },
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.ConnectionLost,
        }
    }
}

fn waitWritable(sock: i32) void {
    var pfd = [1]linux.pollfd{.{ .fd = sock, .events = linux.POLL.OUT, .revents = 0 }};
    _ = linux.ppoll(&pfd, 1, null, null);
}

/// Receives into `buf`, pushing any fds onto `fds` (which must have room
/// for `max_fds`). Returns the byte count; EOF is `error.ConnectionLost`
/// and, with `dontwait`, no data is `error.WouldBlock`.
pub fn recvMsg(sock: i32, buf: []u8, fds: *FdQueue, dontwait: bool) Error!usize {
    std.debug.assert(buf.len > 0 and fds.free() >= max_fds);
    var iov = [1]std.posix.iovec{.{ .base = buf.ptr, .len = buf.len }};
    var control: Control align(@alignOf(linux.cmsghdr)) = undefined;
    var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
    const flags: u32 = linux.MSG.CMSG_CLOEXEC | (if (dontwait) @as(u32, linux.MSG.DONTWAIT) else 0);
    const n = while (true) {
        const rc = linux.recvmsg(sock, &msg, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => return error.ConnectionLost,
        }
    };
    collectFds(control[0..msg.controllen], fds);
    if (msg.flags & linux.MSG.CTRUNC != 0) return error.Protocol;
    if (n == 0) return error.ConnectionLost;
    return n;
}

fn collectFds(control: []const u8, fds: *FdQueue) void {
    var off: usize = 0;
    while (off + @sizeOf(linux.cmsghdr) <= control.len) {
        const h: *align(1) const linux.cmsghdr = @ptrCast(control[off..].ptr);
        if (h.len < @sizeOf(linux.cmsghdr) or off + h.len > control.len) break;
        if (h.level == linux.SOL.SOCKET and h.type == linux.SCM.RIGHTS) {
            const data = control[off + @sizeOf(linux.cmsghdr) .. off + h.len];
            var i: usize = 0;
            while (i + 4 <= data.len) : (i += 4) {
                const fd = std.mem.readInt(i32, data[i..][0..4], builtin.cpu.arch.endian());
                // The caller guaranteed room for max_fds, the most one call carries.
                fds.push(fd) catch {
                    _ = linux.close(fd);
                };
            }
        }
        off += std.mem.alignForward(usize, h.len, @alignOf(linux.cmsghdr));
    }
}

/// A connected `socketpair(AF_UNIX, SOCK_STREAM)`, for tests.
pub fn pair() Error![2]i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS) return error.SystemResources;
    return fds;
}

const testing = std.testing;

test "bytes and fds cross a socketpair" {
    const sp = try pair();
    defer for (sp) |s| {
        _ = linux.close(s);
    };
    var pipe: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer for (pipe) |p| {
        _ = linux.close(p);
    };
    try testing.expectEqual(4, try sendMsg(sp[0], "abcd", &.{ pipe[0], pipe[1] }));
    var q: FdQueue = .{};
    defer q.closeAll();
    var buf: [16]u8 = undefined;
    try testing.expectEqual(4, try recvMsg(sp[1], &buf, &q, true));
    try testing.expectEqualStrings("abcd", buf[0..4]);
    try testing.expectEqual(2, q.count());
    try testing.expectError(error.WouldBlock, recvMsg(sp[1], &buf, &q, true));
    _ = linux.shutdown(sp[0], linux.SHUT.WR);
    try testing.expectError(error.ConnectionLost, recvMsg(sp[1], &buf, &q, false));
}

test "connectPath fails cleanly without a listener" {
    try testing.expectError(error.ConnectFailed, connectPath("/nonexistent/zg-wayland-test"));
    try testing.expectError(error.NameTooLong, connectPath("/" ++ "x" ** 200));
}
