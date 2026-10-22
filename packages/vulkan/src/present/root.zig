//! Presentation: frames in flight, deferred destruction and damage
//! tracking (E02.F04.S03). Targets (swapchain, dmabuf ring, readback)
//! build on these.

/// Frame slots, the timeline and deferred destruction.
pub const FrameScheduler = @import("FrameScheduler.zig");
pub const FrameSlot = FrameScheduler.FrameSlot;
/// Objects destroyed after the timeline passes their last use.
pub const Deferred = @import("Deferred.zig").Deferred;
/// Buffer-age damage tracking.
pub const Damage = @import("Damage.zig");
pub const DamageHistory = Damage.DamageHistory;
pub const RectList = Damage.RectList;
/// The offscreen render plus copy-to-CPU target.
pub const Readback = @import("Readback.zig");

test {
    _ = FrameScheduler;
    _ = @import("Deferred.zig");
    _ = Damage;
    _ = Readback;
    _ = @import("gpu_test.zig");
}
