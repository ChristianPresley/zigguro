//! The shm side of the Readback target (E02.F04.S02.T02): a ring of up to
//! three `allocCpuBuffer` buffers of an external presenter (wl_shm,
//! MIT-SHM), filled from the readback's CPU backbuffer with buffer-age
//! repaint and presented with the frame's damage.
//!
//! Frames are queued as damage only (the backbuffer always holds the
//! latest pixels), so when every buffer is held by the compositor, later
//! frames merge into one pending present: latest wins, nothing blocks.
//! The pending present goes out at the next `flush` that finds a released
//! buffer.

const ShmRing = @This();

const std = @import("std");
const platform = @import("zg_platform");
const CpuImage = @import("../testing/CpuImage.zig");
const Damage = @import("Damage.zig");
const rect = @import("../r2d/rect.zig");

const PxRect = rect.PxRect;
const Size = rect.Size;
const surface = platform.surface;

/// DRM fourcc of the buffers (B, G, R, A bytes in memory).
pub const fourcc_argb8888: u32 = 0x34325241;
/// Presenter buffers in the ring.
pub const ring_len = 3;

const Slot = struct {
    buf: surface.CpuBuffer,
    /// Held by the compositor until `pollReleased` returns it.
    busy: bool = false,
    /// The present that last showed this buffer (0 = never written).
    seq: u64 = 0,
    width: u32,
    height: u32,
};

presenter: *surface.Presenter,
slots: [ring_len]?Slot = @splat(null),
/// Damage of the presents so far, for buffer age.
history: Damage.DamageHistory = .{},
/// Presents so far.
seq: u64 = 0,
/// Damage not presented yet.
unsent: Damage.RectList = .{},
unsent_full: bool = false,
has_unsent: bool = false,
/// Size of the buffers in use.
extent: Size = .{ .w = 0, .h = 0 },
/// Bytes written into shm buffers (tests).
written_bytes: u64 = 0,
/// Frames merged into a later one because no buffer was free.
merged: u64 = 0,

pub fn init(presenter: *surface.Presenter) ShmRing {
    return .{ .presenter = presenter };
}

/// Releases every buffer to the presenter.
pub fn deinit(self: *ShmRing) void {
    for (&self.slots) |*s| if (s.*) |slot| {
        self.presenter.releaseBuffer(slot.buf.handle);
        s.* = null;
    };
    self.* = undefined;
}

/// Queues a frame whose pixels are in `back` (BGRA, the window size) and
/// presents it if a buffer is free. `damage` lists the changed rects;
/// `full` means everything changed.
pub fn submit(self: *ShmRing, back: *const CpuImage, damage: []const PxRect, full: bool) void {
    if (self.has_unsent) self.merged += 1;
    self.has_unsent = true;
    if (full) self.unsent_full = true;
    for (damage) |r| self.unsent.add(r);
    _ = self.flush(back);
}

/// Whether a frame waits for a free buffer.
pub fn pending(self: *const ShmRing) bool {
    return self.has_unsent;
}

/// Presents the queued frame if a buffer is free; true when nothing is
/// left pending.
pub fn flush(self: *ShmRing, back: *const CpuImage) bool {
    self.reclaim();
    if (!self.has_unsent) return true;
    const size: Size = .{ .w = back.width, .h = back.height };
    if (size.w != self.extent.w or size.h != self.extent.h) {
        self.extent = size;
        self.history.invalidateAll();
        self.unsent_full = true;
        self.dropMismatched();
    }
    const slot = self.pick() orelse return false;
    const age: u32 = if (slot.seq == 0) 0 else @intCast(@min(self.seq + 1 - slot.seq, std.math.maxInt(u32)));
    var repaint: Damage.RectList = .{};
    if (self.unsent_full) {
        repaint.add(rect.full(size));
    } else {
        self.history.repaintFor(age, self.unsent.slice(), size, &repaint);
    }
    for (repaint.slice()) |r| self.copyRect(back, slot, r);
    const damage: []const PxRect = if (self.unsent_full) &.{} else self.unsent.slice();
    self.presenter.present(slot.buf.handle, damage, .none, null) catch {
        // The presenter refused the buffer: forget it, keep the frame.
        self.presenter.releaseBuffer(slot.buf.handle);
        self.forget(slot);
        return false;
    };
    slot.busy = true;
    self.seq += 1;
    slot.seq = self.seq;
    if (self.unsent_full) self.history.pushFull() else self.history.push(self.unsent.slice());
    self.unsent = .{};
    self.unsent_full = false;
    self.has_unsent = false;
    return true;
}

fn reclaim(self: *ShmRing) void {
    var released: [8]surface.BufferHandle = undefined;
    while (true) {
        const n = self.presenter.pollReleased(&released);
        for (released[0..n]) |h| {
            for (&self.slots) |*s| if (s.*) |*slot| {
                if (slot.buf.handle == h) slot.busy = false;
            };
        }
        if (n < released.len) break;
    }
    self.dropMismatched();
}

/// Releases free buffers of the wrong size; busy ones go when returned.
fn dropMismatched(self: *ShmRing) void {
    for (&self.slots) |*s| if (s.*) |slot| {
        if (!slot.busy and (slot.width != self.extent.w or slot.height != self.extent.h)) {
            self.presenter.releaseBuffer(slot.buf.handle);
            s.* = null;
        }
    };
}

/// The free buffer written most recently (smallest age), else a new one.
fn pick(self: *ShmRing) ?*Slot {
    var best: ?*Slot = null;
    for (&self.slots) |*s| if (s.*) |*slot| {
        if (!slot.busy and slot.width == self.extent.w and slot.height == self.extent.h and (best == null or slot.seq > best.?.seq)) best = slot;
    };
    if (best) |b| return b;
    for (&self.slots) |*s| if (s.* == null) {
        const buf = self.presenter.allocCpuBuffer(self.extent.w, self.extent.h, fourcc_argb8888) catch return null;
        if (buf.stride < self.extent.w * 4 or buf.pixels.len < @as(usize, buf.stride) * (self.extent.h -| 1) + self.extent.w * 4) {
            self.presenter.releaseBuffer(buf.handle);
            return null;
        }
        s.* = .{ .buf = buf, .width = self.extent.w, .height = self.extent.h };
        return &s.*.?;
    };
    return null;
}

fn forget(self: *ShmRing, slot: *Slot) void {
    for (&self.slots) |*s| if (s.*) |*x| {
        if (x == slot) s.* = null;
    };
}

fn copyRect(self: *ShmRing, back: *const CpuImage, slot: *Slot, r0: PxRect) void {
    const r = rect.clamp(r0, self.extent);
    if (rect.isEmpty(r)) return;
    const row = @as(usize, r.w) * 4;
    const x: usize = @intCast(r.x);
    const y0: usize = @intCast(r.y);
    for (0..r.h) |dy| {
        const y = y0 + dy;
        @memcpy(slot.buf.pixels[y * slot.buf.stride + x * 4 ..][0..row], back.pixels[y * back.stride + x * 4 ..][0..row]);
    }
    self.written_bytes += row * r.h;
}

const testing = std.testing;

/// A presenter that hands out heap buffers and releases what the test
/// says (`hold` buffers stay with the "compositor").
const FakePresenter = struct {
    bufs: [ring_len + 2][]u8 = undefined,
    n: u32 = 0,
    presented: std.ArrayList(u32) = .empty,
    damage_len: std.ArrayList(usize) = .empty,
    to_release: std.ArrayList(surface.BufferHandle) = .empty,
    released: u32 = 0,

    fn drm(_: *anyopaque) ?surface.DrmDevice {
        return null;
    }
    fn formats(_: *anyopaque, _: []surface.FormatModifier) usize {
        return 0;
    }
    fn sync(_: *anyopaque) surface.SyncMode {
        return .cpu_only;
    }
    fn import(_: *anyopaque, _: *const surface.BufferDesc) anyerror!surface.BufferHandle {
        return error.Unsupported;
    }
    fn present(ctx: *anyopaque, buf: surface.BufferHandle, damage: []const PxRect, _: surface.SyncPoint, _: ?surface.ConfigureAck) anyerror!void {
        const f: *FakePresenter = @ptrCast(@alignCast(ctx));
        try f.presented.append(testing.allocator, @intFromEnum(buf));
        try f.damage_len.append(testing.allocator, damage.len);
    }
    fn release(ctx: *anyopaque, _: surface.BufferHandle) void {
        const f: *FakePresenter = @ptrCast(@alignCast(ctx));
        f.released += 1;
    }
    fn poll(ctx: *anyopaque, out: []surface.BufferHandle) usize {
        const f: *FakePresenter = @ptrCast(@alignCast(ctx));
        const n = @min(out.len, f.to_release.items.len);
        @memcpy(out[0..n], f.to_release.items[0..n]);
        f.to_release.clearRetainingCapacity();
        return n;
    }
    fn alloc(ctx: *anyopaque, w: u32, h: u32, _: u32) anyerror!surface.CpuBuffer {
        const f: *FakePresenter = @ptrCast(@alignCast(ctx));
        f.bufs[f.n] = try testing.allocator.alloc(u8, w * h * 4);
        @memset(f.bufs[f.n], 0);
        f.n += 1;
        return .{ .handle = @enumFromInt(f.n - 1), .pixels = f.bufs[f.n - 1], .stride = w * 4 };
    }

    const vtable: surface.PresenterVTable = .{ .drmDevice = drm, .formats = formats, .syncMode = sync, .importBuffer = import, .present = present, .releaseBuffer = release, .pollReleased = poll, .allocCpuBuffer = alloc };

    fn deinit(f: *FakePresenter) void {
        for (f.bufs[0..f.n]) |b| testing.allocator.free(b);
        f.presented.deinit(testing.allocator);
        f.damage_len.deinit(testing.allocator);
        f.to_release.deinit(testing.allocator);
    }
};

test "readback: shm ring picks released buffer, latest wins" {
    const gpa = testing.allocator;
    var fake: FakePresenter = .{};
    defer fake.deinit();
    var pr: surface.Presenter = .{ .ptr = &fake, .vtable = &FakePresenter.vtable };
    var ring = ShmRing.init(&pr);
    defer ring.deinit();
    var back = try CpuImage.initOrder(gpa, 8, 4, .bgra);
    defer back.deinit(gpa);

    // Frame 1: full, buffer 0.
    @memset(back.pixels, 1);
    ring.submit(&back, &.{}, true);
    try testing.expectEqual(@as(u64, 8 * 4 * 4), ring.written_bytes);
    // The compositor still holds buffer 0: frame 2 goes to a new buffer 1,
    // fully (never written).
    back.pixels[0] = 2;
    ring.submit(&back, &.{.{ .x = 0, .y = 0, .w = 1, .h = 1 }}, false);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, fake.presented.items);
    try testing.expectEqual(@as(u64, 2 * 8 * 4 * 4), ring.written_bytes);
    try testing.expectEqual(@as(u8, 2), fake.bufs[1][0]);

    // Buffer 0 comes back (age 2): frame 3 repaints its damage plus frame
    // 2's, not the whole buffer.
    try fake.to_release.append(gpa, @enumFromInt(0));
    back.pixels[4 * 7] = 3;
    const before = ring.written_bytes;
    ring.submit(&back, &.{.{ .x = 7, .y = 0, .w = 1, .h = 1 }}, false);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, fake.presented.items);
    try testing.expectEqual(@as(usize, 1), fake.damage_len.items[2]);
    try testing.expect(ring.written_bytes - before < 8 * 4 * 4);
    try testing.expectEqualSlices(u8, back.pixels, fake.bufs[0]);

    // All three buffers held: buffer 2 is allocated, then frames wait and
    // merge; the latest pixels go out once a buffer is released.
    ring.submit(&back, &.{.{ .x = 1, .y = 1, .w = 1, .h = 1 }}, false);
    try testing.expectEqual(@as(u32, 3), fake.n);
    back.pixels[4 * 9] = 5;
    ring.submit(&back, &.{.{ .x = 1, .y = 1, .w = 1, .h = 1 }}, false);
    back.pixels[4 * 9] = 6;
    ring.submit(&back, &.{.{ .x = 2, .y = 2, .w = 1, .h = 1 }}, false);
    try testing.expect(ring.pending());
    try testing.expectEqual(@as(usize, 4), fake.presented.items.len);
    try testing.expectEqual(@as(u64, 1), ring.merged);
    try fake.to_release.append(gpa, @enumFromInt(1));
    try testing.expect(ring.flush(&back));
    try testing.expect(!ring.pending());
    try testing.expectEqual(@as(u32, 1), fake.presented.items[4]);
    try testing.expectEqual(@as(usize, 2), fake.damage_len.items[4]);
    try testing.expectEqualSlices(u8, back.pixels, fake.bufs[1]);
    try testing.expectEqual(@as(u32, 3), fake.n);

    // Resize: free buffers of the old size are released, the next frame
    // is full in a new buffer.
    var big = try CpuImage.initOrder(gpa, 10, 4, .bgra);
    defer big.deinit(gpa);
    try fake.to_release.append(gpa, @enumFromInt(0));
    ring.submit(&big, &.{.{ .x = 0, .y = 0, .w = 1, .h = 1 }}, false);
    try testing.expectEqual(@as(u32, 4), fake.n);
    try testing.expectEqual(@as(usize, 0), fake.damage_len.items[5]);
    try testing.expectEqual(@as(u32, 1), fake.released);
}
