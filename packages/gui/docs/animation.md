# Animation

`zg_gui.anim` (E04.F08.S03) moves node visuals and view values from the
frame clock. Every window owns an `Animator`; with nothing in flight the
window asks for no frames (idle-zero).

## Animating

```zig
// A node's visual: opacity, translate (x and y), scale, clip.
_ = win.animate(.{ .node_opacity = node }, 0, .{ .tween = .{ .ms = 120 } });
win.animateTranslate(node, .{ .x = 0, .y = 0 }, .{ .spring = .{} });

// A value in view or widget state; the node repaints on each step
// (`rebuild = true` rebuilds its view instead).
_ = win.animate(.{ .value = .{ .ptr = &self.progress, .node = node } }, 1, presets.normal);
```

- `Motion` is `.spring` (`SpringParams{ omega, zeta, rest_eps }`), `.tween`
  (`ms` and a `CubicBezier`) or `.instant`.
- Animating a target that is already moving retargets it: a spring keeps
  its position and velocity, a tween restarts from the current value.
- Animations on a node stop when it unmounts. A `value` target's pointer
  must outlive the animation or name the node that owns it.
- `win.setVisual(node, v)` sets a visual directly; `win.visualOf(node)`
  reads it.

## How visuals paint

A node's `Visual` is applied about the centre of its layout box and
composes down the tree. The paint pass replays the node's cached prims
translated, scaled and faded (`OpList.replayX`); layout does not run and
the widget does not repaint for a move or zoom. Hit testing, damage and
`store.absRect` use the visual rect; `Window.layoutRect` gives the laid
out one. `clip` hides the bottom fraction of the node and its subtree. A
scroll container that is scaled or faded draws without its scroll layer
while it is.

## FLIP

`win.flip(nodes, how)` remembers where `nodes` are painted; after the next
layout each starts at its old place and animates to the new one. Use it
for mode switches, splitter equalize, tab reorder and toast stacking.

## Presets and tokens

`presets.tokens`: `fast_ms` 80, `normal_ms` 120, `slow_ms` 200,
`spring_default` (ω 30, ζ 1), `spring_bouncy` (ω 25, ζ 0.8).
`presets.fadeScale`, `presets.slideUp` and `presets.expandHeight` put a
newly mounted node in its hidden pose and animate it in (or out).

## Reduced motion

`App.reduced_motion` follows the desktop (`Appearance.reduced_motion`)
unless `reduced_motion_follows_system` is cleared (an E15 setting can then
set it). When set, every animation is instant except opacity tweens of
100 ms or less.

## Clock

`tick` steps to the platform frame's `target_ns` (the predicted present
time) when it is on the app's clock, else `App.now_ms`. Springs use the
exact closed form, so motion is the same at 60, 120 or 144 Hz.
