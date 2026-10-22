//! Resize handles between dock areas (E04.F07.S01.T02): the sash on the
//! inner edge of a side area (left, right, bottom, agent) that changes the
//! area's size.
//!
//! Dragging moves the edge, clamped to the area's minimum and to a
//! maximum that leaves the center room; a drag is one undo step.
//! Double-click restores the default size. Focused, the arrow keys across
//! the edge move it 10 px, 50 px with Shift. The handle is a `separator`
//! whose value is the area's size in pixels.

const std = @import("std");
const widget = @import("../core/widget.zig");
const geom = @import("../core/geom.zig");
const ui_mod = @import("../core/ui.zig");
const event_mod = @import("../input/event.zig");
const style_mod = @import("../layout/style.zig");
const measure_mod = @import("../layout/measure.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const theme_mod = @import("../theme/theme.zig");
const model = @import("model.zig");
const splitter = @import("splitter.zig");

const DockModel = model.DockModel;
const Area = model.Area;

/// Where the sash sits relative to its area.
pub fn axisOf(a: Area) model.Axis {
    return if (a == .bottom) .column else .row;
}

/// +1 when moving the sash right (down) grows the area, -1 when it
/// shrinks it.
pub fn growSign(a: Area) f32 {
    return switch (a) {
        .left => 1,
        .right, .agent, .bottom, .center => -1,
    };
}

/// The new size of an area `start` px big after its sash moved `delta`
/// px, within `min..max`.
pub fn resized(a: Area, start: f32, delta: f32, min: f32, max: f32) f32 {
    const want = start + growSign(a) * delta;
    return std.math.clamp(want, min, @max(min, max));
}

/// The handle on an area's inner edge.
pub const AreaSash = struct {
    /// Shown in snapshots.
    pub const name = "area_sash";
    /// Takes focus for the keyboard.
    pub const focusable = true;

    /// Sash props.
    pub const Props = struct {
        dock: *DockModel,
        area: Area,
        min_px: f32 = 170,
        /// The largest size (what leaves the center its minimum).
        max_px: f32 = std.math.inf(f32),
    };

    /// The drag in progress.
    pub const State = struct {
        dragging: bool = false,
        start_pos: f32 = 0,
        start_size: f32 = 0,
    };

    /// A thin bar along the edge.
    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return if (axisOf(props.area) == .row)
            .{ .w = .{ .px = splitter.thickness }, .shrink = 0, .align_self = .stretch }
        else
            .{ .h = .{ .px = splitter.thickness }, .shrink = 0, .align_self = .stretch };
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

    fn size(props: *const Props) f32 {
        return props.dock.areas[@intFromEnum(props.area)].size;
    }

    fn set(ec: *event_mod.EventCx, props: *const Props, px: f32) void {
        props.dock.setAreaSizeLive(props.area, px);
        ec.respond(.{ .changed = true });
    }

    pub fn event(ec: *event_mod.EventCx, props: *const Props, st: *State, ev: *const event_mod.InputEvent) bool {
        const row = axisOf(props.area) == .row;
        switch (ev.*) {
            .pointer_move => |p| {
                ec.setCursor(if (row) .ew_resize else .ns_resize);
                if (!st.dragging) return false;
                const delta = (if (row) p.pos.x else p.pos.y) - st.start_pos;
                set(ec, props, resized(props.area, st.start_size, delta, props.min_px, props.max_px));
                return true;
            },
            .pointer_down => |p| {
                if (p.button != .left) return false;
                ec.focus();
                props.dock.checkpoint() catch {};
                if (p.clicks >= 2) {
                    set(ec, props, std.math.clamp(model.defaultSize(props.area), props.min_px, @max(props.min_px, props.max_px)));
                    return true;
                }
                st.dragging = true;
                st.start_pos = if (row) p.pos.x else p.pos.y;
                st.start_size = size(props);
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
                const step: f32 = if (k.mods.shift) splitter.key_step_big else splitter.key_step;
                const d: f32 = switch (k.key) {
                    .arrow_left => if (row) -step else return false,
                    .arrow_right => if (row) step else return false,
                    .arrow_up => if (!row) -step else return false,
                    .arrow_down => if (!row) step else return false,
                    else => return false,
                };
                props.dock.checkpoint() catch {};
                set(ec, props, resized(props.area, size(props), d, props.min_px, props.max_px));
                return true;
            },
            else => return false,
        }
    }

    /// A separator whose value is the area's size.
    pub fn a11y(props: *const Props, _: *State) widget.A11y {
        return .{ .role = .separator, .name = switch (props.area) {
            .left => "Resize left area",
            .right => "Resize right area",
            .bottom => "Resize bottom area",
            .agent => "Resize agent area",
            .center => "Resize",
        }, .value = size(props) };
    }
};

/// Emits the sash of `area` (place it on the area's inner edge).
pub fn areaSash(ui: *ui_mod.Ui, props: AreaSash.Props) void {
    ui.id(@as(u64, 0x5a5_0000) + @intFromEnum(props.area));
    _ = ui.leaf(AreaSash, props);
}

test "resized follows the edge and clamps" {
    try std.testing.expectEqual(@as(f32, 290), resized(.left, 240, 50, 170, 600));
    try std.testing.expectEqual(@as(f32, 190), resized(.agent, 240, 50, 170, 600));
    try std.testing.expectEqual(@as(f32, 170), resized(.right, 240, 500, 170, 600));
    try std.testing.expectEqual(@as(f32, 600), resized(.bottom, 240, -900, 120, 600));
    // A maximum below the minimum keeps the minimum.
    try std.testing.expectEqual(@as(f32, 170), resized(.left, 240, 50, 170, 100));
}
