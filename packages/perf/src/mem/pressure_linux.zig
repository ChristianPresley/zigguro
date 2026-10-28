//! Linux PSI pressure source (E14.F04.S02.T01). Two triggers on
//! `/proc/pressure/memory`, each on its own fd (a second write on one fd
//! fails with EBUSY): `some` stall of 150 ms in 2 s for moderate, `full`
//! 100 ms in 2 s for critical. The 2 s window is a multiple of 2 s, so it
//! works unprivileged. One task blocks in poll(POLLPRI) with no timeout;
//! an eventfd wakes it to stop. POLLERR means the source went away.

const std = @import("std");
const builtin = @import("builtin");
const pressure = @import("pressure.zig");

const log = std.log.scoped(.zg_perf_mem);

pub const path = "/proc/pressure/memory";
/// Written with the trailing NUL, as the kernel's example does.
pub const some_trigger = "some 150000 2000000";
pub const full_trigger = "full 100000 2000000";

/// The fd layer (real syscalls, or a fake in tests).
pub const Ops = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (ctx: ?*anyopaque, p: [*:0]const u8) ?i32,
    write: *const fn (ctx: ?*anyopaque, fd: i32, bytes: []const u8) error{ Busy, Failed }!void,
    close: *const fn (ctx: ?*anyopaque, fd: i32) void,
};

/// Opens one fd per trigger and arms it: `[some, full]`, -1 where the
/// trigger could not be armed (no PSI, EBUSY, no permission).
pub fn armTriggers(ops: Ops) [2]i32 {
    var fds: [2]i32 = .{ -1, -1 };
    inline for (.{ some_trigger, full_trigger }, 0..) |trig, i| {
        if (ops.open(ops.ctx, path)) |fd| {
            if (ops.write(ops.ctx, fd, trig ++ "\x00")) |_| {
                fds[i] = fd;
            } else |e| {
                log.info("PSI trigger \"{s}\" not armed: {t}", .{ trig, e });
                ops.close(ops.ctx, fd);
            }
        }
    }
    return fds;
}

const real_ops: Ops = .{ .open = realOpen, .write = realWrite, .close = realClose };

fn realOpen(_: ?*anyopaque, p: [*:0]const u8) ?i32 {
    const linux = std.os.linux;
    const rc = linux.open(p, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn realWrite(_: ?*anyopaque, fd: i32, bytes: []const u8) error{ Busy, Failed }!void {
    const linux = std.os.linux;
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .BUSY => error.Busy,
        else => error.Failed,
    };
}

fn realClose(_: ?*anyopaque, fd: i32) void {
    _ = std.os.linux.close(fd);
}

/// The PSI source: armed trigger fds and the stop eventfd.
pub const Psi = struct {
    gpa: std.mem.Allocator,
    sink: pressure.OsSink,
    some: i32,
    full: i32,
    stop_fd: i32,

    /// Arms the triggers; null when PSI is unavailable.
    pub fn open(gpa: std.mem.Allocator, sink: pressure.OsSink) !?*Psi {
        const linux = std.os.linux;
        const fds = armTriggers(real_ops);
        if (fds[0] < 0 and fds[1] < 0) return null;
        const efd = linux.eventfd(0, linux.EFD.CLOEXEC);
        if (linux.errno(efd) != .SUCCESS) {
            for (fds) |fd| if (fd >= 0) realClose(null, fd);
            return null;
        }
        const p = try gpa.create(Psi);
        p.* = .{ .gpa = gpa, .sink = sink, .some = fds[0], .full = fds[1], .stop_fd = @intCast(efd) };
        return p;
    }

    /// The waiting task: blocks in poll until pressure or `requestStop`.
    pub fn run(p: *Psi) std.Io.Cancelable!void {
        const linux = std.os.linux;
        const PRI = linux.POLL.PRI;
        var pfds = [_]linux.pollfd{
            .{ .fd = p.some, .events = PRI, .revents = 0 },
            .{ .fd = p.full, .events = PRI, .revents = 0 },
            .{ .fd = p.stop_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        while (true) {
            const rc = linux.poll(&pfds, pfds.len, -1);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            if (pfds[2].revents != 0) return;
            for (pfds[0..2]) |*f| if (f.revents & (linux.POLL.ERR | linux.POLL.NVAL) != 0) {
                log.info("PSI source went away", .{});
                f.fd = -1;
            };
            if (pfds[1].revents & PRI != 0) p.sink.report(p.sink.ctx, .critical) else if (pfds[0].revents & PRI != 0) p.sink.report(p.sink.ctx, .moderate);
            if (pfds[0].fd < 0 and pfds[1].fd < 0) return;
        }
    }

    /// Wakes `run` so it returns.
    pub fn requestStop(p: *Psi) void {
        const one: u64 = 1;
        _ = std.os.linux.write(p.stop_fd, std.mem.asBytes(&one), 8);
    }

    /// Closes the fds and frees the source (after `run` returned).
    pub fn close(p: *Psi) void {
        for ([_]i32{ p.some, p.full, p.stop_fd }) |fd| if (fd >= 0) realClose(null, fd);
        p.gpa.destroy(p);
    }
};

const FakeFds = struct {
    next: i32 = 10,
    opens: u32 = 0,
    exists: bool = true,
    writes: [32]std.ArrayList(u8) = @splat(.empty),
    closed: [32]bool = @splat(false),

    fn ops(f: *FakeFds) Ops {
        return .{ .ctx = f, .open = open, .write = write, .close = close };
    }
    fn deinit(f: *FakeFds) void {
        for (&f.writes) |*w| w.deinit(std.testing.allocator);
    }
    fn open(ctx: ?*anyopaque, p: [*:0]const u8) ?i32 {
        const f: *FakeFds = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(std.mem.eql(u8, std.mem.span(p), path));
        if (!f.exists) return null;
        f.opens += 1;
        defer f.next += 1;
        return f.next;
    }
    fn write(ctx: ?*anyopaque, fd: i32, bytes: []const u8) error{ Busy, Failed }!void {
        const f: *FakeFds = @ptrCast(@alignCast(ctx.?));
        const w = &f.writes[@intCast(fd)];
        // The kernel: one trigger per fd.
        if (w.items.len > 0) return error.Busy;
        w.appendSlice(std.testing.allocator, bytes) catch return error.Failed;
    }
    fn close(ctx: ?*anyopaque, fd: i32) void {
        const f: *FakeFds = @ptrCast(@alignCast(ctx.?));
        f.closed[@intCast(fd)] = true;
    }
};

test "pressure_linux: trigger string and EBUSY handling" {
    var f: FakeFds = .{};
    defer f.deinit();
    const fds = armTriggers(f.ops());
    try std.testing.expectEqual([2]i32{ 10, 11 }, fds);
    try std.testing.expectEqualStrings("some 150000 2000000\x00", f.writes[10].items);
    try std.testing.expectEqualStrings("full 100000 2000000\x00", f.writes[11].items);
    // A second trigger on an armed fd is EBUSY: the fd is closed, not used.
    try std.testing.expectError(error.Busy, FakeFds.write(&f, 10, "x"));
    var busy: FakeFds = .{ .next = 10 };
    defer busy.deinit();
    try busy.writes[10].append(std.testing.allocator, 'x');
    const b = armTriggers(busy.ops());
    try std.testing.expectEqual([2]i32{ -1, 11 }, b);
    try std.testing.expect(busy.closed[10]);
    // No /proc/pressure (PSI disabled): nothing armed.
    var none: FakeFds = .{ .exists = false };
    defer none.deinit();
    try std.testing.expectEqual([2]i32{ -1, -1 }, armTriggers(none.ops()));
}

test "pressure_linux: real source opens or is skipped, and stops" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Sink = struct {
        fn report(_: *anyopaque, _: pressure.Pressure) void {}
    };
    var dummy: u8 = 0;
    const p = (try Psi.open(std.testing.allocator, .{ .ctx = &dummy, .report = Sink.report })) orelse return error.SkipZigTest;
    var group: std.Io.Group = .init;
    group.concurrent(std.testing.io, Psi.run, .{p}) catch {
        p.close();
        return error.SkipZigTest;
    };
    p.requestStop();
    group.await(std.testing.io) catch {};
    p.close();
}
