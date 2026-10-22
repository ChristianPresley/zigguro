//! `Wake` on Linux: an eventfd that the platform thread polls together with
//! the display fd, and that the UI thread waits on with `ppoll`.

const std = @import("std");
const linux = std.os.linux;

/// An eventfd-backed wake object.
pub const LinuxWake = struct {
    /// The eventfd, created with `EFD_CLOEXEC | EFD_NONBLOCK`.
    fd: i32,

    /// Creates the eventfd.
    pub fn init() error{SystemResources}!LinuxWake {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        return .{ .fd = @intCast(rc) };
    }

    /// Closes the eventfd.
    pub fn deinit(self: *LinuxWake) void {
        _ = linux.close(self.fd);
        self.* = undefined;
    }

    /// Adds 1 to the counter. EAGAIN (counter saturated) still leaves the fd
    /// readable, so it is ignored.
    pub fn signal(self: *LinuxWake) void {
        const one: u64 = 1;
        _ = linux.write(self.fd, std.mem.asBytes(&one), 8);
    }

    /// Resets the counter.
    pub fn consume(self: *LinuxWake) void {
        var v: u64 = 0;
        _ = linux.read(self.fd, std.mem.asBytes(&v), 8);
    }

    /// Waits until signalled or `timeout_ns` passes (null waits forever).
    /// Returns whether the fd is readable. Does not consume.
    pub fn wait(self: *LinuxWake, timeout_ns: ?u64) bool {
        var fds = [1]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        var ts: linux.timespec = undefined;
        const tsp: ?*linux.timespec = if (timeout_ns) |ns| blk: {
            ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
            break :blk &ts;
        } else null;
        const rc = linux.ppoll(&fds, 1, tsp, null);
        if (linux.errno(rc) != .SUCCESS) return false;
        return rc > 0 and fds[0].revents & linux.POLL.IN != 0;
    }
};
