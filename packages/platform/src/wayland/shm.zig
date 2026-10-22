//! The CPU presenter for Wayland windows: `wl_shm` buffers in memfds.
//! `present` acks the pending configure, then sets the scale, attaches,
//! damages and commits in one flush, so the compositor never sees a
//! buffer of the old size after the ack.
//!
//! dmabuf import, explicit sync and presentation feedback belong to the
//! full presenter (E01.F04.S04); `importBuffer` reports `Unsupported`
//! until then.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl_gen");
const types = @import("../api/types.zig");
const surface = @import("../api/surface.zig");
const Backend = @import("backend.zig").WaylandBackend;

/// DRM fourcc `AR24`.
pub const fourcc_argb8888: u32 = 0x34325241;
/// DRM fourcc `XR24`.
pub const fourcc_xrgb8888: u32 = 0x34325258;

const page = std.heap.page_size_min;

/// One shm buffer.
pub const ShmBuffer = struct {
    /// The handle given to E02.
    handle: u32,
    /// The protocol object.
    buffer: wl.wl_buffer.Id,
    /// The mapping.
    mem: []align(page) u8,
    /// Width in pixels.
    w: u32,
    /// Height in pixels.
    h: u32,
    /// Bytes per row.
    stride: u32,
};

/// A window's presenter. It lives in the window's slot and dies with it.
pub const ShmPresenter = struct {
    /// The type-erased presenter handed out by `cpuPresenter`.
    presenter: surface.Presenter,
    /// The backend.
    b: *Backend,
    /// The window.
    win: types.WindowId,
    /// Live buffers. Guarded by the backend mutex.
    buffers: std.ArrayList(ShmBuffer) = .empty,
    /// Buffers the compositor released, not yet polled.
    released: std.ArrayList(surface.BufferHandle) = .empty,
    next: u32 = 1,

    /// A presenter for `win`.
    pub fn init(b: *Backend, win: types.WindowId) ShmPresenter {
        return .{ .presenter = .{ .ptr = undefined, .vtable = &vtable }, .b = b, .win = win };
    }

    /// Points the type-erased presenter at `p` (once `p` has its address).
    pub fn bind(p: *ShmPresenter) void {
        p.presenter.ptr = p;
    }

    /// Destroys every buffer. Backend mutex held.
    pub fn deinit(p: *ShmPresenter) void {
        const gpa = p.b.gpa;
        for (p.buffers.items) |buf| {
            wl.wl_buffer.destroy(p.b.conn, buf.buffer) catch {};
            std.posix.munmap(buf.mem);
        }
        p.buffers.deinit(gpa);
        p.released.deinit(gpa);
    }

    /// The buffer whose protocol object is `id`, if this presenter owns it.
    pub fn byObject(p: *ShmPresenter, id: u32) ?*ShmBuffer {
        for (p.buffers.items) |*buf| if (@intFromEnum(buf.buffer) == id) return buf;
        return null;
    }

    fn byHandle(p: *ShmPresenter, h: surface.BufferHandle) ?usize {
        for (p.buffers.items, 0..) |buf, i| if (buf.handle == @intFromEnum(h)) return i;
        return null;
    }
};

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

fn of(ctx: *anyopaque) *ShmPresenter {
    return @ptrCast(@alignCast(ctx));
}

fn drmDevice(_: *anyopaque) ?surface.DrmDevice {
    return null;
}

fn formats(_: *anyopaque, out: []surface.FormatModifier) usize {
    // Every compositor supports these two (wl_shm requires them).
    const all = [_]surface.FormatModifier{ .{ .fourcc = fourcc_argb8888, .modifier = 0 }, .{ .fourcc = fourcc_xrgb8888, .modifier = 0 } };
    const n = @min(out.len, all.len);
    @memcpy(out[0..n], all[0..n]);
    return all.len;
}

fn syncMode(_: *anyopaque) surface.SyncMode {
    return .cpu_only;
}

fn importBuffer(_: *anyopaque, _: *const surface.BufferDesc) anyerror!surface.BufferHandle {
    return error.Unsupported;
}

fn shmFormat(fourcc: u32) ?wl.wl_shm.Format {
    return switch (fourcc) {
        fourcc_argb8888 => .argb8888,
        fourcc_xrgb8888 => .xrgb8888,
        else => null,
    };
}

fn allocCpuBuffer(ctx: *anyopaque, w: u32, h: u32, fourcc: u32) anyerror!surface.CpuBuffer {
    const p = of(ctx);
    const fmt = shmFormat(fourcc) orelse return error.UnsupportedFormat;
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return error.InvalidSize;
    const stride = w * 4;
    const size: usize = @as(usize, stride) * h;

    const fd_rc = linux.memfd_create("zg-shm", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(fd_rc) != .SUCCESS) return error.SystemResources;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.SystemResources;
    const mem = try std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    errdefer std.posix.munmap(mem);

    const b = p.b;
    b.lock();
    defer b.unlock();
    const pool = try b.conn.newIdVersion(wl.wl_shm_pool, b.conn.version(@intFromEnum(b.shm)), null);
    try wl.wl_shm.createPool(b.conn, b.shm, pool, fd, @intCast(size));
    const buffer = try b.conn.newIdVersion(wl.wl_buffer, b.conn.version(@intFromEnum(pool)), b.handler(.buffer));
    try wl.wl_shm_pool.createBuffer(b.conn, pool, buffer, 0, @intCast(w), @intCast(h), @intCast(stride), fmt);
    try wl.wl_shm_pool.destroy(b.conn, pool);
    const handle = p.next;
    try p.buffers.append(b.gpa, .{ .handle = handle, .buffer = buffer, .mem = mem, .w = w, .h = h, .stride = stride });
    p.next += 1;
    try b.conn.flush();
    return .{ .handle = @enumFromInt(handle), .pixels = mem, .stride = stride };
}

fn present(ctx: *anyopaque, handle: surface.BufferHandle, damage: []const types.PxRect, acquire: surface.SyncPoint, ack: ?surface.ConfigureAck) anyerror!void {
    _ = acquire; // CPU buffers are written before present returns.
    const p = of(ctx);
    const b = p.b;
    b.lock();
    defer b.unlock();
    const i = p.byHandle(handle) orelse return error.InvalidBuffer;
    const buf = p.buffers.items[i];
    try b.presentLocked(p.win, buf.buffer, damage, if (ack) |a| a.serial else null);
}

fn releaseBuffer(ctx: *anyopaque, handle: surface.BufferHandle) void {
    const p = of(ctx);
    const b = p.b;
    b.lock();
    defer b.unlock();
    const i = p.byHandle(handle) orelse return;
    const buf = p.buffers.swapRemove(i);
    wl.wl_buffer.destroy(b.conn, buf.buffer) catch {};
    std.posix.munmap(buf.mem);
    b.conn.flush() catch {};
}

fn pollReleased(ctx: *anyopaque, out: []surface.BufferHandle) usize {
    const p = of(ctx);
    const b = p.b;
    b.lock();
    defer b.unlock();
    const n = @min(out.len, p.released.items.len);
    @memcpy(out[0..n], p.released.items[0..n]);
    p.released.replaceRangeAssumeCapacity(0, n, &.{});
    return n;
}
