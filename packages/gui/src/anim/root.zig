//! Animation (E04.F08.S03): closed-form springs, cubic-bezier tweens, the
//! `Animator` that drives node visuals and view values from the frame
//! clock, FLIP layout transitions and motion presets. A window owns an
//! animator (`Window.animate`); with nothing in flight it asks for no
//! frames.

pub const spring = @import("spring.zig");
pub const bezier = @import("bezier.zig");
pub const tween = @import("tween.zig");
pub const visual = @import("visual.zig");
pub const animator = @import("animator.zig");
pub const flip = @import("flip.zig");
pub const presets = @import("presets.zig");

pub const SpringParams = spring.SpringParams;
pub const SpringState = spring.SpringState;
pub const CubicBezier = bezier.CubicBezier;
pub const Motion = tween.Motion;
pub const Visual = visual.Visual;
pub const Animator = animator.Animator;
pub const AnimTarget = animator.AnimTarget;
pub const AnimId = animator.AnimId;
pub const TickResult = animator.TickResult;
