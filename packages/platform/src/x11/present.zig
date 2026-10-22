//! The presenter for X11 windows (E01.F05.S03.T02). E02's dmabufs are
//! imported as DRI3 pixmaps and shown with Present when the server has
//! DRI3 1.2 and Present 1.2 (see `dri3.zig`); such a buffer is busy from
//! its present until the server's `IdleNotify`. CPU buffers are memfds
//! attached to the server with
//! MIT-SHM `AttachFd` when the server has MIT-SHM 1.2 on a local socket,
//! else plain memory sent with core `PutImage` in row chunks. The pixel
//! layout is DRM `ARGB8888` (B, G, R, A in memory), which is what a
//! depth-24, 32 bpp little-endian ZPixmap expects, so nothing is swizzled.
//!
//! A buffer stays busy while the server may still read it: until its
//! `ShmCompletion` arrives (SHM) and until a newer buffer is presented,
//! because the newest one repaints `Expose` damage (a pixmap's Expose
//! asks for a new frame instead).
//!
//! Threads: `present` and `allocCpuBuffer` run on the thread that renders
//! (the UI thread in `zg_gui.Host`); `pollReleased` on any thread. One
//! mutex guards the buffer list; requests go through the thread-safe
//! `Conn.request`.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const types = @import("../api/types.zig");
const surface = @import("../api/surface.zig");
const proto = @import("proto.zig");
const Conn = @import("conn.zig").Conn;
const dri3 = @import("dri3.zig");
const dmabuf = @import("../wayland/dmabuf.zig");

/// DRM fourcc `AR24`.
pub const fourcc_argb8888: u32 = 0x34325241;
/// DRM fourcc `XR24`.
pub const fourcc_xrgb8888: u32 = 0x34325258;

const log = std.log.scoped(.x11);

/// How buffers reach the server.
pub const Path = enum(u8) {
    /// MIT-SHM segments from memfds.
    shm,
    /// Core PutImage (remote displays, servers without MIT-SHM 1.2).
    put_image,
};

/// Core PutImage requests are split so each carries at most this many
/// pixel bytes.
pub const put_chunk_bytes: usize = 1 << 20;

/// One buffer.
const Buffer = struct {
    handle: u32,
    pixels: []u8,
    w: u32,
    h: u32,
    stride: u32,
    /// The SHM segment, or 0 for PutImage buffers.
    shmseg: u32 = 0,
    /// SHM completions still owed.
    inflight: u32 = 0,
    /// Released to E02 and not handed out since.
    idle: bool = true,
    /// The DRI3 pixmap of an imported dmabuf, or 0.
    pixmap: u32 = 0,
    /// The imported dmabuf's plane fds (borrowed), for implicit sync.
    dmabuf_fds: [4]i32 = .{ -1, -1, -1, -1 },
    planes: u8 = 0,
};

/// A window's presenter.
pub const Presenter = struct {
    /// The type-erased presenter handed out by `cpuPresenter`.
    presenter: surface.Presenter,
    gpa: std.mem.Allocator,
    io: Io,
    conn: *Conn,
    path: Path,
    /// The window and its GC.
    window: u32,
    gc: u32,
    depth: u8,
    win: types.WindowId,

    mutex: Io.Mutex = .init,
    buffers: std.ArrayList(Buffer) = .empty,
    released: std.ArrayList(surface.BufferHandle) = .empty,
    /// The newest presented buffer: it repaints exposed areas.
    last: ?u32 = null,
    next: u32 = 1,
    /// Row staging for PutImage.
    scratch: std.ArrayList(u8) = .empty,
    /// Presents so far.
    seq: u64 = 0,
    /// DRI3/Present support found at startup, or null (CPU only).
    gpu: ?*const dri3.Dri3 = null,
    /// The last PresentPixmap serial.
    serial: u32 = 0,
    /// Whether the CPU-wait sync fallback has been logged.
    warned_cpu_wait: bool = false,

    /// A presenter for `window`, drawing through `gc`.
    pub fn init(gpa: std.mem.Allocator, io: Io, conn: *Conn, path: Path, window: u32, gc: u32, depth: u8, win: types.WindowId) Presenter {
        return .{ .presenter = .{ .ptr = undefined, .vtable = &vtable }, .gpa = gpa, .io = io, .conn = conn, .path = path, .window = window, .gc = gc, .depth = depth, .win = win };
    }

    /// Points the type-erased presenter at `p` (once `p` has its address).
    pub fn bind(p: *Presenter) void {
        p.presenter.ptr = p;
    }

    /// Detaches and frees every buffer.
    pub fn deinit(p: *Presenter) void {
        for (p.buffers.items) |b| p.freeBuffer(b);
        p.buffers.deinit(p.gpa);
        p.released.deinit(p.gpa);
        p.scratch.deinit(p.gpa);
    }

    fn lock(p: *Presenter) void {
        p.mutex.lockUncancelable(p.io);
    }
    fn unlock(p: *Presenter) void {
        p.mutex.unlock(p.io);
    }

    fn find(p: *Presenter, handle: u32) ?*Buffer {
        for (p.buffers.items) |*b| if (b.handle == handle) return b;
        return null;
    }

    fn freeBuffer(p: *Presenter, b: Buffer) void {
        if (b.pixmap != 0) {
            _ = p.conn.request(proto.FreePixmap, .{ .pixmap = b.pixmap }, &.{}) catch {};
        } else if (b.shmseg != 0) {
            _ = p.conn.request(proto.ShmDetach, .{ .shmseg = b.shmseg }, &.{}) catch {};
            _ = linux.munmap(b.pixels.ptr, b.pixels.len);
        } else p.gpa.free(b.pixels);
    }

    /// Marks `b` released when nothing holds it any more. Mutex held.
    fn maybeRelease(p: *Presenter, b: *Buffer) void {
        if (b.idle or b.inflight != 0) return;
        if (b.pixmap == 0 and p.last == b.handle) return;
        b.idle = true;
        p.released.append(p.gpa, @enumFromInt(b.handle)) catch {};
    }

    /// An `ShmCompletion` for `shmseg` arrived (from the event dispatch).
    pub fn onShmCompletion(p: *Presenter, shmseg: u32) bool {
        p.lock();
        defer p.unlock();
        for (p.buffers.items) |*b| if (b.shmseg == shmseg) {
            if (b.inflight > 0) b.inflight -= 1;
            p.maybeRelease(b);
            return true;
        };
        return false;
    }

    /// The server is done with the pixmap `pixmap` (IdleNotify).
    pub fn onIdle(p: *Presenter, pixmap: u32) bool {
        p.lock();
        defer p.unlock();
        for (p.buffers.items) |*b| if (b.pixmap == pixmap and pixmap != 0) {
            b.inflight = 0;
            p.maybeRelease(b);
            return true;
        };
        return false;
    }

    /// Repaints `r` (window coordinates) from the newest presented CPU
    /// buffer, for `Expose`. Returns false when there is none (nothing
    /// presented yet, or the newest frame was a pixmap): the caller then
    /// asks for a frame.
    pub fn repaint(p: *Presenter, r: types.PxRect) bool {
        p.lock();
        defer p.unlock();
        const h = p.last orelse return false;
        const b = p.find(h) orelse return false;
        if (b.pixmap != 0) return false;
        p.put(b, r, false) catch |err| log.debug("expose repaint failed: {t}", .{err});
        return true;
    }

    /// Sends `r` of `b` to the window. Mutex held.
    fn put(p: *Presenter, b: *Buffer, r_in: types.PxRect, notify: bool) !void {
        const r = clip(r_in, b.w, b.h) orelse return;
        switch (p.path) {
            .shm => {
                _ = try p.conn.request(proto.ShmPutImage, .{
                    .drawable = p.window,
                    .gc = p.gc,
                    .total_width = @intCast(b.w),
                    .total_height = @intCast(b.h),
                    .src_x = @intCast(r.x),
                    .src_y = @intCast(r.y),
                    .src_width = @intCast(r.w),
                    .src_height = @intCast(r.h),
                    .dst_x = @intCast(r.x),
                    .dst_y = @intCast(r.y),
                    .depth = p.depth,
                    .send_event = notify,
                    .shmseg = b.shmseg,
                    .offset = 0,
                }, &.{});
                if (notify) b.inflight += 1;
            },
            .put_image => {
                const row_bytes = @as(usize, r.w) * 4;
                const rows_per = @max(1, put_chunk_bytes / row_bytes);
                var y: u32 = 0;
                while (y < r.h) {
                    const n: u32 = @intCast(@min(rows_per, r.h - y));
                    p.scratch.clearRetainingCapacity();
                    try p.scratch.ensureTotalCapacity(p.gpa, row_bytes * n);
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        const src = (@as(usize, @intCast(r.y)) + y + i) * b.stride + @as(usize, @intCast(r.x)) * 4;
                        p.scratch.appendSliceAssumeCapacity(b.pixels[src..][0..row_bytes]);
                    }
                    _ = try p.conn.request(proto.PutImage, .{
                        .drawable = p.window,
                        .gc = p.gc,
                        .width = @intCast(r.w),
                        .height = @intCast(n),
                        .dst_x = @intCast(r.x),
                        .dst_y = @intCast(r.y + @as(i32, @intCast(y))),
                        .depth = p.depth,
                        .pixels = p.scratch.items,
                    }, &.{});
                    y += n;
                }
            },
        }
    }
};

/// `r` clipped to a `w`×`h` buffer, or null when nothing is left.
pub fn clip(r: types.PxRect, w: u32, h: u32) ?types.PxRect {
    const x0 = std.math.clamp(r.x, 0, @as(i32, @intCast(w)));
    const y0 = std.math.clamp(r.y, 0, @as(i32, @intCast(h)));
    const x1 = std.math.clamp(@as(i64, r.x) + r.w, 0, w);
    const y1 = std.math.clamp(@as(i64, r.y) + r.h, 0, h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

/// The bounding box of `rects`.
pub fn unionOf(rects: []const types.PxRect) types.PxRect {
    var x0: i64 = std.math.maxInt(i32);
    var y0: i64 = std.math.maxInt(i32);
    var x1: i64 = std.math.minInt(i32);
    var y1: i64 = std.math.minInt(i32);
    for (rects) |r| {
        x0 = @min(x0, r.x);
        y0 = @min(y0, r.y);
        x1 = @max(x1, @as(i64, r.x) + r.w);
        y1 = @max(y1, @as(i64, r.y) + r.h);
    }
    if (x1 <= x0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
}

const vtable: surface.PresenterVTable = .{
    .drmDevice = drmDevice,
    .formats = formats,
    .syncMode = syncMode,
    .importBuffer = importBuffer,
    .present = present,
    .releaseBuffer = releaseBuffer,
    .pollReleased = pollReleased,
    .allocCpuBuffer = allocCpuBuffer,
};

fn of(ctx: *anyopaque) *Presenter {
    return @ptrCast(@alignCast(ctx));
}

fn drmDevice(ctx: *anyopaque) ?surface.DrmDevice {
    const g = of(ctx).gpu orelse return null;
    return g.device;
}

fn formats(ctx: *anyopaque, out: []surface.FormatModifier) usize {
    if (of(ctx).gpu) |g| return g.formats(out);
    const all = [_]surface.FormatModifier{ .{ .fourcc = fourcc_argb8888, .modifier = 0 }, .{ .fourcc = fourcc_xrgb8888, .modifier = 0 } };
    const n = @min(out.len, all.len);
    @memcpy(out[0..n], all[0..n]);
    return all.len;
}

fn syncMode(ctx: *anyopaque) surface.SyncMode {
    return if (of(ctx).gpu != null) .implicit_sync_file else .cpu_only;
}

fn importBuffer(ctx: *anyopaque, desc: *const surface.BufferDesc) anyerror!surface.BufferHandle {
    const p = of(ctx);
    // Shm images go through `allocCpuBuffer` on X11.
    if (desc.kind != .dmabuf or p.gpu == null) return error.Unsupported;
    if (desc.width == 0 or desc.height == 0 or desc.width > 16384 or desc.height > 16384) return error.InvalidArgument;
    if (desc.planes.len == 0 or desc.planes.len > 4) return error.InvalidArgument;
    var stride: [4]u32 = @splat(0);
    var offset: [4]u32 = @splat(0);
    var fds: [4]i32 = .{ -1, -1, -1, -1 };
    for (desc.planes, 0..) |pl, i| {
        stride[i] = pl.stride;
        offset[i] = pl.offset;
        fds[i] = pl.fd;
    }
    const pixmap = try p.conn.newXid();
    // The connection dups the fds and closes its copies once sent.
    _ = try p.conn.request(dri3.Dri3PixmapFromBuffers, .{
        .pixmap = pixmap,
        .window = p.window,
        .num_buffers = @intCast(desc.planes.len),
        .width = @intCast(desc.width),
        .height = @intCast(desc.height),
        .stride0 = stride[0],
        .offset0 = offset[0],
        .stride1 = stride[1],
        .offset1 = offset[1],
        .stride2 = stride[2],
        .offset2 = offset[2],
        .stride3 = stride[3],
        .offset3 = offset[3],
        .depth = p.depth,
        .bpp = 32,
        .modifier = desc.modifier,
    }, fds[0..desc.planes.len]);
    try p.conn.flush();
    p.lock();
    defer p.unlock();
    const buf: Buffer = .{ .handle = p.next, .pixels = &.{}, .w = desc.width, .h = desc.height, .stride = stride[0], .idle = false, .pixmap = pixmap, .dmabuf_fds = fds, .planes = @intCast(desc.planes.len) };
    p.next +%= 1;
    if (p.next == 0) p.next = 1;
    p.buffers.append(p.gpa, buf) catch |err| {
        p.freeBuffer(buf);
        return err;
    };
    return @enumFromInt(buf.handle);
}

fn allocCpuBuffer(ctx: *anyopaque, w: u32, h: u32, fourcc: u32) anyerror!surface.CpuBuffer {
    const p = of(ctx);
    if (fourcc != fourcc_argb8888 and fourcc != fourcc_xrgb8888) return error.Unsupported;
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return error.InvalidArgument;
    const stride = w * 4;
    const len = @as(usize, stride) * h;
    var buf: Buffer = .{ .handle = 0, .pixels = undefined, .w = w, .h = h, .stride = stride };
    switch (p.path) {
        .shm => {
            const fd_rc = linux.memfd_create("zg-x11-shm", linux.MFD.CLOEXEC);
            if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
            const fd: i32 = @intCast(fd_rc);
            defer _ = linux.close(fd);
            if (linux.errno(linux.ftruncate(fd, @intCast(len))) != .SUCCESS) return error.SystemResources;
            const addr = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
            if (linux.errno(addr) != .SUCCESS) return error.SystemResources;
            buf.pixels = @as([*]u8, @ptrFromInt(addr))[0..len];
            errdefer _ = linux.munmap(buf.pixels.ptr, len);
            buf.shmseg = try p.conn.newXid();
            // The connection dups the fd and closes its copy once sent.
            _ = try p.conn.request(proto.ShmAttachFd, .{ .shmseg = buf.shmseg }, &.{fd});
        },
        .put_image => buf.pixels = try p.gpa.alloc(u8, len),
    }
    p.lock();
    defer p.unlock();
    buf.handle = p.next;
    buf.idle = false;
    p.next +%= 1;
    if (p.next == 0) p.next = 1;
    p.buffers.append(p.gpa, buf) catch |err| {
        p.freeBuffer(buf);
        return err;
    };
    return .{ .handle = @enumFromInt(buf.handle), .pixels = buf.pixels, .stride = stride };
}

fn present(ctx: *anyopaque, handle: surface.BufferHandle, damage: []const types.PxRect, acquire: surface.SyncPoint, _: ?surface.ConfigureAck) anyerror!void {
    const p = of(ctx);
    switch (acquire) {
        .none => {},
        // The presenter owns the sync_file and closes it here.
        .sync_file => |sf| {
            defer _ = linux.close(sf);
            p.lock();
            const found = p.find(@intFromEnum(handle));
            const copy = if (found) |b| b.* else null;
            p.unlock();
            const b = copy orelse return error.InvalidArgument;
            // Outside the mutex: the fallback blocks.
            if (b.planes > 0) {
                if (dmabuf.importSyncFile(b.dmabuf_fds[0..b.planes], sf) == .waited and !p.warned_cpu_wait) {
                    p.warned_cpu_wait = true;
                    log.warn("DMA_BUF_IOCTL_IMPORT_SYNC_FILE unavailable; waiting on the CPU (degraded)", .{});
                }
            } else dmabuf.waitSyncFile(sf);
        },
        .syncobj => return error.Unsupported,
    }
    p.lock();
    defer p.unlock();
    const b = p.find(@intFromEnum(handle)) orelse return error.InvalidArgument;
    b.idle = false;
    if (b.pixmap != 0) {
        p.serial +%= 1;
        _ = try p.conn.request(dri3.PresentPixmap, .{ .window = p.window, .pixmap = b.pixmap, .serial = p.serial }, &.{});
        b.inflight = 1;
        p.seq += 1;
        // A CPU buffer shown before stops repainting Expose damage.
        const prev = p.last;
        p.last = b.handle;
        if (prev) |h| if (h != b.handle) if (p.find(h)) |old| p.maybeRelease(old);
        try p.conn.flush();
        return;
    }
    const full: types.PxRect = .{ .x = 0, .y = 0, .w = b.w, .h = b.h };
    // Many small rects cost more requests than one bounding box.
    if (damage.len == 0) {
        try p.put(b, full, true);
    } else if (damage.len > 16) {
        try p.put(b, unionOf(damage), true);
    } else for (damage, 0..) |r, i| try p.put(b, r, i == damage.len - 1);
    const prev = p.last;
    p.last = b.handle;
    p.seq += 1;
    if (prev) |h| if (h != b.handle) if (p.find(h)) |old| p.maybeRelease(old);
    // PutImage copies the pixels into the request: a later present may
    // reuse the buffer at once, once it is no longer the newest.
    try p.conn.flush();
}

fn releaseBuffer(ctx: *anyopaque, handle: surface.BufferHandle) void {
    const p = of(ctx);
    p.lock();
    defer p.unlock();
    for (p.buffers.items, 0..) |b, i| if (b.handle == @intFromEnum(handle)) {
        p.freeBuffer(b);
        _ = p.buffers.swapRemove(i);
        if (p.last == b.handle) p.last = null;
        p.conn.flush() catch {};
        break;
    };
    var i: usize = 0;
    while (i < p.released.items.len) {
        if (p.released.items[i] == handle) _ = p.released.swapRemove(i) else i += 1;
    }
}

fn pollReleased(ctx: *anyopaque, out: []surface.BufferHandle) usize {
    const p = of(ctx);
    p.lock();
    defer p.unlock();
    const n = @min(out.len, p.released.items.len);
    @memcpy(out[0..n], p.released.items[0..n]);
    p.released.replaceRangeAssumeCapacity(0, n, &.{});
    return n;
}

test "clip and union" {
    try std.testing.expectEqual(types.PxRect{ .x = 0, .y = 0, .w = 5, .h = 4 }, clip(.{ .x = -3, .y = -1, .w = 8, .h = 5 }, 10, 10).?);
    try std.testing.expectEqual(types.PxRect{ .x = 8, .y = 8, .w = 2, .h = 2 }, clip(.{ .x = 8, .y = 8, .w = 9, .h = 9 }, 10, 10).?);
    try std.testing.expectEqual(@as(?types.PxRect, null), clip(.{ .x = 10, .y = 0, .w = 3, .h = 3 }, 10, 10));
    try std.testing.expectEqual(@as(?types.PxRect, null), clip(.{ .x = 0, .y = 0, .w = 0, .h = 3 }, 10, 10));
    const rects = [_]types.PxRect{ .{ .x = 1, .y = 2, .w = 3, .h = 4 }, .{ .x = 10, .y = 0, .w = 1, .h = 1 } };
    try std.testing.expectEqual(types.PxRect{ .x = 1, .y = 0, .w = 10, .h = 6 }, unionOf(&rects));
}
