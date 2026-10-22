//! The built-in container (`Ui.open`), root and view-boundary kinds. A box
//! paints its style's background and border; layout comes from its style.

const std = @import("std");
const widget = @import("../core/widget.zig");
const ids = @import("../core/ids.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const style_mod = @import("../layout/style.zig");

/// A generic container node.
pub const Box = struct {
    /// Shown in snapshots.
    pub const name = "box";

    /// What `Ui.open` retains for a box.
    pub const Props = struct {
        role: widget.Role = .none,
        label: []const u8 = "",
        key_context: []const u8 = "",
    };

    /// Paints the style's background and border.
    pub fn paint(pc: *paint_cx.PaintCx, props: *const Props, _: *widget.NoState) void {
        _ = props;
        const st = pc.style;
        const r = pc.bounds();
        pc.rect(r, pc.fillColor(st.bg), .all(st.radius));
        if (st.border_w > 0) pc.border(r, st.border_w, pc.fillColor(st.border), st.radius);
    }

    /// Role and label from the props.
    pub fn a11y(props: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = props.role, .name = props.label };
    }
};

/// The boundary node of a mounted view.
pub const ViewBoundary = struct {
    /// Shown in snapshots.
    pub const name = "view";

    /// The view's debug name.
    pub const Props = struct { view_name: []const u8 = "" };

    /// Views are groups for assistive technology.
    pub fn a11y(_: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .none };
    }
};

/// A window's root node.
pub const Root = struct {
    /// Shown in snapshots.
    pub const name = "root";

    /// The root has no props.
    pub const Props = struct {};

    /// Paints the window background.
    pub fn paint(pc: *paint_cx.PaintCx, _: *const Props, _: *widget.NoState) void {
        pc.fill(pc.bounds(), .bg_base, 0);
    }

    /// The window.
    pub fn a11y(_: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .window };
    }
};

var registered: bool = false;

/// Registers root, box, text and view at their fixed kind ids. Idempotent.
pub fn registerBuiltins() void {
    if (registered) return;
    widget.registerBuiltin(.root, widget.vtableOf(Root));
    widget.registerBuiltin(.box, widget.vtableOf(Box));
    widget.registerBuiltin(.text, widget.vtableOf(@import("text.zig").Text));
    widget.registerBuiltin(.view, widget.vtableOf(ViewBoundary));
    registered = true;
}

test "builtins register at fixed ids" {
    registerBuiltins();
    try std.testing.expectEqualStrings("box", widget.vtable(.box).name);
    try std.testing.expectEqualStrings("text", widget.vtable(.text).name);
    try std.testing.expectEqualStrings("view", widget.vtable(ids.KindId.view).name);
    _ = style_mod;
}
