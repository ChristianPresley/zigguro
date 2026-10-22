//! Dock splitters (E04.F07.S01.T02): the handle between two children of a
//! split.
//!
//! Dragging moves the boundary between the two neighbors; when one reaches
//! the minimum size, the rest comes from the next ones beyond it (VS Code
//! "sash" behavior). A drag is one undo step. Double-click equalizes the
//! split. Focused, Left/Right (Up/Down for a column) move it 10 px, 50 px
//! with Shift. The handle is a `separator` whose value is the share of
//! the child before it.

const std = @import("std");
const widget = @import("../core/widget.zig");
const geom = @import("../core/geom.zig");
const event_mod = @import("../input/event.zig");
const style_mod = @import("../layout/style.zig");
const measure_mod = @import("../layout/measure.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const theme_mod = @import("../theme/theme.zig");
const model = @import("model.zig");

const DockModel = model.DockModel;

/// The drawn thickness; the handle is hit-tested this wide too.
pub const thickness: f32 = 4;
/// Keyboard steps.
pub const key_step: f32 = 10;
pub const key_step_big: f32 = 50;

/// Moves the boundary after child `i` by `delta_px` within `start`
/// ratios over `total_px`, keeping every child at least `min_px` (taking
/// from further neighbors once the nearest is at its minimum). Writes the
/// result to `out`.
pub fn dragRatios(start: []const f32, i: usize, delta_px: f32, total_px: f32, min_px: f32, out: []f32) void {
    const n = start.len;
    var sizes_buf: [64]f32 = undefined;
    const sizes = sizes_buf[0..n];
    for (start, sizes) |r, *s| s.* = r * total_px;
    if (i + 1 >= n or total_px <= 0) {
        @memcpy(out, start);
        return;
    }
    if (delta_px > 0) {
        var left = delta_px;
        var j = i + 1;
        while (j < n and left > 0) : (j += 1) {
            const take = @min(left, @max(0, sizes[j] - min_px));
            sizes[j] -= take;
            left -= take;
        }
        sizes[i] += delta_px - left;
    } else if (delta_px < 0) {
        var left = -delta_px;
        var j = i + 1;
        while (j > 0 and left > 0) {
            j -= 1;
            const take = @min(left, @max(0, sizes[j] - min_px));
            sizes[j] -= take;
            left -= take;
        }
        sizes[i + 1] += -delta_px - left;
    }
    for (sizes, out) |s, *o| o.* = s / total_px;
}

/// The handle between children `index` and `index + 1` of a split.
pub const Splitter = struct {
    /// Shown in snapshots.
    pub const name = "splitter";
    /// Takes focus for the keyboard.
    pub const focusable = true;

    /// Splitter props.
    pub const Props = struct {
        dock: *DockModel,
        split: model.SplitId,
        index: u32,
        axis: model.Axis,
        /// The split's size along its axis less its splitters (last frame).
        total_px: f32,
        min_px: f32 = 80,
    };

    /// The drag in progress.
    pub const State = struct {
        dragging: bool = false,
        start: f32 = 0,
        ratios: [64]f32 = undefined,
        n: usize = 0,
    };

    /// A fixed-thickness bar across the split.
    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return if (props.axis == .row)
            .{ .w = .{ .px = thickness }, .h = .{ .pct = 100 }, .shrink = 0 }
        else
            .{ .h = .{ .px = thickness }, .w = .{ .pct = 100 }, .shrink = 0 };
    }

    /// No content.
    pub fn measure(_: *measure_mod.MeasureCx, _: *const Props, _: *State, _: ?f32) geom.Size {
        return .{};
    }

    /// The accent while hovered, dragged or focused.
    pub fn paint(pc: *paint_cx.PaintCx, _: *const Props, st: *State) void {
        const r = pc.bounds();
        if (st.dragging or pc.state.hovered or pc.state.focus_visible) pc.fill(r, .accent, 0) else pc.fill(r, .border, 0);
    }

    pub fn event(ec: *event_mod.EventCx, props: *const Props, st: *State, ev: *const event_mod.InputEvent) bool {
        const row = props.axis == .row;
        switch (ev.*) {
            .pointer_move => |p| {
                ec.setCursor(if (row) .ew_resize else .ns_resize);
                if (!st.dragging) return false;
                apply(ec, props, st, (if (row) p.pos.x else p.pos.y) - st.start);
                return true;
            },
            .pointer_down => |p| {
                if (p.button != .left) return false;
                ec.focus();
                if (p.clicks >= 2) {
                    equalize(props);
                    ec.respond(.{ .changed = true });
                    return true;
                }
                if (!begin(props, st)) return false;
                st.dragging = true;
                st.start = if (row) p.pos.x else p.pos.y;
                ec.capture();
                return true;
            },
            .pointer_up => {
                if (!st.dragging) return false;
                st.dragging = false;
                ec.releaseCapture();
                ec.repaint();
                return true;
            },
            .key => |k| {
                if (k.action == .release or k.mods.ctrl or k.mods.alt) return false;
                const step: f32 = if (k.mods.shift) key_step_big else key_step;
                const d: f32 = switch (k.key) {
                    .arrow_left => if (row) -step else return false,
                    .arrow_right => if (row) step else return false,
                    .arrow_up => if (!row) -step else return false,
                    .arrow_down => if (!row) step else return false,
                    else => return false,
                };
                if (!begin(props, st)) return false;
                apply(ec, props, st, d);
                return true;
            },
            else => return false,
        }
    }

    /// Records the undo step and the starting ratios.
    fn begin(props: *const Props, st: *State) bool {
        const sp = props.dock.splitOf(props.split) orelse return false;
        st.n = @min(sp.ratios.items.len, st.ratios.len);
        @memcpy(st.ratios[0..st.n], sp.ratios.items[0..st.n]);
        props.dock.checkpoint() catch {};
        return true;
    }

    fn apply(ec: *event_mod.EventCx, props: *const Props, st: *State, delta: f32) void {
        var out: [64]f32 = undefined;
        dragRatios(st.ratios[0..st.n], props.index, delta, props.total_px, props.min_px, out[0..st.n]);
        props.dock.setRatiosLive(props.split, out[0..st.n]);
        ec.respond(.{ .changed = true });
    }

    fn equalize(props: *const Props) void {
        const sp = props.dock.splitOf(props.split) orelse return;
        var out: [64]f32 = undefined;
        const n = @min(sp.ratios.items.len, out.len);
        for (out[0..n]) |*o| o.* = 1 / @as(f32, @floatFromInt(n));
        props.dock.setRatios(props.split, out[0..n]) catch {};
    }

    /// A separator whose value is the share before it.
    pub fn a11y(props: *const Props, _: *State) widget.A11y {
        const sp = props.dock.splitOf(props.split) orelse return .{ .role = .separator };
        var v: f32 = 0;
        for (sp.ratios.items[0..@min(props.index + 1, sp.ratios.items.len)]) |r| v += r;
        return .{ .role = .separator, .name = "Resize", .value = v };
    }
};

const testing = std.testing;

test "splitter clamps min sizes and cascades" {
    var out: [3]f32 = undefined;
    // 300 / 300 / 400 of 1000, min 100.
    const start = [_]f32{ 0.3, 0.3, 0.4 };
    dragRatios(&start, 0, 50, 1000, 100, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.35), out[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[1], 1e-5);
    // Past the middle child's minimum, the last one gives way.
    dragRatios(&start, 0, 400, 1000, 100, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.7), out[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.1), out[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.2), out[2], 1e-5);
    // Everything at its minimum: the boundary stops.
    dragRatios(&start, 0, 900, 1000, 100, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.8), out[0], 1e-5);
    // Leftwards cascades the other way.
    dragRatios(&start, 1, -500, 1000, 100, &out);
    try testing.expectApproxEqAbs(@as(f32, 0.1), out[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.1), out[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.8), out[2], 1e-5);
}
