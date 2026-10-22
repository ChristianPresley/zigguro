//! Decides when the render thread may start the next frame
//! (E02.F04.S03.T01). Owned by the render thread; pure apart from the
//! present waiter a swapchain installs.
//!
//! - `present_wait2` / `present_wait`: every present carries the id from
//!   `nextPresentId`; before the frame presenting id k starts, the pacer
//!   waits until id `k - max_queued` is displayed, so at most `max_queued`
//!   frames are queued (1 = low latency).
//! - `platform_frame`: a presented frame arms a frame callback (Wayland
//!   frame done, X11 CompleteNotify); the next frame starts when E04
//!   forwards it. With no callback outstanding, frames start at once.
//! - `timer`: at most one frame start per refresh interval.
//! - `immediate`: no pacing (headless, tests).
//!
//! The pacer is only consulted while a frame is pending, so an idle
//! window causes no wakeups.

const std = @import("std");

const FramePacer = @This();

pub const Mode = enum { immediate, present_wait2, present_wait, platform_frame, timer };

/// What the target and device offer.
pub const Caps = struct {
    /// No presentation engine (headless or readback targets).
    headless: bool = false,
    /// VK_KHR_present_wait2 on the swapchain.
    present_wait2: bool = false,
    /// VK_KHR_present_wait on the swapchain.
    present_wait: bool = false,
    /// The platform delivers frame callbacks (external presenter).
    platform_frames: bool = false,
};

pub const WaitResult = enum { ready, timeout, lost };

/// Installed by a swapchain target: blocks until `present_id` is
/// displayed or `timeout_ns` passes.
pub const PresentWaiter = struct {
    ctx: *anyopaque,
    wait: *const fn (ctx: *anyopaque, present_id: u64, timeout_ns: u64) WaitResult,
};

/// When the next frame may start.
pub const Readiness = union(enum) {
    /// Start now.
    now,
    /// Start at this monotonic time (ns).
    at: u64,
    /// Wait for a platform frame signal.
    signal,
};

mode: Mode,
/// Refresh interval for the timer mode.
refresh_ns: u64,
/// Frames allowed in the presentation queue (present-wait modes).
max_queued: u64 = 1,
/// The id the next present carries.
next_id: u64 = 1,
last_start_ns: ?u64 = null,
frame_outstanding: bool = false,
waiter: ?PresentWaiter = null,

/// The best mode for `caps`.
pub fn selectMode(caps: Caps) Mode {
    if (caps.headless) return .immediate;
    if (caps.present_wait2) return .present_wait2;
    if (caps.present_wait) return .present_wait;
    if (caps.platform_frames) return .platform_frame;
    return .timer;
}

pub fn init(mode: Mode, refresh_ns: u64) FramePacer {
    return .{ .mode = mode, .refresh_ns = @max(refresh_ns, 1) };
}

/// The id the next present carries; each call advances it.
pub fn nextPresentId(self: *FramePacer) u64 {
    const id = self.next_id;
    self.next_id += 1;
    return id;
}

/// The present id to wait for before starting the frame that presents
/// `id` (null when fewer than `max_queued` frames came before it).
pub fn waitIdFor(self: *const FramePacer, id: u64) ?u64 {
    if (id <= self.max_queued) return null;
    return id - self.max_queued;
}

/// Whether a frame may start at `now_ns`.
pub fn readiness(self: *const FramePacer, now_ns: u64) Readiness {
    return switch (self.mode) {
        .immediate, .present_wait2, .present_wait => .now,
        .platform_frame => if (self.frame_outstanding) .signal else .now,
        .timer => if (self.last_start_ns) |t| (if (now_ns >= t + self.refresh_ns) .now else .{ .at = t + self.refresh_ns }) else .now,
    };
}

/// Present-wait modes: blocks (render thread only) until the frame
/// before the next one is displayed. Other modes, or no waiter yet, are
/// ready at once.
pub fn waitReady(self: *FramePacer, timeout_ns: ?u64) WaitResult {
    switch (self.mode) {
        .present_wait2, .present_wait => {},
        else => return .ready,
    }
    const w = self.waiter orelse return .ready;
    const id = self.waitIdFor(self.next_id) orelse return .ready;
    return w.wait(w.ctx, id, timeout_ns orelse std.math.maxInt(u64));
}

/// Records a frame started at `now_ns`; `presented` says whether it
/// reached the screen (an idle frame arms no callback).
pub fn frameDone(self: *FramePacer, now_ns: u64, presented: bool) void {
    self.last_start_ns = now_ns;
    if (self.mode == .platform_frame and presented) self.frame_outstanding = true;
}

/// The platform's frame callback arrived.
pub fn onPlatformFrame(self: *FramePacer) void {
    self.frame_outstanding = false;
}

const testing = std.testing;

test "pacer: id arithmetic and mode selection" {
    try testing.expectEqual(Mode.immediate, selectMode(.{ .headless = true, .present_wait2 = true }));
    try testing.expectEqual(Mode.present_wait2, selectMode(.{ .present_wait2 = true, .present_wait = true }));
    try testing.expectEqual(Mode.present_wait, selectMode(.{ .present_wait = true, .platform_frames = true }));
    try testing.expectEqual(Mode.platform_frame, selectMode(.{ .platform_frames = true }));
    try testing.expectEqual(Mode.timer, selectMode(.{}));

    var p = init(.present_wait2, 16_000_000);
    try testing.expectEqual(@as(u64, 1), p.nextPresentId());
    try testing.expectEqual(@as(u64, 2), p.nextPresentId());
    // Low latency: frame k waits for k - 1 to be displayed.
    try testing.expectEqual(@as(?u64, null), p.waitIdFor(1));
    try testing.expectEqual(@as(?u64, 2), p.waitIdFor(3));
    p.max_queued = 2;
    try testing.expectEqual(@as(?u64, null), p.waitIdFor(2));
    try testing.expectEqual(@as(?u64, 1), p.waitIdFor(3));

    // The waiter sees the id of the frame before the next one.
    const W = struct {
        var seen: u64 = 0;
        fn wait(_: *anyopaque, id: u64, _: u64) WaitResult {
            seen = id;
            return .ready;
        }
    };
    var dummy: u8 = 0;
    p.max_queued = 1;
    p.waiter = .{ .ctx = &dummy, .wait = W.wait };
    try testing.expectEqual(WaitResult.ready, p.waitReady(null));
    try testing.expectEqual(@as(u64, 2), W.seen);

    var t = init(.timer, 10);
    try testing.expectEqual(Readiness.now, t.readiness(100));
    t.frameDone(100, true);
    try testing.expectEqual(Readiness{ .at = 110 }, t.readiness(105));
    try testing.expectEqual(Readiness.now, t.readiness(110));

    var f = init(.platform_frame, 10);
    f.frameDone(5, false); // idle frame: no callback armed
    try testing.expectEqual(Readiness.now, f.readiness(6));
    f.frameDone(7, true);
    try testing.expectEqual(Readiness.signal, f.readiness(8));
    f.onPlatformFrame();
    try testing.expectEqual(Readiness.now, f.readiness(9));
}
