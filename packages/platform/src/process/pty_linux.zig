//! `Pty` on Linux: a `/dev/ptmx` master with a race-free slave from
//! `TIOCGPTPEER`, a child that becomes session leader with the slave as its
//! controlling terminal, and pidfd-based exit handling.

const std = @import("std");
const linux = std.os.linux;
const pty = @import("pty.zig");
const spawn_linux = @import("spawn_linux.zig");

/// The Linux PTY state behind `pty.Pty`.
pub const LinuxPty = struct {
    /// Non-blocking master fd; -1 after a hangup.
    master: linux.fd_t,
    /// The child.
    child: spawn_linux.Child,
    /// Cached exit status once reaped.
    status: ?pty.ExitStatus = null,

    /// Opens the pair, sets the size and spawns the child on it.
    pub fn spawn(gpa: std.mem.Allocator, opts: pty.SpawnOptions) pty.Error!LinuxPty {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const prep = try spawn_linux.prepare(arena_state.allocator(), opts.argv, opts.cwd, opts.env, opts.policy, opts.term);

        const m = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (linux.errno(m) != .SUCCESS) return error.SystemResources;
        const master: linux.fd_t = @intCast(m);
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.SystemResources;
        const slave = try openSlave(master);
        defer _ = linux.close(slave);

        var tio: linux.termios = undefined;
        if (linux.errno(linux.tcgetattr(slave, &tio)) == .SUCCESS) {
            tio.iflag.IUTF8 = true;
            _ = linux.tcsetattr(slave, .NOW, &tio);
        }
        try setSize(slave, opts.size);
        const child = try spawn_linux.spawn(&prep, .{ .pty_slave = slave, .new_session = true });
        return .{ .master = master, .child = child };
    }

    fn openSlave(master: linux.fd_t) pty.Error!linux.fd_t {
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
        const r = linux.ioctl(master, linux.T.IOCGPTPEER, @as(u32, @bitCast(flags)));
        if (linux.errno(r) == .SUCCESS) return @intCast(r);
        // Kernels before 4.13: look up the slave number and open it by path.
        var n: c_uint = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS) return error.SystemResources;
        var buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "/dev/pts/{d}", .{n}) catch unreachable;
        const s = linux.open(path, flags, 0);
        if (linux.errno(s) != .SUCCESS) return error.SystemResources;
        return @intCast(s);
    }

    fn setSize(fd: linux.fd_t, size: pty.PtySize) pty.Error!void {
        const ws: std.posix.winsize = .{ .row = size.rows, .col = size.cols, .xpixel = size.px_w, .ypixel = size.px_h };
        if (linux.errno(linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws))) != .SUCCESS) return error.SystemResources;
    }

    /// See `pty.Pty.resize`.
    pub fn resize(self: *LinuxPty, size: pty.PtySize) pty.Error!void {
        if (self.master < 0) return error.Closed;
        try setSize(self.master, size);
    }

    /// See `pty.Pty.read`.
    pub fn read(self: *LinuxPty, buf: []u8) pty.Error!usize {
        if (self.master < 0) return 0;
        while (true) {
            const r = linux.read(self.master, buf.ptr, buf.len);
            switch (linux.errno(r)) {
                .SUCCESS => return r,
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                // Every slave fd is closed: the child side is gone.
                .IO => return 0,
                else => return error.Unexpected,
            }
        }
    }

    /// See `pty.Pty.write`.
    pub fn write(self: *LinuxPty, bytes: []const u8) pty.Error!usize {
        if (self.master < 0) return error.Closed;
        while (true) {
            const r = linux.write(self.master, bytes.ptr, bytes.len);
            switch (linux.errno(r)) {
                .SUCCESS => return r,
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .IO => return error.Closed,
                else => return error.Unexpected,
            }
        }
    }

    /// See `pty.Pty.waitReadable`.
    pub fn waitReadable(self: *LinuxPty, timeout_ns: ?u64) bool {
        if (self.master < 0) return true;
        var fds = [1]linux.pollfd{.{ .fd = self.master, .events = linux.POLL.IN, .revents = 0 }};
        var ts: linux.timespec = undefined;
        const tsp: ?*linux.timespec = if (timeout_ns) |ns| blk: {
            ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            break :blk &ts;
        } else null;
        const r = linux.ppoll(&fds, 1, tsp, null);
        return linux.errno(r) == .SUCCESS and r > 0;
    }

    /// See `pty.Pty.wait`.
    pub fn wait(self: *LinuxPty) pty.Error!pty.ExitStatus {
        if (self.status) |s| return s;
        const s = (spawn_linux.waitPidfd(self.child.pidfd, false) catch return error.Unexpected).?;
        self.status = s;
        return s;
    }

    /// See `pty.Pty.tryWait`.
    pub fn tryWait(self: *LinuxPty) pty.Error!?pty.ExitStatus {
        if (self.status) |s| return s;
        self.status = spawn_linux.waitPidfd(self.child.pidfd, true) catch return error.Unexpected;
        return self.status;
    }

    /// See `pty.Pty.kill`.
    pub fn kill(self: *LinuxPty, how: pty.KillMode) void {
        switch (how) {
            .hangup => if (self.master >= 0) {
                _ = linux.close(self.master);
                self.master = -1;
            },
            .terminate => _ = linux.pidfd_send_signal(self.child.pidfd, .TERM, null, 0),
            // The child is session leader, so its pid is also the group id.
            .kill_tree => _ = linux.kill(-self.child.pid, .KILL),
        }
    }

    /// See `pty.Pty.close`.
    pub fn close(self: *LinuxPty) void {
        if (self.master >= 0) _ = linux.close(self.master);
        _ = linux.close(self.child.pidfd);
        self.* = undefined;
    }
};
