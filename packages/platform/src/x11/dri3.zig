//! DRI3 and Present for the X11 presenter (E01.F05.S03.T02, the GPU
//! path): the requests, replies and events we use, and the startup probe
//! that finds the server's DRM device and modifiers. E02's dmabufs become
//! pixmaps with `PixmapFromBuffers` and reach the window with
//! `PresentPixmap`; `IdleNotify` releases them and `CompleteNotify`
//! reports when they were shown.
//!
//! Requires DRI3 1.2 (modifiers, multi-plane pixmaps) and Present 1.2.
//! Explicit sync (`PresentPixmapSynced`, DRI3 1.4 `ImportSyncobj`) waits
//! for a release point in the presenter contract.

const std = @import("std");
const linux = std.os.linux;
const surface = @import("../api/surface.zig");
const proto = @import("proto.zig");
const Conn = @import("conn.zig").Conn;
const Cookie = @import("conn.zig").Cookie;
const FdQueue = @import("../wayland/wire/fdqueue.zig").FdQueue;
const decodeDev = @import("../wayland/dmabuf.zig").decodeDev;

const DecodeError = proto.DecodeError;
const le = std.builtin.Endian.little;

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], le);
}
fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], le);
}
fn u64At(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], le);
}

/// A `major.minor` version reply (DRI3 and Present share the layout).
pub const VersionReply = struct {
    major: u32,
    minor: u32,
    /// Decodes the reply from its wire bytes.
    pub fn decode(b: []const u8, _: *FdQueue) DecodeError!VersionReply {
        if (b.len < 32) return error.Malformed;
        return .{ .major = u32At(b, 8), .minor = u32At(b, 12) };
    }

    /// Whether this is at least `major.minor`.
    pub fn atLeast(v: VersionReply, major: u32, minor: u32) bool {
        return v.major > major or (v.major == major and v.minor >= minor);
    }
};

/// DRI3 QueryVersion.
pub const Dri3QueryVersion = struct {
    /// The extension that owns this request.
    pub const extension = "DRI3";
    /// The minor opcode.
    pub const minor = 0;
    major_version: u32 = 1,
    minor_version: u32 = 4,
    /// The server's DRI3 version.
    pub const Reply = VersionReply;
};

/// DRI3 Open: the server's DRM device for `drawable`'s screen, as an fd.
pub const Dri3Open = struct {
    /// The extension that owns this request.
    pub const extension = "DRI3";
    /// The minor opcode.
    pub const minor = 1;
    drawable: u32,
    provider: u32 = 0,

    /// The device fd (ours to close).
    pub const Reply = struct {
        fd: i32,
        /// Decodes the reply from its wire bytes; takes the passed fd.
        pub fn decode(b: []const u8, fds: *FdQueue) DecodeError!Reply {
            if (b.len < 32 or b[1] != 1) return error.Malformed;
            return .{ .fd = fds.pop() orelse return error.Malformed };
        }
    };
};

/// DRI3 GetSupportedModifiers (1.2).
pub const Dri3GetSupportedModifiers = struct {
    /// The extension that owns this request.
    pub const extension = "DRI3";
    /// The minor opcode.
    pub const minor = 6;
    window: u32,
    depth: u8,
    bpp: u8,
    _pad: [2]u8 = .{ 0, 0 },

    /// Modifiers for the window, then for the screen (views into the
    /// reply, little-endian u64s).
    pub const Reply = struct {
        window: []const u8,
        screen: []const u8,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            const nw: usize = u32At(b, 8);
            const ns: usize = u32At(b, 12);
            if (nw > 4096 or ns > 4096 or b.len < 32 + (nw + ns) * 8) return error.Malformed;
            return .{ .window = b[32..][0 .. nw * 8], .screen = b[32 + nw * 8 ..][0 .. ns * 8] };
        }
    };
};

/// DRI3 PixmapFromBuffers (1.2): a pixmap over up to four dmabuf planes,
/// one fd each, sent with the request.
pub const Dri3PixmapFromBuffers = struct {
    /// The extension that owns this request.
    pub const extension = "DRI3";
    /// The minor opcode.
    pub const minor = 7;
    pixmap: u32,
    window: u32,
    num_buffers: u8,
    _pad0: [3]u8 = .{ 0, 0, 0 },
    width: u16,
    height: u16,
    stride0: u32,
    offset0: u32,
    stride1: u32 = 0,
    offset1: u32 = 0,
    stride2: u32 = 0,
    offset2: u32 = 0,
    stride3: u32 = 0,
    offset3: u32 = 0,
    depth: u8,
    bpp: u8,
    _pad1: [2]u8 = .{ 0, 0 },
    modifier: u64,
};

/// Present QueryVersion.
pub const PresentQueryVersion = struct {
    /// The extension that owns this request.
    pub const extension = "Present";
    /// The minor opcode.
    pub const minor = 0;
    major_version: u32 = 1,
    minor_version: u32 = 4,
    /// The server's Present version.
    pub const Reply = VersionReply;
};

/// Present Pixmap: shows `pixmap` in `window` (at the next vblank with
/// `options = 0`).
pub const PresentPixmap = struct {
    /// The extension that owns this request.
    pub const extension = "Present";
    /// The minor opcode.
    pub const minor = 1;
    window: u32,
    pixmap: u32,
    serial: u32,
    /// XFIXES region of valid contents; 0 is all.
    valid: u32 = 0,
    /// XFIXES region to update; 0 is all.
    update: u32 = 0,
    x_off: i16 = 0,
    y_off: i16 = 0,
    target_crtc: u32 = 0,
    wait_fence: u32 = 0,
    idle_fence: u32 = 0,
    options: u32 = 0,
    _pad: [4]u8 = .{ 0, 0, 0, 0 },
    target_msc: u64 = 0,
    divisor: u64 = 0,
    remainder: u64 = 0,
};

/// Present SelectInput.
pub const PresentSelectInput = struct {
    /// The extension that owns this request.
    pub const extension = "Present";
    /// The minor opcode.
    pub const minor = 3;
    eid: u32,
    window: u32,
    event_mask: u32,
};

/// `PresentSelectInput` mask bits.
pub const EventMask = struct {
    /// ConfigureNotify.
    pub const configure: u32 = 1;
    /// CompleteNotify.
    pub const complete: u32 = 2;
    /// IdleNotify.
    pub const idle: u32 = 4;
};

/// Present event types (GenericEvent `evtype`).
pub const EventType = struct {
    /// ConfigureNotify.
    pub const configure: u16 = 0;
    /// CompleteNotify.
    pub const complete: u16 = 1;
    /// IdleNotify.
    pub const idle: u16 = 2;
};

/// CompleteNotify modes.
pub const CompleteMode = enum(u8) { copy = 0, flip = 1, skip = 2, suboptimal_copy = 3, _ };

/// A decoded Present event.
pub const Event = union(enum) {
    /// A PresentPixmap finished: shown at `ust` (µs, CLOCK_MONOTONIC) on
    /// vblank `msc`.
    complete: struct { window: u32, serial: u32, ust: u64, msc: u64, mode: CompleteMode, is_pixmap: bool },
    /// The server no longer reads `pixmap`.
    idle: struct { window: u32, serial: u32, pixmap: u32 },
    /// Anything else (ConfigureNotify, RedirectNotify).
    other,
};

/// Decodes a Present GenericEvent (byte 1 must be Present's opcode).
pub fn decodeEvent(ev: []const u8) ?Event {
    if (ev.len < 32) return null;
    return switch (u16At(ev, 8)) {
        EventType.complete => if (ev.len < 40) null else .{ .complete = .{
            .is_pixmap = ev[10] == 0,
            .mode = @enumFromInt(ev[11]),
            .window = u32At(ev, 16),
            .serial = u32At(ev, 20),
            .ust = u64At(ev, 24),
            .msc = u64At(ev, 32),
        } },
        EventType.idle => .{ .idle = .{ .window = u32At(ev, 16), .serial = u32At(ev, 20), .pixmap = u32At(ev, 24) } },
        else => .other,
    };
}

/// What the startup probe found.
pub const Dri3 = struct {
    /// The server's DRM device, from DRI3 Open.
    device: ?surface.DrmDevice,
    /// Modifiers for XRGB8888/ARGB8888 at depth 24, 32 bpp.
    modifiers: []u64,
    /// Present's major opcode, to match its GenericEvents.
    present_opcode: u8,

    /// Frees the modifier list.
    pub fn deinit(d: *Dri3, gpa: std.mem.Allocator) void {
        gpa.free(d.modifiers);
    }

    /// Writes (fourcc, modifier) pairs into `out`: XRGB8888 then
    /// ARGB8888 for each modifier. Returns the total.
    pub fn formats(d: *const Dri3, out: []surface.FormatModifier) usize {
        const fourccs = [_]u32{ 0x34325258, 0x34325241 };
        var n: usize = 0;
        for (d.modifiers) |m| for (fourccs) |f| {
            if (n < out.len) out[n] = .{ .fourcc = f, .modifier = m };
            n += 1;
        };
        return n;
    }
};

/// The probe's requests in flight.
pub const Probe = struct {
    dri3_version: Cookie(Dri3QueryVersion),
    present_version: Cookie(PresentQueryVersion),
    open: Cookie(Dri3Open),
    modifiers: Cookie(Dri3GetSupportedModifiers),
    present_opcode: u8,

    /// Sends the probe's requests (pipelined); null when the server lacks
    /// DRI3 or Present.
    pub fn send(c: *Conn, root: u32) !?Probe {
        _ = c.extension("DRI3") orelse return null;
        const present = c.extension("Present") orelse return null;
        return .{
            .dri3_version = try c.request(Dri3QueryVersion, .{}, &.{}),
            .present_version = try c.request(PresentQueryVersion, .{}, &.{}),
            .open = try c.request(Dri3Open, .{ .drawable = root }, &.{}),
            .modifiers = try c.request(Dri3GetSupportedModifiers, .{ .window = root, .depth = 24, .bpp = 32 }, &.{}),
            .present_opcode = present.major_opcode,
        };
    }

    /// Reads the replies. Null when a version is too old, DRI3 Open
    /// fails (no DRM device, a remote client) or no modifier is offered.
    pub fn finish(p: Probe, gpa: std.mem.Allocator, c: *Conn) !?Dri3 {
        // Every reply is read so none is left behind.
        const dv = c.reply(p.dri3_version) catch null;
        const pv = c.reply(p.present_version) catch null;
        const open = c.reply(p.open) catch null;
        var device: ?surface.DrmDevice = null;
        if (open) |o| {
            device = deviceOf(o.fd);
            _ = linux.close(o.fd);
        }
        const mods = c.reply(p.modifiers) catch null;
        if (dv == null or !dv.?.atLeast(1, 2) or pv == null or !pv.?.atLeast(1, 2) or open == null) return null;
        const r = mods orelse return null;
        const src = if (r.window.len > 0) r.window else r.screen;
        if (src.len == 0) return null;
        const list = try gpa.alloc(u64, src.len / 8);
        for (list, 0..) |*m, i| m.* = u64At(src, i * 8);
        return .{ .device = device, .modifiers = list, .present_opcode = p.present_opcode };
    }
};

/// The DRM device behind `fd` (its `st_rdev`).
fn deviceOf(fd: i32) ?surface.DrmDevice {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &st)) != .SUCCESS) return null;
    return .{ .major = st.rdev_major, .minor = st.rdev_minor };
}

// ---- tests ----

const testing = std.testing;
const FakeServer = @import("testing/fake_server.zig").FakeServer;
const ext = @import("ext.zig");

test "PixmapFromBuffers and PresentPixmap request layouts" {
    var buf: [128]u8 = undefined;
    const n = try proto.writeRequest(&buf, Dri3PixmapFromBuffers, .{
        .pixmap = 0x400010,
        .window = 0x400001,
        .num_buffers = 2,
        .width = 640,
        .height = 480,
        .stride0 = 2560,
        .offset0 = 0,
        .stride1 = 1280,
        .offset1 = 4096,
        .depth = 24,
        .bpp = 32,
        .modifier = 0x0100_0000_0000_0002,
    }, 149, false);
    try testing.expectEqual(64, n);
    try testing.expectEqual(149, buf[0]);
    try testing.expectEqual(7, buf[1]);
    try testing.expectEqual(16, u16At(&buf, 2));
    try testing.expectEqual(0x400010, u32At(&buf, 4));
    try testing.expectEqual(2, buf[12]);
    try testing.expectEqual(640, u16At(&buf, 16));
    try testing.expectEqual(2560, u32At(&buf, 20));
    try testing.expectEqual(1280, u32At(&buf, 28));
    try testing.expectEqual(4096, u32At(&buf, 32));
    try testing.expectEqual(24, buf[52]);
    try testing.expectEqual(32, buf[53]);
    try testing.expectEqual(0x0100_0000_0000_0002, u64At(&buf, 56));

    const m = try proto.writeRequest(&buf, PresentPixmap, .{ .window = 1, .pixmap = 2, .serial = 3 }, 148, false);
    try testing.expectEqual(72, m);
    try testing.expectEqual(1, buf[1]);
    try testing.expectEqual(18, u16At(&buf, 2));
    try testing.expectEqual(3, u32At(&buf, 12));
    try testing.expectEqual(0, u32At(&buf, 40)); // options: vsync
}

test "decode CompleteNotify and IdleNotify" {
    var ev: [40]u8 = @splat(0);
    ev[0] = proto.generic_event;
    ev[1] = 148;
    std.mem.writeInt(u32, ev[4..8], 2, le);
    std.mem.writeInt(u16, ev[8..10], EventType.complete, le);
    ev[11] = @intFromEnum(CompleteMode.flip);
    std.mem.writeInt(u32, ev[16..20], 0x400001, le);
    std.mem.writeInt(u32, ev[20..24], 9, le);
    std.mem.writeInt(u64, ev[24..32], 123_456, le);
    std.mem.writeInt(u64, ev[32..40], 77, le);
    const c = decodeEvent(&ev).?.complete;
    try testing.expect(c.is_pixmap);
    try testing.expectEqual(CompleteMode.flip, c.mode);
    try testing.expectEqual(@as(u32, 9), c.serial);
    try testing.expectEqual(@as(u64, 123_456), c.ust);
    try testing.expectEqual(@as(u64, 77), c.msc);

    std.mem.writeInt(u16, ev[8..10], EventType.idle, le);
    std.mem.writeInt(u32, ev[24..28], 0x400010, le);
    const i = decodeEvent(ev[0..32]).?.idle;
    try testing.expectEqual(@as(u32, 0x400010), i.pixmap);
}

/// A reply with `w8` and `w12` at offsets 8 and 12 and `extra` after
/// the header.
fn sendReply2(fs: *FakeServer, seq: u16, data: u8, w8: u32, w12: u32, extra: []const u8, fds: []const i32) !void {
    var buf: [32 + 64]u8 = @splat(0);
    buf[0] = 1;
    buf[1] = data;
    std.mem.writeInt(u16, buf[2..4], seq, le);
    std.mem.writeInt(u32, buf[4..8], @intCast(extra.len / 4), le);
    std.mem.writeInt(u32, buf[8..12], w8, le);
    std.mem.writeInt(u32, buf[12..16], w12, le);
    @memcpy(buf[32..][0..extra.len], extra);
    try fs.sendBytes(buf[0 .. 32 + extra.len], fds);
}

test "probe: versions, device and modifiers" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    // No extensions: nothing to probe.
    try testing.expectEqual(@as(?Probe, null), try Probe.send(c, 0x3d7));
    c.extensions[ext.index("DRI3").?] = .{ .major_opcode = 149, .first_event = 0, .first_error = 0 };
    c.extensions[ext.index("Present").?] = .{ .major_opcode = 148, .first_event = 0, .first_error = 0 };

    const p = (try Probe.send(c, 0x3d7)).?;
    try c.flush();
    // A memfd stands in for the DRM node (no rdev: device stays null).
    const dev_fd: i32 = @intCast(linux.memfd_create("zg-test-drm", linux.MFD.CLOEXEC));
    defer _ = linux.close(dev_fd);
    var mods: [16]u8 = undefined;
    std.mem.writeInt(u64, mods[0..8], 0x0100_0000_0000_0001, le);
    std.mem.writeInt(u64, mods[8..16], 0, le);
    try sendReply2(fs, 1, 0, 1, 4, "", &.{});
    try sendReply2(fs, 2, 0, 1, 2, "", &.{});
    try sendReply2(fs, 3, 1, 0, 0, "", &.{dev_fd});
    try sendReply2(fs, 4, 0, 0, 2, &mods, &.{});
    var d = (try p.finish(testing.allocator, c)).?;
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 148), d.present_opcode);
    try testing.expectEqual(surface.DrmDevice{ .major = 0, .minor = 0 }, d.device.?);
    var out: [8]surface.FormatModifier = undefined;
    try testing.expectEqual(@as(usize, 4), d.formats(&out));
    try testing.expectEqual(surface.FormatModifier{ .fourcc = 0x34325258, .modifier = 0x0100_0000_0000_0001 }, out[0]);
    try testing.expectEqual(surface.FormatModifier{ .fourcc = 0x34325241, .modifier = 0 }, out[3]);
}

test "probe: DRI3 1.0 is not enough" {
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    c.extensions[ext.index("DRI3").?] = .{ .major_opcode = 149, .first_event = 0, .first_error = 0 };
    c.extensions[ext.index("Present").?] = .{ .major_opcode = 148, .first_event = 0, .first_error = 0 };
    const p = (try Probe.send(c, 0x3d7)).?;
    try c.flush();
    try sendReply2(fs, 1, 0, 1, 0, "", &.{});
    try sendReply2(fs, 2, 0, 1, 2, "", &.{});
    // Open fails (no DRM device); GetSupportedModifiers is a BadRequest.
    try fs.sendError(3, 8, 149, 0);
    try fs.sendError(4, 1, 149, 0);
    try testing.expectEqual(@as(?Dri3, null), try p.finish(testing.allocator, c));
}

test "presenter: import as a pixmap, PresentPixmap, IdleNotify releases" {
    const present_mod = @import("present.zig");
    const fs = try FakeServer.init(testing.allocator);
    defer fs.deinit();
    const c = try fs.connect();
    defer c.deinit();
    c.extensions[ext.index("DRI3").?] = .{ .major_opcode = 149, .first_event = 0, .first_error = 0 };
    c.extensions[ext.index("Present").?] = .{ .major_opcode = 148, .first_event = 0, .first_error = 0 };
    var mods = [_]u64{0};
    const gpu: Dri3 = .{ .device = .{ .major = 226, .minor = 128 }, .modifiers = &mods, .present_opcode = 148 };
    var p = present_mod.Presenter.init(testing.allocator, testing.io, c, .put_image, 0x400100, 0x400101, 24, @enumFromInt(1));
    p.bind();
    p.gpu = &gpu;
    defer p.deinit();
    const pr = &p.presenter;
    try testing.expectEqual(surface.SyncMode.implicit_sync_file, pr.syncMode());
    try testing.expectEqual(surface.DrmDevice{ .major = 226, .minor = 128 }, pr.drmDevice().?);

    const buf_fd: i32 = @intCast(linux.memfd_create("zg-test-dmabuf", linux.MFD.CLOEXEC));
    defer _ = linux.close(buf_fd);
    const planes = [_]surface.Plane{.{ .fd = buf_fd, .offset = 0, .stride = 256 }};
    const h = try pr.importBuffer(&.{ .width = 64, .height = 32, .fourcc = 0x34325258, .modifier = 0, .planes = &planes, .kind = .dmabuf });
    try testing.expectError(error.Unsupported, pr.importBuffer(&.{ .width = 64, .height = 32, .fourcc = 0x34325258, .modifier = 0, .planes = &planes, .kind = .shm }));

    var sink: [4096]u8 = undefined;
    var got = try fs.recvAvailable(&sink);
    try testing.expectEqual(@as(u8, 149), got[0]);
    try testing.expectEqual(@as(u8, 7), got[1]);
    try testing.expectEqual(@as(u32, 64), u32At(got, 0) >> 16 << 2);
    try testing.expectEqual(@as(usize, 1), fs.fds.count());
    fs.fds.closeAll();
    const pixmap = u32At(got, 4);

    // A signalled eventfd as the sync_file: the import ioctl fails on a
    // memfd, so the presenter waits on it, then closes it.
    const sync_fd: i32 = @intCast(linux.eventfd(1, linux.EFD.CLOEXEC));
    try pr.present(h, &.{}, .{ .sync_file = sync_fd }, null);
    try testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(sync_fd, linux.F.GETFD, 0)));
    got = try fs.recvAvailable(&sink);
    try testing.expectEqual(@as(u8, 148), got[0]);
    try testing.expectEqual(@as(u8, 1), got[1]);
    try testing.expectEqual(pixmap, u32At(got, 8));
    try testing.expectEqual(@as(u32, 1), u32At(got, 12));

    var rel: [2]surface.BufferHandle = undefined;
    try testing.expectEqual(@as(usize, 0), pr.pollReleased(&rel));
    try testing.expect(p.onIdle(pixmap));
    try testing.expectEqual(@as(usize, 1), pr.pollReleased(&rel));
    try testing.expectEqual(h, rel[0]);
    // An Expose with a pixmap as the newest frame asks for a new frame.
    try testing.expect(!p.repaint(.{ .x = 0, .y = 0, .w = 8, .h = 8 }));
    pr.releaseBuffer(h);
    got = try fs.recvAvailable(&sink);
    try testing.expectEqual(@as(u8, proto.FreePixmap.opcode), got[0]);
}
