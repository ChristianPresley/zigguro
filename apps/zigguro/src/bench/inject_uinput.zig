//! `bench-latency` keystrokes through a Linux uinput virtual keyboard
//! (E14.F03.S02.T02). The compositor or X server reads it like real
//! hardware, so the whole input path is measured. Needs write access to
//! /dev/uinput (root, or a udev rule; see `udev_rule`).
//!
//! Numbers from `linux/uinput.h` and `linux/input-event-codes.h`.

const std = @import("std");
const linux = std.os.linux;
const keys = @import("keys.zig");
const Injector = @import("injector.zig").Injector;

/// The udev rule that gives the logged-in user /dev/uinput.
pub const udev_rule =
    \\KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
;

const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const SYN_REPORT: u16 = 0;
const BUS_VIRTUAL: u16 = 0x06;

/// `_IOW('U', nr, size)`.
fn iow(nr: u8, size: u14) u32 {
    return (1 << 30) | (@as(u32, size) << 16) | ('U' << 8) | nr;
}

const InputId = extern struct { bustype: u16, vendor: u16, product: u16, version: u16 };
const UinputSetup = extern struct { id: InputId, name: [80]u8, ff_effects_max: u32 };
const InputEvent = extern struct { sec: isize, usec: isize, type: u16, code: u16, value: i32 };

const UI_SET_EVBIT = iow(100, @sizeOf(c_int));
const UI_SET_KEYBIT = iow(101, @sizeOf(c_int));
const UI_DEV_SETUP = iow(3, @sizeOf(UinputSetup));
/// `_IO('U', 1)` and `_IO('U', 2)`.
const UI_DEV_CREATE: u32 = ('U' << 8) | 1;
const UI_DEV_DESTROY: u32 = ('U' << 8) | 2;

comptime {
    // Values from the kernel headers (x86_64 and aarch64).
    std.debug.assert(UI_SET_EVBIT == 0x40045564);
    std.debug.assert(UI_SET_KEYBIT == 0x40045565);
    std.debug.assert(UI_DEV_SETUP == 0x405c5503);
    std.debug.assert(UI_DEV_CREATE == 0x5501);
}

const Uinput = struct {
    gpa: std.mem.Allocator,
    fd: i32,
};

pub const Error = error{ AccessDenied, NoUinput, Uinput };

fn check(rc: usize) Error!void {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .ACCES, .PERM => return error.AccessDenied,
        .NOENT, .NODEV, .NXIO => return error.NoUinput,
        else => return error.Uinput,
    }
}

/// A virtual keyboard with the benchmark's keys. Waits 200 ms for the
/// compositor to pick it up.
pub fn create(gpa: std.mem.Allocator, io: std.Io) !Injector {
    const rc = linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    try check(rc);
    const fd: i32 = @intCast(rc);
    errdefer _ = linux.close(fd);
    try check(linux.ioctl(fd, UI_SET_EVBIT, EV_KEY));
    for ("abcdefghijklmnopqrstuvwxyz \x08") |ch| try check(linux.ioctl(fd, UI_SET_KEYBIT, keys.keyFor(ch).evdev));
    var setup: UinputSetup = .{ .id = .{ .bustype = BUS_VIRTUAL, .vendor = 0x7a67, .product = 0x0001, .version = 1 }, .name = @splat(0), .ff_effects_max = 0 };
    @memcpy(setup.name[0.."zigguro bench-latency".len], "zigguro bench-latency");
    try check(linux.ioctl(fd, UI_DEV_SETUP, @intFromPtr(&setup)));
    try check(linux.ioctl(fd, UI_DEV_CREATE, 0));
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    const u = try gpa.create(Uinput);
    u.* = .{ .gpa = gpa, .fd = fd };
    return .{ .ptr = u, .vtable = &.{ .keyTap = keyTap, .deinit = deinit } };
}

fn emit(fd: i32, ty: u16, code: u16, value: i32) !void {
    const ev: InputEvent = .{ .sec = 0, .usec = 0, .type = ty, .code = code, .value = value };
    const bytes = std.mem.asBytes(&ev);
    try check(linux.write(fd, bytes.ptr, bytes.len));
}

fn keyTap(ptr: *anyopaque, ch: u8) anyerror!void {
    const u: *Uinput = @ptrCast(@alignCast(ptr));
    const code = keys.keyFor(ch).evdev;
    try emit(u.fd, EV_KEY, code, 1);
    try emit(u.fd, EV_SYN, SYN_REPORT, 0);
    try emit(u.fd, EV_KEY, code, 0);
    try emit(u.fd, EV_SYN, SYN_REPORT, 0);
}

fn deinit(ptr: *anyopaque) void {
    const u: *Uinput = @ptrCast(@alignCast(ptr));
    _ = linux.ioctl(u.fd, UI_DEV_DESTROY, 0);
    _ = linux.close(u.fd);
    u.gpa.destroy(u);
}
