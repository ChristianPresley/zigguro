//! The presenter for Wayland windows: `wl_shm` buffers in memfds from
//! `allocCpuBuffer`, and E02's images through `importBuffer` (dmabuf via
//! zwp_linux_dmabuf_v1, or an shm fd). `present` attaches a sync_file
//! acquire fence (implicit sync), then acks the pending configure, sets
//! the scale, attaches, damages, asks for a frame callback and
//! presentation feedback and commits in one flush, so the compositor
//! never sees a buffer of the old size after the ack.
//!
//! CPU buffers (E01.F04.S04.T02) are carved from pools: one sealed memfd
//! (`linux/memfd.zig`) and one `wl_shm_pool` sized for a ring of
//! `ring_slots` buffers, rows padded to 64 bytes. A pool with no buffers
//! left grows in place (`wl_shm_pool.resize`, never shrinking); one that
//! still has buffers is left to drain and a new pool takes over, so a
//! mapping is never moved under pixels E02 still holds. A buffer the app
//! releases while the compositor holds it is destroyed at its
//! `wl_buffer.release`.
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
const memfd = @import("../linux/memfd.zig");

/// DRM fourcc `AR24`.
pub const fourcc_argb8888: u32 = 0x34325241;
/// DRM fourcc `XR24`.
pub const fourcc_xrgb8888: u32 = 0x34325258;

/// Buffers a new pool has room for.
pub const ring_slots = 3;

/// Slot offsets in a pool are aligned to this.
const slot_align = 64;

/// A memfd and its `wl_shm_pool`, from which `allocCpuBuffer` carves
/// buffers.
pub const Pool = struct {
    mem: memfd.Memfd,
    id: wl.wl_shm_pool.Id,
    /// Bytes handed out from the start.
    used: usize = 0,
    /// Buffers carved from it and not yet destroyed.
    live: u32 = 0,
};

/// One buffer: allocated shm, imported shm, or imported dmabuf.
pub const ShmBuffer = struct {
    /// The handle given to E02.
    handle: u32,
    /// The protocol object.
    buffer: wl.wl_buffer.Id,
    /// The pool of an `allocCpuBuffer` buffer; null for imports.
    pool: ?*Pool = null,
    /// Attached and not yet released by the compositor.
    busy: bool = false,
    /// Released by the app while busy: destroyed at `wl_buffer.release`.
    doomed: bool = false,
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
    /// CPU buffer pools; the last one is current.
    pools: std.ArrayList(*Pool) = .empty,
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
        for (p.buffers.items) |buf| wl.wl_buffer.destroy(p.b.conn, buf.buffer) catch {};
        for (p.pools.items) |pool| p.dropPool(pool);
        p.pools.deinit(gpa);
        p.buffers.deinit(gpa);
        p.released.deinit(gpa);
    }

    fn dropPool(p: *ShmPresenter, pool: *Pool) void {
        wl.wl_shm_pool.destroy(p.b.conn, pool.id) catch {};
        pool.mem.deinit();
        p.b.gpa.destroy(pool);
    }

    /// `wl_buffer.release` for `buf`: reported to E02, or the buffer is
    /// destroyed if E02 already let go of it. Backend mutex held.
    pub fn onRelease(p: *ShmPresenter, buf: *ShmBuffer) !void {
        buf.busy = false;
        if (buf.doomed) {
            const i = (@intFromPtr(buf) - @intFromPtr(p.buffers.items.ptr)) / @sizeOf(ShmBuffer);
            p.destroyAt(i);
            return;
        }
        try p.released.append(p.b.gpa, @enumFromInt(buf.handle));
    }

    /// Destroys buffer `i` and retires its pool once empty and no longer
    /// current. Backend mutex held.
    fn destroyAt(p: *ShmPresenter, i: usize) void {
        const buf = p.buffers.swapRemove(i);
        wl.wl_buffer.destroy(p.b.conn, buf.buffer) catch {};
        const pool = buf.pool orelse return;
        pool.live -= 1;
        if (pool.live > 0 or pool == p.pools.getLast()) return;
        for (p.pools.items, 0..) |x, j| if (x == pool) {
            _ = p.pools.orderedRemove(j);
            break;
        };
        p.dropPool(pool);
    }

    /// `size` bytes at a 64-byte offset in the current pool, growing it
    /// when it is empty or starting a new one when it is not. Backend
    /// mutex held.
    fn carve(p: *ShmPresenter, size: usize) !struct { pool: *Pool, offset: usize } {
        const b = p.b;
        const need = std.mem.alignForward(usize, size, slot_align);
        if (p.pools.items.len > 0) {
            const cur = p.pools.getLast();
            if (cur.used + need <= cur.mem.mem.len) {
                defer cur.used += need;
                return .{ .pool = cur, .offset = cur.used };
            }
            if (cur.live == 0) {
                // Nothing points into it: reuse from the start, larger.
                const want = need * ring_slots;
                if (want > cur.mem.mem.len) {
                    if (want > std.math.maxInt(i32)) return error.InvalidSize;
                    try cur.mem.grow(want);
                    try wl.wl_shm_pool.resize(b.conn, cur.id, @intCast(want));
                }
                cur.used = need;
                return .{ .pool = cur, .offset = 0 };
            }
        }
        const want = need * ring_slots;
        if (want > std.math.maxInt(i32)) return error.InvalidSize;
        try p.pools.ensureUnusedCapacity(b.gpa, 1);
        const pool = try b.gpa.create(Pool);
        errdefer b.gpa.destroy(pool);
        var mem = try memfd.Memfd.create("zg-shm", want);
        errdefer mem.deinit();
        const id = try b.conn.newIdVersion(wl.wl_shm_pool, b.conn.version(@intFromEnum(b.shm)), null);
        try wl.wl_shm.createPool(b.conn, b.shm, id, mem.fd, @intCast(want));
        pool.* = .{ .mem = mem, .id = id, .used = need };
        p.pools.appendAssumeCapacity(pool);
        return .{ .pool = pool, .offset = 0 };
    }

    /// The buffer whose protocol object is `id`, if this presenter owns it.
    pub fn byObject(p: *ShmPresenter, id: u32) ?*ShmBuffer {
        for (p.buffers.items) |*buf| if (@intFromEnum(buf.buffer) == id) return buf;
        return null;
    }

    fn byHandle(p: *ShmPresenter, h: surface.BufferHandle) ?usize {
        for (p.buffers.items, 0..) |buf, i| if (buf.handle == @intFromEnum(h) and !buf.doomed) return i;
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
    const stride = memfd.stride32(w);
    const size: usize = @as(usize, stride) * h;

    const b = p.b;
    b.lock();
    defer b.unlock();
    try p.buffers.ensureUnusedCapacity(b.gpa, 1);
    const slot = try p.carve(size);
    const c = b.conn;
    const buffer = try c.newIdVersion(wl.wl_buffer, c.version(@intFromEnum(slot.pool.id)), b.handler(.buffer));
    try wl.wl_shm_pool.createBuffer(c, slot.pool.id, buffer, @intCast(slot.offset), @intCast(w), @intCast(h), @intCast(stride), fmt);
    slot.pool.live += 1;
    const handle = p.next;
    p.buffers.appendAssumeCapacity(.{ .handle = handle, .buffer = buffer, .pool = slot.pool, .w = w, .h = h, .stride = stride });
    p.next += 1;
    try c.flush();
    return .{ .handle = @enumFromInt(handle), .pixels = slot.pool.mem.mem[slot.offset..][0..size], .stride = stride };
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
    const buf = &p.buffers.items[i];
    try b.presentLocked(p.win, buf.buffer, damage, if (ack) |a| a.serial else null);
    buf.busy = true;
}

fn releaseBuffer(ctx: *anyopaque, handle: surface.BufferHandle) void {
    const p = of(ctx);
    const b = p.b;
    b.lock();
    defer b.unlock();
    const i = p.byHandle(handle) orelse return;
    // The compositor may still read it: destroy it at its release.
    if (p.buffers.items[i].busy) {
        p.buffers.items[i].doomed = true;
        return;
    }
    p.destroyAt(i);
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

test "wl_shm formats are not DRM fourccs" {
    try std.testing.expectEqual(wl.wl_shm.Format.argb8888, shmFormat(fourcc_argb8888).?);
    try std.testing.expectEqual(wl.wl_shm.Format.xrgb8888, shmFormat(fourcc_xrgb8888).?);
    try std.testing.expectEqual(0, @intFromEnum(shmFormat(fourcc_argb8888).?));
    try std.testing.expectEqual(1, @intFromEnum(shmFormat(fourcc_xrgb8888).?));
    try std.testing.expectEqual(null, shmFormat(0x34325258 + 1));
}
