//! The presenter for Wayland windows: `wl_shm` buffers in memfds from
//! `allocCpuBuffer`, and E02's images through `importBuffer` (dmabuf via
//! zwp_linux_dmabuf_v1, or an shm fd). `present` attaches a sync_file
//! acquire fence (implicit sync), then acks the pending configure, sets
//! the scale, attaches, damages, asks for a frame callback and
//! presentation feedback and commits in one flush, so the compositor
//! never sees a buffer of the old size after the ack.
//!
//! Explicit sync (wp_linux_drm_syncobj_v1) needs a release timeline the
//! presenter contract does not carry yet; a `.syncobj` acquire point is
//! `error.Unsupported`.

const std = @import("std");
const linux = std.os.linux;
const wl = @import("wl_gen");
const types = @import("../api/types.zig");
const surface = @import("../api/surface.zig");
const Backend = @import("backend.zig").WaylandBackend;
const dmabuf = @import("dmabuf.zig");

/// DRM fourcc `AR24`.
pub const fourcc_argb8888: u32 = 0x34325241;
/// DRM fourcc `XR24`.
pub const fourcc_xrgb8888: u32 = 0x34325258;

const page = std.heap.page_size_min;

/// One buffer: allocated shm, imported shm, or imported dmabuf.
pub const ShmBuffer = struct {
    /// The handle given to E02.
    handle: u32,
    /// The protocol object.
    buffer: wl.wl_buffer.Id,
    /// The mapping of an `allocCpuBuffer` buffer; null for imports.
    mem: ?[]align(page) u8 = null,
    /// An imported dmabuf's plane fds (borrowed from E02), for implicit
    /// sync.
    dmabuf_fds: [4]i32 = .{ -1, -1, -1, -1 },
    /// How many `dmabuf_fds` are set; 0 for shm.
    planes: u8 = 0,
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
    /// Whether the CPU-wait fallback has been logged.
    warned_cpu_wait: bool = false,

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
            if (buf.mem) |m| std.posix.munmap(m);
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

fn drmDevice(ctx: *anyopaque) ?surface.DrmDevice {
    const b = of(ctx).b;
    b.lock();
    defer b.unlock();
    return b.feedback.device;
}

fn formats(ctx: *anyopaque, out: []surface.FormatModifier) usize {
    const b = of(ctx).b;
    b.lock();
    defer b.unlock();
    // With dmabuf, the compositor's list in preference order.
    if (b.dmabuf != null and b.feedback.formats.items.len > 0) return b.feedback.copyFormats(out);
    // Every compositor supports these two (wl_shm requires them).
    const all = [_]surface.FormatModifier{ .{ .fourcc = fourcc_argb8888, .modifier = 0 }, .{ .fourcc = fourcc_xrgb8888, .modifier = 0 } };
    const n = @min(out.len, all.len);
    @memcpy(out[0..n], all[0..n]);
    return all.len;
}

fn syncMode(ctx: *anyopaque) surface.SyncMode {
    const b = of(ctx).b;
    return if (b.dmabuf != null) .implicit_sync_file else .cpu_only;
}

fn importBuffer(ctx: *anyopaque, desc: *const surface.BufferDesc) anyerror!surface.BufferHandle {
    const p = of(ctx);
    const b = p.b;
    const c = b.conn;
    if (desc.width == 0 or desc.height == 0 or desc.width > 16384 or desc.height > 16384) return error.InvalidSize;
    if (desc.planes.len == 0 or desc.planes.len > 4) return error.InvalidBuffer;
    b.lock();
    defer b.unlock();
    try p.buffers.ensureUnusedCapacity(b.gpa, 1);
    var entry: ShmBuffer = .{ .handle = p.next, .buffer = undefined, .w = desc.width, .h = desc.height, .stride = desc.planes[0].stride };
    switch (desc.kind) {
        .dmabuf => {
            const dm = b.dmabuf orelse return error.Unsupported;
            const params = try c.newIdVersion(wl.zwp_linux_buffer_params_v1, c.version(@intFromEnum(dm)), null);
            try wl.zwp_linux_dmabuf_v1.createParams(c, dm, params);
            const hi: u32 = @truncate(desc.modifier >> 32);
            const lo: u32 = @truncate(desc.modifier);
            for (desc.planes, 0..) |pl, i| {
                try wl.zwp_linux_buffer_params_v1.add(c, params, pl.fd, @intCast(i), pl.offset, pl.stride, hi, lo);
                entry.dmabuf_fds[i] = pl.fd;
            }
            entry.planes = @intCast(desc.planes.len);
            entry.buffer = try c.newIdVersion(wl.wl_buffer, 1, b.handler(.buffer));
            try wl.zwp_linux_buffer_params_v1.createImmed(c, params, entry.buffer, @intCast(desc.width), @intCast(desc.height), desc.fourcc, .{});
            try wl.zwp_linux_buffer_params_v1.destroy(c, params);
        },
        .shm => {
            const fmt = shmFormat(desc.fourcc) orelse return error.UnsupportedFormat;
            const pl = desc.planes[0];
            const size = @as(u64, pl.offset) + @as(u64, pl.stride) * desc.height;
            if (size > std.math.maxInt(i32)) return error.InvalidSize;
            const pool = try c.newIdVersion(wl.wl_shm_pool, c.version(@intFromEnum(b.shm)), null);
            try wl.wl_shm.createPool(c, b.shm, pool, pl.fd, @intCast(size));
            entry.buffer = try c.newIdVersion(wl.wl_buffer, c.version(@intFromEnum(pool)), b.handler(.buffer));
            try wl.wl_shm_pool.createBuffer(c, pool, entry.buffer, @intCast(pl.offset), @intCast(desc.width), @intCast(desc.height), @intCast(pl.stride), fmt);
            try wl.wl_shm_pool.destroy(c, pool);
        },
    }
    p.buffers.appendAssumeCapacity(entry);
    p.next += 1;
    try c.flush();
    return @enumFromInt(entry.handle);
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
    const p = of(ctx);
    const b = p.b;
    switch (acquire) {
        .none => {},
        // The presenter owns the sync_file and closes it here.
        .sync_file => |sf| {
            defer _ = linux.close(sf);
            b.lock();
            const i = p.byHandle(handle);
            const buf = if (i) |x| p.buffers.items[x] else null;
            b.unlock();
            const bf = buf orelse return error.InvalidBuffer;
            // Imported outside the mutex: the fallback blocks.
            if (bf.planes > 0) {
                if (dmabuf.importSyncFile(bf.dmabuf_fds[0..bf.planes], sf) == .waited and !p.warned_cpu_wait) {
                    p.warned_cpu_wait = true;
                    std.log.scoped(.wayland).warn("DMA_BUF_IOCTL_IMPORT_SYNC_FILE unavailable; waiting on the CPU (degraded)", .{});
                }
            } else dmabuf.waitSyncFile(sf);
        },
        .syncobj => return error.Unsupported,
    }
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
    if (buf.mem) |m| std.posix.munmap(m);
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
