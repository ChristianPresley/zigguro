//! Scroll containers and virtual lists (E04.F04).
//!
//! A scroll container is any box whose style sets `scroll_x`/`scroll_y`:
//! its children get unbounded space on that axis, paint shifted by the
//! node's offset and clip to it, and the window scrolls the innermost
//! container under the pointer on wheel and touchpad events. Scrolling
//! repaints without relayout. A thumb shows where the content fits.
//!
//! `virtualList` builds only the rows in (and just around) the viewport,
//! so a list of a million rows costs what its visible rows cost. Rows are
//! keyed by index, so their state survives scrolling while they stay in
//! range.

const std = @import("std");
const ids = @import("../core/ids.zig");
const ui_mod = @import("../core/ui.zig");
const window_mod = @import("../core/window.zig");
const style_mod = @import("../layout/style.zig");
const HeightIndex = @import("height_index.zig").HeightIndex;

const Ui = ui_mod.Ui;
const NodeId = ids.NodeId;
const Style = style_mod.Style;
const Window = window_mod.Window;

/// Options for `scrollArea`.
pub const ScrollOptions = struct {
    /// The container's style; the scroll axes and `clip` are set for you.
    style: Style = .{ .grow = 1, .dir = .column },
    x: bool = false,
    y: bool = true,
    test_id: []const u8 = "",
};

/// Opens a scroll container and returns its node; close it with
/// `ui.close()`.
pub fn scrollArea(ui: *Ui, opts: ScrollOptions) NodeId {
    var st = opts.style;
    st.scroll_x = opts.x;
    st.scroll_y = opts.y;
    ui.open(.{ .style = st, .test_id = opts.test_id });
    return ui.current();
}

/// Options for `virtualList`.
pub const ListOptions = struct {
    count: usize,
    /// Height of every row, unless `heights` is given.
    row_h: f32 = 22,
    /// Per-row heights (must have `count` rows).
    heights: ?*const HeightIndex = null,
    /// Rows built beyond each edge of the viewport.
    overscan: usize = 3,
    /// The scroll container's style (`scroll_y` and `dir = .column` are set).
    style: Style = .{ .grow = 1 },
    test_id: []const u8 = "",
};

/// What `virtualList` built.
pub const Visible = struct {
    /// The scroll container.
    node: NodeId,
    /// The first built row.
    first: usize,
    /// One past the last built row.
    end: usize,
};

/// Row geometry, uniform or from a `HeightIndex`.
const Rows = struct {
    opts: *const ListOptions,

    fn offset(r: Rows, i: usize) f32 {
        if (r.opts.heights) |h| return h.prefix(i);
        return @as(f32, @floatFromInt(i)) * r.opts.row_h;
    }

    fn height(r: Rows, i: usize) f32 {
        if (r.opts.heights) |h| return h.get(i);
        return r.opts.row_h;
    }

    fn at(r: Rows, y: f32) usize {
        if (r.opts.count == 0) return 0;
        if (r.opts.heights) |h| return h.find(y);
        if (r.opts.row_h <= 0) return 0;
        const i: usize = @intFromFloat(@max(0, @floor(y / r.opts.row_h)));
        return @min(i, r.opts.count - 1);
    }
};

/// Builds the visible rows of a `count`-row list: `row(ctx, ui, i)` emits
/// row `i` inside a box of the row's height. The view rebuilds when the
/// list scrolls.
pub fn virtualList(ui: *Ui, opts: ListOptions, ctx: anytype, comptime row: fn (@TypeOf(ctx), *Ui, usize) void) Visible {
    var st = opts.style;
    st.scroll_y = true;
    st.dir = .column;
    ui.open(.{ .style = st, .test_id = opts.test_id, .rebuild_on_scroll = true });
    defer ui.close();
    const node = ui.current();
    const win = ui.window();
    const rows: Rows = .{ .opts = &opts };

    var first: usize = 0;
    var end: usize = 0;
    if (opts.count > 0 and !node.isNone()) {
        const off = win.scrollOffset(node).y;
        var vh = win.store.relRect(node).h - st.padding.vertical() - 2 * st.border_w;
        if (vh <= 0) vh = win.size.h; // not laid out yet
        first = rows.at(off) -| opts.overscan;
        end = @min(opts.count, rows.at(off + vh) + 1 + opts.overscan);
    }

    const top = rows.offset(first);
    if (top > 0) {
        ui.id(@as([]const u8, "virtual-top"));
        ui.open(.{ .style = .{ .h = .{ .px = top }, .shrink = 0 } });
        ui.close();
    }
    var i = first;
    while (i < end) : (i += 1) {
        ui.id(@as(u64, i));
        ui.open(.{ .style = .{ .h = .{ .px = rows.height(i) }, .shrink = 0, .dir = .row, .align_items = .center } });
        row(ctx, ui, i);
        ui.close();
    }
    const bottom = rows.offset(opts.count) - rows.offset(end);
    if (bottom > 0) {
        ui.id(@as([]const u8, "virtual-bottom"));
        ui.open(.{ .style = .{ .h = .{ .px = bottom }, .shrink = 0 } });
        ui.close();
    }
    return .{ .node = node, .first = first, .end = end };
}

/// Scrolls a virtual list so row `i` is in view (top-aligned when it was
/// above, bottom-aligned when below).
pub fn scrollToRow(win: *Window, list: NodeId, opts: ListOptions, i: usize) void {
    if (opts.count == 0 or list.isNone()) return;
    const rows: Rows = .{ .opts = &opts };
    const idx = @min(i, opts.count - 1);
    const y0 = rows.offset(idx);
    const y1 = y0 + rows.height(idx);
    const st = &win.store.cold.items[list.index].style;
    const vh = win.store.relRect(list).h - st.padding.vertical() - 2 * st.border_w;
    const off = win.scrollOffset(list);
    if (y0 < off.y) {
        _ = win.scrollTo(list, .{ .x = off.x, .y = y0 });
    } else if (y1 > off.y + vh) {
        _ = win.scrollTo(list, .{ .x = off.x, .y = y1 - vh });
    }
}
