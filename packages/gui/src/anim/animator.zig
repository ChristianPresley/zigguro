//! The `Animator`: drives node visual properties and view-state values
//! from the frame clock. Active animations live in a dense array; `tick`
//! steps them all and drops the finished ones, and returns `.idle` once
//! none is left, so the frame loop stops asking for frames.
//!
//! Writes go through a `Sink` (the window): node targets set the node's
//! `Visual` and repaint it, `value` targets store into the pointer and
//! mark the owning node for repaint (or its view for rebuild).
//!
//! With reduced motion every animation is instant except opacity tweens of
//! 100 ms or less.

const std = @import("std");
const ids = @import("../core/ids.zig");
const spring = @import("spring.zig");
const tween = @import("tween.zig");

const NodeId = ids.NodeId;
const SpringParams = spring.SpringParams;
const SpringState = spring.SpringState;
const Coeffs = spring.Coeffs;
const Tween = tween.Tween;
pub const Motion = tween.Motion;

/// An animation handle; `none` when the change was applied at once.
pub const AnimId = enum(u32) { none = 0, _ };

pub const TickResult = enum { active, idle };

/// What an animation moves. Translation is two targets (x and y) so each
/// axis can retarget alone.
pub const AnimTarget = union(enum) {
    node_opacity: NodeId,
    node_translate_x: NodeId,
    node_translate_y: NodeId,
    node_scale: NodeId,
    node_clip: NodeId,
    /// A value in widget or view state. The owner must outlive the
    /// animation or cancel it (`cancelNode(node)` happens on unmount).
    value: Value,

    pub const Value = struct {
        ptr: *f32,
        /// Repainted on each step (its view rebuilt when `rebuild`).
        node: NodeId = .none,
        rebuild: bool = false,
    };

    /// The node the target belongs to (none for a bare value).
    pub fn node(t: AnimTarget) NodeId {
        return switch (t) {
            .value => |v| v.node,
            inline else => |n| n,
        };
    }

    /// The same property of the same node (or the same pointer).
    pub fn eql(a: AnimTarget, b: AnimTarget) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .value => |v| v.ptr == b.value.ptr,
            inline else => |n, tag| n.eql(@field(b, @tagName(tag))),
        };
    }

    pub fn isOpacity(t: AnimTarget) bool {
        return t == .node_opacity;
    }
};

/// Where values go: the window applies node targets to its visuals.
pub const Sink = struct {
    ctx: *anyopaque,
    /// The target's current value (node visuals; values read the pointer).
    get: *const fn (ctx: *anyopaque, t: AnimTarget) f32,
    /// Stores `v` (after a value target's pointer was written).
    set: *const fn (ctx: *anyopaque, t: AnimTarget, v: f32) void,
};

const Anim = struct {
    id: AnimId,
    target: AnimTarget,
    value: f32,
    kind: union(enum) {
        spring: struct { s: SpringState, p: SpringParams, last_ns: ?u64 = null },
        tween: Tween,
    },
};

pub const Animator = struct {
    gpa: std.mem.Allocator,
    anims: std.ArrayList(Anim) = .empty,
    next_id: u32 = 1,
    reduced_motion: bool = false,
    sink: ?Sink = null,
    /// Spring coefficients for the last (params, dt): one exp per frame
    /// when every spring shares them.
    cache: ?struct { p: SpringParams, dt_ns: u64, k: Coeffs } = null,

    /// The longest opacity tween reduced motion still plays.
    pub const reduced_fade_ms = 100;

    pub fn init(gpa: std.mem.Allocator) Animator {
        return .{ .gpa = gpa };
    }

    pub fn deinit(a: *Animator) void {
        a.anims.deinit(a.gpa);
    }

    /// Animations in flight.
    pub fn count(a: *const Animator) usize {
        return a.anims.items.len;
    }

    pub fn isActive(a: *const Animator) bool {
        return a.anims.items.len > 0;
    }

    /// `how` under the reduced-motion rule.
    pub fn effective(a: *const Animator, t: AnimTarget, how: Motion) Motion {
        if (!a.reduced_motion) return how;
        return switch (how) {
            .tween => |tw| if (t.isOpacity() and tw.ms <= reduced_fade_ms) how else .instant,
            else => .instant,
        };
    }

    fn find(a: *const Animator, t: AnimTarget) ?usize {
        for (a.anims.items, 0..) |an, i| {
            if (an.target.eql(t)) return i;
        }
        return null;
    }

    fn current(a: *const Animator, t: AnimTarget) f32 {
        if (t == .value) return t.value.ptr.*;
        if (a.sink) |s| return s.get(s.ctx, t);
        return 0;
    }

    fn write(a: *Animator, t: AnimTarget, v: f32) void {
        if (t == .value) t.value.ptr.* = v;
        if (a.sink) |s| s.set(s.ctx, t, v);
    }

    /// Moves `t` to `to`. An animation already on `t` is retargeted: a
    /// spring keeps its position and velocity, a tween restarts from the
    /// current value. Out of memory, the value jumps.
    pub fn animate(a: *Animator, t: AnimTarget, to: f32, how: Motion) AnimId {
        const existing = a.find(t);
        const m = a.effective(t, how);
        if (m == .instant) {
            if (existing) |i| _ = a.anims.swapRemove(i);
            a.write(t, to);
            return .none;
        }
        const from = if (existing) |i| a.anims.items[i].value else a.current(t);
        if (existing) |i| {
            const an = &a.anims.items[i];
            switch (m) {
                .spring => |p| switch (an.kind) {
                    .spring => |*sp| {
                        sp.s.target = to;
                        sp.p = p;
                    },
                    .tween => an.kind = .{ .spring = .{ .s = .{ .x = from, .target = to }, .p = p } },
                },
                .tween => |tw| an.kind = .{ .tween = .{ .from = from, .to = to, .ms = tw.ms, .curve = tw.curve } },
                .instant => unreachable,
            }
            return an.id;
        }
        if (from == to) {
            a.write(t, to);
            return .none;
        }
        const id: AnimId = @enumFromInt(a.next_id);
        a.next_id +%= 1;
        if (a.next_id == 0) a.next_id = 1;
        const kind: @FieldType(Anim, "kind") = switch (m) {
            .spring => |p| .{ .spring = .{ .s = .{ .x = from, .target = to }, .p = p } },
            .tween => |tw| .{ .tween = .{ .from = from, .to = to, .ms = tw.ms, .curve = tw.curve } },
            .instant => unreachable,
        };
        a.anims.append(a.gpa, .{ .id = id, .target = t, .value = from, .kind = kind }) catch {
            a.write(t, to);
            return .none;
        };
        return id;
    }

    fn coeffs(a: *Animator, p: SpringParams, dt_ns: u64) Coeffs {
        if (a.cache) |c| {
            if (c.dt_ns == dt_ns and c.p.eql(p)) return c.k;
        }
        const k = Coeffs.of(p, @as(f64, @floatFromInt(dt_ns)) / std.time.ns_per_s);
        a.cache = .{ .p = p, .dt_ns = dt_ns, .k = k };
        return k;
    }

    /// Steps every animation to `now_ns` (the predicted present time) and
    /// writes the values; finished ones are dropped. No allocation.
    pub fn tick(a: *Animator, now_ns: u64) TickResult {
        var i: usize = 0;
        while (i < a.anims.items.len) {
            const an = &a.anims.items[i];
            var done = false;
            switch (an.kind) {
                .spring => |*sp| {
                    if (sp.last_ns) |last| {
                        const dt = now_ns -| last;
                        if (dt > 0) sp.s.apply(a.coeffs(sp.p, dt));
                    }
                    sp.last_ns = now_ns;
                    if (sp.s.atRest(sp.p)) {
                        sp.s.settle();
                        done = true;
                    }
                    an.value = sp.s.x;
                },
                .tween => |*tw| {
                    an.value = tw.at(now_ns);
                    done = tw.done(now_ns);
                },
            }
            a.write(an.target, an.value);
            if (done) _ = a.anims.swapRemove(i) else i += 1;
        }
        return if (a.anims.items.len == 0) .idle else .active;
    }

    /// Drops animation `id` where it is (no-op when finished).
    pub fn cancel(a: *Animator, id: AnimId) void {
        for (a.anims.items, 0..) |an, i| if (an.id == id) {
            _ = a.anims.swapRemove(i);
            return;
        };
    }

    /// Drops every animation on node `n` (on unmount), value targets owned
    /// by it included.
    pub fn cancelNode(a: *Animator, n: NodeId) void {
        var i: usize = 0;
        while (i < a.anims.items.len) {
            if (a.anims.items[i].target.node().eql(n)) _ = a.anims.swapRemove(i) else i += 1;
        }
    }

    /// The animation on `t`, if one is running.
    pub fn idOf(a: *const Animator, t: AnimTarget) AnimId {
        const i = a.find(t) orelse return .none;
        return a.anims.items[i].id;
    }
};

test "animator idle when settled" {
    var a: Animator = .init(std.testing.allocator);
    defer a.deinit();
    var x: f32 = 0;
    const t: AnimTarget = .{ .value = .{ .ptr = &x } };
    try std.testing.expectEqual(TickResult.idle, a.tick(0));
    const id = a.animate(t, 10, .{ .spring = .{} });
    try std.testing.expect(id != .none);
    var now: u64 = 1_000_000_000;
    var frames: u32 = 0;
    while (a.tick(now) == .active) : (frames += 1) now += 8_333_333;
    try std.testing.expectEqual(@as(f32, 10), x);
    try std.testing.expect(frames > 5 and frames < 120);
    try std.testing.expectEqual(@as(usize, 0), a.count());
    // Animating to where it is starts nothing.
    try std.testing.expectEqual(AnimId.none, a.animate(t, 10, .{ .spring = .{} }));
    try std.testing.expect(!a.isActive());
}

test "retarget keeps the animation and its velocity" {
    var a: Animator = .init(std.testing.allocator);
    defer a.deinit();
    var x: f32 = 0;
    const t: AnimTarget = .{ .value = .{ .ptr = &x } };
    const id = a.animate(t, 100, .{ .spring = .{} });
    _ = a.tick(0);
    _ = a.tick(16_000_000);
    const v = a.anims.items[0].kind.spring.s.v;
    try std.testing.expectEqual(id, a.animate(t, -100, .{ .spring = .{} }));
    try std.testing.expectEqual(@as(usize, 1), a.count());
    try std.testing.expectEqual(v, a.anims.items[0].kind.spring.s.v);
    // A tween retarget starts from the current value.
    _ = a.animate(t, 50, .{ .tween = .{ .ms = 100, .curve = .linear } });
    try std.testing.expectEqual(x, a.anims.items[0].kind.tween.from);
}

test "reduced motion instant" {
    var a: Animator = .init(std.testing.allocator);
    defer a.deinit();
    a.reduced_motion = true;
    var x: f32 = 0;
    const t: AnimTarget = .{ .value = .{ .ptr = &x } };
    try std.testing.expectEqual(AnimId.none, a.animate(t, 5, .{ .spring = .{} }));
    try std.testing.expectEqual(@as(f32, 5), x);
    try std.testing.expectEqual(AnimId.none, a.animate(t, 7, .{ .tween = .{ .ms = 80 } }));
    try std.testing.expectEqual(@as(f32, 7), x);
    // Short opacity fades still play.
    const n: NodeId = .{ .index = 3, .gen = 1 };
    try std.testing.expect(a.effective(.{ .node_opacity = n }, .{ .tween = .{ .ms = 100 } }) == .tween);
    try std.testing.expect(a.effective(.{ .node_opacity = n }, .{ .tween = .{ .ms = 200 } }) == .instant);
    try std.testing.expect(a.effective(.{ .node_opacity = n }, .{ .spring = .{} }) == .instant);
    try std.testing.expect(a.effective(.{ .node_scale = n }, .{ .tween = .{ .ms = 50 } }) == .instant);
}

test "cancelNode drops the node's animations" {
    var a: Animator = .init(std.testing.allocator);
    defer a.deinit();
    const n: NodeId = .{ .index = 3, .gen = 1 };
    const m: NodeId = .{ .index = 4, .gen = 1 };
    var x: f32 = 0;
    var y: f32 = 0;
    _ = a.animate(.{ .value = .{ .ptr = &x, .node = n } }, 1, .{ .spring = .{} });
    _ = a.animate(.{ .value = .{ .ptr = &y, .node = m } }, 1, .{ .spring = .{} });
    a.cancelNode(n);
    try std.testing.expectEqual(@as(usize, 1), a.count());
    try std.testing.expect(a.idOf(.{ .value = .{ .ptr = &y } }) != .none);
}
