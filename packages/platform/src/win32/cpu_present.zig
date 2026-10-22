//! The Win32 CPU presenter (E01.F02.S05.T01): buffers are top-down 32 bpp
//! DIB sections, so E02's software renderer writes B, G, R, A bytes, which
//! is DRM `ARGB8888` and needs no swizzle. `present` copies the damaged
//! rects to the window with `BitBlt` on the calling thread (GDI allows a
//! window DC from any thread) and keeps the buffer as the newest one, which
//! `WM_PAINT` replays on the platform thread. A buffer is released when a
//! newer one is presented.
//!
//! Differences from the task text, for now: the blit happens in `present`
//! rather than through a `WM_APP_PRESENT` mailbox, and frame pacing is the
//! backend's refresh timer, not a high-resolution waitable timer.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const types = @import("../api/types.zig");
const surface = @import("../api/surface.zig");
const t = @import("bindings/types.zig");
const msgs = @import("msgs.zig");

const is_windows = builtin.os.tag == .windows;
const user32 = if (is_windows) @import("bindings/user32.zig") else struct {};
const gdi32 = if (is_windows) @import("bindings/gdi32.zig") else struct {};

/// DRM fourcc `AR24`.
pub const fourcc_argb8888: u32 = 0x34325241;
/// DRM fourcc `XR24`.
pub const fourcc_xrgb8888: u32 = 0x34325258;

/// More damage rects than this are blitted as their union.
pub const max_rects = 16;

const Buffer = struct {
    handle: u32,
    hbm: t.HBITMAP,
    pixels: []u8,
    w: u32,
    h: u32,
    /// Handed to E02 and not released since.
    busy: bool = true,
};

/// A window's presenter.
pub const CpuPresenter = struct {
    /// The type-erased presenter handed out by `cpuPresenter`.
    presenter: surface.Presenter,
    gpa: std.mem.Allocator,
    io: Io,
    hwnd: ?t.HWND = null,

    mutex: Io.Mutex = .init,
    buffers: std.ArrayList(Buffer) = .empty,
    released: std.ArrayList(surface.BufferHandle) = .empty,
    last: ?u32 = null,
    next: u32 = 1,
    /// Presents so far.
    seq: u64 = 0,

    /// A presenter; `bind` it once it has its final address.
    pub fn init(gpa: std.mem.Allocator, io: Io) CpuPresenter {
        return .{ .presenter = .{ .ptr = undefined, .vtable = &vtable }, .gpa = gpa, .io = io };
    }

    /// Points the type-erased presenter at `p`.
    pub fn bind(p: *CpuPresenter) void {
        p.presenter.ptr = p;
    }

    /// Frees every buffer.
    pub fn deinit(p: *CpuPresenter) void {
        for (p.buffers.items) |b| freeBuffer(b);
        p.buffers.deinit(p.gpa);
        p.released.deinit(p.gpa);
    }

    fn lock(p: *CpuPresenter) void {
        p.mutex.lockUncancelable(p.io);
    }
    fn unlock(p: *CpuPresenter) void {
        p.mutex.unlock(p.io);
    }

    fn find(p: *CpuPresenter, handle: u32) ?*Buffer {
        for (p.buffers.items) |*b| if (b.handle == handle) return b;
        return null;
    }

    /// Repaints `r` of the window from the newest buffer into `hdc` (from
    /// `BeginPaint`). Black where nothing was presented yet, so a new
    /// window never flashes white.
    pub fn paint(p: *CpuPresenter, hdc: t.HDC, r: t.RECT) void {
        if (!is_windows) return;
        p.lock();
        defer p.unlock();
        const b = if (p.last) |h| p.find(h) else null;
        if (b) |buf| {
            blit(hdc, buf, .{ .x = r.left, .y = r.top, .w = @intCast(@max(0, r.right - r.left)), .h = @intCast(@max(0, r.bottom - r.top)) });
        } else {
            _ = gdi32.BitBlt(hdc, r.left, r.top, r.right - r.left, r.bottom - r.top, null, 0, 0, msgs.BLACKNESS);
        }
    }
};

fn freeBuffer(b: Buffer) void {
    if (is_windows) _ = gdi32.DeleteObject(@ptrCast(b.hbm));
}

/// Copies `r` (clipped to the buffer) of `b` into `hdc`.
fn blit(hdc: t.HDC, b: *const Buffer, r: types.PxRect) void {
    if (!is_windows) return;
    const c = clip(r, b.w, b.h) orelse return;
    const mem = gdi32.CreateCompatibleDC(hdc) orelse return;
    defer _ = gdi32.DeleteDC(mem);
    const old = gdi32.SelectObject(mem, @ptrCast(b.hbm));
    _ = gdi32.BitBlt(hdc, c.x, c.y, @intCast(c.w), @intCast(c.h), mem, c.x, c.y, msgs.SRCCOPY);
    if (old) |o| _ = gdi32.SelectObject(mem, o);
}

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

/// The `BITMAPINFO` of a top-down 32 bpp DIB of `w`×`h`.
pub fn dibInfo(w: u32, h: u32) t.BITMAPINFO {
    return .{ .bmiHeader = .{ .biWidth = @intCast(w), .biHeight = -@as(i32, @intCast(h)), .biBitCount = 32, .biCompression = msgs.BI_RGB } };
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

fn of(ctx: *anyopaque) *CpuPresenter {
    return @ptrCast(@alignCast(ctx));
}

fn drmDevice(_: *anyopaque) ?surface.DrmDevice {
    return null;
}

fn formats(_: *anyopaque, out: []surface.FormatModifier) usize {
    if (out.len > 0) out[0] = .{ .fourcc = fourcc_argb8888, .modifier = 0 };
    return 1;
}

fn syncMode(_: *anyopaque) surface.SyncMode {
    return .cpu_only;
}

fn importBuffer(_: *anyopaque, _: *const surface.BufferDesc) anyerror!surface.BufferHandle {
    return error.Unsupported;
}

fn allocCpuBuffer(ctx: *anyopaque, w: u32, h: u32, fourcc: u32) anyerror!surface.CpuBuffer {
    if (!is_windows) return error.Unsupported;
    const p = of(ctx);
    if (fourcc != fourcc_argb8888 and fourcc != fourcc_xrgb8888) return error.Unsupported;
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return error.InvalidArgument;
    const bmi = dibInfo(w, h);
    var bits: ?*anyopaque = null;
    const hbm = gdi32.CreateDIBSection(null, &bmi, msgs.DIB_RGB_COLORS, &bits, null, 0) orelse return error.SystemResources;
    const len = @as(usize, w) * 4 * h;
    const buf: Buffer = .{ .handle = 0, .hbm = hbm, .pixels = @as([*]u8, @ptrCast(bits orelse return error.SystemResources))[0..len], .w = w, .h = h };
    p.lock();
    defer p.unlock();
    var b = buf;
    b.handle = p.next;
    p.next +%= 1;
    if (p.next == 0) p.next = 1;
    p.buffers.append(p.gpa, b) catch |err| {
        freeBuffer(b);
        return err;
    };
    return .{ .handle = @enumFromInt(b.handle), .pixels = b.pixels, .stride = w * 4 };
}

fn present(ctx: *anyopaque, handle: surface.BufferHandle, damage: []const types.PxRect, acquire: surface.SyncPoint, _: ?surface.ConfigureAck) anyerror!void {
    if (!is_windows) return error.Unsupported;
    const p = of(ctx);
    if (acquire != .none) return error.Unsupported;
    p.lock();
    defer p.unlock();
    const b = p.find(@intFromEnum(handle)) orelse return error.InvalidArgument;
    const hwnd = p.hwnd orelse return error.SurfaceLost;
    b.busy = true;
    if (user32.GetDC(hwnd)) |hdc| {
        defer _ = user32.ReleaseDC(hwnd, hdc);
        const full: types.PxRect = .{ .x = 0, .y = 0, .w = b.w, .h = b.h };
        if (damage.len == 0) {
            blit(hdc, b, full);
        } else if (damage.len > max_rects) {
            blit(hdc, b, unionOf(damage));
        } else for (damage) |r| blit(hdc, b, r);
        _ = gdi32.GdiFlush();
    }
    const prev = p.last;
    p.last = b.handle;
    p.seq += 1;
    if (prev) |h| if (h != b.handle) if (p.find(h)) |old| if (old.busy) {
        old.busy = false;
        try p.released.append(p.gpa, @enumFromInt(old.handle));
    };
}

fn releaseBuffer(ctx: *anyopaque, handle: surface.BufferHandle) void {
    const p = of(ctx);
    p.lock();
    defer p.unlock();
    for (p.buffers.items, 0..) |b, i| if (b.handle == @intFromEnum(handle)) {
        freeBuffer(b);
        _ = p.buffers.swapRemove(i);
        if (p.last == b.handle) p.last = null;
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

test "damage union when > 16 rects" {
    var rects: [17]types.PxRect = undefined;
    for (&rects, 0..) |*r, i| r.* = .{ .x = @intCast(i * 10), .y = 5, .w = 2, .h = 2 };
    try std.testing.expectEqual(types.PxRect{ .x = 0, .y = 5, .w = 162, .h = 2 }, unionOf(&rects));
    try std.testing.expectEqual(@as(?types.PxRect, null), clip(.{ .x = 50, .y = 0, .w = 5, .h = 5 }, 50, 50));
}

test "ARGB8888 fourcc ↔ DIB byte order" {
    // A top-down DIB: negative height, 32 bpp, BI_RGB.
    const bmi = dibInfo(4, 3);
    try std.testing.expectEqual(@as(i32, -3), bmi.bmiHeader.biHeight);
    try std.testing.expectEqual(@as(u16, 32), bmi.bmiHeader.biBitCount);
    // 'AR24' little-endian is B, G, R, A in memory, which is BI_RGB order.
    const px: u32 = 0xff112233; // A=ff R=11 G=22 B=33
    const bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, px));
    try std.testing.expectEqualSlices(u8, &.{ 0x33, 0x22, 0x11, 0xff }, &bytes);
    try std.testing.expectEqualSlices(u8, "AR24", &std.mem.toBytes(std.mem.nativeToLittle(u32, fourcc_argb8888)));
}
