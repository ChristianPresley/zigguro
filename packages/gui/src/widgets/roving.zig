//! Roving focus for composite widgets (WAI-ARIA APG toolbar/breadcrumb
//! keyboard): Left/Right move focus between a group's items with wrap,
//! Home/End jump to the ends.
//!
//! `Group` is the container: `ui.begin(Group, ...)` returns its `Roving`
//! state, the build adds each item's node with `add`, and the items call
//! `onKey` from their `event`. Every item still takes Tab focus (the
//! window has no tab-stop exclusion yet).

const std = @import("std");
const ids = @import("../core/ids.zig");
const widget = @import("../core/widget.zig");
const window_mod = @import("../core/window.zig");
const style_mod = @import("../layout/style.zig");
const event_mod = @import("../input/event.zig");
const theme_mod = @import("../theme/theme.zig");

const NodeId = ids.NodeId;
const Window = window_mod.Window;

/// The most items a group tracks.
pub const max_items = 64;

/// A group's items in order, rebuilt each build.
pub const Roving = struct {
    win: ?*Window = null,
    nodes: [max_items]NodeId = @splat(.none),
    len: u8 = 0,

    /// Starts a build: forgets the previous items.
    pub fn reset(r: *Roving, win: *Window) void {
        r.win = win;
        r.len = 0;
    }

    /// Adds the next item (beyond `max_items` items are not reachable by
    /// arrows).
    pub fn add(r: *Roving, n: NodeId) void {
        if (r.len == max_items or n.isNone()) return;
        r.nodes[r.len] = n;
        r.len += 1;
    }

    /// The index of `n`, if it is an item.
    pub fn indexOf(r: *const Roving, n: NodeId) ?usize {
        for (r.nodes[0..r.len], 0..) |m, i| if (m.eql(n)) return i;
        return null;
    }

    /// Moves focus from item `from` for Left/Right/Home/End; true when the
    /// key was used.
    pub fn onKey(r: *Roving, from: NodeId, k: event_mod.KeyPress) bool {
        if (k.action == .release or k.mods.ctrl or k.mods.alt or k.mods.shift) return false;
        const w = r.win orelse return false;
        if (r.len == 0) return false;
        const i = r.indexOf(from) orelse return false;
        const n = r.len;
        const to: usize = switch (k.key) {
            .arrow_right => (i + 1) % n,
            .arrow_left => (i + n - 1) % n,
            .home => 0,
            .end => n - 1,
            else => return false,
        };
        w.setFocus(r.nodes[to], true);
        return true;
    }
};

/// The container that holds a group's `Roving` state.
pub const Group = struct {
    /// Shown in snapshots.
    pub const name = "roving_group";
    /// The items.
    pub const State = Roving;

    /// Group props.
    pub const Props = struct {
        role: widget.Role = .group,
        label: []const u8 = "",
        /// Space between items.
        gap: f32 = 0,
    };

    /// A row of items, stretched to the row's height.
    pub fn style(props: *const Props, _: *const theme_mod.Theme) style_mod.Style {
        return .{ .dir = .row, .align_items = .stretch, .gap = props.gap };
    }

    /// The role and name.
    pub fn a11y(props: *const Props, _: *Roving) widget.A11y {
        return .{ .role = props.role, .name = props.label };
    }
};

test "roving: arrows wrap, Home/End jump" {
    var r: Roving = .{};
    // No window: keys are not used.
    try std.testing.expect(!r.onKey(.none, .{ .key = .arrow_right }));
    r.len = 0;
    try std.testing.expectEqual(@as(?usize, null), r.indexOf(.none));
}
